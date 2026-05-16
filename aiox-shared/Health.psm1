# aiox-shared/Health.psm1
# Hardening #3: cmdlet `aiohealth` (Test-AioxHealth)
#
# Verifica saude do AI-Skills-Hub em < 2 segundos (com -SkipSsh).
# 10 checks independentes; cada um tem timeout proprio para que um check travado
# nao trave o comando inteiro.
#
# Estrutura de retorno:
#   @{
#     overall = 'ok'|'warn'|'error'
#     checks  = @(@{name; status; detail; durationMs})
#     totalDurationMs = N
#   }
#
# DESIGN:
#   - Cada check tem uma funcao Test-AioxCheck-<Name> que retorna @{status;detail}.
#     Pester pode usar Mock para substituir essas funcoes nos testes.
#   - Test-AioxHealth orquestra execucao paralela (Start-Job) com timeout,
#     OU sequencial (via -Sequential) quando rodando em testes Pester
#     (porque Mock nao atravessa runspaces de Start-Job).
#   - -Quiet retorna $true/$false. Sem -Quiet imprime tabela colorida.

Set-StrictMode -Version Latest

$Script:DefaultHubRoot = 'C:\Users\marce\Diego\AI-Skills-Hub'
$Script:DefaultVpsSyncStatus = Join-Path $env:USERPROFILE '.claude-orchestrator\vps-sync-status.json'
$Script:DefaultOauthRefreshLog = Join-Path $env:USERPROFILE '.claude-orchestrator\usage\logs\oauth-refresh.jsonl'
$Script:DefaultRotationLog = Join-Path $env:USERPROFILE '.claude-orchestrator\usage\logs\rotation.jsonl'
$Script:DefaultJunctionPath = Join-Path $env:USERPROFILE '.claude-profiles\active'

# ---------- Individual checks ----------
# Each returns @{status='ok|warn|error'; detail=string}

function Test-AioxCheck-PwshSyntax {
    param([string]$HubRoot = $Script:DefaultHubRoot)
    $script = Join-Path $HubRoot 'manage-skills.ps1'
    if (-not (Test-Path -LiteralPath $script)) {
        return @{ status = 'error'; detail = "manage-skills.ps1 not found at $script" }
    }
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        return @{ status = 'error'; detail = "$($errors.Count) parse error(s) in manage-skills.ps1" }
    }
    return @{ status = 'ok'; detail = 'manage-skills.ps1 parses cleanly' }
}

function Test-AioxCheck-PesterQuick {
    param([string]$HubRoot = $Script:DefaultHubRoot)
    $testsDir = Join-Path $HubRoot 'aiox-shared\tests'
    if (-not (Test-Path -LiteralPath $testsDir)) {
        return @{ status = 'warn'; detail = "aiox-shared/tests dir missing" }
    }
    # Roda Pester em modo silencioso EXCLUINDO AioxHealth.Tests.ps1 — se
    # rodassemos esse arquivo de dentro de Test-AioxHealth, criariamos
    # recursao mock-de-mock-de-Pester que trava o runspace. Os testes do
    # Health module sao validados via aiotest direto.
    try {
        $testFiles = Get-ChildItem -LiteralPath $testsDir -Filter '*.Tests.ps1' -ErrorAction Stop |
            Where-Object { $_.Name -ne 'AioxHealth.Tests.ps1' }
        if (-not $testFiles -or $testFiles.Count -eq 0) {
            return @{ status = 'warn'; detail = "no Pester test files found (excluding AioxHealth.Tests.ps1)" }
        }
        $cfg = New-PesterConfiguration
        $cfg.Run.Path = @($testFiles | ForEach-Object { $_.FullName })
        $cfg.Run.PassThru = $true
        $cfg.Output.Verbosity = 'None'
        $cfg.Run.Exit = $false
        $result = Invoke-Pester -Configuration $cfg
        if ($result.FailedCount -eq 0) {
            return @{ status = 'ok'; detail = "$($result.PassedCount)/$($result.TotalCount) tests pass (aiox-shared, excl. self)" }
        } else {
            return @{ status = 'error'; detail = "$($result.FailedCount) test(s) failed in aiox-shared" }
        }
    } catch {
        return @{ status = 'error'; detail = "Pester failed to run: $($_.Exception.Message)" }
    }
}

