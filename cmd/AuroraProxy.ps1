[CmdletBinding()]
param(
    [int]$ProxyPort = 11435,
    [string]$OllamaUrl = "http://127.0.0.1:11434",
    [string]$SearxngUrl = "http://127.0.0.1:8080",
    [ValidateRange(0, 2)]
    [int]$VerboseLevel = 0,
    [switch]$ConsoleTrace
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Net.Http

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$ProxyPort/")
$listener.Start()

$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromMinutes(15)
$hopByHopHeaders = @("Connection", "Keep-Alive", "Proxy-Authenticate", "Proxy-Authorization", "TE", "Trailer", "Transfer-Encoding", "Upgrade")

function Get-TracePreview {
    param([byte[]]$Bytes)

    if ($null -eq $Bytes -or $Bytes.Length -eq 0) {
        return "(empty)"
    }

    $text = [Text.Encoding]::UTF8.GetString($Bytes) -replace "\s+", " "
    if ($text.Length -gt 2000) {
        return $text.Substring(0, 2000) + "... [truncated]"
    }
    return $text
}

function Write-Trace {
    param([string]$Message)

    if ($VerboseLevel -lt 1) {
        return
    }

    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Message
    if ($ConsoleTrace) {
        Write-Host $line
    }
}

function Write-ProxyError {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [int]$StatusCode,
        [string]$Message
    )

    $payload = [Text.Encoding]::UTF8.GetBytes((@{ error = $Message } | ConvertTo-Json -Compress))
    $Response.StatusCode = $StatusCode
    $Response.ContentType = "application/json"
    $Response.ContentLength64 = $payload.Length
    $Response.OutputStream.Write($payload, 0, $payload.Length)
    $Response.Close()
}

$searchTool = [ordered]@{
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
}

function Invoke-WebSearch {
    param(
        [string]$Query,
        [int]$MaxResults = 5
    )

    if ([string]::IsNullOrWhiteSpace($Query)) {
        return (@{ error = "web_search requires a non-empty query" } | ConvertTo-Json -Compress)
    }

    try {
        $encoded = [Uri]::EscapeDataString($Query)
        $response = Invoke-RestMethod -Uri "$($SearxngUrl.TrimEnd('/'))/search?q=$encoded&format=json" -TimeoutSec 30 -Verbose:$false
        $results = @($response.results) | Select-Object -First $MaxResults | ForEach-Object {
            [ordered]@{ title = $_.title; url = $_.url; snippet = $_.content }
        }
        return (@{ query = $Query; results = @($results) } | ConvertTo-Json -Depth 10 -Compress)
    }
    catch {
        return (@{ query = $Query; error = $_.Exception.Message; results = @() } | ConvertTo-Json -Compress)
    }
}

function Invoke-ChatWithWebSearch {
    param([object]$Payload)

    $messages = New-Object System.Collections.ArrayList
    foreach ($message in @($Payload.messages | Where-Object { $null -ne $_ })) { [void]$messages.Add($message) }

    $tools = New-Object System.Collections.ArrayList
    foreach ($tool in @($Payload.tools | Where-Object { $null -ne $_ })) {
        if ($tool.function.name -ne "web_search") { [void]$tools.Add($tool) }
    }
    [void]$tools.Add($searchTool)

    for ($round = 1; $round -le 4; $round++) {
        $request = [ordered]@{}
        foreach ($property in $Payload.PSObject.Properties) {
            if ($property.Name -notin @("messages", "tools", "stream")) { $request[$property.Name] = $property.Value }
        }
        $request.model = $Payload.model
        $request.messages = @($messages)
        $request.tools = @($tools)
        $request.stream = $false
        $request.keep_alive = -1
        $json = $request | ConvertTo-Json -Depth 30 -Compress

        Write-Trace "WEB_CHAT round=$round messages=$($messages.Count)"
        if ($VerboseLevel -ge 2) { Write-Trace "WEB_CHAT_REQUEST_BODY $json" }
        $response = Invoke-WebRequest -Uri "$($OllamaUrl.TrimEnd('/'))/api/chat" -Method Post -Body $json -ContentType "application/json" -TimeoutSec 900 -UseBasicParsing
        $raw = $response.Content
        $decoded = $raw | ConvertFrom-Json
        $toolCalls = @($decoded.message.tool_calls | Where-Object { $null -ne $_ })
        Write-Trace "WEB_CHAT_RESPONSE status=$($response.StatusCode) tool_calls=$($toolCalls.Count)"
        if ($VerboseLevel -ge 2) { Write-Trace "WEB_CHAT_RESPONSE_BODY $raw" }

        if ($toolCalls.Count -eq 0) { return $raw }

        $webCalls = @($toolCalls | Where-Object { $_.function.name -eq "web_search" })
        if ($webCalls.Count -eq 0) { return $raw }
        [void]$messages.Add($decoded.message)
        foreach ($call in $webCalls) {
            $arguments = $call.function.arguments
            if ($arguments -is [string]) { $arguments = $arguments | ConvertFrom-Json }
            $query = [string]$arguments.query
            $maxResults = 5
            if ($arguments.max_results) { $maxResults = [Math]::Min(10, [Math]::Max(1, [int]$arguments.max_results)) }
            $result = Invoke-WebSearch -Query $query -MaxResults $maxResults
            Write-Trace "WEB_SEARCH query=$query"
            if ($VerboseLevel -ge 2) { Write-Trace "WEB_SEARCH_RESULT $result" }
            [void]$messages.Add([pscustomobject]@{ role = "tool"; tool_name = "web_search"; content = $result })
        }
    }

    throw "Web-search tool loop exceeded its four-round limit."
}

