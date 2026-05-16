$Script:HubRoot = 'C:\Users\marce\Diego\AI-Skills-Hub'

# Re-export cleanup cmdlets so 'aiocleanup*' aliases below resolve to them
# without users having to import Cleanup.psm1 separately.
Import-Module (Join-Path $PSScriptRoot 'Cleanup.psm1') -Force -Global

# Hardening #3: Health module (cmdlet `aiohealth` -> Test-AioxHealth).
# Importado aqui para que `aiohealth` funcione apos `Import-Module Aiox` sem
# o usuario precisar importar Health.psm1 manualmente.
$Script:HealthModulePath = Join-Path $PSScriptRoot 'Health.psm1'
if (Test-Path -LiteralPath $Script:HealthModulePath) {
    Import-Module $Script:HealthModulePath -Force -Global -DisableNameChecking
}

function Get-AioxScript {
    param([Parameter(Mandatory)][ValidateSet('claude','codex','gemini')][string]$Cli)
    switch ($Cli) {
        'claude' { return Join-Path $Script:HubRoot 'auto-rotate.ps1' }
        'codex'  { return Join-Path $Script:HubRoot 'auto-rotate-codex.ps1' }
        'gemini' { return Join-Path $Script:HubRoot 'auto-rotate-gemini.ps1' }
    }
}

function Get-AioxStatus {
    [CmdletBinding()]
    param([ValidateSet('claude','codex','gemini')][string]$Cli = 'claude')
    & (Get-AioxScript -Cli $Cli) -Status
}

function Get-AioxList {
    [CmdletBinding()]
    param([ValidateSet('claude','codex','gemini')][string]$Cli = 'claude')
    & (Get-AioxScript -Cli $Cli) -List
}

function Get-AioxPreview {
    [CmdletBinding()]
    param([ValidateSet('claude','codex','gemini')][string]$Cli = 'claude')
    & (Get-AioxScript -Cli $Cli) -Preview
}

function Switch-AioxProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0)][string]$Profile,
        [ValidateSet('claude','codex','gemini')][string]$Cli = 'claude',
        [switch]$DryRun
    )
    & (Get-AioxScript -Cli $Cli) -Switch $Profile -DryRun:$DryRun
}

function Open-AioxUI {
    [CmdletBinding()]
    param([ValidateSet('skills','auth')][string]$Mode = 'skills')
    if ($Mode -eq 'auth') {
        Start-Process (Join-Path $Script:HubRoot 'claude-auth-manager.bat')
    } else {
        Start-Process (Join-Path $Script:HubRoot 'skill-manager.bat')
    }
}

function Enable-AioxAutoRotate {
    [CmdletBinding()] param()
    try {
        $r = Invoke-RestMethod -Method Post -Uri 'http://localhost:8766/api/auto-rotate/toggle' -Body '{"enabled":true}' -ContentType 'application/json' -TimeoutSec 3
        Write-Host "Auto-rotate ENABLED (tasks: $($r.tasks | ConvertTo-Json -Compress))" -ForegroundColor Green
    } catch {
        Write-Warning "Auth UI nao esta rodando na porta 8766. Use 'aiou auth' primeiro."
    }
}

function Disable-AioxAutoRotate {
    [CmdletBinding()] param()
    try {
        $r = Invoke-RestMethod -Method Post -Uri 'http://localhost:8766/api/auto-rotate/toggle' -Body '{"enabled":false}' -ContentType 'application/json' -TimeoutSec 3
        Write-Host "Auto-rotate DISABLED (tasks: $($r.tasks | ConvertTo-Json -Compress))" -ForegroundColor Yellow
    } catch {
        Write-Warning "Auth UI nao esta rodando na porta 8766. Use 'aiou auth' primeiro."
    }
}