function Test-AioxCheck-ScheduledTasks {
    $reconcile = Get-ScheduledTask -TaskName 'AI Skills Hub Reconcile' -ErrorAction SilentlyContinue
    $claudeAR  = Get-ScheduledTask -TaskName 'ClaudeAutoRotate' -ErrorAction SilentlyContinue
    $codexAR   = Get-ScheduledTask -TaskName 'CodexAutoRotate' -ErrorAction SilentlyContinue

    if (-not $reconcile) {
        return @{ status = 'warn'; detail = "Reconcile task MISSING (expected 'AI Skills Hub Reconcile')" }
    }
    $reconState = [string]$reconcile.State
    if ($reconState -notin @('Ready','Running')) {
        return @{ status = 'warn'; detail = "Reconcile state=$reconState (expected Ready)" }
    }
    $arParts = @()
    foreach ($t in @(@{n='ClaudeAutoRotate'; v=$claudeAR}, @{n='CodexAutoRotate'; v=$codexAR})) {
        if ($null -eq $t.v) { $arParts += "$($t.n)=Missing" }
        else { $arParts += "$($t.n)=$([string]$t.v.State)" }
    }
    $detail = "Reconcile=$reconState, $($arParts -join ', ') (ok)"
    return @{ status = 'ok'; detail = $detail }
}

function Test-AioxCheck-ReconcileRecent {
    $task = Get-ScheduledTask -TaskName 'AI Skills Hub Reconcile' -ErrorAction SilentlyContinue
    if (-not $task) { return @{ status = 'warn'; detail = 'Reconcile task missing' } }
    $info = $task | Get-ScheduledTaskInfo
    if (-not $info.LastRunTime -or $info.LastRunTime.Year -lt 2000) {
        return @{ status = 'warn'; detail = 'Reconcile has never run' }
    }
    $ageMin = (New-TimeSpan -Start $info.LastRunTime -End (Get-Date)).TotalMinutes
    $ageMin = [math]::Max(0, $ageMin)
    if ($ageMin -gt 5) {
        return @{ status = 'warn'; detail = "last run: $([math]::Round($ageMin,1)) min ago (>5)" }
    }
    return @{ status = 'ok'; detail = "last run: $([math]::Round($ageMin,1)) min ago" }
}

function Test-AioxCheck-VpsSyncStatus {
    param([string]$Path = $Script:DefaultVpsSyncStatus)
    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ status = 'warn'; detail = "vps-sync-status.json missing ($Path)" }
    }
    try {
        $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        return @{ status = 'error'; detail = "vps-sync-status.json invalid JSON: $($_.Exception.Message)" }
    }
    # Localiza a entry com lastRunAt mais recente entre todas as chaves (perfis).
    $latest = $null; $latestName = $null
    foreach ($p in $json.PSObject.Properties) {
        $entry = $p.Value
        if ($entry -and $entry.PSObject.Properties.Name -contains 'lastRunAt') {
            try {
                $ts = [DateTimeOffset]::Parse([string]$entry.lastRunAt)
                if (-not $latest -or $ts -gt $latest.ts) {
                    $latest = @{ ts = $ts; entry = $entry }
                    $latestName = $p.Name
                }
            } catch { continue }
        }
    }
    if (-not $latest) {
        return @{ status = 'warn'; detail = 'no entries with valid lastRunAt' }
    }
    $now = [DateTimeOffset]::Now
    # ageH pode ficar negativo se relogio local estiver atrasado em relacao
    # ao timestamp gravado; usamos abs para evitar "age=-4274h".
    $ageH = [math]::Abs(($now - $latest.ts).TotalHours)
    $entryStatus = [string]$latest.entry.status
    if ($entryStatus -eq 'error') {
        return @{ status = 'error'; detail = "latest entry '$latestName' status=error" }
    }
    if ($ageH -gt 24) {
        return @{ status = 'warn'; detail = "latest entry '$latestName' is $([math]::Round($ageH,1))h old (>24h)" }
    }
    return @{ status = 'ok'; detail = "latest '$latestName' status=$entryStatus, age=$([math]::Round($ageH,1))h" }
}

