# aiox-shared/Alerting.psm1 — Proactive alerts via openclaw Telegram bot on the VPS
#
# Hardening #1: when the VPS (openclaw) or local auth refresh fails, the user
# must be notified out-of-band. The bot lives on the VPS (marce@79.72.71.20),
# so the alert delivery path is:
#
#     PowerShell  --ssh-->  marce@79.72.71.20  --openclaw-->  Telegram (default account)
#
# Design choices:
#   - Deliberately NO Telegram bot token on the Windows box. We piggyback on
#     the openclaw daemon that already has 5 Telegram accounts configured. The
#     'default' account is used unless the caller overrides.
#   - Throttle on (message-hash) for 30 min: a 401-refresh loop fires every
#     ~6 min; without throttle we would spam Telegram. The throttle file lives
#     in ~/.claude-orchestrator/usage/state/alert-throttle.json and is keyed
#     by SHA-256 of the message body (lowercased, trimmed).
#   - SSH failure is non-fatal: we fall back to writing the alert as a JSON
#     line in ~/.claude-orchestrator/usage/logs/alerts-undelivered.jsonl so
#     post-mortem analysis still has the signal. The caller receives
#     delivered=$false with a reason string.
#   - All FS paths are computed via Get-AioxStatePath / Get-AioxLogPath
#     helpers; tests inject the home root via -StateRoot / -LogRoot.
#   - We invoke ssh.exe directly via Start-Process so tests can stub the
#     entire SSH transport with a mock that doesn't touch the network. The
#     mock is gated by the AIOX_SSH_TRANSPORT env var; in production it stays
#     empty and we use the real ssh binary.

Set-StrictMode -Version Latest

# ── Defaults ──────────────────────────────────────────────────────────────────
$Script:DefaultVpsHost      = 'marce@79.72.71.20'
$Script:DefaultAccount      = 'default'
$Script:DefaultChannel      = 'telegram'
$Script:ThrottleSeconds     = 30 * 60   # 30 minutes
$Script:DefaultSshTimeoutSec = 10

function Get-AioxStateRoot {
    param([string]$Override)
    if ($Override) { return $Override }
    return (Join-Path $env:USERPROFILE '.claude-orchestrator\usage\state')
}

function Get-AioxLogRoot {
    param([string]$Override)
    if ($Override) { return $Override }
    return (Join-Path $env:USERPROFILE '.claude-orchestrator\usage\logs')
}

function Get-MessageHash {
    param([Parameter(Mandatory)][string]$Message)
    $norm = $Message.Trim().ToLowerInvariant()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($norm)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash($bytes)
    } finally {
        $sha.Dispose()
    }
    return ([System.BitConverter]::ToString($hashBytes) -replace '-','').ToLowerInvariant()
}

function Read-ThrottleState {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @{} }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if (-not $raw -or -not $raw.Trim()) { return @{} }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        # Convert PSObject -> hashtable for easy index access
        $h = @{}
        foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
        return $h
    } catch {
        # Corrupted throttle file: treat as empty, don't crash the alerter.
        return @{}
    }
}

function Write-ThrottleState {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$State
    )
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $json = $State | ConvertTo-Json -Depth 4 -Compress
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $json, $utf8NoBom)
}

function Append-UndeliveredAlert {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$Severity,
        [Parameter(Mandatory)][string]$Reason
    )
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $entry = [ordered]@{
        ts       = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        severity = $Severity
        message  = $Message
        reason   = $Reason
    }
    $line = ($entry | ConvertTo-Json -Compress -Depth 4) + [Environment]::NewLine
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::AppendAllText($Path, $line, $utf8NoBom)
}

function Invoke-SshSendAlert {
    # Test seam: returns $true on delivery, throws on failure.
    # In production this calls ssh.exe with a strict timeout. In tests the
    # caller injects a scriptblock via -TransportOverride that mimics the
    # contract:
    #     param($VpsHost,$Account,$Channel,$Message) -> hashtable, e.g.:
    #     @{ ok = $true }                          # success
    #     @{ ok = $false; reason = 'ssh_timeout' } # failure
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VpsHost,
        [Parameter(Mandatory)][string]$Account,
        [Parameter(Mandatory)][string]$Channel,
        [Parameter(Mandatory)][string]$Message,
        [int]$TimeoutSec = 10,
        [scriptblock]$TransportOverride
    )

    if ($TransportOverride) {
        # Tests inject this. The override is expected to mimic the contract.
        return (& $TransportOverride $VpsHost $Account $Channel $Message)
    }

    # Real SSH path. We use ssh -o ConnectTimeout=<n> and rely on PowerShell
    # to enforce a wall-clock cap via Wait-Process -Timeout. The remote
    # command quotes the message body with single quotes; we escape embedded
    # single quotes by using the standard '"'"' shell trick.
    $escapedMsg = $Message -replace "'", "'""'""'"
    $remoteCmd = "openclaw message send --channel $Channel --account $Account --message '$escapedMsg'"

    $sshArgs = @(
        '-o', "ConnectTimeout=$TimeoutSec",
        '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=accept-new',
        $VpsHost,
        $remoteCmd
    )

    try {
        $proc = Start-Process -FilePath 'ssh' -ArgumentList $sshArgs -NoNewWindow -PassThru `
            -RedirectStandardOutput ([System.IO.Path]::GetTempFileName()) `
            -RedirectStandardError  ([System.IO.Path]::GetTempFileName())
        $finished = $proc.WaitForExit(($TimeoutSec + 5) * 1000)
        if (-not $finished) {
            try { $proc.Kill() } catch {}
            return @{ ok = $false; reason = 'ssh_timeout' }
        }
        if ($proc.ExitCode -ne 0) {
            return @{ ok = $false; reason = "ssh_exit_$($proc.ExitCode)" }
        }
        return @{ ok = $true }
    } catch {
        return @{ ok = $false; reason = "ssh_exception: $($_.Exception.Message)" }
    }
}

