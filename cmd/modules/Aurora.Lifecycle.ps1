# AURORA lifecycle functions

function Warm-Model {
    param(
        [string]$BaseUrl,
        [string]$ModelName,
        [int]$ContextLength
    )

    Write-Info "Loading model $ModelName into VRAM. This can take a while."
    try {
        Invoke-JsonPost -Uri "$($BaseUrl.TrimEnd('/'))/api/generate" -Body @{
            model       = $ModelName
            prompt      = "Reply with exactly OK."
            stream      = $false
            keep_alive  = -1
            options     = @{ num_ctx = $ContextLength }
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
        [string]$SearxngUrl,
        [string]$ModelName,
        [int]$ContextLength,
        [ValidateRange(0, 2)]
        [int]$VerboseLevel = 0,
        [switch]$SkipPull
    )

    Start-Searxng -BaseUrl $SearxngUrl
    Ensure-OllamaRunning -BaseUrl $BaseUrl
    Ensure-Model -ModelName $ModelName -SkipPull:$SkipPull
    Start-LocalProxy -OllamaUrl $BaseUrl -SearxngUrl $SearxngUrl -Port $ProxyPort -VerboseLevel $VerboseLevel
    Start-TailscaleServe -BaseUrl (Get-ProxyUrl -Port $ProxyPort) -Port $ServePort
    Warm-Model -BaseUrl $BaseUrl -ModelName $ModelName -ContextLength $ContextLength
    Show-Status -BaseUrl $BaseUrl -RemoteUrl $RemoteUrl -ModelName $ModelName -SearchUrl $SearxngUrl
    if ($VerboseLevel -gt 0) {
        Wait-VerboseSession -BaseUrl $BaseUrl -ModelName $ModelName -SearxngUrl $SearxngUrl -Port $ProxyPort -ServePort $ServePort
    }
}

function Wait-VerboseSession {
    param(
        [string]$BaseUrl,
        [string]$ModelName,
        [string]$SearxngUrl,
        [int]$Port,
        [int]$ServePort
    )

    Write-Info "Verbose session is active in this PowerShell. Press Ctrl+C to stop AURORA."
    try {
        while ($true) {
            $pidPath = Get-ProxyPidPath -Port $Port
            $proxyPid = 0
            if (-not (Test-Path -LiteralPath $pidPath) -or -not [int]::TryParse((Get-Content -LiteralPath $pidPath -Raw).Trim(), [ref]$proxyPid) -or -not (Get-LocalProxyProcess -ProcessId $proxyPid)) {
                throw "The local proxy stopped unexpectedly."
            }
            Start-Sleep -Milliseconds 500
        }
    }
    finally {
        Write-Info "Stopping AURORA verbose session."
        try { Stop-TailscaleServe -Port $ServePort } catch { Write-Warn $_.Exception.Message }
        try { Stop-LocalProxy -Port $Port } catch { Write-Warn $_.Exception.Message }
        try { Stop-Ollama -BaseUrl $BaseUrl -ModelName $ModelName } catch { Write-Warn $_.Exception.Message }
        try { Stop-Searxng -BaseUrl $SearxngUrl } catch { Write-Warn $_.Exception.Message }
    }
}

