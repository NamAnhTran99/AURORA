# AURORA SearXNG service functions

function Test-Searxng {
    param([string]$BaseUrl)

    try {
        Invoke-RestMethod -Uri "$($BaseUrl.TrimEnd('/'))/config" -TimeoutSec 3 -Verbose:$false | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Invoke-SearxngCompose {
    param([string[]]$Arguments)

    $composePath = Join-Path $SearxngDir "docker-compose.yml"
    if (-not (Test-Path -LiteralPath $composePath -PathType Leaf)) {
        throw "SearXNG Compose file was not found at $composePath."
    }
    & docker compose -f $composePath @Arguments
    if ($LASTEXITCODE -ne 0) { throw "SearXNG Docker Compose failed with exit code $LASTEXITCODE." }
}

function Start-Searxng {
    param([string]$BaseUrl)

    Assert-Command "docker" | Out-Null
    if (-not (Test-Searxng -BaseUrl $BaseUrl)) {
        Write-Info "Starting local SearXNG."
        Invoke-SearxngCompose -Arguments @("up", "-d")
    }
    $deadline = (Get-Date).AddSeconds(60)
    do {
        if (Test-Searxng -BaseUrl $BaseUrl) {
            Write-Ok "SearXNG is online at $BaseUrl."
            return
        }
        Start-Sleep -Milliseconds 750
    } while ((Get-Date) -lt $deadline)
    throw "SearXNG did not become reachable at $BaseUrl."
}

function Stop-Searxng {
    param([string]$BaseUrl)

    Assert-Command "docker" | Out-Null
    Invoke-SearxngCompose -Arguments @("down")
    if (Test-Searxng -BaseUrl $BaseUrl) { throw "SearXNG is still reachable at $BaseUrl." }
    Write-Ok "SearXNG is offline."
}

function Show-SearxngStatus {
    param([string]$BaseUrl)
    if (Test-Searxng -BaseUrl $BaseUrl) { Write-Ok "SearXNG API online at $BaseUrl." }
    else { Write-Warn "SearXNG API offline at $BaseUrl." }
}
