# tests/SkillLockfile.Tests.ps1 — Pester 5 tests for lib/skill-lockfile.ps1
#
# Covers:
#   1. Get returns empty schema when file doesn't exist
#   2. Add adds entry and persists to disk
#   3. Add refreshes updatedAt across calls
#   4. Remove removes entry from disk
#   5. Get-SkillTreeHash is deterministic across two runs
#   6. Get-SkillTreeHash detects mutation in any file
#
# Bonus:
#   7. installedAt is preserved when an existing entry is updated
#   8. Lockfile JSON survives a Get -> Add -> Get roundtrip

BeforeAll {
    $repoRoot   = Split-Path -Parent $PSScriptRoot
    $libScript  = Join-Path $repoRoot 'lib\skill-lockfile.ps1'

    if (-not (Test-Path -LiteralPath $libScript)) {
        throw "skill-lockfile.ps1 not found at $libScript"
    }

    . $libScript

    function New-TempSkillDir {
        param([hashtable]$Files = @{})
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("skill-{0}" -f ([Guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        if (-not $Files -or $Files.Count -eq 0) {
            $Files = @{
                'SKILL.md'        = "# Test skill`nbody"
                'scripts/run.ps1' = "Write-Output 'hi'"
                'data/sample.txt' = "alpha`nbeta"
            }
        }
        foreach ($rel in $Files.Keys) {
            $full = Join-Path $dir $rel
            $parent = Split-Path -Parent $full
            if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            Set-Content -LiteralPath $full -Value $Files[$rel] -Encoding UTF8 -NoNewline
        }
        return $dir
    }

    function New-TempLockPath {
        $f = Join-Path ([System.IO.Path]::GetTempPath()) ("lock-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
        return $f
    }
}

Describe "Get-SkillLockfile" {
    BeforeEach {
        $script:lockPath = New-TempLockPath
    }
    AfterEach {
        if ($script:lockPath -and (Test-Path -LiteralPath $script:lockPath)) {
            Remove-Item -LiteralPath $script:lockPath -Force -ErrorAction SilentlyContinue
        }
    }

    It "Returns an empty lockfile structure when the file does not exist" {
        Test-Path -LiteralPath $script:lockPath | Should -BeFalse
        $lf = Get-SkillLockfile -Path $script:lockPath
        $lf | Should -Not -BeNullOrEmpty
        $lf['version'] | Should -Be 1
        $lf.Contains('skills') | Should -BeTrue
        $lf['skills'].Count | Should -Be 0
        $lf['updatedAt'] | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
        # Must NOT have created the file just from a Get call
        Test-Path -LiteralPath $script:lockPath | Should -BeFalse
    }
}

Describe "Add-SkillToLockfile" {
    BeforeEach {
        $script:lockPath = New-TempLockPath
        $script:skillDir = New-TempSkillDir
    }
    AfterEach {
        if ($script:lockPath -and (Test-Path -LiteralPath $script:lockPath)) {
            Remove-Item -LiteralPath $script:lockPath -Force -ErrorAction SilentlyContinue
        }
        if ($script:skillDir -and (Test-Path -LiteralPath $script:skillDir)) {
            Remove-Item -LiteralPath $script:skillDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Adds an entry, persists to disk, and round-trips" {
        Add-SkillToLockfile -Name 'spreadsheet' `
                            -Source 'anthropics/skills' `
                            -Ref 'main' `
                            -Commit 'abc123' `
                            -SkillDir $script:skillDir `
                            -Version '1.2.0' `
                            -Path $script:lockPath | Out-Null

        Test-Path -LiteralPath $script:lockPath | Should -BeTrue

        $reloaded = Get-SkillLockfile -Path $script:lockPath
        $reloaded['skills'].Contains('spreadsheet') | Should -BeTrue
        $entry = $reloaded['skills']['spreadsheet']
        $entry['source']      | Should -Be 'anthropics/skills'
        $entry['ref']         | Should -Be 'main'
        $entry['commit']      | Should -Be 'abc123'
        $entry['version']     | Should -Be '1.2.0'
        $entry['sha256_tree'] | Should -Match '^[0-9a-f]{64}$'
        # ConvertFrom-Json coerces ts strings to [DateTime]; verify ISO 8601
        # by reading the raw JSON file and matching the on-disk string.
        $rawJson = Get-Content -LiteralPath $script:lockPath -Raw -Encoding UTF8
        $rawJson | Should -Match '"installedAt":\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
    }

    It "Refreshes updatedAt between two Add calls" {
        Add-SkillToLockfile -Name 'spreadsheet' -Source 's' -Ref 'main' `
                            -Commit 'c1' -SkillDir $script:skillDir `
                            -Path $script:lockPath | Out-Null
        $first = (Get-SkillLockfile -Path $script:lockPath)['updatedAt']

        Start-Sleep -Milliseconds 25

        Add-SkillToLockfile -Name 'pdf' -Source 's' -Ref 'main' `
                            -Commit 'c2' -SkillDir $script:skillDir `
                            -Path $script:lockPath | Out-Null
        $second = (Get-SkillLockfile -Path $script:lockPath)['updatedAt']

        $second | Should -Not -Be $first
        ([datetime]$second) | Should -BeGreaterThan ([datetime]$first)
    }

    It "Preserves installedAt when an existing entry is updated" {
        Add-SkillToLockfile -Name 'spreadsheet' -Source 's' -Ref 'main' `
                            -Commit 'c1' -SkillDir $script:skillDir `
                            -Path $script:lockPath | Out-Null
        $original = (Get-SkillLockfile -Path $script:lockPath)['skills']['spreadsheet']['installedAt']

        Start-Sleep -Milliseconds 25

        # Mutate file so sha changes, then re-add with new commit.
        Set-Content -LiteralPath (Join-Path $script:skillDir 'SKILL.md') `
                    -Value "# Updated body" -Encoding UTF8 -NoNewline
        Add-SkillToLockfile -Name 'spreadsheet' -Source 's' -Ref 'main' `
                            -Commit 'c2' -SkillDir $script:skillDir `
                            -Path $script:lockPath | Out-Null

        $after = (Get-SkillLockfile -Path $script:lockPath)['skills']['spreadsheet']
        $after['installedAt'] | Should -Be $original
        $after['commit']      | Should -Be 'c2'
    }
}

Describe "Remove-SkillFromLockfile" {
    BeforeEach {
        $script:lockPath = New-TempLockPath
        $script:skillDir = New-TempSkillDir
        Add-SkillToLockfile -Name 'spreadsheet' -Source 's' -Ref 'main' `
                            -Commit 'c1' -SkillDir $script:skillDir `
                            -Path $script:lockPath | Out-Null
        Add-SkillToLockfile -Name 'pdf' -Source 's' -Ref 'main' `
                            -Commit 'c2' -SkillDir $script:skillDir `
                            -Path $script:lockPath | Out-Null
    }
    AfterEach {
        if ($script:lockPath -and (Test-Path -LiteralPath $script:lockPath)) {
            Remove-Item -LiteralPath $script:lockPath -Force -ErrorAction SilentlyContinue
        }
        if ($script:skillDir -and (Test-Path -LiteralPath $script:skillDir)) {
            Remove-Item -LiteralPath $script:skillDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Removes the named entry and persists" {
        Remove-SkillFromLockfile -Name 'pdf' -Path $script:lockPath | Out-Null

        $reloaded = Get-SkillLockfile -Path $script:lockPath
        $reloaded['skills'].Contains('pdf')         | Should -BeFalse
        $reloaded['skills'].Contains('spreadsheet') | Should -BeTrue
        $reloaded['skills'].Count                   | Should -Be 1
    }
}

Describe "Get-SkillTreeHash" {
    BeforeEach {
        $script:skillDir = New-TempSkillDir
    }
    AfterEach {
        if ($script:skillDir -and (Test-Path -LiteralPath $script:skillDir)) {
            Remove-Item -LiteralPath $script:skillDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Returns the same hash on two consecutive calls (deterministic)" {
        $h1 = Get-SkillTreeHash -SkillDir $script:skillDir
        $h2 = Get-SkillTreeHash -SkillDir $script:skillDir
        $h1 | Should -Match '^[0-9a-f]{64}$'
        $h2 | Should -Be $h1
    }

    It "Detects mutation of any file in the tree" {
        $before = Get-SkillTreeHash -SkillDir $script:skillDir
        $target = Join-Path $script:skillDir 'data\sample.txt'
        Set-Content -LiteralPath $target -Value "alpha`nbeta`ngamma" -Encoding UTF8 -NoNewline
        $after  = Get-SkillTreeHash -SkillDir $script:skillDir
        $after | Should -Not -Be $before
    }

    It "Detects newly added files" {
        $before = Get-SkillTreeHash -SkillDir $script:skillDir
        Set-Content -LiteralPath (Join-Path $script:skillDir 'NEW.md') `
                    -Value "added" -Encoding UTF8 -NoNewline
        $after = Get-SkillTreeHash -SkillDir $script:skillDir
        $after | Should -Not -Be $before
    }
}
