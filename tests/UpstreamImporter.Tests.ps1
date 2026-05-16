# tests/UpstreamImporter.Tests.ps1 — Pester 5 tests for lib/upstream-importer.ps1
#
# Coverage:
#   1. Resolve-UpstreamSource detects 'ccpi'
#   2. Resolve-UpstreamSource detects 'ccpm'
#   3. Resolve-UpstreamSource detects 'alireza'
#   4. Resolve-UpstreamSource detects 'anthropics' (and falls back to 'generic')
#   5. Import-FromUpstream success path: creates target folder, .skill-meta.json,
#      and registers the entry in the lockfile when git is mocked.
#   6. Import-FromUpstream surfaces stderr cleanly when git clone fails.
#
# Bonus:
#   7. Import-FromUpstream rolls back on invalid frontmatter (target removed).
#
# `git` is replaced via a fake executable (.cmd shim) that simulates clone +
# rev-parse so we never hit the network.

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'lib\skill-lockfile.ps1')
    . (Join-Path $repoRoot 'lib\frontmatter-validator.ps1')
    . (Join-Path $repoRoot 'lib\upstream-importer.ps1')

    # ---------------------------------------------------------------------
    # Fake git: a PowerShell script we point Import-FromUpstream at via the
    # -GitExecutable parameter. It supports two commands:
    #   git clone --depth 1 --branch <b> <url> <dest>   -> creates <dest> and
    #         a synthetic skill tree based on env vars FAKE_GIT_LAYOUT and
    #         FAKE_GIT_SKILL_NAME (so each test seeds its own contents).
    #   git rev-parse HEAD                              -> prints a SHA.
    # FAKE_GIT_FAIL_CLONE=1 makes clone exit non-zero with stderr.
    # ---------------------------------------------------------------------
    $script:FakeGitDir = Join-Path $TestDrive 'fake-git'
    New-Item -ItemType Directory -Path $script:FakeGitDir -Force | Out-Null
    $script:FakeGitPs1 = Join-Path $script:FakeGitDir 'fake-git.ps1'

    $fakeGitBody = @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args)

if ($env:FAKE_GIT_FAIL_CLONE -eq '1' -and $Args[0] -eq 'clone') {
    [Console]::Error.WriteLine('fatal: simulated clone failure (network down)')
    exit 128
}

