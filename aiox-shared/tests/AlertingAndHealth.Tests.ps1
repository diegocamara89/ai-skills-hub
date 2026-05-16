#Requires -Version 7.0
#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

# aiox-shared/tests/AlertingAndHealth.Tests.ps1
#
# Hardening #1 — Pester suite for the proactive Telegram alerts pipeline:
#     Alerting.psm1       (Send-AioxAlert + Get-MessageHash)
#     VpsAuthHealth.psm1  (Test-VpsAuthHealth)
#     HealthMonitor.psm1  (Invoke-AioxHealthMonitorTick)
#
# All tests are hermetic: NO real ssh, NO real Telegram, NO HKCU writes,
# NO Scheduled Task registration. SSH/Telegram are injected via
# -TransportOverride scriptblocks built via the New-*Stub* helpers below.
#
# Why factory-built scriptblocks (not $using: or closures over $script:vars):
#   The transport overrides are invoked from INSIDE a different module
#   (HealthMonitor / VpsAuthHealth). PowerShell scoping means $script:foo
#   inside those scriptblocks resolves against the *invoking module's*
#   script scope, not this test file's. $using: only works in jobs and
#   remoting. The portable solution is to splice the payload string into a
#   freshly compiled scriptblock body so the value travels intrinsically.

BeforeAll {
    $script:HereRoot = (Resolve-Path "$PSScriptRoot/..").Path
    $script:AlertingPath  = Join-Path $script:HereRoot 'Alerting.psm1'
    $script:HealthPath    = Join-Path $script:HereRoot 'VpsAuthHealth.psm1'
    $script:MonitorPath   = Join-Path $script:HereRoot 'HealthMonitor.psm1'

    # Order matters: HealthMonitor.psm1 internally imports Alerting +
    # VpsAuthHealth + StructuredLogger with -Force. If we imported those
    # FIRST with -Global, the nested -Force inside HealthMonitor would
    # displace them out of the global scope. So we import HealthMonitor
    # FIRST, THEN re-import the leaves with -Global so the exported
    # Send-AioxAlert / Test-VpsAuthHealth / Get-MessageHash are visible
    # directly in It blocks.
    Import-Module $script:MonitorPath  -Force -DisableNameChecking -Global
    Import-Module $script:AlertingPath -Force -DisableNameChecking -Global
    Import-Module $script:HealthPath   -Force -DisableNameChecking -Global

    function script:New-SshStubOk {
        param([string]$Output = '')
        $safe = $Output -replace "'", "''"
        return [scriptblock]::Create("param(`$vh,`$win,`$pat) @{ ok = `$true; output = '$safe' }")
    }
    function script:New-SshStubFail {
        param([string]$Reason)
        return [scriptblock]::Create("param(`$vh,`$win,`$pat) @{ ok = `$false; reason = '$Reason' }")
    }
    function script:New-AlertStubOk {
        return [scriptblock]::Create("param(`$h,`$a,`$c,`$m) @{ ok = `$true }")
    }
    function script:New-AlertStubFail {
        param([string]$Reason)
        return [scriptblock]::Create("param(`$h,`$a,`$c,`$m) @{ ok = `$false; reason = '$Reason' }")
    }
}

# ────────────────────────────────────────────────────────────────────────────
Describe "Send-AioxAlert throttle + transport" {

    BeforeEach {
        # Per-test isolated state/log roots so we never touch the real
        # ~/.claude-orchestrator/usage/* files.
        $script:tmpRoot = Join-Path $TestDrive ("alert-$(Get-Random)")
        $script:stateRoot = Join-Path $script:tmpRoot 'state'
        $script:logRoot   = Join-Path $script:tmpRoot 'logs'
        New-Item -ItemType Directory -Path $script:stateRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $script:logRoot   -Force | Out-Null
    }

    It "delivers when SSH transport reports ok=true and persists throttle stamp" {
        $okTransport = New-AlertStubOk

        $r = Send-AioxAlert -Message 'VPS auth refresh loop' `
            -StateRoot $script:stateRoot -LogRoot $script:logRoot `
            -TransportOverride $okTransport

        $r.delivered | Should -BeTrue
        $r.reason    | Should -Be 'sent'

        $throttleFile = Join-Path $script:stateRoot 'alert-throttle.json'
        Test-Path -LiteralPath $throttleFile | Should -BeTrue

        $state = Get-Content -LiteralPath $throttleFile -Raw | ConvertFrom-Json
        @($state.PSObject.Properties).Count | Should -Be 1
    }

    It "throttles duplicate message within 30 min window" {
        $okTransport = New-AlertStubOk

        $r1 = Send-AioxAlert -Message 'Token refresh failed: 401' `
            -StateRoot $script:stateRoot -LogRoot $script:logRoot `
            -TransportOverride $okTransport
        $r1.delivered | Should -BeTrue

        $r2 = Send-AioxAlert -Message 'Token refresh failed: 401' `
            -StateRoot $script:stateRoot -LogRoot $script:logRoot `
            -TransportOverride $okTransport
        $r2.delivered | Should -BeFalse
        $r2.reason    | Should -Be 'throttled'
    }

    It "falls back to alerts-undelivered.jsonl when SSH fails" {
        $failTransport = New-AlertStubFail -Reason 'ssh_timeout'

        $r = Send-AioxAlert -Message 'Critical: codex auth lapsed' `
            -StateRoot $script:stateRoot -LogRoot $script:logRoot `
            -Severity 'error' -TransportOverride $failTransport

        $r.delivered | Should -BeFalse
        $r.reason    | Should -Be 'ssh_timeout'

        $undelivered = Join-Path $script:logRoot 'alerts-undelivered.jsonl'
        Test-Path -LiteralPath $undelivered | Should -BeTrue

        $line = Get-Content -LiteralPath $undelivered -Tail 1
        $entry = $line | ConvertFrom-Json
        $entry.severity | Should -Be 'error'
        $entry.reason   | Should -Be 'ssh_timeout'
        $entry.message  | Should -Match 'codex auth lapsed'
    }

    It "does NOT update throttle when SSH delivery fails (so retry can succeed)" {
        $failTransport = New-AlertStubFail -Reason 'ssh_exit_255'

        $r1 = Send-AioxAlert -Message 'msg-A' `
            -StateRoot $script:stateRoot -LogRoot $script:logRoot `
            -TransportOverride $failTransport
        $r1.delivered | Should -BeFalse

        # Now simulate a successful retry: same message must NOT be throttled,
        # because the first attempt failed.
        $okTransport = New-AlertStubOk
        $r2 = Send-AioxAlert -Message 'msg-A' `
            -StateRoot $script:stateRoot -LogRoot $script:logRoot `
            -TransportOverride $okTransport

        $r2.delivered | Should -BeTrue
        $r2.reason    | Should -Be 'sent'
    }
}

