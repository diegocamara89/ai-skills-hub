# Tests for the Gemini auth backend added to manage-skills.ps1.
#
# Scope: pure unit behavior of Get-GeminiAuthUrlFromText, Add-GeminiProfile and
# Get-GeminiProfiles. Tests use $TestDrive overrides and never touch the user's
# real ~/.gemini-profiles directory. Login flow (Start-GeminiAuthLogin) is not
# covered here because it spawns a Windows Terminal session — that path is
# exercised by manual smoke tests instead.

BeforeAll {
    . "$PSScriptRoot/../manage-skills.ps1" 2>$null
}

Describe "Get-GeminiAuthUrlFromText" {
    It "Extracts Google accounts.google.com OAuth URL" {
        $text = "Open this URL in a browser: https://accounts.google.com/o/oauth2/v2/auth?client_id=abc&scope=email more"
        $url = Get-GeminiAuthUrlFromText -Text $text
        $url | Should -Match '^https://accounts\.google\.com/o/oauth2/v2/auth\?client_id=abc'
    }

    It "Extracts oauth2.googleapis.com URL when present" {
        $text = "redirect: https://oauth2.googleapis.com/token?foo=bar end"
        Get-GeminiAuthUrlFromText -Text $text | Should -Match '^https://oauth2\.googleapis\.com/token'
    }

    It "Falls back to first https:// match" {
        $text = "see https://example.com/auth?x=1 here"
        Get-GeminiAuthUrlFromText -Text $text | Should -Be 'https://example.com/auth?x=1'
    }

    It "Returns null on empty input" {
        Get-GeminiAuthUrlFromText -Text '' | Should -BeNullOrEmpty
        Get-GeminiAuthUrlFromText -Text $null | Should -BeNullOrEmpty
    }

    It "Returns null when no URL present" {
        Get-GeminiAuthUrlFromText -Text 'no url here' | Should -BeNullOrEmpty
    }
}

Describe "Add-GeminiProfile" {
    BeforeEach {
        $script:fakeRoot = Join-Path $TestDrive ('gemini-profiles-' + [guid]::NewGuid())
    }

    It "Rejects names with invalid characters" {
        { Add-GeminiProfile -Name 'Bad Name!' -ProfilesRoot $script:fakeRoot } | Should -Throw
        { Add-GeminiProfile -Name 'GEMINI-X' -ProfilesRoot $script:fakeRoot } | Should -Throw
        { Add-GeminiProfile -Name 'with/slash' -ProfilesRoot $script:fakeRoot } | Should -Throw
    }

    It "Rejects the reserved name 'active'" {
        { Add-GeminiProfile -Name 'active' -ProfilesRoot $script:fakeRoot } | Should -Throw
    }

    It "Creates the profile directory under the profiles root" {
        $r = Add-GeminiProfile -Name 'gemini-a' -ProfilesRoot $script:fakeRoot
        $r.added | Should -BeTrue
        $r.name  | Should -Be 'gemini-a'
        Test-Path -LiteralPath $r.configDir -PathType Container | Should -BeTrue
        $r.configDir | Should -Be (Join-Path $script:fakeRoot 'gemini-a')
    }

    It "Refuses to create a profile that already exists" {
        Add-GeminiProfile -Name 'gemini-a' -ProfilesRoot $script:fakeRoot | Out-Null
        { Add-GeminiProfile -Name 'gemini-a' -ProfilesRoot $script:fakeRoot } | Should -Throw
    }

    It "Accepts generic lowercase names too" {
        $r = Add-GeminiProfile -Name 'work01' -ProfilesRoot $script:fakeRoot
        $r.name | Should -Be 'work01'
    }
}

Describe "Get-GeminiProfiles" {
    BeforeEach {
        $script:fakeRoot = Join-Path $TestDrive ('gemini-profiles-' + [guid]::NewGuid())
    }

    It "Returns empty array when profiles root does not exist" {
        $r = @(Get-GeminiProfiles -ProfilesRoot (Join-Path $TestDrive 'does-not-exist'))
        $r.Count | Should -Be 0
    }

    It "Detects profiles with and without oauth_creds.json" {
        New-Item -ItemType Directory -Path $script:fakeRoot -Force | Out-Null
        $a = Join-Path $script:fakeRoot 'gemini-a'
        $b = Join-Path $script:fakeRoot 'gemini-b'
        New-Item -ItemType Directory -Path $a -Force | Out-Null
        New-Item -ItemType Directory -Path $b -Force | Out-Null
        '{"access_token":"fake"}' | Set-Content -LiteralPath (Join-Path $a 'oauth_creds.json') -Encoding UTF8

        $r = @(Get-GeminiProfiles -ProfilesRoot $script:fakeRoot) | Sort-Object name

        $r.Count | Should -Be 2
        ($r | Where-Object { $_.name -eq 'gemini-a' }).hasAuth | Should -BeTrue
        ($r | Where-Object { $_.name -eq 'gemini-b' }).hasAuth | Should -BeFalse
    }
}