function Get-AioxAutoRotateState {
    [CmdletBinding()] param()
    try {
        $r = Invoke-RestMethod -Uri 'http://localhost:8766/api/auto-rotate/status' -TimeoutSec 3
        $color = if ($r.enabled) { 'Green' } else { 'Yellow' }
        Write-Host "Auto-rotate: $(if ($r.enabled) { 'ENABLED' } else { 'DISABLED' })" -ForegroundColor $color
        $r.tasks.PSObject.Properties | ForEach-Object { "  $($_.Name): $($_.Value)" } | Write-Host
    } catch {
        Write-Warning "Auth UI nao esta rodando na porta 8766."
    }
}

function Get-AioxAuthUrls {
    [CmdletBinding()]
    param(
        [int]$Limit = 10,
        [switch]$CopyLatest
    )
    $urls = $null

    # Try via running UI first (fast)
    try {
        $r = Invoke-RestMethod -Uri "http://localhost:8766/api/auth-login-urls?limit=$Limit" -TimeoutSec 2 -ErrorAction Stop
        $urls = @($r.urls)
    } catch {
        # Fallback: dot-source manage-skills.ps1 and call function directly
        try {
            . (Join-Path $Script:HubRoot 'manage-skills.ps1') 2>$null
            $urls = @(Get-RecentAuthLoginUrls -Limit $Limit)
        } catch {
            Write-Warning "Nao foi possivel ler historico de login URLs: $($_.Exception.Message)"
            return
        }
    }

    if (-not $urls -or $urls.Count -eq 0) {
        Write-Host "Nenhuma sessao de login com URL capturada ainda." -ForegroundColor Yellow
        Write-Host "Inicie um login (ex: Add-ClaudeProfile ou Start-CodexAuthLogin) e tente de novo."
        return
    }

    Write-Host ""
    foreach ($u in $urls) {
        $status = if ($u.done) { '[DONE]' } else { '[PEND]' }
        $color = if ($u.done) { 'DarkGray' } else { 'Cyan' }
        Write-Host "  $status $($u.tool)/$($u.profile)" -ForegroundColor $color -NoNewline
        Write-Host "  $($u.createdAt)" -ForegroundColor DarkGray
        Write-Host "    $($u.loginUrl)"
        Write-Host ""
    }

    if ($CopyLatest -and $urls.Count -gt 0) {
        $latest = $urls[0].loginUrl
        Set-Clipboard -Value $latest
        Write-Host "  ^ URL mais recente copiado para a clipboard" -ForegroundColor Green
    }
}