function Invoke-StreamingChatWithWebSearch {
    param([object]$Payload)

    $messages = New-Object System.Collections.ArrayList
    foreach ($message in @($Payload.messages | Where-Object { $null -ne $_ })) { [void]$messages.Add($message) }

    $tools = New-Object System.Collections.ArrayList
    foreach ($tool in @($Payload.tools | Where-Object { $null -ne $_ })) {
        if ($tool.function.name -ne "web_search") { [void]$tools.Add($tool) }
    }
    [void]$tools.Add($searchTool)

    for ($round = 1; $round -le 4; $round++) {
        $request = [ordered]@{}
        foreach ($property in $Payload.PSObject.Properties) {
            if ($property.Name -notin @("messages", "tools")) { $request[$property.Name] = $property.Value }
        }
        $request.model = $Payload.model
        $request.messages = @($messages)
        $request.tools = @($tools)
        $request.stream = $true
        $request.keep_alive = -1
        $json = $request | ConvertTo-Json -Depth 30 -Compress

        Write-Trace "WEB_STREAM round=$round messages=$($messages.Count)"
        if ($VerboseLevel -ge 2) { Write-Trace "WEB_STREAM_REQUEST_BODY $json" }
        $response = Invoke-WebRequest -Uri "$($OllamaUrl.TrimEnd('/'))/api/chat" -Method Post -Body $json -ContentType "application/json" -TimeoutSec 900 -UseBasicParsing
        $streamBody = if ($response.Content -is [byte[]]) {
            [Text.Encoding]::UTF8.GetString($response.Content)
        }
        else {
            [string]$response.Content
        }
        $rawLines = @($streamBody -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $decodedLines = @($rawLines | ForEach-Object {
            try { $_ | ConvertFrom-Json } catch { $null }
        } | Where-Object { $null -ne $_ })
        $toolCalls = @($decodedLines | ForEach-Object { @($_.message.tool_calls | Where-Object { $null -ne $_ }) })
        $webCalls = @($toolCalls | Where-Object { $_.function.name -eq "web_search" })

        Write-Trace "WEB_STREAM_RESPONSE status=$($response.StatusCode) tool_calls=$($toolCalls.Count)"
        if ($VerboseLevel -ge 2) { Write-Trace "WEB_STREAM_RESPONSE_BODY $streamBody" }

        if ($webCalls.Count -eq 0) {
            return (($rawLines -join [Environment]::NewLine) + [Environment]::NewLine)
        }

        if ($toolCalls.Count -ne $webCalls.Count) {
            return (($rawLines -join [Environment]::NewLine) + [Environment]::NewLine)
        }

        $assistantMessage = $null
        foreach ($decoded in $decodedLines) {
            if ($decoded.message -and $decoded.message.tool_calls) {
                $assistantMessage = $decoded.message
            }
        }
        if ($assistantMessage) { [void]$messages.Add($assistantMessage) }

        foreach ($call in $webCalls) {
            $arguments = $call.function.arguments
            if ($arguments -is [string]) { $arguments = $arguments | ConvertFrom-Json }
            $query = [string]$arguments.query
            $maxResults = 5
            if ($arguments.max_results) { $maxResults = [Math]::Min(10, [Math]::Max(1, [int]$arguments.max_results)) }
            $result = Invoke-WebSearch -Query $query -MaxResults $maxResults
            Write-Trace "WEB_SEARCH query=$query"
            if ($VerboseLevel -ge 2) { Write-Trace "WEB_SEARCH_RESULT $result" }
            [void]$messages.Add([pscustomobject]@{ role = "tool"; tool_name = "web_search"; content = $result })
        }
    }

    throw "Web-search tool loop exceeded its four-round limit."
}

function Write-RawJsonResponse {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [string]$Body
    )

    $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
    $Response.StatusCode = 200
    $Response.ContentType = "application/json"
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.Close()
}

