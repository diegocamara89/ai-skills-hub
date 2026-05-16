# aiox-shared/StructuredLogger.psm1 — JSON-lines structured logger
# Used by auto-rotate.ps1 / auto-rotate-codex.ps1 (and future auto-rotate-*.ps1)
# Each call appends one JSON object per line. UTF-8 without BOM.

function Write-StructuredLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Event,
        [ValidateSet('info','warn','error','debug')][string]$Level = 'info',
        [hashtable]$Properties = @{}
    )

    $entry = [ordered]@{
        ts    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        level = $Level
        event = $Event
    }
    if ($Properties) {
        foreach ($k in $Properties.Keys) {
            $entry[$k] = $Properties[$k]
        }
    }

    $json = $entry | ConvertTo-Json -Compress -Depth 5

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    # Append using UTF-8 without BOM. PS7 Add-Content -Encoding UTF8 already
    # emits no BOM, but using AppendAllText guarantees behavior across hosts
    # and avoids any line-ending surprises.
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::AppendAllText($Path, $json + [Environment]::NewLine, $utf8NoBom)
}

Export-ModuleMember -Function Write-StructuredLog