# ────────────────────────────────────────────────────────────────────────────
Describe "Test-VpsAuthHealth probe" {

    It "returns healthy=`$null when SSH transport reports failure" {
        $sshFail = New-SshStubFail -Reason 'ssh_unreachable'

        $h = Test-VpsAuthHealth -TransportOverride $sshFail

        $h.healthy | Should -BeNullOrEmpty   # $null
        $h.reason  | Should -Be 'ssh_unreachable'
    }

    It "returns healthy=`$true when probe returns 0 matching lines" {
        $sshEmpty = New-SshStubOk -Output ''

        $h = Test-VpsAuthHealth -TransportOverride $sshEmpty

        $h.healthy | Should -BeTrue
    }

    It "returns healthy=`$false count=5 when >=3 matches present" {
        $lines5 = @(
            'May 10 22:01:00 host claude[1]: [openai-codex] Token refresh failed: 401'
            'May 10 22:07:00 host claude[1]: [openai-codex] Token refresh failed: 401'
            'May 10 22:13:00 host claude[1]: [openai-codex] Token refresh failed: 401'
            'May 10 22:19:00 host claude[1]: FailoverError: retrying'
            'May 10 22:25:00 host claude[1]: [openai-codex] Token refresh failed: 401'
        ) -join "`n"
        $sshHits = New-SshStubOk -Output $lines5

        $h = Test-VpsAuthHealth -TransportOverride $sshHits

        $h.healthy   | Should -BeFalse
        $h.reason    | Should -Be 'token_refresh_loop'
        $h.count     | Should -Be 5
        $h.firstSeen | Should -Not -BeNullOrEmpty
    }

    It "stays healthy when match count < Threshold (default 3)" {
        # 2 hits -> below threshold -> healthy
        $lines2 = @(
            'Token refresh failed: 401'
            'Token refresh failed: 401'
        ) -join "`n"
        $sshTwo = New-SshStubOk -Output $lines2

        $h = Test-VpsAuthHealth -TransportOverride $sshTwo

        $h.healthy | Should -BeTrue
        $h.count   | Should -Be 2
    }
}