function Write-RawResponse {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [string]$Body,
        [string]$ContentType
    )

    $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
    $Response.StatusCode = 200
    $Response.ContentType = $ContentType
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.Close()
}

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        $requestMessage = $null
        $responseMessage = $null
        $bodyText = $null

        try {
            $query = if ($request.Url.Query) { $request.Url.Query } else { "" }
            $targetUri = "$($OllamaUrl.TrimEnd('/'))$($request.Url.AbsolutePath)$query"
            Write-Trace "REQUEST $($request.HttpMethod) $($request.Url.AbsolutePath)$query"
            $requestMessage = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::new($request.HttpMethod), $targetUri)
            $requestMessage.Headers.Host = "localhost:11434"

            foreach ($headerName in $request.Headers.AllKeys) {
                if ($headerName -eq "Host" -or $hopByHopHeaders -contains $headerName) {
                    continue
                }
                $requestMessage.Headers.TryAddWithoutValidation($headerName, $request.Headers[$headerName]) | Out-Null
            }

            if ($request.HasEntityBody) {
                $body = New-Object System.IO.MemoryStream
                $request.InputStream.CopyTo($body)
                $body.Position = 0
                $bodyText = [Text.Encoding]::UTF8.GetString($body.ToArray())
                if ($VerboseLevel -ge 2) {
                    Write-Trace "REQUEST_BODY $(Get-TracePreview -Bytes $body.ToArray())"
                }

                if ($request.Url.AbsolutePath -eq "/api/chat") {
                    $chatPayload = $bodyText | ConvertFrom-Json
                    if ([bool]$chatPayload.stream) {
                        $rawChatResponse = Invoke-StreamingChatWithWebSearch -Payload $chatPayload
                        Write-RawResponse -Response $response -Body $rawChatResponse -ContentType "application/x-ndjson"
                        continue
                    }
                    else {
                        $rawChatResponse = Invoke-ChatWithWebSearch -Payload $chatPayload
                        if ($VerboseLevel -ge 2) { Write-Trace "FINAL_RESPONSE_BODY $rawChatResponse" }
                        Write-RawJsonResponse -Response $response -Body $rawChatResponse
                        continue
                    }
                }

                $requestMessage.Content = New-Object System.Net.Http.StreamContent($body)
                foreach ($headerName in $request.Headers.AllKeys) {
                    if ($headerName -in @("Content-Type", "Content-Encoding", "Content-Language", "Content-Location", "Content-MD5", "Content-Range")) {
                        $requestMessage.Content.Headers.TryAddWithoutValidation($headerName, $request.Headers[$headerName]) | Out-Null
                    }
                }
            }

            $responseMessage = $client.SendAsync($requestMessage, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            Write-Trace "RESPONSE $([int]$responseMessage.StatusCode) $($responseMessage.ReasonPhrase) content_type=$($responseMessage.Content.Headers.ContentType)"
            $response.StatusCode = [int]$responseMessage.StatusCode
            $response.StatusDescription = $responseMessage.ReasonPhrase

            foreach ($header in $responseMessage.Headers) {
                if ($hopByHopHeaders -notcontains $header.Key) {
                    $response.Headers[$header.Key] = ($header.Value -join ", ")
                }
            }
            foreach ($header in $responseMessage.Content.Headers) {
                if ($header.Key -eq "Content-Type") {
                    $response.ContentType = ($header.Value -join ", ")
                }
                elseif ($hopByHopHeaders -notcontains $header.Key -and $header.Key -ne "Content-Length") {
                    $response.Headers[$header.Key] = ($header.Value -join ", ")
                }
            }

            if ($responseMessage.Content.Headers.ContentLength) {
                $response.ContentLength64 = [long]$responseMessage.Content.Headers.ContentLength
            }
            else {
                $response.SendChunked = $true
            }

            if ($VerboseLevel -ge 2) {
                $responseBytes = $responseMessage.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
                Write-Trace "RESPONSE_BODY $(Get-TracePreview -Bytes $responseBytes)"
                $response.OutputStream.Write($responseBytes, 0, $responseBytes.Length)
            }
            else {
                $responseStream = $responseMessage.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                $responseStream.CopyTo($response.OutputStream)
                $responseStream.Dispose()
            }
            $response.Close()
        }
        catch {
            try {
                Write-ProxyError -Response $response -StatusCode 502 -Message $_.Exception.Message
            }
            catch {
                $response.Abort()
            }
        }
        finally {
            if ($responseMessage) { $responseMessage.Dispose() }
            if ($requestMessage) { $requestMessage.Dispose() }
        }
    }
}
finally {
    $client.Dispose()
    $listener.Stop()
    $listener.Close()
}
