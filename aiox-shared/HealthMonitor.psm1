# aiox-shared/HealthMonitor.psm1 — Orchestration tick that ties health probe + alerting
#
# Hardening #1 entry point. The Scheduled Task `AioxHealthMonitor` runs this
# every 5 minutes (when enabled). Flow:
#
#     1. Test-VpsAuthHealth
#         healthy=$true     -> log event=health_ok, exit
#         healthy=$null     -> log event=health_unreachable, exit (no alert yet,
#                              we want to avoid spamming during transient ssh
#                              hiccups; if it persists Hardening #2 will add a
#                              separate alert for that)
#         healthy=$false    -> log event=health_unhealthy, fire Send-AioxAlert
#
#     2. Always emit a JSON-line summary to:
#            ~/.claude-orchestrator/usage/logs/health-monitor.jsonl
#
# The tick swallows all exceptions and writes them as event=tick_error so a
# rogue Scheduled Task invocation never throws up to the Task Scheduler engine
# (which would spam the Event Viewer).

Set-StrictMode -Version Latest

# We import the sibling modules from the same folder so that
# Import-Module HealthMonitor.psm1 -Force in any test pulls fresh copies of
# Alerting + VpsAuthHealth as well.
$Script:ModuleRoot = $PSScriptRoot
Import-Module (Join-Path $Script:ModuleRoot 'Alerting.psm1')        -Force -DisableNameChecking
Import-Module (Join-Path $Script:ModuleRoot 'VpsAuthHealth.psm1')   -Force -DisableNameChecking
Import-Module (Join-Path $Script:ModuleRoot 'StructuredLogger.psm1') -Force -DisableNameChecking

function Get-HealthMonitorLogPath {
    param([string]$Override)
    if ($Override) { return $Override }
    return (Join-Path $env:USERPROFILE '.claude-orchestrator\usage\logs\health-monitor.jsonl')
}

function Invoke-AioxHealthMonitorTick {
    <#
    .SYNOPSIS
        One iteration of the health monitor: probe VPS auth, alert if unhealthy.

    .DESCRIPTION
        Designed to be invoked by Task Scheduler every ~5 minutes (or manually
        during debugging). All side effects are JSON-line logging and (on
        unhealthy verdict) a throttled Telegram alert.

    .PARAMETER LogPath
        Override path for the structured log (default:
        ~/.claude-orchestrator/usage/logs/health-monitor.jsonl).

    .PARAMETER AlertStateRoot, AlertLogRoot
        Test hooks forwarded to Send-AioxAlert.

    .PARAMETER HealthTransportOverride
        Test hook: scriptblock forwarded to Test-VpsAuthHealth.

    .PARAMETER AlertTransportOverride
        Test hook: scriptblock forwarded to Send-AioxAlert.

    .OUTPUTS
        Hashtable summarizing what happened on this tick. Shape:
            @{
                event   = 'health_ok' | 'health_unreachable' | 'health_unhealthy' | 'tick_error'
                level   = 'info' | 'warn' | 'error'
                alertSent = $true|$false      # only set when alert was attempted
                alertReason = <string>        # only set when alert was attempted
                detail  = <hashtable>         # raw health probe result
            }
    #>
    [CmdletBinding()]
    param(
        [string]$LogPath,
        [string]$AlertStateRoot,
        [string]$AlertLogRoot,
        [scriptblock]$HealthTransportOverride,
        [scriptblock]$AlertTransportOverride,
        # Allow callers (and tests) to override the alert sender entirely.
        # Useful if the user later wants to send to email/Slack instead of
        # Telegram without touching this orchestrator.
        [scriptblock]$AlertSender
    )

    $logFile = Get-HealthMonitorLogPath -Override $LogPath

    try {
        $health = Test-VpsAuthHealth -TransportOverride $HealthTransportOverride

        if ($null -eq $health.healthy) {
            # SSH unreachable. Log and bail without alerting (avoid noise).
            Write-StructuredLog -Path $logFile -Event 'health_unreachable' -Level 'warn' -Properties @{
                reason = [string]$health.reason
            }
            return @{
                event  = 'health_unreachable'
                level  = 'warn'
                detail = $health
            }
        }

        if ($health.healthy -eq $true) {
            Write-StructuredLog -Path $logFile -Event 'health_ok' -Level 'info' -Properties @{}
            return @{
                event  = 'health_ok'
                level  = 'info'
                detail = $health
            }
        }

        # Unhealthy path: fire alert.
        $msg = "VPS auth refresh loop detected: $($health.count) hits of '$($health.reason)' in last 10 min (first: $($health.firstSeen))."

        $alertResult = if ($AlertSender) {
            & $AlertSender $msg
        } else {
            Send-AioxAlert -Message $msg -Severity 'error' `
                -StateRoot $AlertStateRoot -LogRoot $AlertLogRoot `
                -TransportOverride $AlertTransportOverride
        }

        Write-StructuredLog -Path $logFile -Event 'health_unhealthy' -Level 'error' -Properties @{
            reason      = [string]$health.reason
            count       = [int]$health.count
            firstSeen   = [string]$health.firstSeen
            alertSent   = [bool]$alertResult.delivered
            alertReason = [string]$alertResult.reason
        }

        return @{
            event       = 'health_unhealthy'
            level       = 'error'
            alertSent   = [bool]$alertResult.delivered
            alertReason = [string]$alertResult.reason
            detail      = $health
        }

    } catch {
        $errMsg = $_.Exception.Message
        try {
            Write-StructuredLog -Path $logFile -Event 'tick_error' -Level 'error' -Properties @{
                error = $errMsg
            }
        } catch {
            # If logging itself failed, write to stderr as a last resort.
            [Console]::Error.WriteLine("[health-monitor] tick_error: $errMsg (logging also failed: $($_.Exception.Message))")
        }
        return @{
            event = 'tick_error'
            level = 'error'
            error = $errMsg
        }
    }
}

