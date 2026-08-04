# AURORA proxy and Tailscale functions

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

    $processInfo = Get-CimInstance Win32_Process -Filter "Name = 'tailscale.exe'" -ErrorAction SilentlyContinue -Verbose:$false |
        Where-Object { $_.CommandLine -match "\bserve\b" -and $_.CommandLine -like "*--https=$Port*" }

    foreach ($info in $processInfo) {
        Get-Process -Id $info.ProcessId -ErrorAction SilentlyContinue -Verbose:$false
    }
}

function Get-LocalProxyProcess {
    param([int]$ProcessId)

    if ($ProcessId -le 0) {
        return $null
    }

    $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue -Verbose:$false
    if (-not $processInfo -or $processInfo.CommandLine -notmatch "AuroraProxy\.ps1") {
        return $null
    }

    return Get-Process -Id $ProcessId -ErrorAction SilentlyContinue -Verbose:$false
}

function Start-LocalProxy {
    param(
        [string]$OllamaUrl,
        [string]$SearxngUrl = "http://127.0.0.1:8080",
        [int]$Port,
        [ValidateRange(0, 2)]
        [int]$VerboseLevel = 0
    )

    $proxyUrl = Get-ProxyUrl -Port $Port
    $proxyScript = Join-Path $AuroraRoot "AuroraProxy.ps1"
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
    $proxyArguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass"
    )
    $proxyArguments += @(
        "-File", $proxyScript,
        "-ProxyPort", $Port,
        "-OllamaUrl", $OllamaUrl,
        "-SearxngUrl", $SearxngUrl
    )
    $traceEnabled = $VerboseLevel -gt 0
    if ($traceEnabled) {
        $proxyArguments += @("-VerboseLevel", $VerboseLevel, "-ConsoleTrace")
    }
    if ($traceEnabled) {
        $proxyProcess = Start-Process -FilePath "powershell.exe" -ArgumentList $proxyArguments -NoNewWindow -PassThru
    }
    else {
        $proxyProcess = Start-Process -FilePath "powershell.exe" -ArgumentList $proxyArguments -WindowStyle Hidden -PassThru
    }
    Set-Content -LiteralPath $pidPath -Value $proxyProcess.Id -Encoding ASCII

    $deadline = (Get-Date).AddSeconds(15)
    do {
        if ((Test-OllamaApi -BaseUrl $proxyUrl).Online) {
            Write-Ok "Local Ollama proxy is running at $proxyUrl."
            if ($VerboseLevel -gt 0) {
                Write-Info "Live proxy trace is attached to this PowerShell window."
            }
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
