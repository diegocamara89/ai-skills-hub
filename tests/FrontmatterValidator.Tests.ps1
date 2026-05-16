# tests/FrontmatterValidator.Tests.ps1 — Pester 5 tests for Task 11
# Validates Test-SkillFrontmatter behaviour against synthetic skill folders
# created in TestDrive (auto-cleaned by Pester).
#
# Coverage matrix:
#   1. happy path (all valid fields + optional version + body references)
#   2. missing SKILL.md
#   3. missing frontmatter delimiters
#   4. BOM warning
#   5. invalid kebab-case name
#   6. oversize description
#   7. invalid semver version (warn)
#   8. missing referenced file in body
#   9. trailing whitespace warn
#  10. missing required field (description)

BeforeAll {
    . "$PSScriptRoot/../lib/frontmatter-validator.ps1"

    # Defined in BeforeAll so it is visible at Run-time inside It blocks.
    function Write-Skill {
        param([string]$Content, [bool]$Bom = $false)
        $enc = New-Object System.Text.UTF8Encoding $Bom
        [System.IO.File]::WriteAllText($script:skillFile, $Content, $enc)
    }
}

Describe "Test-SkillFrontmatter" {

    BeforeEach {
        # Fresh per-test directory under Pester's TestDrive.
        $script:dir = Join-Path $TestDrive ("skill-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:dir -Force | Out-Null
        $script:skillFile = Join-Path $script:dir 'SKILL.md'
    }

    It "1. Happy path: returns valid=true with no errors when all fields are correct" {
        $content = @"
---
name: my-skill
description: A simple test skill that does things.
version: 1.2.3
---

# Body content here.
See references/api.md for details.
"@
        # Need the referenced file to exist.
        New-Item -ItemType Directory -Path (Join-Path $script:dir 'references') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:dir 'references/api.md') -Value '# api'
        Write-Skill -Content $content

        $result = Test-SkillFrontmatter -SkillDir $script:dir
        $result.valid | Should -BeTrue
        @($result.errors | Where-Object { $_.severity -eq 'error' }).Count | Should -Be 0
        $result.parsed.name | Should -Be 'my-skill'
        $result.parsed.description | Should -Be 'A simple test skill that does things.'
        $result.parsed.version | Should -Be '1.2.3'
    }

    It "2. Missing SKILL.md: returns error 'SKILL.md not found'" {
        # No file written.
        $result = Test-SkillFrontmatter -SkillDir $script:dir
        $result.valid | Should -BeFalse
        @($result.errors | Where-Object { $_.field -eq 'SKILL.md' -and $_.severity -eq 'error' }).Count | Should -Be 1
    }

    It "3. Missing frontmatter delimiters: returns error 'Missing YAML frontmatter'" {
        Write-Skill -Content "# Just a markdown body, no frontmatter`n"
        $result = Test-SkillFrontmatter -SkillDir $script:dir
        $result.valid | Should -BeFalse
        @($result.errors | Where-Object { $_.field -eq 'frontmatter' -and $_.severity -eq 'error' }).Count | Should -BeGreaterOrEqual 1
    }

    It "4. BOM present: emits warn but does not invalidate" {
        $content = @"
---
name: bom-skill
description: Skill written with a UTF-8 BOM.
---

body
"@
        Write-Skill -Content $content -Bom $true
        $result = Test-SkillFrontmatter -SkillDir $script:dir
        $result.valid | Should -BeTrue
        @($result.errors | Where-Object { $_.severity -eq 'warn' -and $_.reason -match 'BOM' }).Count | Should -Be 1
    }

    It "5. Invalid kebab-case name (uppercase): returns error" {
        $content = @"
---
name: MySkill
description: Bad name casing.
---
body
"@
        Write-Skill -Content $content
        $result = Test-SkillFrontmatter -SkillDir $script:dir
        $result.valid | Should -BeFalse
        @($result.errors | Where-Object { $_.field -eq 'name' -and $_.severity -eq 'error' }).Count | Should -BeGreaterOrEqual 1
    }

    It "6. Oversize description (>1024 chars): returns error" {
        $bigDesc = 'a' * 1100
        $content = @"
---
name: big-desc
description: $bigDesc
---
body
"@
        Write-Skill -Content $content
        $result = Test-SkillFrontmatter -SkillDir $script:dir
        $result.valid | Should -BeFalse
        @($result.errors | Where-Object { $_.field -eq 'description' -and $_.severity -eq 'error' }).Count | Should -BeGreaterOrEqual 1
    }

    It "7. Invalid semver version: emits warn but valid stays true" {
        $content = @"
---
name: bad-ver
description: Has a non-semver version string.
version: v1.2
---
body
"@
        Write-Skill -Content $content
        $result = Test-SkillFrontmatter -SkillDir $script:dir
        $result.valid | Should -BeTrue
        @($result.errors | Where-Object { $_.field -eq 'version' -and $_.severity -eq 'warn' }).Count | Should -Be 1
    }

    It "8. Missing referenced file: returns error" {
        $content = @"
---
name: ref-skill
description: References a file that does not exist.
---

# Body
See references/missing.md for more info.
"@
        Write-Skill -Content $content
        $result = Test-SkillFrontmatter -SkillDir $script:dir
        $result.valid | Should -BeFalse
        @($result.errors | Where-Object { $_.field -eq 'references' -and $_.severity -eq 'error' }).Count | Should -BeGreaterOrEqual 1
    }

    It "9. Trailing whitespace on frontmatter line: emits warn" {
        # Note the trailing two spaces after 'description' value.
        $content = "---`nname: trail-skill`ndescription: trailing whitespace here  `n---`n`nbody`n"
        Write-Skill -Content $content
        $result = Test-SkillFrontmatter -SkillDir $script:dir
        $result.valid | Should -BeTrue
        @($result.errors | Where-Object { $_.severity -eq 'warn' -and $_.reason -match 'Trailing whitespace' }).Count | Should -Be 1
    }

    It "10. Missing required field (description): returns error" {
        $content = @"
---
name: only-name
---
body
"@
        Write-Skill -Content $content
        $result = Test-SkillFrontmatter -SkillDir $script:dir
        $result.valid | Should -BeFalse
        @($result.errors | Where-Object { $_.field -eq 'description' -and $_.severity -eq 'error' }).Count | Should -BeGreaterOrEqual 1
    }
}
