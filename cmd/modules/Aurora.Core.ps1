# AURORA core and Ollama functions

function Import-AuroraDotEnv {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
            $name = $Matches[1]
            $value = $Matches[2]
            if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            [Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }
    }
}

function Get-CommandPath {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        return $null
    }
    return $cmd.Source
}

function Assert-Command {
    param([string]$Name)
    $path = Get-CommandPath $Name
    if (-not $path) {
        throw "Required command '$Name' was not found on PATH."
    }
    return $path
}

function Invoke-JsonPost {
    param(
        [string]$Uri,
        [hashtable]$Body,
        [int]$TimeoutSec = 120
    )

    $json = $Body | ConvertTo-Json -Depth 10 -Compress
    return Invoke-RestMethod -Uri $Uri -Method Post -Body $json -ContentType "application/json" -TimeoutSec $TimeoutSec -Verbose:$false
}

function Test-OllamaApi {
    param([string]$BaseUrl)

    try {
        $version = Invoke-RestMethod -Uri "$($BaseUrl.TrimEnd('/'))/api/version" -TimeoutSec 3 -Verbose:$false
        return [pscustomobject]@{
            Online  = $true
            Version = $version.version
            Error   = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Online  = $false
            Version = $null
            Error   = $_.Exception.Message
        }
    }
}

function Wait-Ollama {
    param(
        [string]$BaseUrl,
        [int]$TimeoutSec = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $probe = Test-OllamaApi -BaseUrl $BaseUrl
        if ($probe.Online) {
            return $probe
        }
        Start-Sleep -Milliseconds 750
    } while ((Get-Date) -lt $deadline)

    throw "Ollama did not become reachable at $BaseUrl within $TimeoutSec seconds."
}

function Get-OllamaPs {
    param([string]$BaseUrl)

    return Invoke-RestMethod -Uri "$($BaseUrl.TrimEnd('/'))/api/ps" -TimeoutSec 5 -Verbose:$false
}

function Find-LoadedModel {
    param(
        [object]$PsState,
        [string]$ModelName
    )

    if (-not $PsState -or -not $PsState.models) {
        return $null
    }

    return $PsState.models |
        Where-Object { $_.name -eq $ModelName -or $_.model -eq $ModelName } |
        Select-Object -First 1
}

function Get-ContextSize {
    param([object]$ModelState)

    foreach ($property in @("context_length", "context_size", "num_ctx", "num_ctx_train")) {
        if ($ModelState.PSObject.Properties.Name -contains $property -and $null -ne $ModelState.$property) {
            return $ModelState.$property
        }
    }

    if ($ModelState.model_info) {
        foreach ($property in $ModelState.model_info.PSObject.Properties) {
            if ($property.Name -match "context" -and $null -ne $property.Value) {
                return $property.Value
            }
        }
    }

    return "unknown"
}

function Wait-ModelLoadedState {
    param(
        [string]$BaseUrl,
        [string]$ModelName,
        [bool]$ShouldBeLoaded,
        [int]$TimeoutSec = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $lastState = $null
    do {
        $lastState = Get-OllamaPs -BaseUrl $BaseUrl
        $loaded = $null -ne (Find-LoadedModel -PsState $lastState -ModelName $ModelName)
        if ($loaded -eq $ShouldBeLoaded) {
            return $lastState
        }
        Start-Sleep -Milliseconds 750
    } while ((Get-Date) -lt $deadline)

    Write-Host ""
    Write-Warn "Observed state did not match requested state before timeout."
    Write-LoadedModelState -PsState $lastState -ModelName $ModelName | Out-Null
    $wanted = if ($ShouldBeLoaded) { "loaded" } else { "unloaded" }
    throw "Model $ModelName was not observed as $wanted within $TimeoutSec seconds."
}

function Ensure-OllamaRunning {
    param([string]$BaseUrl)

    Assert-Command "ollama" | Out-Null
    $probe = Test-OllamaApi -BaseUrl $BaseUrl
    if ($probe.Online) {
        Write-Ok "Ollama is already running at $BaseUrl (version $($probe.Version))."
        return
    }

    Write-Info "Starting Ollama server."
    Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden | Out-Null
    $probe = Wait-Ollama -BaseUrl $BaseUrl -TimeoutSec 45
    Write-Ok "Ollama is running at $BaseUrl (version $($probe.Version))."
}

function Ensure-Model {
    param(
        [string]$ModelName,
        [switch]$SkipPull
    )

    if ($SkipPull) {
        Write-Warn "Skipping model availability check because -NoPull was set."
        return
    }

    Assert-Command "ollama" | Out-Null
    $list = & ollama list 2>$null
    $found = $false
    foreach ($line in $list) {
        if ($line -match "^\s*$([regex]::Escape($ModelName))\s") {
            $found = $true
            break
        }
    }

    if ($found) {
        Write-Ok "Model $ModelName is installed."
        return
    }

    Write-Info "Pulling model $ModelName. This can take a while."
    & ollama pull $ModelName
    if ($LASTEXITCODE -ne 0) {
        throw "ollama pull $ModelName failed with exit code $LASTEXITCODE."
    }
    Write-Ok "Model $ModelName is installed."
}

function Get-OllamaProcesses {
    return @(Get-Process -ErrorAction SilentlyContinue -Verbose:$false | Where-Object {
        $_.ProcessName -like "ollama*" -or $_.ProcessName -eq "llama-server"
    })
}

function Stop-Ollama {
    param(
        [string]$BaseUrl,
        [string]$ModelName
    )

    $probe = Test-OllamaApi -BaseUrl $BaseUrl
    if ($probe.Online) {
        Write-Host ""
        Write-Info "Observed state before unload:"
        $before = Get-OllamaPs -BaseUrl $BaseUrl
        Write-LoadedModelState -PsState $before -ModelName $ModelName | Out-Null

        Write-Info "Unloading model $ModelName."
        try {
            Invoke-JsonPost -Uri "$($BaseUrl.TrimEnd('/'))/api/generate" -Body @{
                model      = $ModelName
                keep_alive = 0
            } -TimeoutSec 20 | Out-Null
            $afterUnload = Wait-ModelLoadedState -BaseUrl $BaseUrl -ModelName $ModelName -ShouldBeLoaded $false -TimeoutSec 30
            Write-Host ""
            Write-Info "Observed state after unload:"
            Write-LoadedModelState -PsState $afterUnload -ModelName $ModelName | Out-Null
            Write-Ok "Model $ModelName is observed unloaded."
        }
        catch {
            throw "Model unload failed or was not observed: $($_.Exception.Message)"
        }
    }

    $processes = @(Get-OllamaProcesses)
    if ($processes.Count -gt 0) {
        Write-Info "Stopping all Ollama processes."
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $processes | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 750
            $processes = @(Get-OllamaProcesses)
            if ($processes.Count -eq 0) {
                break
            }
            Write-Warn "Ollama processes are still present; retrying shutdown."
        }
    }

    if ($processes.Count -gt 0) {
        $names = ($processes | ForEach-Object { "$($_.ProcessName) [$($_.Id)]" }) -join ", "
        throw "Ollama processes are still running after shutdown attempts: $names"
    }

    $afterStop = Test-OllamaApi -BaseUrl $BaseUrl
    if ($afterStop.Online) {
        throw "Ollama process stop was requested, but the API is still reachable at $BaseUrl."
    }
    Write-Ok "All Ollama processes stopped; API is offline."
}