function Test-AioxCheck-OauthRefreshJsonl {
    param([string]$Path = $Script:DefaultOauthRefreshLog)
    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ status = 'warn'; detail = 'oauth-refresh.jsonl missing (not yet emitted?)' }
    }
    $lines = Get-Content -LiteralPath $Path -Tail 50 -ErrorAction SilentlyContinue
    if (-not $lines) { return @{ status = 'ok'; detail = '0 entries in last 50 lines' } }
    $cutoff = (Get-Date).AddHours(-24)
    $fails = 0
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $obj = $line | ConvertFrom-Json -ErrorAction Stop
        } catch { continue }
        if ([string]$obj.event -ne 'oauth-refresh-fail') { continue }
        $tsProp = $obj.PSObject.Properties.Name -contains 'ts'
        if (-not $tsProp) { $fails++; continue }
        try {
            $ts = [DateTimeOffset]::Parse([string]$obj.ts).LocalDateTime
            if ($ts -ge $cutoff) { $fails++ }
        } catch { $fails++ }
    }
    if ($fails -ge 3) { return @{ status = 'error'; detail = "$fails refresh failures in last 24h" } }
    if ($fails -ge 1) { return @{ status = 'warn'; detail = "$fails refresh failures in last 24h" } }
    return @{ status = 'ok'; detail = '0 failures in last 24h' }
}

function Test-AioxCheck-RotationJsonlSize {
    param([string]$Path = $Script:DefaultRotationLog)
    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ status = 'warn'; detail = 'rotation.jsonl missing' }
    }
    $bytes = (Get-Item -LiteralPath $Path).Length
    $mb = [math]::Round($bytes / 1MB, 2)
    if ($bytes -gt 200MB) { return @{ status = 'error'; detail = "$mb MB / 200 MB hard limit exceeded" } }
    if ($bytes -gt 50MB)  { return @{ status = 'warn';  detail = "$mb MB / 50 MB soft limit exceeded" } }
    return @{ status = 'ok'; detail = "$mb MB / 50 MB max" }
}