if ($Args[0] -eq 'clone') {
    # Find destination (last arg). Layout flag selects folder structure.
    $dest = $Args[$Args.Count - 1]
    $layout    = if ($env:FAKE_GIT_LAYOUT)     { $env:FAKE_GIT_LAYOUT }     else { 'ccpi' }
    $skillName = if ($env:FAKE_GIT_SKILL_NAME) { $env:FAKE_GIT_SKILL_NAME } else { 'demo-skill' }
    $invalidFm = ($env:FAKE_GIT_INVALID_FRONTMATTER -eq '1')

    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    # Pretend the clone has a .git dir so it looks legit.
    New-Item -ItemType Directory -Path (Join-Path $dest '.git') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dest '.git\HEAD') -Value 'ref: refs/heads/main' -Encoding UTF8

    switch ($layout) {
        'ccpi'       { $skillDir = Join-Path $dest ("skills\" + $skillName) }
        'ccpm'       { $skillDir = Join-Path $dest ("skills\" + $skillName) }
        'alireza'    { $skillDir = Join-Path $dest ("skills\" + $skillName) }
        'anthropics' { $skillDir = Join-Path $dest $skillName }
        default      { $skillDir = Join-Path $dest $skillName }
    }
    New-Item -ItemType Directory -Path $skillDir -Force | Out-Null

    if ($invalidFm) {
        $body = "# no frontmatter at all`nbody only"
    } else {
        $body = "---`nname: $skillName`ndescription: A synthetic skill used by upstream importer tests.`nversion: 0.1.0`n---`n`n# Body`n"
    }
    Set-Content -LiteralPath (Join-Path $skillDir 'SKILL.md') -Value $body -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $skillDir 'extra.txt') -Value 'extra payload' -Encoding UTF8
    exit 0
}

if ($Args[0] -eq 'rev-parse' -and $Args[1] -eq 'HEAD') {
    Write-Output 'deadbeefcafe1234567890abcdef1234567890ab'
    exit 0
}

[Console]::Error.WriteLine("fake-git: unknown command: $($Args -join ' ')")
exit 99
'@
    Set-Content -LiteralPath $script:FakeGitPs1 -Value $fakeGitBody -Encoding UTF8

    # Wrap the .ps1 in a .cmd shim so we can pass a single string to
    # _UpstreamImporter_RunGit (which calls Process.Start). The shim lives
    # alongside the .ps1 so PSScriptRoot resolution stays clean.
    $script:FakeGitCmd = Join-Path $script:FakeGitDir 'fake-git.cmd'
    $shim = "@echo off`r`npwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$script:FakeGitPs1`" %*`r`n"
    Set-Content -LiteralPath $script:FakeGitCmd -Value $shim -Encoding ASCII

    function Reset-FakeGitEnv {
        $env:FAKE_GIT_LAYOUT               = $null
        $env:FAKE_GIT_SKILL_NAME           = $null
        $env:FAKE_GIT_FAIL_CLONE           = $null
        $env:FAKE_GIT_INVALID_FRONTMATTER  = $null
    }
}

Describe "Resolve-UpstreamSource" {

    It "Detects 'ccpi' for jeremylongshore/claude-code-plugins" {
        Resolve-UpstreamSource -Url 'https://github.com/jeremylongshore/claude-code-plugins' | Should -Be 'ccpi'
        Resolve-UpstreamSource -Url 'https://github.com/jeremylongshore/claude-code-plugins.git' | Should -Be 'ccpi'
    }

    It "Detects 'ccpm' for daymade/claude-code-skills" {
        Resolve-UpstreamSource -Url 'https://github.com/daymade/claude-code-skills' | Should -Be 'ccpm'
    }

    It "Detects 'alireza' for alirezarezvani/claude-skills" {
        Resolve-UpstreamSource -Url 'https://github.com/alirezarezvani/claude-skills' | Should -Be 'alireza'
    }

    It "Detects 'anthropics' for anthropics/skills and 'generic' for unknown URLs" {
        Resolve-UpstreamSource -Url 'https://github.com/anthropics/skills' | Should -Be 'anthropics'
        Resolve-UpstreamSource -Url 'https://github.com/some/random-repo' | Should -Be 'generic'
    }
}

Describe "Import-FromUpstream — success path (mocked git)" {

    BeforeEach {
        Reset-FakeGitEnv
        $script:scratch = Join-Path $TestDrive ("scratch-" + [guid]::NewGuid().ToString('N').Substring(0,8))
        $script:allSkillsRoot = Join-Path $script:scratch 'all-skills'
        $script:tempRoot      = Join-Path $script:scratch 'tmp'
        $script:lockPath      = Join-Path $script:scratch 'skills.lock.json'
        New-Item -ItemType Directory -Path $script:scratch -Force | Out-Null
        New-Item -ItemType Directory -Path $script:allSkillsRoot -Force | Out-Null
    }

    It "Creates target folder, .skill-meta.json, and registers in the lockfile" {
        $env:FAKE_GIT_LAYOUT     = 'anthropics'
        $env:FAKE_GIT_SKILL_NAME = 'spreadsheet'

        $result = Import-FromUpstream -Url 'https://github.com/anthropics/skills' `
                                      -SkillName 'spreadsheet' `
                                      -AllSkillsRoot $script:allSkillsRoot `
                                      -TempRoot $script:tempRoot `
                                      -LockfilePath $script:lockPath `
                                      -GitExecutable $script:FakeGitCmd

        $result.success         | Should -BeTrue
        $result.source          | Should -Be 'anthropics'
        $result.skillName       | Should -Be 'spreadsheet'
        $result.commit          | Should -Be 'deadbeefcafe1234567890abcdef1234567890ab'
        $result.lockfileUpdated | Should -BeTrue

        $target = Join-Path $script:allSkillsRoot 'spreadsheet'
        Test-Path -LiteralPath (Join-Path $target 'SKILL.md')        | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $target '.skill-meta.json')| Should -BeTrue
        Test-Path -LiteralPath (Join-Path $target 'extra.txt')       | Should -BeTrue

        $metaRaw = Get-Content -LiteralPath (Join-Path $target '.skill-meta.json') -Raw
        $meta = $metaRaw | ConvertFrom-Json
        $meta.source      | Should -Be 'anthropics'
        $meta.skillName   | Should -Be 'spreadsheet'
        $meta.originalUrl | Should -Be 'https://github.com/anthropics/skills'
        $meta.commit      | Should -Be 'deadbeefcafe1234567890abcdef1234567890ab'
        # Verify ISO 8601 importedAt by matching the raw JSON (ConvertFrom-Json
        # coerces the ts string to [DateTime] which loses the textual format).
        $metaRaw | Should -Match '"importedAt":\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'

        Test-Path -LiteralPath $script:lockPath | Should -BeTrue
        $lf = Get-SkillLockfile -Path $script:lockPath
        $lf['skills'].Contains('spreadsheet') | Should -BeTrue
        $lf['skills']['spreadsheet']['source'] | Should -Be 'anthropics'
        $lf['skills']['spreadsheet']['commit'] | Should -Be 'deadbeefcafe1234567890abcdef1234567890ab'

        # Temp clone must be cleaned up.
        @(Get-ChildItem -LiteralPath $script:tempRoot -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It "Uses ccpi adapter (skills/<name> subfolder) when URL matches jeremylongshore" {
        $env:FAKE_GIT_LAYOUT     = 'ccpi'
        $env:FAKE_GIT_SKILL_NAME = 'demo-skill'

        $result = Import-FromUpstream -Url 'https://github.com/jeremylongshore/claude-code-plugins' `
                                      -SkillName 'demo-skill' `
                                      -AllSkillsRoot $script:allSkillsRoot `
                                      -TempRoot $script:tempRoot `
                                      -LockfilePath $script:lockPath `
                                      -GitExecutable $script:FakeGitCmd

        $result.source | Should -Be 'ccpi'
        Test-Path -LiteralPath (Join-Path $script:allSkillsRoot 'demo-skill\SKILL.md') | Should -BeTrue
    }

    It "Surfaces git clone failure as a thrown exception with stderr in the message" {
        $env:FAKE_GIT_FAIL_CLONE = '1'

        $err = $null
        try {
            Import-FromUpstream -Url 'https://github.com/anthropics/skills' `
                                -SkillName 'spreadsheet' `
                                -AllSkillsRoot $script:allSkillsRoot `
                                -TempRoot $script:tempRoot `
                                -LockfilePath $script:lockPath `
                                -GitExecutable $script:FakeGitCmd | Out-Null
        } catch {
            $err = $_
        }

        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -Match 'git clone failed'
        $err.Exception.Message | Should -Match 'simulated clone failure'

        # Target must NOT be present.
        Test-Path -LiteralPath (Join-Path $script:allSkillsRoot 'spreadsheet') | Should -BeFalse
        # Lockfile must NOT have been created (no entry registered).
        if (Test-Path -LiteralPath $script:lockPath) {
            $lf = Get-SkillLockfile -Path $script:lockPath
            $lf['skills'].Contains('spreadsheet') | Should -BeFalse
        }
    }

    It "Rolls back when frontmatter validation fails" {
        $env:FAKE_GIT_LAYOUT              = 'anthropics'
        $env:FAKE_GIT_SKILL_NAME          = 'broken-skill'
        $env:FAKE_GIT_INVALID_FRONTMATTER = '1'

        { Import-FromUpstream -Url 'https://github.com/anthropics/skills' `
                              -SkillName 'broken-skill' `
                              -AllSkillsRoot $script:allSkillsRoot `
                              -TempRoot $script:tempRoot `
                              -LockfilePath $script:lockPath `
                              -GitExecutable $script:FakeGitCmd } | Should -Throw

        Test-Path -LiteralPath (Join-Path $script:allSkillsRoot 'broken-skill') | Should -BeFalse
    }
}