function Invoke-AioxCleanupAlias {
    # Manual cleanup runner -- defaults to DryRun for safety. Pass -Live to actually mutate.
    [CmdletBinding()]
    param(
        [switch]$Live,
        [int]$SessionDaysToKeep = 14,
        [int]$LogMaxSizeMB      = 50,
        [int]$LogTruncateToMB   = 25
    )
    $dry = -not $Live
    $r = Invoke-AioxCleanup -DryRun:$dry `
        -SessionDaysToKeep $SessionDaysToKeep `
        -LogMaxSizeMB $LogMaxSizeMB `
        -LogTruncateToMB $LogTruncateToMB
    $mode = if ($dry) { 'DRY-RUN' } else { 'LIVE' }
    Write-Host ""
    Write-Host "  Cleanup [$mode]" -ForegroundColor Cyan
    Write-Host "    sessionsArchived : $($r.sessionsArchived)"
    Write-Host "    sessionsRemoved  : $($r.sessionsRemoved)"
    Write-Host "    logsRotated      : $($r.logsRotated)"
    Write-Host "    bytesFreed       : $($r.bytesFreed)"
    Write-Host "    durationMs       : $($r.durationMs)"
    if ($dry) {
        Write-Host "    (re-run with -Live to actually apply)" -ForegroundColor Yellow
    }
    return $r
}

# ── Hardening #1: VPS auth-refresh-loop alerting via openclaw -> Telegram ────
# DISABLED by default. The Scheduled Task `AioxHealthMonitor` is registered
# lazily by Enable-AioxHealthMonitor and remains off until the user opts in.
function Enable-AioxHealthMonitor {
    [CmdletBinding()] param()
    try {
        Import-Module (Join-Path $Script:HubRoot 'aiox-shared\HealthMonitor.psm1') -Force -DisableNameChecking
        Register-AioxHealthMonitorTask
        Enable-ScheduledTask -TaskName (Get-AioxHealthMonitorTaskName) -ErrorAction Stop | Out-Null
        Write-Host "AioxHealthMonitor ENABLED (runs every 5 min, alerts via openclaw->Telegram)." -ForegroundColor Green
    } catch {
        Write-Warning "Falha ao habilitar AioxHealthMonitor: $($_.Exception.Message)"
    }
}

function Disable-AioxHealthMonitor {
    [CmdletBinding()] param()
    try {
        Import-Module (Join-Path $Script:HubRoot 'aiox-shared\HealthMonitor.psm1') -Force -DisableNameChecking
        Disable-ScheduledTask -TaskName (Get-AioxHealthMonitorTaskName) -ErrorAction Stop | Out-Null
        Write-Host "AioxHealthMonitor DISABLED." -ForegroundColor Yellow
    } catch {
        Write-Warning "Falha ao desabilitar AioxHealthMonitor: $($_.Exception.Message). Task pode nao estar registrada ainda."
    }
}

function Get-AioxHealthMonitorState {
    [CmdletBinding()] param()
    try {
        Import-Module (Join-Path $Script:HubRoot 'aiox-shared\HealthMonitor.psm1') -Force -DisableNameChecking
        $taskName = Get-AioxHealthMonitorTaskName
        $t = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
        $color = if ($t.State -eq 'Ready' -or $t.State -eq 'Running') { 'Green' } else { 'Yellow' }
        Write-Host "AioxHealthMonitor task: $($t.State)" -ForegroundColor $color
    } catch {
        Write-Host "AioxHealthMonitor task: NotRegistered" -ForegroundColor DarkGray
        Write-Host "  Use 'aiohealth-on' para registrar e ativar." -ForegroundColor DarkGray
    }
}

function Test-AioxSuite {
    [CmdletBinding()]
    param([switch]$Detailed)
    $output = if ($Detailed) { 'Detailed' } else { 'Normal' }
    Invoke-Pester (Join-Path $Script:HubRoot 'tests'), (Join-Path $Script:HubRoot 'aiox-shared\tests') -Output $output
}

function Show-AioxHelp {
    [CmdletBinding()] param()
    Write-Host ""
    Write-Host "  AIOX  --  AI-Skills-Hub helper cmdlets" -ForegroundColor Cyan
    Write-Host "  =======================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  STATUS & INFO" -ForegroundColor Yellow
    Write-Host "    aios [-Cli claude|codex|gemini]        Show active profile + usage %"
    Write-Host "    aiol [-Cli ...]                        List all profiles + state"
    Write-Host "    aiop [-Cli ...]                        Preview next profile (no swap)"
    Write-Host "    aiostate                               Auto-rotate ON/OFF state"
    Write-Host ""
    Write-Host "  SWITCH" -ForegroundColor Yellow
    Write-Host "    aiosw <profile> [-Cli ...] [-DryRun]   Switch to <profile>"
    Write-Host "      ex: aiosw claude-c"
    Write-Host "      ex: aiosw codex-b -Cli codex"
    Write-Host "      ex: aiosw claude-d -DryRun"
    Write-Host ""
    Write-Host "  AUTH URLS (historico de links OAuth)" -ForegroundColor Yellow
    Write-Host "    aiourls [-Limit N] [-CopyLatest]       List recent OAuth URLs"
    Write-Host "      ex: aiourls                          (mostra ultimos 10)"
    Write-Host "      ex: aiourls -Limit 3                 (so os 3 mais recentes)"
    Write-Host "      ex: aiourls -CopyLatest              (copia o mais recente p/ clipboard)"
    Write-Host ""
    Write-Host "  UI" -ForegroundColor Yellow
    Write-Host "    aiou                                   Skill Manager UI :8765"
    Write-Host "    aiou auth                              Auth UI :8766 (Claude / Codex / Gemini)"
    Write-Host ""
    Write-Host "  AUTO-ROTATE TOGGLE" -ForegroundColor Yellow
    Write-Host "    aioon                                  Enable auto-rotate"
    Write-Host "    aiooff                                 Disable auto-rotate"
    Write-Host "    aiostate                               Show current state"
    Write-Host "    (auth UI deve estar rodando: aiou auth)"
    Write-Host ""
    Write-Host "  DEV" -ForegroundColor Yellow
    Write-Host "    aiotest                                Run Pester suite"
    Write-Host "    aiotest -Detailed                      Verbose output"
    Write-Host ""
    Write-Host "  HEALTH" -ForegroundColor Yellow
    Write-Host "    aiohealth                              System health (10 checks, < 2s w/ -SkipSsh)"
    Write-Host "    aiohealth -SkipSsh                     Skip VPS SSH probe (offline mode)"
    Write-Host "    aiohealth -Quiet                       Returns `$true/`$false (overall ok?)"
    Write-Host "    aiohealth -SshTimeoutSec 10            Override SSH timeout (default 5s)"
    Write-Host ""
    Write-Host "  HEALTH MONITOR (proactive Telegram alerts via VPS openclaw)" -ForegroundColor Yellow
    Write-Host "    aiohealth-on                           Register + enable 5-min Scheduled Task"
    Write-Host "    aiohealth-off                          Disable Scheduled Task (task stays registered)"
    Write-Host "    aiohealth-state                        Show task state (Ready/Disabled/NotRegistered)"
    Write-Host "    aiohealth-tick                         Run one tick manually (probe + maybe alert)"
    Write-Host "    (alerts use openclaw -> Telegram via SSH to marce@79.72.71.20)"
    Write-Host "    (logs in ~/.claude-orchestrator/usage/logs/health-monitor.jsonl)"
    Write-Host ""
    Write-Host "  CLEANUP" -ForegroundColor Yellow
    Write-Host "    aiocleanup                             Manual cleanup (DRY-RUN by default)"
    Write-Host "    aiocleanup -Live                       Apply cleanup (archive sessions, rotate logs)"
    Write-Host "    aiocleanup-on                          Enable scheduled cleanup task"
    Write-Host "    aiocleanup-off                         Disable scheduled cleanup task"
    Write-Host "    Register-AioxCleanupTask               Register Sun 03:00 weekly task"
    Write-Host "    Unregister-AioxCleanupTask             Remove the scheduled task"
    Write-Host ""
    Write-Host "  HELP" -ForegroundColor Yellow
    Write-Host "    aiohelp                                This help"
    Write-Host "    Get-Command -Module Aiox               List all cmdlets"
    Write-Host ""
}

Set-Alias -Name aiourls  -Value Get-AioxAuthUrls
Set-Alias -Name aios     -Value Get-AioxStatus
Set-Alias -Name aiol     -Value Get-AioxList
Set-Alias -Name aiop     -Value Get-AioxPreview
Set-Alias -Name aiosw    -Value Switch-AioxProfile
Set-Alias -Name aiou     -Value Open-AioxUI
Set-Alias -Name aioon    -Value Enable-AioxAutoRotate
Set-Alias -Name aiooff   -Value Disable-AioxAutoRotate
Set-Alias -Name aiostate -Value Get-AioxAutoRotateState
Set-Alias -Name aiotest  -Value Test-AioxSuite
Set-Alias -Name aiohelp  -Value Show-AioxHelp
Set-Alias -Name aiocleanup     -Value Invoke-AioxCleanupAlias
Set-Alias -Name aiocleanup-on  -Value Enable-AioxCleanup
Set-Alias -Name aiocleanup-off -Value Disable-AioxCleanup
Set-Alias -Name aiohealth      -Value Test-AioxHealth

# Hardening #1: VPS auth-refresh-loop alerter
Set-Alias -Name aiohealth-on     -Value Enable-AioxHealthMonitor
Set-Alias -Name aiohealth-off    -Value Disable-AioxHealthMonitor
Set-Alias -Name aiohealth-state  -Value Get-AioxHealthMonitorState
Set-Alias -Name aiohealth-tick   -Value Invoke-AioxHealthMonitorTick

Export-ModuleMember -Function * -Alias *