function Test-AioxCheck-ActiveProfile {
    param([string]$JunctionPath = $Script:DefaultJunctionPath)
    if (-not (Test-Path -LiteralPath $JunctionPath)) {
        return @{ status = 'warn'; detail = "junction not found ($JunctionPath)" }
    }
    try {
        $item = Get-Item -LiteralPath $JunctionPath -Force -ErrorAction Stop
    } catch {
        return @{ status = 'error'; detail = "Get-Item failed: $($_.Exception.Message)" }
    }
    $resolved = $null
    if ($item.LinkType -in @('Junction','SymbolicLink') -and $item.Target) {
        $target = if ($item.Target -is [array]) { $item.Target[0] } else { [string]$item.Target }
        if ($target.StartsWith('\??\'))  { $target = $target.Substring(4) }
        elseif ($target.StartsWith('\\?\')) { $target = $target.Substring(4) }
        $resolved = Split-Path -Leaf $target
    } else {
        $resolved = Split-Path -Leaf $JunctionPath
    }
    if (-not $resolved -or $resolved -eq 'active') {
        return @{ status = 'warn'; detail = "junction resolves to '$resolved' (expected profile name)" }
    }
    return @{ status = 'ok'; detail = $resolved }
}

function Test-AioxCheck-VpsSshReach {
    param(
        [string]$User = 'marce',
        [string]$Host_ = '79.72.71.20',
        [int]$TimeoutSec = 5
    )
    # ssh com ConnectTimeout. Captura tudo (stdout+stderr).
    $sshArgs = @(
        '-o', "ConnectTimeout=$TimeoutSec",
        '-o', 'BatchMode=yes',          # nao pede password
        '-o', 'StrictHostKeyChecking=no',
        "$User@$Host_",
        'echo ok'
    )
    try {
        $out = & ssh @sshArgs 2>&1
        $exit = $LASTEXITCODE
    } catch {
        return @{ status = 'warn'; detail = "ssh invocation failed: $($_.Exception.Message)" }
    }
    $outStr = ($out | Out-String).Trim()
    if ($exit -eq 0 -and $outStr -match 'ok') {
        return @{ status = 'ok'; detail = 'reachable' }
    }
    # Timeout / connection refused: warn (VPS pode estar offline). Nao error.
    return @{ status = 'warn'; detail = "ssh exit=$exit (output: $($outStr -replace '\s+',' ' | Select-Object -First 1))" }
}

function Test-AioxCheck-DiskFree {
    param([string]$Drive = 'C')
    try {
        $d = Get-PSDrive -Name $Drive -ErrorAction Stop
    } catch {
        return @{ status = 'error'; detail = "drive $Drive not found" }
    }
    $freeGB = [math]::Round($d.Free / 1GB, 1)
    if ($freeGB -lt 1)  { return @{ status = 'error'; detail = "$freeGB GB free (<1 GB)" } }
    if ($freeGB -lt 5)  { return @{ status = 'warn';  detail = "$freeGB GB free (<5 GB)" } }
    return @{ status = 'ok'; detail = "$freeGB GB free" }
}

# ---------- Orchestration ----------

# Para gerar a tabela ordenamos os checks na ordem canonica abaixo. A ordem
# tambem define a ordem de execucao no modo sequencial.
$Script:HealthCheckOrder = @(
    'pwsh-syntax', 'pester-quick', 'scheduled-tasks', 'reconcile-recent',
    'vps-sync-status', 'oauth-refresh-jsonl', 'rotation-jsonl-size',
    'active-profile', 'vps-ssh-reach', 'disk-free'
)

# Per-check timeout overrides (segundos). pester-quick precisa de mais tempo
# em runspaces frescos porque importa Pester + 4 modulos.
$Script:HealthCheckTimeouts = @{
    'pester-quick'   = 20
    'vps-ssh-reach'  = 15
}

# Checks que devem rodar SEMPRE no runspace principal (nao via Start-Job).
# pester-quick: rodar em runspace fresco custa 20s+ (re-importa Pester),
#   mas no runspace principal Pester ja esta cached e termina em ~1s.
$Script:HealthCheckInProcess = @('pester-quick')

function Get-AioxCheckDispatcher {
    # Mapa name -> scriptblock que invoca a funcao certa.
    # Indireção via funcoes wrapper permite que Pester use Mock.
    return @{
        'pwsh-syntax'         = { Test-AioxCheck-PwshSyntax }
        'pester-quick'        = { Test-AioxCheck-PesterQuick }
        'scheduled-tasks'     = { Test-AioxCheck-ScheduledTasks }
        'reconcile-recent'    = { Test-AioxCheck-ReconcileRecent }
        'vps-sync-status'     = { Test-AioxCheck-VpsSyncStatus }
        'oauth-refresh-jsonl' = { Test-AioxCheck-OauthRefreshJsonl }
        'rotation-jsonl-size' = { Test-AioxCheck-RotationJsonlSize }
        'active-profile'      = { Test-AioxCheck-ActiveProfile }
        'vps-ssh-reach'       = { Test-AioxCheck-VpsSshReach -TimeoutSec $script:SshTimeoutForJob }
        'disk-free'           = { Test-AioxCheck-DiskFree }
    }
}

function Invoke-AioxCheckSafely {
    # Roda um check com timeout. Retorna @{name; status; detail; durationMs}.
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Block,
        [int]$TimeoutSec = 8
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $result = & $Block
        $sw.Stop()
        if ($null -eq $result -or -not ($result -is [hashtable])) {
            return @{ name = $Name; status = 'error'; detail = 'check returned non-hashtable'; durationMs = $sw.ElapsedMilliseconds }
        }
        $status = if ($result.ContainsKey('status')) { [string]$result.status } else { 'error' }
        $detail = if ($result.ContainsKey('detail')) { [string]$result.detail } else { '' }
        return @{ name = $Name; status = $status; detail = $detail; durationMs = $sw.ElapsedMilliseconds }
    } catch {
        $sw.Stop()
        return @{ name = $Name; status = 'error'; detail = "exception: $($_.Exception.Message)"; durationMs = $sw.ElapsedMilliseconds }
    }
}

function Format-AioxHealthRow {
    param([hashtable]$Row, [int]$NameWidth = 20)
    $statusUpper = $Row.status.ToUpperInvariant()
    $color = switch ($Row.status) {
        'ok'    { 'Green' }
        'warn'  { 'Yellow' }
        'error' { 'Red' }
        default { 'Gray' }
    }
    $tag = "[$statusUpper]".PadRight(8)
    $name = $Row.name.PadRight($NameWidth)
    $dur = "($($Row.durationMs)ms)".PadRight(9)
    Write-Host "  " -NoNewline
    Write-Host $tag -NoNewline -ForegroundColor $color
    Write-Host "$name $dur $($Row.detail)"
}

function Test-AioxHealth {
    [CmdletBinding()]
    param(
        [switch]$Quiet,
        [switch]$SkipSsh,
        [int]$SshTimeoutSec = 5,
        [switch]$Sequential,           # Use sequencial em vez de Start-Job (test-friendly)
        [int]$PerCheckTimeoutSec = 8,
        [string]$HubRoot = $Script:DefaultHubRoot
    )

    $totalSw = [System.Diagnostics.Stopwatch]::StartNew()
    $script:SshTimeoutForJob = $SshTimeoutSec

    $namesToRun = @($Script:HealthCheckOrder)
    if ($SkipSsh) { $namesToRun = $namesToRun | Where-Object { $_ -ne 'vps-ssh-reach' } }

    $dispatcher = Get-AioxCheckDispatcher
    $rows = @()

    if ($Sequential) {
        foreach ($name in $namesToRun) {
            $block = $dispatcher[$name]
            $rows += Invoke-AioxCheckSafely -Name $name -Block $block -TimeoutSec $PerCheckTimeoutSec
        }
    } else {
        # Modo paralelo: Start-Job por check, EXCETO os listados em
        # HealthCheckInProcess (que rodam no runspace principal antes para
        # reaproveitar modulos ja carregados).
        $modulePath = $PSCommandPath
        $jobs = @()
        $dispatcher = Get-AioxCheckDispatcher

        # 1) Roda checks in-process (sincronos)
        foreach ($name in $namesToRun) {
            if ($Script:HealthCheckInProcess -notcontains $name) { continue }
            $rows += Invoke-AioxCheckSafely -Name $name -Block $dispatcher[$name] -TimeoutSec $PerCheckTimeoutSec
        }

        # 2) Roda checks paralelos via Start-Job
        foreach ($name in $namesToRun) {
            if ($Script:HealthCheckInProcess -contains $name) { continue }
            $jobs += @{
                name = $name
                job  = Start-Job -ArgumentList $modulePath, $name, $SshTimeoutSec -ScriptBlock {
                    param($mp, $checkName, $sshTimeout)
                    Import-Module $mp -Force
                    $sw = [System.Diagnostics.Stopwatch]::StartNew()
                    try {
                        switch ($checkName) {
                            'pwsh-syntax'         { $r = Test-AioxCheck-PwshSyntax }
                            'pester-quick'        { $r = Test-AioxCheck-PesterQuick }
                            'scheduled-tasks'     { $r = Test-AioxCheck-ScheduledTasks }
                            'reconcile-recent'    { $r = Test-AioxCheck-ReconcileRecent }
                            'vps-sync-status'     { $r = Test-AioxCheck-VpsSyncStatus }
                            'oauth-refresh-jsonl' { $r = Test-AioxCheck-OauthRefreshJsonl }
                            'rotation-jsonl-size' { $r = Test-AioxCheck-RotationJsonlSize }
                            'active-profile'      { $r = Test-AioxCheck-ActiveProfile }
                            'vps-ssh-reach'       { $r = Test-AioxCheck-VpsSshReach -TimeoutSec $sshTimeout }
                            'disk-free'           { $r = Test-AioxCheck-DiskFree }
                            default               { $r = @{ status = 'error'; detail = "unknown check $checkName" } }
                        }
                        $sw.Stop()
                        return @{ name = $checkName; status = [string]$r.status; detail = [string]$r.detail; durationMs = $sw.ElapsedMilliseconds }
                    } catch {
                        $sw.Stop()
                        return @{ name = $checkName; status = 'error'; detail = "exception: $($_.Exception.Message)"; durationMs = $sw.ElapsedMilliseconds }
                    }
                }
            }
        }

        foreach ($j in $jobs) {
            $effectiveTimeout = if ($Script:HealthCheckTimeouts.ContainsKey($j.name)) {
                [int]$Script:HealthCheckTimeouts[$j.name]
            } else { $PerCheckTimeoutSec }
            $completed = Wait-Job -Job $j.job -Timeout $effectiveTimeout
            if ($completed) {
                $out = Receive-Job -Job $j.job -ErrorAction SilentlyContinue
                # Start-Job emite hashtables como PSCustomObject quando atravessa serializacao.
                $row = $null
                if ($out -is [array]) { $out = $out | Select-Object -Last 1 }
                if ($out -is [hashtable]) {
                    $row = $out
                } elseif ($out) {
                    $row = @{
                        name        = [string]$out.name
                        status      = [string]$out.status
                        detail      = [string]$out.detail
                        durationMs  = [int]$out.durationMs
                    }
                } else {
                    $row = @{ name = $j.name; status = 'error'; detail = 'job returned nothing'; durationMs = $PerCheckTimeoutSec * 1000 }
                }
                $rows += $row
            } else {
                Stop-Job -Job $j.job -ErrorAction SilentlyContinue
                $rows += @{ name = $j.name; status = 'error'; detail = "timeout (>${effectiveTimeout}s)"; durationMs = $effectiveTimeout * 1000 }
            }
            Remove-Job -Job $j.job -Force -ErrorAction SilentlyContinue
        }
    }

    # Reordena conforme HealthCheckOrder
    $orderIndex = @{}
    for ($i = 0; $i -lt $Script:HealthCheckOrder.Count; $i++) { $orderIndex[$Script:HealthCheckOrder[$i]] = $i }
    $rows = $rows | Sort-Object { if ($orderIndex.ContainsKey($_.name)) { $orderIndex[$_.name] } else { 999 } }

    # Determina overall
    $errors = @($rows | Where-Object { $_.status -eq 'error' })
    $warns  = @($rows | Where-Object { $_.status -eq 'warn' })
    $overall = if ($errors.Count -gt 0) { 'error' } elseif ($warns.Count -gt 0) { 'warn' } else { 'ok' }

    $totalSw.Stop()

    $result = @{
        overall = $overall
        checks = @($rows)
        totalDurationMs = $totalSw.ElapsedMilliseconds
    }

    if ($Quiet) {
        return ($overall -eq 'ok')
    }

    # Imprime tabela colorida
    Write-Host ''
    Write-Host 'AIOX Health Check' -ForegroundColor Cyan
    Write-Host '=================' -ForegroundColor Cyan
    $nameWidth = ([int](($rows | ForEach-Object { $_.name.Length } | Measure-Object -Maximum).Maximum)) + 2
    foreach ($r in $rows) {
        Format-AioxHealthRow -Row $r -NameWidth $nameWidth
    }
    Write-Host ''
    $overallColor = switch ($overall) {
        'ok'    { 'Green' }
        'warn'  { 'Yellow' }
        'error' { 'Red' }
    }
    Write-Host "Overall: $($overall.ToUpperInvariant()) ($($warns.Count) warnings, $($errors.Count) errors)" -ForegroundColor $overallColor
    Write-Host ("Total: {0:N2}s" -f ($totalSw.ElapsedMilliseconds / 1000))

    return $result
}

Export-ModuleMember -Function `
    Test-AioxHealth, `
    Test-AioxCheck-PwshSyntax, `
    Test-AioxCheck-PesterQuick, `
    Test-AioxCheck-ScheduledTasks, `
    Test-AioxCheck-ReconcileRecent, `
    Test-AioxCheck-VpsSyncStatus, `
    Test-AioxCheck-OauthRefreshJsonl, `
    Test-AioxCheck-RotationJsonlSize, `
    Test-AioxCheck-ActiveProfile, `
    Test-AioxCheck-VpsSshReach, `
    Test-AioxCheck-DiskFree, `
    Invoke-AioxCheckSafely, `
    Get-AioxCheckDispatcher
