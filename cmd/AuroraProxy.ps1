[CmdletBinding()]
param(
    [int]$ProxyPort = 11435,
    [string]$OllamaUrl = "http://127.0.0.1:11434",
    [switch]$Trace,
    [switch]$ConsoleTrace,
    [switch]$FullTrace
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
    if (-not $FullTrace -and $text.Length -gt 2000) {
        return $text.Substring(0, 2000) + "... [truncated]"
    }
    return $text
}

function Write-Trace {
    param([string]$Message)

    if (-not $Trace) {
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

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        $requestMessage = $null
        $responseMessage = $null

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
                Write-Trace "REQUEST_BODY $(Get-TracePreview -Bytes $body.ToArray())"
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

            if ($Trace) {
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
