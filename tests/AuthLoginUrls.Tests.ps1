BeforeAll {
    . "$PSScriptRoot/../manage-skills.ps1" 2>$null

    function New-FakeSession {
        param(
            [string]$Root,
            [string]$Tool,
            [string]$ProfileName,
            [string]$StdoutContent,
            [switch]$Done
        )
        $sid = [guid]::NewGuid().ToString()
        $dir = Join-Path $Root "$Tool-$sid"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $meta = [ordered]@{
            sessionId = $sid
            tool      = $Tool
            profile   = $ProfileName
            profileDir = "C:\fake\$Tool-profiles\$ProfileName"
            createdAt = (Get-Date).ToString('o')
            donePath  = Join-Path $dir 'done.txt'
            scriptPath = Join-Path $dir 'run-login.ps1'
            stdoutPath = Join-Path $dir 'stdout.log'
        }
        $meta | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'meta.json')
        Set-Content -LiteralPath (Join-Path $dir 'stdout.log') -Value $StdoutContent

        if ($Done) {
            Set-Content -LiteralPath (Join-Path $dir 'done.txt') -Value 'ok'
        }
        return $dir
    }
}

Describe "Get-RecentAuthLoginUrls" {
    BeforeEach {
        $script:fakeRoot = Join-Path $TestDrive ('auth-state-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:fakeRoot -Force | Out-Null
    }

    It "Returns empty array when state root does not exist" {
        $result = Get-RecentAuthLoginUrls -Limit 5 -StateRoot (Join-Path $TestDrive 'nonexistent')
        ,$result | Should -HaveCount 0
    }

    It "Extracts Claude OAuth URL from stdout.log" {
        New-FakeSession -Root $script:fakeRoot -Tool 'claude' -ProfileName 'claude-a' `
            -StdoutContent "blah blah https://claude.ai/oauth/authorize?code=ABC123 more text"

        $result = @(Get-RecentAuthLoginUrls -Limit 5 -StateRoot $script:fakeRoot)
        $result.Count | Should -Be 1
        $result[0].tool | Should -Be 'claude'
        $result[0].profile | Should -Be 'claude-a'
        $result[0].loginUrl | Should -Match '^https://claude\.ai/oauth/authorize\?code=ABC123'
        $result[0].done | Should -BeFalse
    }

    It "Extracts Codex URL using codex extractor" {
        New-FakeSession -Root $script:fakeRoot -Tool 'codex' -ProfileName 'codex-b' `
            -StdoutContent "Codex login: open https://auth.openai.com/oauth/codex?state=xyz to continue" -Done

        $result = @(Get-RecentAuthLoginUrls -Limit 5 -StateRoot $script:fakeRoot)
        $result.Count | Should -Be 1
        $result[0].tool | Should -Be 'codex'
        $result[0].loginUrl | Should -Match '^https://auth\.openai\.com'
        $result[0].done | Should -BeTrue
    }

    It "Skips sessions without URL in stdout" {
        New-FakeSession -Root $script:fakeRoot -Tool 'claude' -ProfileName 'claude-x' `
            -StdoutContent "no URL here"

        $result = @(Get-RecentAuthLoginUrls -Limit 5 -StateRoot $script:fakeRoot)
        $result.Count | Should -Be 0
    }

    It "Returns sessions sorted by most recent LastWriteTime, limited" {
        $d1 = New-FakeSession -Root $script:fakeRoot -Tool 'claude' -ProfileName 'c1' `
            -StdoutContent "https://claude.ai/oauth/authorize?old=1"
        Start-Sleep -Milliseconds 50
        $d2 = New-FakeSession -Root $script:fakeRoot -Tool 'claude' -ProfileName 'c2' `
            -StdoutContent "https://claude.ai/oauth/authorize?new=2"

        $result = @(Get-RecentAuthLoginUrls -Limit 1 -StateRoot $script:fakeRoot)
        $result.Count | Should -Be 1
        $result[0].profile | Should -Be 'c2'
    }
}
