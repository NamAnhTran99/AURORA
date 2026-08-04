#!/usr/bin/env pwsh
param(
    [ValidateSet("start", "stop", "status", "run", "test", "context", "help")]
    [string]$Command = "help",

    [string]$Model = "",
    [int]$ContextLength = 0,
    [string]$LocalBaseUrl = "http://127.0.0.1:11434",
    [string]$Endpoint = "",
    [int]$ProxyPort = 11435,
    [int]$ServePort = 443,
    [switch]$SkipRemote,
    [switch]$NoPull,
    [ValidateRange(0, 2)]
    [int]$Verbose = 0,
    [string]$Prompt
)

$ErrorActionPreference = "Stop"
$AuroraRoot = $PSScriptRoot

$moduleRoot = Join-Path $PSScriptRoot "modules"
. (Join-Path $moduleRoot "Aurora.Output.ps1")
. (Join-Path $moduleRoot "Aurora.Core.ps1")
. (Join-Path $moduleRoot "Aurora.Network.ps1")
. (Join-Path $moduleRoot "Aurora.Lifecycle.ps1")

Import-AuroraDotEnv -Path (Join-Path $AuroraRoot "..\.env")
if ([string]::IsNullOrWhiteSpace($Model)) {
    $Model = if ([string]::IsNullOrWhiteSpace($env:AURORA_MODEL)) { "qwen3:14b" } else { $env:AURORA_MODEL }
}
if ($ContextLength -le 0) {
    $ContextLength = if ([string]::IsNullOrWhiteSpace($env:AURORA_CONTEXT_LENGTH)) { 32768 } else { [int]$env:AURORA_CONTEXT_LENGTH }
}
if ($ContextLength -le 0) {
    throw "Context length must be greater than zero."
}
if ([string]::IsNullOrWhiteSpace($Endpoint)) {
    $Endpoint = $env:AURORA_ENDPOINT
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
  .\Aurora.ps1 start    [-Model "model:tag"] [-ContextLength 32768] [-NoPull]
  .\Aurora.ps1 run      [-Model "model:tag"] [-ContextLength 32768] [-NoPull] # alias for start
  .\Aurora.ps1 stop     [-Model "model:tag"]
  .\Aurora.ps1 status   [-Model "model:tag"]
  .\Aurora.ps1 test     [-Model "model:tag"] [-SkipRemote] [-Prompt "Say hello"]
  .\Aurora.ps1 context  [-Model "model:tag"]

Verbose levels:
  -Verbose 0  Silent (default)
  -Verbose 1  Request/response metadata
  -Verbose 2  Full request/response payload previews

Defaults:
  Model:       $Model
  Context:     $ContextLength
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
            Invoke-AuroraStart -BaseUrl $LocalBaseUrl -RemoteUrl $Endpoint -ModelName $Model -ContextLength $ContextLength -VerboseLevel $Verbose -SkipPull:$NoPull
        }
        "run" {
            Invoke-AuroraStart -BaseUrl $LocalBaseUrl -RemoteUrl $Endpoint -ModelName $Model -ContextLength $ContextLength -VerboseLevel $Verbose -SkipPull:$NoPull
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