function Send-AioxAlert {
    <#
    .SYNOPSIS
        Send a proactive alert to the user via the openclaw Telegram bot on the VPS.

    .DESCRIPTION
        SSHs to the openclaw VPS and pipes the message to:
            openclaw message send --channel telegram --account <Account> --message "<Message>"

        Throttles duplicate messages: if the same message body (hash) was sent
        within ThrottleSeconds (default 30 min), the call returns
        delivered=$false / reason='throttled' without contacting the VPS.

        If SSH delivery fails for any reason, the alert is appended to
        ~/.claude-orchestrator/usage/logs/alerts-undelivered.jsonl as a JSON
        line, and the function returns delivered=$false with a descriptive
        reason. The caller never sees an exception.

    .PARAMETER Message
        The message body to send. A "[ALERT]" prefix is added automatically
        unless the body already starts with "[ALERT]".

    .PARAMETER Severity
        Severity tag forwarded to the throttle/log records: warn or error.

    .PARAMETER VpsHost
        Override the VPS host (default: marce@79.72.71.20).

    .PARAMETER Account
        Override the openclaw channel account (default: 'default').

    .PARAMETER Channel
        Override the openclaw channel (default: 'telegram').

    .PARAMETER StateRoot
        Test hook: override the throttle-state directory.

    .PARAMETER LogRoot
        Test hook: override the undelivered-log directory.

    .PARAMETER TransportOverride
        Test hook: scriptblock that simulates the SSH transport. See
        Invoke-SshSendAlert for the contract.

    .OUTPUTS
        Hashtable: @{ delivered = <bool>; reason = <string> }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('warn','error')][string]$Severity = 'warn',
        [string]$VpsHost   = $Script:DefaultVpsHost,
        [string]$Account   = $Script:DefaultAccount,
        [string]$Channel   = $Script:DefaultChannel,
        [string]$StateRoot,
        [string]$LogRoot,
        [int]$TimeoutSec   = $Script:DefaultSshTimeoutSec,
        [scriptblock]$TransportOverride
    )

    if (-not $Message -or -not $Message.Trim()) {
        return @{ delivered = $false; reason = 'empty_message' }
    }

    # Normalize prefix exactly once
    $body = if ($Message.StartsWith('[ALERT]')) { $Message } else { "[ALERT] $Message" }

    $stateDir   = Get-AioxStateRoot -Override $StateRoot
    $logDir     = Get-AioxLogRoot   -Override $LogRoot
    $throttleFile  = Join-Path $stateDir 'alert-throttle.json'
    $undeliveredFile = Join-Path $logDir 'alerts-undelivered.jsonl'

    $hash = Get-MessageHash -Message $body
    $now  = Get-Date
    $state = Read-ThrottleState -Path $throttleFile

    if ($state.ContainsKey($hash)) {
        $lastIsoString = [string]$state[$hash]
        try {
            $last = [DateTime]::Parse($lastIsoString, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
            $elapsed = ($now.ToUniversalTime() - $last.ToUniversalTime()).TotalSeconds
            if ($elapsed -lt $Script:ThrottleSeconds) {
                return @{ delivered = $false; reason = 'throttled'; lastSeen = $lastIsoString }
            }
        } catch {
            # Corrupted entry: ignore and proceed to send.
        }
    }

    # Attempt delivery
    $deliveryResult = Invoke-SshSendAlert -VpsHost $VpsHost -Account $Account `
        -Channel $Channel -Message $body -TimeoutSec $TimeoutSec `
        -TransportOverride $TransportOverride

    if ($deliveryResult.ok) {
        # Record successful send timestamp into throttle
        $state[$hash] = $now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        Write-ThrottleState -Path $throttleFile -State $state
        return @{ delivered = $true; reason = 'sent' }
    } else {
        # Fallback: log to undelivered file. Do NOT update throttle so the
        # next tick can retry.
        $reason = $deliveryResult.reason
        Append-UndeliveredAlert -Path $undeliveredFile -Message $body `
            -Severity $Severity -Reason $reason
        return @{ delivered = $false; reason = $reason }
    }
}

Export-ModuleMember -Function Send-AioxAlert, Get-MessageHash
