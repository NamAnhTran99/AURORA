#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("start", "stop", "status", "run", "test", "context", "help")]
    [string]$Command = "help",

    [string]$Model = "gpt-oss:20b",
    [string]$LocalBaseUrl = "http://127.0.0.1:11434",
    [string]$Endpoint = "",
    [int]$ProxyPort = 11435,
    [int]$ServePort = 443,
    [switch]$SkipRemote,
    [switch]$NoPull,
    [string]$Prompt
)

$ErrorActionPreference = "Stop"

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

Import-AuroraDotEnv -Path (Join-Path $PSScriptRoot "..\.env")
if ([string]::IsNullOrWhiteSpace($Endpoint)) {
    $Endpoint = $env:AURORA_ENDPOINT
}

function Write-Info {
    param([string]$Message)
    Write-Host "[AURORA] $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "[FAIL] $Message" -ForegroundColor Red
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
    return Invoke-RestMethod -Uri $Uri -Method Post -Body $json -ContentType "application/json" -TimeoutSec $TimeoutSec
}

function Test-OllamaApi {
    param([string]$BaseUrl)

    try {
        $version = Invoke-RestMethod -Uri "$($BaseUrl.TrimEnd('/'))/api/version" -TimeoutSec 3
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

function Get-ProxyUrl {
    param([int]$Port)
    return "http://127.0.0.1:$Port"
}

function Get-ProxyPidPath {
    param([int]$Port)
    return Join-Path $env:TEMP "aurora-proxy-$Port.pid"
}

function Get-TailscalePidPath {
    param([int]$Port)
    return Join-Path $env:TEMP "aurora-tailscale-serve-$Port.pid"
}

function Get-TailscaleServeProcesses {
    param([int]$Port)

    $processInfo = Get-CimInstance Win32_Process -Filter "Name = 'tailscale.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match "\bserve\b" -and $_.CommandLine -like "*--https=$Port*" }

    foreach ($info in $processInfo) {
        Get-Process -Id $info.ProcessId -ErrorAction SilentlyContinue
    }
}

function Get-LocalProxyProcess {
    param([int]$ProcessId)

    if ($ProcessId -le 0) {
        return $null
    }

    $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
    if (-not $processInfo -or $processInfo.CommandLine -notmatch "AuroraProxy\.ps1") {
        return $null
    }

    return Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
}

function Start-LocalProxy {
    param(
        [string]$OllamaUrl,
        [int]$Port
    )

    $proxyUrl = Get-ProxyUrl -Port $Port
    $proxyScript = Join-Path $PSScriptRoot "AuroraProxy.ps1"
    $pidPath = Get-ProxyPidPath -Port $Port

    if (-not (Test-Path -LiteralPath $proxyScript -PathType Leaf)) {
        throw "Local proxy script was not found at $proxyScript."
    }

    if (Test-Path -LiteralPath $pidPath -PathType Leaf) {
        $existingPid = 0
        [int]::TryParse((Get-Content -LiteralPath $pidPath -Raw).Trim(), [ref]$existingPid) | Out-Null
        $existingProcess = Get-LocalProxyProcess -ProcessId $existingPid
        if ($existingProcess -and (Test-OllamaApi -BaseUrl $proxyUrl).Online) {
            Write-Ok "Local Ollama proxy is already running at $proxyUrl."
            return
        }
        Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
    }

    Write-Info "Starting local Ollama proxy at $proxyUrl."
    $proxyProcess = Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $proxyScript,
        "-ProxyPort", $Port,
        "-OllamaUrl", $OllamaUrl
    ) -WindowStyle Hidden -PassThru
    Set-Content -LiteralPath $pidPath -Value $proxyProcess.Id -Encoding ASCII

    $deadline = (Get-Date).AddSeconds(15)
    do {
        if ((Test-OllamaApi -BaseUrl $proxyUrl).Online) {
            Write-Ok "Local Ollama proxy is running at $proxyUrl."
            return
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    Stop-Process -Id $proxyProcess.Id -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
    throw "Local Ollama proxy did not become reachable at $proxyUrl."
}

function Stop-LocalProxy {
    param([int]$Port)

    $pidPath = Get-ProxyPidPath -Port $Port
    if (-not (Test-Path -LiteralPath $pidPath -PathType Leaf)) {
        Write-Ok "No AURORA local proxy process is registered."
        return
    }

    $proxyPid = 0
    [int]::TryParse((Get-Content -LiteralPath $pidPath -Raw).Trim(), [ref]$proxyPid) | Out-Null
    $proxyProcess = Get-LocalProxyProcess -ProcessId $proxyPid
    if ($proxyProcess) {
        Stop-Process -Id $proxyPid -Force
        Write-Ok "Local Ollama proxy stopped."
    }
    else {
        Write-Warn "Registered local Ollama proxy process was not found."
    }
    Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
}

function Format-Bytes {
    param([Nullable[long]]$Bytes)

    if ($null -eq $Bytes) {
        return "unknown"
    }

    $units = @("B", "KiB", "MiB", "GiB", "TiB")
    $value = [double]$Bytes
    $index = 0
    while ($value -ge 1024 -and $index -lt ($units.Count - 1)) {
        $value = $value / 1024
        $index++
    }

    return "{0:N2} {1}" -f $value, $units[$index]
}

function Get-OllamaPs {
    param([string]$BaseUrl)

    return Invoke-RestMethod -Uri "$($BaseUrl.TrimEnd('/'))/api/ps" -TimeoutSec 5
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

function Get-ProcessorSplit {
    param([object]$ModelState)

    $size = [Nullable[long]]$null
    $vram = [Nullable[long]]$null

    if ($null -ne $ModelState.size) {
        $size = [long]$ModelState.size
    }
    if ($null -ne $ModelState.size_vram) {
        $vram = [long]$ModelState.size_vram
    }

    if ($null -eq $size -or $size -le 0 -or $null -eq $vram) {
        return "unknown"
    }

    $gpuPct = [Math]::Round(([double]$vram / [double]$size) * 100, 1)
    if ($gpuPct -gt 100) {
        $gpuPct = 100
    }
    $cpuPct = [Math]::Round(100 - $gpuPct, 1)
    return "$gpuPct% GPU / $cpuPct% CPU ($((Format-Bytes $vram)) VRAM of $((Format-Bytes $size)) total)"
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

function Write-LoadedModelState {
    param(
        [object]$PsState,
        [string]$ModelName
    )

    $loaded = Find-LoadedModel -PsState $PsState -ModelName $ModelName
    if (-not $loaded) {
        Write-Host "Loaded state: unloaded"
        if ($PsState -and $PsState.models -and $PsState.models.Count -gt 0) {
            Write-Host "Other loaded models:"
            $PsState.models | ForEach-Object {
                Write-Host "  - $($_.name)"
            }
        }
        return $false
    }

    Write-Host "Loaded state: loaded"
    Write-Host "Model:        $($loaded.model)"
    Write-Host "Name:         $($loaded.name)"
    Write-Host "Processor:    $(Get-ProcessorSplit -ModelState $loaded)"
    Write-Host "Context size: $(Get-ContextSize -ModelState $loaded)"
    Write-Host "Expiry:       $($loaded.expires_at)"
    if ($loaded.details) {
        Write-Host "Format:       $($loaded.details.format)"
        Write-Host "Family:       $($loaded.details.family)"
        Write-Host "Parameters:   $($loaded.details.parameter_size)"
        Write-Host "Quantization: $($loaded.details.quantization_level)"
    }

    return $true
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

function Start-TailscaleServe {
    param(
        [string]$BaseUrl,
        [int]$Port
    )

    Assert-Command "tailscale" | Out-Null
    $pidPath = Get-TailscalePidPath -Port $Port
    $existing = @(Get-TailscaleServeProcesses -Port $Port)
    if ($existing.Count -gt 0) {
        Write-Warn "Tailscale Serve is already running for HTTPS port $Port."
        return
    }

    Write-Info "Publishing $BaseUrl through non-persistent Tailscale Serve on HTTPS port $Port."
    $serveProcess = Start-Process -FilePath "tailscale" -ArgumentList @("serve", "--yes", "--https=$Port", $BaseUrl) -WindowStyle Hidden -PassThru
    Set-Content -LiteralPath $pidPath -Value $serveProcess.Id -Encoding ASCII
    Start-Sleep -Milliseconds 750
    Write-Ok "Tailscale Serve is configured."
}

function Warm-Model {
    param(
        [string]$BaseUrl,
        [string]$ModelName
    )

    Write-Info "Loading model $ModelName into VRAM. This can take a while."
    try {
        Invoke-JsonPost -Uri "$($BaseUrl.TrimEnd('/'))/api/generate" -Body @{
            model  = $ModelName
            prompt = "Reply with exactly OK."
            stream = $false
        } -TimeoutSec 900 | Out-Null
    }
    catch {
        throw "Model warm-up failed: $($_.Exception.Message)"
    }

    $observed = Wait-ModelLoadedState -BaseUrl $BaseUrl -ModelName $ModelName -ShouldBeLoaded $true -TimeoutSec 30
    Write-Host ""
    Write-Info "Observed state after model warm-up:"
    Write-LoadedModelState -PsState $observed -ModelName $ModelName | Out-Null
}

function Invoke-AuroraStart {
    param(
        [string]$BaseUrl,
        [string]$RemoteUrl,
        [string]$ModelName,
        [switch]$SkipPull
    )

    Ensure-OllamaRunning -BaseUrl $BaseUrl
    Ensure-Model -ModelName $ModelName -SkipPull:$SkipPull
    Start-LocalProxy -OllamaUrl $BaseUrl -Port $ProxyPort
    Start-TailscaleServe -BaseUrl (Get-ProxyUrl -Port $ProxyPort) -Port $ServePort
    Warm-Model -BaseUrl $BaseUrl -ModelName $ModelName
    Show-Status -BaseUrl $BaseUrl -RemoteUrl $RemoteUrl -ModelName $ModelName
}

function Stop-TailscaleServe {
    param([int]$Port)

    $pidPath = Get-TailscalePidPath -Port $Port
    $serveProcesses = @(Get-TailscaleServeProcesses -Port $Port)
    if ($serveProcesses.Count -gt 0) {
        Write-Info "Stopping AURORA Tailscale Serve processes."
        $serveProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 750
    }
    Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue

    $tailscale = Get-CommandPath "tailscale"
    if (-not $tailscale) {
        Write-Warn "tailscale was not found; skipping Serve shutdown."
        return
    }

    $serveState = Get-TailscaleServeStatus
    if ($serveState.Available -and -not $serveState.Configured) {
        Write-Ok "No Tailscale Serve handler is configured."
        return
    }

    Write-Info "Disabling Tailscale Serve HTTPS port $Port."
    & tailscale serve "--https=$Port" off
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "Tailscale Serve is disabled for HTTPS port $Port."
    }
    else {
        Write-Warn "tailscale serve off exited with code $LASTEXITCODE."
    }

    $remaining = @(Get-TailscaleServeProcesses -Port $Port)
    if ($remaining.Count -gt 0) {
        $names = ($remaining | ForEach-Object { "$($_.ProcessName) [$($_.Id)]" }) -join ", "
        throw "Tailscale Serve processes are still running: $names"
    }
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

    $processes = @(Get-Process -Name "ollama*" -ErrorAction SilentlyContinue)
    if ($processes.Count -gt 0) {
        Write-Info "Stopping all Ollama processes."
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $processes | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 750
            $processes = @(Get-Process -Name "ollama*" -ErrorAction SilentlyContinue)
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

function Get-TailscaleServeStatus {
    $tailscale = Get-CommandPath "tailscale"
    if (-not $tailscale) {
        return [pscustomobject]@{
            Available = $false
            Raw       = "tailscale was not found on PATH."
        }
    }

    try {
        $raw = & tailscale serve status --json 2>&1
        $rawText = ($raw -join [Environment]::NewLine)
        $available = ($LASTEXITCODE -eq 0)
        return [pscustomobject]@{
            Available  = $available
            Configured = ($available -and $rawText.Trim() -ne "{}" -and -not [string]::IsNullOrWhiteSpace($rawText))
            Raw        = $rawText
        }
    }
    catch {
        return [pscustomobject]@{
            Available  = $false
            Configured = $false
            Raw        = $_.Exception.Message
        }
    }
}

function Show-Status {
    param(
        [string]$BaseUrl,
        [string]$RemoteUrl,
        [string]$ModelName
    )

    Write-Host "AURORA status"
    Write-Host "-------------"
    Write-Host "Model:        $ModelName"
    Write-Host "Local API:    $BaseUrl"
    $displayRemoteUrl = if ([string]::IsNullOrWhiteSpace($RemoteUrl)) { "(not configured; set AURORA_ENDPOINT)" } else { $RemoteUrl }
    Write-Host "Tailnet URL:  $displayRemoteUrl"
    Write-Host ""

    $ollama = Test-OllamaApi -BaseUrl $BaseUrl
    if ($ollama.Online) {
        Write-Ok "Ollama API online (version $($ollama.Version))."
    }
    else {
        Write-Fail "Ollama API offline: $($ollama.Error)"
    }

    $ollamaExe = Get-CommandPath "ollama"
    if ($ollamaExe) {
        Write-Ok "ollama CLI: $ollamaExe"
        if ($ollama.Online) {
            try {
                $models = & ollama list 2>$null
                $modelLine = $models | Where-Object { $_ -match "^\s*$([regex]::Escape($ModelName))\s" } | Select-Object -First 1
                if ($modelLine) {
                    Write-Ok "Model installed: $ModelName"
                }
                else {
                    Write-Warn "Model is not listed locally: $ModelName"
                }
            }
            catch {
                Write-Warn "Could not list Ollama models: $($_.Exception.Message)"
            }
        }
        else {
            Write-Warn "Skipping model list because the Ollama API is offline."
        }
    }
    else {
        Write-Fail "ollama CLI was not found on PATH."
    }

    if ($ollama.Online) {
        try {
            Write-Host ""
            Write-Info "Observed /api/ps state:"
            $running = Get-OllamaPs -BaseUrl $BaseUrl
            $modelLoaded = Write-LoadedModelState -PsState $running -ModelName $ModelName
            if ($modelLoaded) {
                Write-Ok "Model loaded: $ModelName"
            }
            else {
                Write-Warn "Model loaded: no ($ModelName)"
            }
        }
        catch {
            Write-Warn "Could not read loaded models from /api/ps: $($_.Exception.Message)"
        }
    }

    Write-Host ""
    $serve = Get-TailscaleServeStatus
    if ($serve.Available) {
        Write-Ok "Tailscale Serve status is available."
    }
    else {
        Write-Warn "Tailscale Serve status unavailable."
    }
    if ($serve.Raw) {
        Write-Host $serve.Raw
    }

    if ($serve.Configured -and -not [string]::IsNullOrWhiteSpace($RemoteUrl)) {
        Write-Ok "Tailscale URL: $RemoteUrl"
    }
    else {
        Write-Warn "Tailscale URL is not active."
    }
}

function Invoke-AuroraTest {
    param(
        [string]$BaseUrl,
        [string]$RemoteUrl,
        [string]$ModelName,
        [switch]$SkipRemoteTest,
        [string]$UserPrompt
    )

    $testPrompt = if ($UserPrompt) { $UserPrompt } else { "Reply with one short sentence confirming AURORA is online." }

    Write-Info "Testing local Ollama generation."
    $local = Invoke-JsonPost -Uri "$($BaseUrl.TrimEnd('/'))/api/generate" -Body @{
        model  = $ModelName
        prompt = $testPrompt
        stream = $false
    } -TimeoutSec 180
    $afterLocal = Wait-ModelLoadedState -BaseUrl $BaseUrl -ModelName $ModelName -ShouldBeLoaded $true -TimeoutSec 30
    Write-Ok "Local response:"
    Write-Host $local.response
    Write-Host ""
    Write-Info "Observed state after local test:"
    Write-LoadedModelState -PsState $afterLocal -ModelName $ModelName | Out-Null

    if ($SkipRemoteTest) {
        Write-Warn "Skipping remote endpoint test."
        return
    }

    if ([string]::IsNullOrWhiteSpace($RemoteUrl)) {
        Write-Warn "Skipping remote endpoint test because AURORA_ENDPOINT is not configured."
        return
    }

    Write-Host ""
    Write-Info "Testing Tailscale endpoint generation."
    $remote = Invoke-JsonPost -Uri "$($RemoteUrl.TrimEnd('/'))/api/generate" -Body @{
        model  = $ModelName
        prompt = $testPrompt
        stream = $false
    } -TimeoutSec 180
    $afterRemote = Wait-ModelLoadedState -BaseUrl $BaseUrl -ModelName $ModelName -ShouldBeLoaded $true -TimeoutSec 30
    Write-Ok "Remote response:"
    Write-Host $remote.response
    Write-Host ""
    Write-Info "Observed state after remote test:"
    Write-LoadedModelState -PsState $afterRemote -ModelName $ModelName | Out-Null
}

function Show-Context {
    param(
        [string]$BaseUrl,
        [string]$RemoteUrl,
        [string]$ModelName,
        [int]$ProxyPort
    )

    Write-Host "AURORA context"
    Write-Host "--------------"
    Write-Host "Model:        $ModelName"
    Write-Host "Local API:    $BaseUrl"
    $displayRemoteUrl = if ([string]::IsNullOrWhiteSpace($RemoteUrl)) { "(not configured; set AURORA_ENDPOINT)" } else { $RemoteUrl }
    Write-Host "Tailnet URL:  $displayRemoteUrl"
    $proxyUrl = Get-ProxyUrl -Port $ProxyPort
    Write-Host "Serve target: $proxyUrl via HTTPS port $ServePort"
    Write-Host ""
    Write-Host "Useful endpoints:"
    Write-Host "  GET  $($BaseUrl.TrimEnd('/'))/api/version"
    Write-Host "  GET  $($BaseUrl.TrimEnd('/'))/api/ps"
    Write-Host "  POST $($BaseUrl.TrimEnd('/'))/api/generate"
    Write-Host "  POST $($RemoteUrl.TrimEnd('/'))/api/generate"
    Write-Host ""

    $probe = Test-OllamaApi -BaseUrl $BaseUrl
    if (-not $probe.Online) {
        Write-Warn "Ollama is offline, so model metadata cannot be loaded."
        return
    }

    try {
        $show = Invoke-JsonPost -Uri "$($BaseUrl.TrimEnd('/'))/api/show" -Body @{
            model = $ModelName
        } -TimeoutSec 30

        if ($show.details) {
            Write-Host "Model details:"
            $show.details.PSObject.Properties | ForEach-Object {
                Write-Host "  $($_.Name): $($_.Value)"
            }
        }

        if ($show.model_info) {
            Write-Host ""
            Write-Host "Context-related model info:"
            $show.model_info.PSObject.Properties |
                Where-Object { $_.Name -match "context|embedding|block_count|attention" } |
                ForEach-Object { Write-Host "  $($_.Name): $($_.Value)" }
        }
    }
    catch {
        Write-Warn "Could not read model metadata: $($_.Exception.Message)"
    }
}

function Show-Help {
    Write-Host @"
AURORA - Windows PowerShell CLI for local Ollama + Tailscale Serve

Usage:
  .\Aurora.ps1 start    [-NoPull]
  .\Aurora.ps1 run      [-NoPull]                         # alias for start
  .\Aurora.ps1 stop
  .\Aurora.ps1 status
  .\Aurora.ps1 test     [-SkipRemote] [-Prompt "Say hello"]
  .\Aurora.ps1 context

Defaults:
  Model:       $Model
  Local API:   $LocalBaseUrl
  Endpoint:    $(if ([string]::IsNullOrWhiteSpace($Endpoint)) { "(not configured; set AURORA_ENDPOINT)" } else { $Endpoint })
  Proxy port:  $ProxyPort
  Serve port:  $ServePort

Start configures:
  tailscale serve --https=$ServePort http://127.0.0.1:$ProxyPort
"@
}

try {
    switch ($Command) {
        "start" {
            Invoke-AuroraStart -BaseUrl $LocalBaseUrl -RemoteUrl $Endpoint -ModelName $Model -SkipPull:$NoPull
        }
        "run" {
            Invoke-AuroraStart -BaseUrl $LocalBaseUrl -RemoteUrl $Endpoint -ModelName $Model -SkipPull:$NoPull
        }
        "stop" {
            Stop-TailscaleServe -Port $ServePort
            Stop-LocalProxy -Port $ProxyPort
            Stop-Ollama -BaseUrl $LocalBaseUrl -ModelName $Model
        }
        "status" {
            Show-Status -BaseUrl $LocalBaseUrl -RemoteUrl $Endpoint -ModelName $Model
        }
        "test" {
            Invoke-AuroraTest -BaseUrl $LocalBaseUrl -RemoteUrl $Endpoint -ModelName $Model -SkipRemoteTest:$SkipRemote -UserPrompt $Prompt
        }
        "context" {
            Show-Context -BaseUrl $LocalBaseUrl -RemoteUrl $Endpoint -ModelName $Model -ProxyPort $ProxyPort
        }
        default {
            Show-Help
        }
    }
}
catch {
    Write-Fail $_.Exception.Message
    exit 1
}
