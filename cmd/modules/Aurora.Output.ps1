# AURORA output and display formatting

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

function Format-Bytes {
    param([Nullable[long]]$Bytes)

    if ($null -eq $Bytes) { return "unknown" }

    $units = @("B", "KiB", "MiB", "GiB", "TiB")
    $value = [double]$Bytes
    $index = 0
    while ($value -ge 1024 -and $index -lt ($units.Count - 1)) {
        $value = $value / 1024
        $index++
    }
    return "{0:N2} {1}" -f $value, $units[$index]
}

function Get-ProcessorSplit {
    param([object]$ModelState)

    $size = [Nullable[long]]$null
    $vram = [Nullable[long]]$null
    if ($null -ne $ModelState.size) { $size = [long]$ModelState.size }
    if ($null -ne $ModelState.size_vram) { $vram = [long]$ModelState.size_vram }
    if ($null -eq $size -or $size -le 0 -or $null -eq $vram) { return "unknown" }

    $gpuPct = [Math]::Round(([double]$vram / [double]$size) * 100, 1)
    if ($gpuPct -gt 100) { $gpuPct = 100 }
    $cpuPct = [Math]::Round(100 - $gpuPct, 1)
    return "$gpuPct% GPU / $cpuPct% CPU ($((Format-Bytes $vram)) VRAM of $((Format-Bytes $size)) total)"
}

function Write-LoadedModelState {
    param([object]$PsState, [string]$ModelName)

    $loaded = Find-LoadedModel -PsState $PsState -ModelName $ModelName
    if (-not $loaded) {
        Write-Host "Loaded state: unloaded"
        if ($PsState -and $PsState.models -and $PsState.models.Count -gt 0) {
            Write-Host "Other loaded models:"
            $PsState.models | ForEach-Object { Write-Host "  - $($_.name)" }
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