# ────────────────────────────────────────────────────────────────────────────
Describe "Invoke-AioxHealthMonitorTick orchestration" {

    BeforeEach {
        $script:tmpRoot   = Join-Path $TestDrive ("monitor-$(Get-Random)")
        $script:stateRoot = Join-Path $script:tmpRoot 'state'
        $script:logRoot   = Join-Path $script:tmpRoot 'logs'
        New-Item -ItemType Directory -Path $script:stateRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $script:logRoot   -Force | Out-Null
        $script:monitorLog = Join-Path $script:logRoot 'health-monitor.jsonl'
    }

    It "does NOT alert when health probe says healthy=true" {
        $sshEmpty = New-SshStubOk -Output ''
        # Track sender invocations via a script-scope counter file. We can't
        # rely on -AlertSender closures sharing $script:vars across module
        # boundaries, so we use a side-effect file.
        $sentinel = Join-Path $script:tmpRoot 'sender-called.txt'
        $fakeSender = [scriptblock]::Create("param(`$msg) Add-Content -LiteralPath '$sentinel' -Value `$msg; @{ delivered = `$true; reason = 'sent' }")

        $r = Invoke-AioxHealthMonitorTick `
            -LogPath $script:monitorLog `
            -HealthTransportOverride $sshEmpty `
            -AlertSender $fakeSender

        $r.event | Should -Be 'health_ok'
        Test-Path -LiteralPath $sentinel | Should -BeFalse

        # Log line was emitted with event=health_ok and level=info
        Test-Path -LiteralPath $script:monitorLog | Should -BeTrue
        $line = Get-Content -LiteralPath $script:monitorLog -Tail 1
        $entry = $line | ConvertFrom-Json
        $entry.event | Should -Be 'health_ok'
        $entry.level | Should -Be 'info'
    }

    It "DOES alert when health probe says healthy=false" {
        $bigOutput = (1..5 | ForEach-Object { 'May 10 22:0' + $_ + ':00 host x: Token refresh failed: 401' }) -join "`n"
        $sshHits = New-SshStubOk -Output $bigOutput

        $sentinel = Join-Path $script:tmpRoot 'sender-called.txt'
        $fakeSender = [scriptblock]::Create("param(`$msg) Add-Content -LiteralPath '$sentinel' -Value `$msg; @{ delivered = `$true; reason = 'sent' }")

        $r = Invoke-AioxHealthMonitorTick `
            -LogPath $script:monitorLog `
            -HealthTransportOverride $sshHits `
            -AlertSender $fakeSender

        $r.event     | Should -Be 'health_unhealthy'
        $r.alertSent | Should -BeTrue
        Test-Path -LiteralPath $sentinel | Should -BeTrue
        (Get-Content -LiteralPath $sentinel -Raw) | Should -Match 'token_refresh_loop'

        # JSON-line log written with event=health_unhealthy + level=error
        $line = Get-Content -LiteralPath $script:monitorLog -Tail 1
        $entry = $line | ConvertFrom-Json
        $entry.event | Should -Be 'health_unhealthy'
        $entry.level | Should -Be 'error'
        $entry.count | Should -Be 5
        $entry.alertSent | Should -BeTrue
    }

    It "logs event=health_unreachable when SSH probe fails (no alert)" {
        $sshFail = New-SshStubFail -Reason 'ssh_unreachable'
        $sentinel = Join-Path $script:tmpRoot 'sender-called.txt'
        $fakeSender = [scriptblock]::Create("param(`$msg) Add-Content -LiteralPath '$sentinel' -Value `$msg; @{ delivered = `$true; reason = 'sent' }")

        $r = Invoke-AioxHealthMonitorTick `
            -LogPath $script:monitorLog `
            -HealthTransportOverride $sshFail `
            -AlertSender $fakeSender

        $r.event | Should -Be 'health_unreachable'
        Test-Path -LiteralPath $sentinel | Should -BeFalse

        $line = Get-Content -LiteralPath $script:monitorLog -Tail 1
        $entry = $line | ConvertFrom-Json
        $entry.event | Should -Be 'health_unreachable'
        $entry.level | Should -Be 'warn'
        $entry.reason | Should -Be 'ssh_unreachable'
    }

    It "structured log entries always carry event and level fields" {
        # Run all three branches and verify every produced JSON line has both
        $sshEmpty = New-SshStubOk -Output ''
        $sshFail  = New-SshStubFail -Reason 'ssh_unreachable'
        $bigOutput = (1..3 | ForEach-Object { 'May 10 22:0' + $_ + ':00 host x: Token refresh failed: 401' }) -join "`n"
        $sshHits  = New-SshStubOk -Output $bigOutput
        $okSender = [scriptblock]::Create("param(`$msg) @{ delivered = `$true; reason = 'sent' }")

        Invoke-AioxHealthMonitorTick -LogPath $script:monitorLog `
            -HealthTransportOverride $sshEmpty -AlertSender $okSender | Out-Null
        Invoke-AioxHealthMonitorTick -LogPath $script:monitorLog `
            -HealthTransportOverride $sshFail  -AlertSender $okSender | Out-Null
        Invoke-AioxHealthMonitorTick -LogPath $script:monitorLog `
            -HealthTransportOverride $sshHits  -AlertSender $okSender | Out-Null

        $allLines = Get-Content -LiteralPath $script:monitorLog
        $allLines.Count | Should -Be 3
        foreach ($l in $allLines) {
            $e = $l | ConvertFrom-Json
            $e.event | Should -Not -BeNullOrEmpty
            $e.level | Should -Not -BeNullOrEmpty
            $e.ts    | Should -Not -BeNullOrEmpty
        }
    }
}

# ────────────────────────────────────────────────────────────────────────────
Describe "Get-MessageHash determinism" {

    It "same message produces identical hash regardless of leading/trailing whitespace + casing" {
        (Get-MessageHash -Message 'Hello World') | Should -Be (Get-MessageHash -Message '  hello WORLD  ')
    }

    It "different message produces different hash" {
        (Get-MessageHash -Message 'A') | Should -Not -Be (Get-MessageHash -Message 'B')
    }
}