# ── Scheduled Task management ─────────────────────────────────────────────────
# DISABLED by default. The user toggles via Enable-/Disable-AioxHealthMonitor
# (exported through Aiox.psm1 as aiohealth-on / aiohealth-off).

$Script:HealthMonitorTaskName = 'AioxHealthMonitor'

function Get-AioxHealthMonitorTaskName { return $Script:HealthMonitorTaskName }

function Register-AioxHealthMonitorTask {
    <#
    .SYNOPSIS
        Idempotently register the Scheduled Task for the health monitor.
        Always registers it DISABLED — Enable-AioxHealthMonitor flips it on.
    #>
    [CmdletBinding()]
    param(
        [string]$HubRoot = 'C:\Users\marce\Diego\AI-Skills-Hub',
        [int]$IntervalMinutes = 5
    )

    $modulePath = Join-Path $HubRoot 'aiox-shared\HealthMonitor.psm1'
    $cmd = "Import-Module '$modulePath' -Force; Invoke-AioxHealthMonitorTick | Out-Null"
    $action = New-ScheduledTaskAction -Execute 'pwsh.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -Command `"$cmd`""

    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
    # NOTE: -RepetitionDuration is intentionally omitted so the trigger
    # repeats indefinitely (default behavior on Win10+/PS7).

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 4)

    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive

    Register-ScheduledTask -TaskName $Script:HealthMonitorTaskName `
        -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
        -Description 'AIOX Hardening #1: probes openclaw VPS for token-refresh-loop and alerts via Telegram.' `
        -Force | Out-Null

    # Register as DISABLED — user must opt-in via Enable-AioxHealthMonitor.
    Disable-ScheduledTask -TaskName $Script:HealthMonitorTaskName | Out-Null
}

Export-ModuleMember -Function `
    Invoke-AioxHealthMonitorTick, `
    Register-AioxHealthMonitorTask, `
    Get-AioxHealthMonitorTaskName
