# AURORA internal tool registry

$script:AuroraToolRegistry = [ordered]@{}

function Register-AuroraTool {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [object]$Definition,
        [Parameter(Mandatory)] [scriptblock]$Handler
    )

    $script:AuroraToolRegistry[$Name] = [pscustomobject]@{
        Definition = $Definition
        Handler    = $Handler
    }
}

function Get-AuroraToolDefinition {
    param([Parameter(Mandatory)] [string]$Name)

    $tool = $script:AuroraToolRegistry[$Name]
    if ($null -eq $tool) { throw "AURORA tool is not registered: $Name" }
    Write-Output -NoEnumerate $tool.Definition
}

function Get-AuroraToolDefinitions {
    return @($script:AuroraToolRegistry.Values | ForEach-Object { Write-Output -NoEnumerate $_.Definition })
}

function Invoke-AuroraTool {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [object]$Arguments,
        [hashtable]$Context = @{}
    )

    $tool = $script:AuroraToolRegistry[$Name]
    if ($null -eq $tool) { throw "AURORA tool is not registered: $Name" }
    return & $tool.Handler $Arguments $Context
}

Register-AuroraTool -Name "web_search" -Definition ([ordered]@{
    type = "function"
    function = [ordered]@{
        name = "web_search"
        description = "Search the web when current, uncertain, or external information is needed. Return concise source-backed results."
        parameters = [ordered]@{
            type = "object"
            required = @("query")
            properties = [ordered]@{
                query = [ordered]@{ type = "string"; description = "The web search query" }
                max_results = [ordered]@{ type = "integer"; description = "Maximum results, from 1 to 10" }
            }
        }
    }
}) -Handler {
    param($Arguments, $Context)

    $query = [string]$Arguments.query
    if ([string]::IsNullOrWhiteSpace($query)) {
        return (@{ error = "web_search requires a non-empty query" } | ConvertTo-Json -Compress)
    }

    $maxResults = 5
    if ($Arguments.max_results) { $maxResults = [Math]::Min(10, [Math]::Max(1, [int]$Arguments.max_results)) }

    try {
        $encoded = [Uri]::EscapeDataString($query)
        $baseUrl = [string]$Context.SearxngUrl
        $response = Invoke-RestMethod -Uri "$($baseUrl.TrimEnd('/'))/search?q=$encoded&format=json" -TimeoutSec 30 -Verbose:$false
        $results = @($response.results) | Select-Object -First $maxResults | ForEach-Object {
            [ordered]@{ title = $_.title; url = $_.url; snippet = $_.content }
        }
        return (@{ query = $query; results = @($results) } | ConvertTo-Json -Depth 10 -Compress)
    }
    catch {
        return (@{ query = $query; error = $_.Exception.Message; results = @() } | ConvertTo-Json -Compress)
    }
}
