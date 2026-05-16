[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = "help",

    [string]$ProjectPath,

    [string[]]$Skills = @(),

    [switch]$Install,

    [switch]$DryRun,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Script:IsUiCommand = $Command.ToLowerInvariant() -eq "ui"
$Script:HubRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:AllSkillsRoot = Join-Path $Script:HubRoot "all-skills"
$Script:GlobalSkillsRoot = Join-Path $Script:HubRoot "global-skills"
$Script:BackupsRoot = Join-Path $Script:HubRoot "backups"
$Script:StateRoot = Join-Path $Script:HubRoot "state"
$Script:NativeIntegrationsRoot = Join-Path $Script:StateRoot "native-integrations"
$Script:SuperpowersCheckoutRoot = Join-Path $Script:NativeIntegrationsRoot "superpowers"
$Script:ClaudeAuthStateRoot = Join-Path $Script:StateRoot "claude-auth"
$Script:ImportReportJson = Join-Path $Script:StateRoot "import-report.json"
$Script:ImportReportMd = Join-Path $Script:StateRoot "import-report.md"
$Script:GlobalGeminiGenerated = Join-Path $Script:StateRoot "gemini-global.generated.md"
$Script:ManagedTargetsStateJson = Join-Path $Script:StateRoot "managed-targets.json"
$Script:UserProfileRoot = if ((-not $Script:IsUiCommand) -and $env:AI_SKILLS_USERPROFILE_ROOT) { $env:AI_SKILLS_USERPROFILE_ROOT } elseif ($env:USERPROFILE) { $env:USERPROFILE } else { [Environment]::GetFolderPath("UserProfile") }
$Script:RoamingAppDataRoot = if ((-not $Script:IsUiCommand) -and $env:AI_SKILLS_APPDATA_ROOT) { $env:AI_SKILLS_APPDATA_ROOT } elseif ($env:APPDATA) { $env:APPDATA } else { [Environment]::GetFolderPath("ApplicationData") }
$Script:LocalAppDataRoot = if ((-not $Script:IsUiCommand) -and $env:AI_SKILLS_LOCALAPPDATA_ROOT) { $env:AI_SKILLS_LOCALAPPDATA_ROOT } elseif ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [Environment]::GetFolderPath("LocalApplicationData") }
$Script:ClaudeOrchestratorRoot = Join-Path $Script:UserProfileRoot ".claude-orchestrator"
$Script:ClaudeUsageStateRoot = Join-Path $Script:ClaudeOrchestratorRoot "usage"
$Script:ClaudeStatuslineToolsRoot = Join-Path $Script:ClaudeOrchestratorRoot "statusline-tools"
$Script:GeminiRoot = Join-Path $Script:UserProfileRoot ".gemini"
$Script:GeminiLegacySkillsRoot = Join-Path $Script:GeminiRoot "antigravity\skills"
$Script:LegacyGeminiSkillNames = @(
    "defuddle",
    "json-canvas",
    "obsidian-bases",
    "obsidian-cli",
    "obsidian-markdown"
)

$Script:RecommendedGlobalSkills = @(
    "doc",
    "napkin",
    "orchestrate",
    "pdf",
    "persona-bridge",
    "playwright",
    "spreadsheet",
    "subagent-creator"
)

# Dot-source library helpers (Task 9/10/11). These provide:
#   - Get-SkillLockfile / Add-SkillToLockfile / Get-SkillTreeHash
#   - Test-SkillFrontmatter
#   - Resolve-UpstreamSource / Import-FromUpstream
# Each lib is self-contained and has no load-time side-effects.
foreach ($_libRel in @('lib\skill-lockfile.ps1', 'lib\frontmatter-validator.ps1', 'lib\upstream-importer.ps1')) {
    $_libPath = Join-Path $Script:HubRoot $_libRel
    if (Test-Path -LiteralPath $_libPath) {
        . $_libPath
    }
}

function Write-Step {
    param([string]$Message)
    Write-Host "[AI-SKILLS] $Message"
}

function Set-NoCacheHeaders {
    param($Response)

    $Response.Headers["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
    $Response.Headers["Pragma"] = "no-cache"
    $Response.Headers["Expires"] = "0"
}

function Normalize-FullPath {
    param([string]$Path)
    $p = $Path
    # Strip Windows internal path prefixes that junction .Target may return
    if     ($p.StartsWith('\??\'))  { $p = $p.Substring(4) }
    elseif ($p.StartsWith('\\?\')) { $p = $p.Substring(4) }
    elseif ($p.StartsWith('\?\'))  { $p = $p.Substring(3) }
    return [System.IO.Path]::GetFullPath($p)
}

function Join-UserProfilePath {
    param([string]$RelativePath)
    return Join-Path $Script:UserProfileRoot $RelativePath
}

function Get-RuntimeInfo {
    return [ordered]@{
        pid = $PID
        hubRoot = $Script:HubRoot
        userProfileRoot = $Script:UserProfileRoot
        roamingAppDataRoot = $Script:RoamingAppDataRoot
        localAppDataRoot = $Script:LocalAppDataRoot
        managedTargetsState = $Script:ManagedTargetsStateJson
        globalSkillsRoot = $Script:GlobalSkillsRoot
        nativeIntegrationsRoot = $Script:NativeIntegrationsRoot
        claudeAuthStateRoot = $Script:ClaudeAuthStateRoot
        claudeUsageStateRoot = $Script:ClaudeUsageStateRoot
    }
}

function Get-LatestClaudeCliPath {
    $candidates = @()

    # 1. Check AppData Packages folder (old installer)
    $packagesRoot = Join-Path $Script:LocalAppDataRoot "Packages"
    if (Test-Path -LiteralPath $packagesRoot) {
        $patterns = @(
            (Join-Path $packagesRoot "Claude_*\LocalCache\Roaming\Claude\claude-code\*\claude.exe"),
            (Join-Path $packagesRoot "Claude*\LocalCache\Roaming\Claude\claude-code\*\claude.exe")
        )
        foreach ($pattern in $patterns) {
            $candidates += @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue)
        }
    }

    # 2. Check .local\bin (new default installer)
    $localBin = Join-Path $Script:UserProfileRoot ".local\bin\claude.exe"
    if (Test-Path -LiteralPath $localBin) {
        $candidates += [System.IO.FileInfo]::new($localBin)
    }

    # 3. Check System PATH
    $pathCommand = Get-Command "claude.exe" -ErrorAction SilentlyContinue
    if ($pathCommand) {
        $candidates += [System.IO.FileInfo]::new($pathCommand.Source)
    }

    if ($candidates.Count -eq 0) {
        # Fallback to 'claude' without .exe extension for unix-like or shim environments
        $pathFallback = Get-Command "claude" -ErrorAction SilentlyContinue
        if ($pathFallback) {
            return $pathFallback.Source
        }
        return $null
    }

    $selected = $candidates | Select-Object -Unique FullName | ForEach-Object { [System.IO.FileInfo]::new($_.FullName) } | Sort-Object @{
        Expression = {
            # Try to get version from directory name first (Packages layout)
            if ($_.Directory.Name -match '^\d+\.\d+\.') {
                try { return [version]$_.Directory.Name } catch {}
            }
            # Try to get version from file version info
            if ($_.VersionInfo.ProductVersion -match '^\d+\.\d+\.') {
                try { return [version]($_.VersionInfo.ProductVersion -replace '^([0-9.]+).*', '$1') } catch {}
            }
            # Fallback
            return [version]"0.0"
        }
    } -Descending | Select-Object -First 1

    return $selected.FullName
}

function Get-NpmCmdShimPath {
    param([string]$CommandName)

    $candidate = Join-Path $Script:RoamingAppDataRoot "npm\$CommandName.cmd"
    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }

    $cmd = Get-Command "$CommandName.cmd" -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    $fallback = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($fallback) {
        return $fallback.Source
    }

    return $null
}

function Get-SuperpowersCheckoutPath {
    return $Script:SuperpowersCheckoutRoot
}

function Get-SuperpowersSkillDirs {
    param([string]$RepoPath = $(Get-SuperpowersCheckoutPath))

    $skillsRoot = Join-Path $RepoPath "skills"
    if (-not (Test-Path -LiteralPath $skillsRoot)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $skillsRoot -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "SKILL.md") }
    )
}

function Get-RepoImportValidation {
    param(
        [string]$RepoPath,
        [string]$RepoName
    )

    $rootSkill = Join-Path $RepoPath "SKILL.md"
    if (Test-Path -LiteralPath $rootSkill) {
        return [pscustomobject]@{
            IsValid = $true
            Reason = ""
        }
    }

    $skillsDir = Join-Path $RepoPath "skills"
    if (Test-Path -LiteralPath $skillsDir) {
        return [pscustomobject]@{
            IsValid = $false
            Reason = "O repositorio '$RepoName' parece ser um pacote nativo ou multi-skill. Use a sincronizacao nativa em vez de importar a raiz."
        }
    }

    return [pscustomobject]@{
        IsValid = $false
        Reason = "O repositorio '$RepoName' nao possui SKILL.md na raiz e nao pode ser importado como uma skill unica."
    }
}

function Get-SuperpowersNativeStatus {
    $repoPath = Get-SuperpowersCheckoutPath
    $repoPresent = Test-Path -LiteralPath $repoPath
    $skillDirs = @(Get-SuperpowersSkillDirs -RepoPath $repoPath)
    $claudeCli = Get-LatestClaudeCliPath
    $claudeMarketplacePath = Join-UserProfilePath ".claude\plugins\marketplaces\claude-plugins-official\.claude-plugin\marketplace.json"
    $claudeMarketplaceAvailable = $false
    if (Test-Path -LiteralPath $claudeMarketplacePath) {
        $claudeMarketplaceAvailable = (Get-Content -LiteralPath $claudeMarketplacePath -Raw) -match '"superpowers"'
    }

    $claudePluginsRoot = Join-UserProfilePath ".claude\plugins"
    $claudeInstalled = $false
    if (Test-Path -LiteralPath $claudePluginsRoot) {
        $installedPluginsJson = Join-Path $claudePluginsRoot "installed_plugins.json"
        if (Test-Path -LiteralPath $installedPluginsJson) {
            try {
                $installedJson = Get-Content -LiteralPath $installedPluginsJson -Raw | ConvertFrom-Json
                if ($installedJson.plugins.PSObject.Properties.Name -contains "superpowers@claude-plugins-official") {
                    $claudeInstalled = $true
                }
            } catch {
                $claudeInstalled = $false
            }
        }

        if (-not $claudeInstalled) {
            $claudeInstalled = @(
                Get-ChildItem -LiteralPath $claudePluginsRoot -Recurse -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match "superpowers" }
            ).Count -gt 0
        }
    }

    $codexUserRoot = Join-UserProfilePath ".agents\skills"
    $codexLegacyRoot = Join-UserProfilePath ".codex\skills"
    $codexUserSynced = @()
    $codexLegacySynced = @()
    foreach ($skillDir in $skillDirs) {
        if (Test-Path -LiteralPath (Join-Path $codexUserRoot $skillDir.Name)) {
            $codexUserSynced += $skillDir.Name
        }
        if (Test-Path -LiteralPath (Join-Path $codexLegacyRoot $skillDir.Name)) {
            $codexLegacySynced += $skillDir.Name
        }
    }

    $geminiCmd = Get-NpmCmdShimPath -CommandName "gemini"
    $geminiExtensionsRoot = Join-UserProfilePath ".gemini\extensions"
    $geminiManifestPath = Join-Path $repoPath "gemini-extension.json"
    $geminiInstalled = $false
    if (Test-Path -LiteralPath $geminiExtensionsRoot) {
        $geminiInstalled = @(
            Get-ChildItem -LiteralPath $geminiExtensionsRoot -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "superpowers" }
        ).Count -gt 0
    }

    return [pscustomobject]@{
        repoPresent = $repoPresent
        checkoutPath = $repoPath
        childSkills = @($skillDirs | Select-Object -ExpandProperty Name)
        claude = [ordered]@{
            cliPath = $claudeCli
            marketplaceAvailable = $claudeMarketplaceAvailable
            installed = $claudeInstalled
        }
        codex = [ordered]@{
            availableSkillCount = $skillDirs.Count
            userRoot = $codexUserRoot
            legacyRoot = $codexLegacyRoot
            userSynced = @($codexUserSynced | Sort-Object -Unique)
            legacySynced = @($codexLegacySynced | Sort-Object -Unique)
        }
        gemini = [ordered]@{
            cliPath = $geminiCmd
            extensionRoot = $geminiExtensionsRoot
            manifestPresent = (Test-Path -LiteralPath $geminiManifestPath)
            installed = $geminiInstalled
        }
    }
}

function Get-ClaudeOrchestratorConfigPath {
    return Join-Path $Script:ClaudeOrchestratorRoot "config.json"
}

function Get-ClaudeOrchestratorConfig {
    param(
        [string]$ConfigPath
    )

    $configPath = if ($ConfigPath) { $ConfigPath } else { Get-ClaudeOrchestratorConfigPath }
    if (-not (Test-Path -LiteralPath $configPath)) {
        return $null
    }

    return Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
}

function ConvertTo-ClaudeOrderedDictionary {
    param([object]$InputObject)

    $result = [ordered]@{}
    if ($null -eq $InputObject) {
        return $result
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($entry in $InputObject.GetEnumerator()) {
            $result[$entry.Key] = $entry.Value
        }
        return $result
    }

    foreach ($prop in $InputObject.PSObject.Properties) {
        $result[$prop.Name] = $prop.Value
    }

    return $result
}

function Expand-ClaudePath {
    param([string]$Path)

    if (-not $Path) {
        return $Path
    }

    $expanded = [Environment]::ExpandEnvironmentVariables([string]$Path)
    if ($expanded.StartsWith("~")) {
        $home = $Script:UserProfileRoot
        $relative = $expanded.Substring(1).TrimStart("\", "/")
        if ($relative) {
            return Join-Path $home $relative
        }
        return $home
    }

    return $expanded
}

function Get-ClaudeAccountStatePath {
    $config = Get-ClaudeOrchestratorConfig
    if ($config -and $config.state_file) {
        return Expand-ClaudePath -Path ([string]$config.state_file)
    }

    return Join-Path $Script:ClaudeOrchestratorRoot "state.json"
}

function New-ClaudeAccountStateStore {
    return [ordered]@{
        version = 1
        updatedAt = $null
        profiles = [ordered]@{}
    }
}

function New-ClaudeProfileRuntimeState {
    param(
        [string]$ProfileName,
        [string]$ConfigDir
    )

    return [ordered]@{
        profileId = [string]$ProfileName
        configDir = [string]$ConfigDir
        loggedIn = $false
        state = "auth_required"
        leaseOwner = ""
        leaseExpiresAt = $null
        cooldownUntil = $null
        lastSuccessAt = $null
        lastFailureAt = $null
        lastFailureKind = ""
        lastKnownModel = ""
        quotaNote = ""
    }
}

function Normalize-ClaudeProfileRuntimeState {
    param(
        [System.Collections.IDictionary]$State,
        [ValidateSet("state", "cli")]
        [string]$Source = "state"
    )

    if ($null -eq $State) {
        return $null
    }

    switch ($Source) {
        "cli" {
            if ($State.Contains("loggedIn")) {
                if (-not [bool]$State["loggedIn"]) {
                    $State["state"] = "auth_required"
                }
                elseif (-not $State["state"] -or $State["state"] -eq "auth_required") {
                    $State["state"] = "available"
                }
            }
        }
        default {
            if (-not $State["state"]) {
                $State["state"] = if ([bool]$State["loggedIn"]) { "available" } else { "auth_required" }
            }

            if ($State["state"] -eq "auth_required") {
                $State["loggedIn"] = $false
            }
        }
    }

    if (-not $State["state"]) {
        $State["state"] = "auth_required"
    }

    return $State
}

function Get-ClaudeAccountStateStore {
    $store = New-ClaudeAccountStateStore
    $statePath = Get-ClaudeAccountStatePath

    if (Test-Path -LiteralPath $statePath) {
        try {
            $raw = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json

            foreach ($prop in $raw.PSObject.Properties) {
                if ($prop.Name -eq "profiles") {
                    if ($null -eq $prop.Value) {
                        continue
                    }

                    foreach ($profileProp in $prop.Value.PSObject.Properties) {
                        $profileName = [string]$profileProp.Name
                        $rawProfile = $profileProp.Value
                        $profileState = ConvertTo-ClaudeOrderedDictionary -InputObject $rawProfile
                        if ($profileState.Contains("config_dir") -and -not $profileState.Contains("configDir")) {
                            $profileState["configDir"] = [string]$profileState["config_dir"]
                        }
                        if (-not $profileState.Contains("profileId")) {
                            $profileState["profileId"] = $profileName
                        }
                        if (-not $profileState.Contains("configDir")) {
                            $profileState["configDir"] = ""
                        }
                        if (-not $profileState.Contains("loggedIn")) {
                            $profileState["loggedIn"] = $false
                        }
                        if (-not $profileState.Contains("state")) {
                            $profileState["state"] = "auth_required"
                        }
                        if (-not $profileState.Contains("leaseOwner")) {
                            $profileState["leaseOwner"] = ""
                        }
                        if (-not $profileState.Contains("leaseExpiresAt")) {
                            $profileState["leaseExpiresAt"] = $null
                        }
                        if (-not $profileState.Contains("cooldownUntil")) {
                            $profileState["cooldownUntil"] = $null
                        }
                        if (-not $profileState.Contains("lastSuccessAt")) {
                            $profileState["lastSuccessAt"] = $null
                        }
                        if (-not $profileState.Contains("lastFailureAt")) {
                            $profileState["lastFailureAt"] = $null
                        }
                        if (-not $profileState.Contains("lastFailureKind")) {
                            $profileState["lastFailureKind"] = ""
                        }
                        if (-not $profileState.Contains("lastKnownModel")) {
                            $profileState["lastKnownModel"] = ""
                        }
                        if (-not $profileState.Contains("quotaNote")) {
                            $profileState["quotaNote"] = ""
                        }

                        Normalize-ClaudeProfileRuntimeState -State $profileState -Source "state" | Out-Null
                        $store.profiles[$profileName] = $profileState
                    }
                    continue
                }

                if ($prop.Name -eq "version") {
                    $store.version = [int]$prop.Value
                    continue
                }

                if ($prop.Name -eq "updatedAt") {
                    $store.updatedAt = [string]$prop.Value
                    continue
                }

                $store[$prop.Name] = $prop.Value
            }
        } catch {
            throw "Falha ao ler o estado Claude em '$statePath': $($_.Exception.Message)"
        }
    }

    foreach ($profile in Get-ClaudeProfileDefinitions) {
        if (-not $store.profiles.Contains($profile.name)) {
            $store.profiles[$profile.name] = New-ClaudeProfileRuntimeState -ProfileName $profile.name -ConfigDir $profile.configDir
        } else {
            $runtimeState = $store.profiles[$profile.name]
            $runtimeState["profileId"] = [string]$profile.name
            if (-not $runtimeState.Contains("configDir") -or -not $runtimeState["configDir"]) {
                $runtimeState["configDir"] = [string]$profile.configDir
            }
            Normalize-ClaudeProfileRuntimeState -State $runtimeState | Out-Null
        }
    }

    return $store
}

function Save-ClaudeAccountStateStore {
    param([System.Collections.IDictionary]$State)

    $normalized = ConvertTo-ClaudeOrderedDictionary -InputObject $State
    $normalized["version"] = if ($State -and $State.Contains("version") -and $State["version"]) { [int]$State["version"] } else { 1 }
    $normalized["updatedAt"] = (Get-Date).ToString("o")
    $normalized["profiles"] = [ordered]@{}

    if ($State -and $State.Contains("profiles") -and $State["profiles"]) {
        foreach ($entry in $State["profiles"].GetEnumerator() | Sort-Object Key) {
            $profileName = [string]$entry.Key
            $profileState = ConvertTo-ClaudeOrderedDictionary -InputObject $entry.Value
            if (-not $profileState.Contains("profileId")) {
                $profileState["profileId"] = $profileName
            }
            if (-not $profileState.Contains("state")) {
                $profileState["state"] = if ($profileState.Contains("loggedIn") -and [bool]$profileState["loggedIn"]) { "available" } else { "auth_required" }
            }
            if (-not $profileState.Contains("loggedIn")) {
                $profileState["loggedIn"] = $false
            }
            Normalize-ClaudeProfileRuntimeState -State $profileState -Source "state" | Out-Null
            $normalized["profiles"][$profileName] = $profileState
        }
    }

    Write-JsonFile -Path (Get-ClaudeAccountStatePath) -Data $normalized
}

function Set-ClaudeProfileJunction {
    param(
        [Parameter(Mandatory)]
        [string]$ProfileName
    )

    $profilesRoot = Join-Path $Script:UserProfileRoot ".claude-profiles"
    $activeLink   = Join-Path $profilesRoot "active"
    $target       = Join-Path $profilesRoot $ProfileName

    if (-not (Test-Path -LiteralPath $target -PathType Container)) {
        throw "Perfil inexistente: $target"
    }

    # Garantir que CLAUDE_CONFIG_DIR aponta para a junction (apenas na primeira vez)
    $currentEnv = [System.Environment]::GetEnvironmentVariable("CLAUDE_CONFIG_DIR", "User")
    if ($currentEnv -ne $activeLink) {
        [System.Environment]::SetEnvironmentVariable("CLAUDE_CONFIG_DIR", $activeLink, "User")
    }

    # Remover junction existente se houver
    if (Test-Path -LiteralPath $activeLink) {
        $item = Get-Item -LiteralPath $activeLink -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
            throw "Recusando remover caminho que nao e junction: $activeLink"
        }
        [System.IO.Directory]::Delete($activeLink, $false)
    }

    # Criar nova junction apontando para o perfil selecionado
    New-Item -ItemType Junction -Path $activeLink -Target $target | Out-Null

    # Atualizar marker sem BOM (usado pelo PowerShell profile para novos terminais)
    $markerPath = Join-Path $Script:UserProfileRoot ".claude-active-dir"
    Set-FileAtomic -Path $markerPath -Content $activeLink

    Write-Host "Junction atualizada: active -> $ProfileName"
}

# ── Codex profile management ──────────────────────────────────────────────────

function Set-CodexProfileJunction {
    # Nova arquitetura: 'active' aponta SEMPRE para ~/.codex.
    # Trocar de perfil = copiar auth.json do perfil para ~/.codex/auth.json.
    # Sessions, state e history ficam em ~/.codex (compartilhados entre perfis).
    param(
        [Parameter(Mandatory)]
        [string]$ProfileName
    )

    $profilesRoot  = Join-Path $Script:UserProfileRoot ".codex-profiles"
    $realCodexDir  = Join-Path $Script:UserProfileRoot ".codex"
    $activeLink    = Join-Path $profilesRoot "active"
    $profileDir    = Join-Path $profilesRoot $ProfileName
    $profileAuth   = Join-Path $profileDir "auth.json"

    if (-not (Test-Path -LiteralPath $profileDir -PathType Container)) {
        throw "Perfil Codex inexistente: $profileDir"
    }

    # Arquitetura tem dois modos suportados:
    #   junction: active eh junction -> ~/.codex (legado)
    #   real:     active eh diretorio real (ocorre quando o Codex Desktop cria CODEX_HOME do zero;
    #             tentar refazer a junction triggera bug de path "~" no worker do Codex)
    # Em ambos os modos, escrever/ler em $activeLink resolve no local certo.
    $activeIsJunction = $false
    if (Test-Path -LiteralPath $activeLink) {
        $item = Get-Item -LiteralPath $activeLink -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $rawTarget = $item.Target
            if ($rawTarget -is [System.Array]) { $rawTarget = $rawTarget[0] }
            $rawTarget = [string]$rawTarget
            if ($rawTarget.StartsWith('\??\')) { $rawTarget = $rawTarget.Substring(4) }
            if ($rawTarget.TrimEnd('\') -eq $realCodexDir.TrimEnd('\')) { $activeIsJunction = $true }
            else {
                # junction antiga apontando pra outro lugar - reapontar para ~/.codex
                [System.IO.Directory]::Delete($activeLink, $false)
                if (-not (Test-Path -LiteralPath $realCodexDir)) { New-Item -ItemType Directory -Path $realCodexDir -Force | Out-Null }
                New-Item -ItemType Junction -Path $activeLink -Target $realCodexDir | Out-Null
                $activeIsJunction = $true
            }
        }
    } else {
        # active nao existe: criar junction default
        if (-not (Test-Path -LiteralPath $realCodexDir)) { New-Item -ItemType Directory -Path $realCodexDir -Force | Out-Null }
        New-Item -ItemType Junction -Path $activeLink -Target $realCodexDir | Out-Null
        $activeIsJunction = $true
    }

    # Garantir CODEX_HOME
    $currentEnv = [System.Environment]::GetEnvironmentVariable("CODEX_HOME", "User")
    if ($currentEnv -ne $activeLink) {
        [System.Environment]::SetEnvironmentVariable("CODEX_HOME", $activeLink, "User")
    }

    # Trocar conta: sobrescrever auth.json no diretorio ativo (junction ou real - ambos resolvem corretamente)
    if (Test-Path -LiteralPath $profileAuth) {
        $targetAuth = Join-Path $activeLink "auth.json"
        $authContent = [System.IO.File]::ReadAllText($profileAuth)
        $null = $authContent | ConvertFrom-Json
        Set-FileAtomic -Path $targetAuth -Content $authContent
    }

    # Gravar perfil ativo
    $activeProfileMarker = Join-Path $Script:UserProfileRoot ".codex-active-profile"
    Set-FileAtomic -Path $activeProfileMarker -Content $ProfileName

    Write-Host "Codex: conta ativa trocada para $ProfileName (sessions compartilhadas)"
}

function Get-CodexRateLimits {
    param([string]$ProfileDir)
    # Lê o evento token_count mais recente dos arquivos de sessão JSONL
    # Estrutura: sessions/YYYY/MM/DD/rollout-*.jsonl
    $sessionsRoot = Join-Path $ProfileDir "sessions"
    if (-not (Test-Path -LiteralPath $sessionsRoot)) { return $null }

    # Pegar o JSONL mais recente (por data de modificação)
    $latestFile = Get-ChildItem -LiteralPath $sessionsRoot -Recurse -Filter "rollout-*.jsonl" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $latestFile) { return $null }

    # Ler o arquivo com compartilhamento de leitura (FileShare.ReadWrite) para evitar
    # erro quando o arquivo está sendo gravado pelo processo Codex
    try {
        $stream = [System.IO.File]::Open($latestFile.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader($stream)
        $lines = @()
        while (-not $reader.EndOfStream) {
            $lines += $reader.ReadLine()
        }
        $reader.Close()
        $stream.Close()
    } catch {
        return $null
    }

    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i]
        if ($line -notmatch '"rate_limits"') { continue }
        try {
            $obj = $line | ConvertFrom-Json
            $rl = $obj.payload.rate_limits
            if ($rl -and $rl.primary) {
                return [ordered]@{
                    fiveHour = [ordered]@{
                        usedPercent    = [double]$rl.primary.used_percent
                        windowMinutes  = [int]$rl.primary.window_minutes
                        resetsAt       = [long]$rl.primary.resets_at
                    }
                    sevenDay = if ($rl.secondary) { [ordered]@{
                        usedPercent    = [double]$rl.secondary.used_percent
                        windowMinutes  = [int]$rl.secondary.window_minutes
                        resetsAt       = [long]$rl.secondary.resets_at
                    }} else { $null }
                    seenAt   = $obj.timestamp
                    source   = $latestFile.FullName
                }
            }
        } catch {}
    }
    return $null
}

function Get-CodexAuthInfo {
    param([string]$ProfileDir)
    # Decodifica JWTs do auth.json. id_token carrega claims de identidade
    # (email, name, plan) e expira rapido (~1h). access_token carrega a
    # expiracao real de uso da API (~10 dias). Lemos os dois.
    $authPath = Join-Path $ProfileDir "auth.json"
    if (-not (Test-Path -LiteralPath $authPath)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($authPath).Trim()
        if ($raw.Length -le 5 -or $raw -eq '{}') { return $null }
        $auth = $raw | ConvertFrom-Json

        $decodeJwt = {
            param($tok)
            if (-not $tok) { return $null }
            $parts = $tok.Split('.')
            if ($parts.Count -lt 2) { return $null }
            $payload = $parts[1]
            $mod = $payload.Length % 4
            if ($mod -ne 0) { $payload += '=' * (4 - $mod) }
            $payload = $payload.Replace('-', '+').Replace('_', '/')
            try {
                return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
            } catch { return $null }
        }

        $idClaims     = & $decodeJwt $auth.tokens.id_token
        $accessClaims = & $decodeJwt $auth.tokens.access_token

        # Identidade vem do id_token (OIDC)
        $openaiAuth = if ($idClaims) { $idClaims.'https://api.openai.com/auth' } else { $null }

        # Expiracao prioriza access_token (vida longa real). Fallback: id_token.
        $expiresAt = $null
        $expiresIn = $null
        $expSource = $null
        if ($accessClaims -and $accessClaims.exp) {
            $exp = [long]$accessClaims.exp
            $expiresAt = [DateTimeOffset]::FromUnixTimeSeconds($exp).ToString("o")
            $expiresIn = [int]($exp - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
            $expSource = "access_token"
        } elseif ($idClaims -and $idClaims.exp) {
            $exp = [long]$idClaims.exp
            $expiresAt = [DateTimeOffset]::FromUnixTimeSeconds($exp).ToString("o")
            $expiresIn = [int]($exp - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
            $expSource = "id_token"
        }

        return [ordered]@{
            email    = if ($idClaims) { [string]$idClaims.email } else { $null }
            name     = if ($idClaims) { [string]$idClaims.name } else { $null }
            planType = if ($openaiAuth) { [string]$openaiAuth.chatgpt_plan_type } else { $null }
            authMode = [string]($auth.auth_mode)
            accessTokenExpiresAt = $expiresAt
            accessTokenExpiresIn = $expiresIn
            expirySource         = $expSource
        }
    } catch { return $null }
}

function Restore-CodexAuthIfEmpty {
    # Se ~/.codex/auth.json estiver vazio ou com "{}", restaura a partir do perfil
    # apontado por .codex-active-profile. Cobre o caso em que um "codex login"
    # foi iniciado e interrompido, zerando o auth central, enquanto os cofres
    # .codex-profiles/<perfil>/auth.json mantem o token valido.
    # Le auth.json do diretorio ativo (active eh junction OU dir real, ambos resolvem)
    $activeLink    = Join-Path (Join-Path $Script:UserProfileRoot ".codex-profiles") "active"
    $centralAuth   = Join-Path $activeLink "auth.json"
    if (-not (Test-Path -LiteralPath $centralAuth)) { return $false }
    try {
        $raw = [System.IO.File]::ReadAllText($centralAuth).Trim()
    } catch { return $false }
    # Considera "vazio" se tiver menos de 20 chars ou for exatamente "{}"
    if ($raw.Length -gt 20 -and $raw -ne '{}') { return $false }

    $markerPath = Join-Path $Script:UserProfileRoot ".codex-active-profile"
    if (-not (Test-Path -LiteralPath $markerPath)) { return $false }
    $activeName = (Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8).Trim()
    if (-not $activeName) { return $false }

    $profileAuth = Join-Path (Join-Path $Script:UserProfileRoot ".codex-profiles") (Join-Path $activeName "auth.json")
    if (-not (Test-Path -LiteralPath $profileAuth)) { return $false }
    try {
        $profileRaw = [System.IO.File]::ReadAllText($profileAuth).Trim()
    } catch { return $false }
    if ($profileRaw.Length -le 20 -or $profileRaw -eq '{}') { return $false }

    try {
        $null = $profileRaw | ConvertFrom-Json
        Set-FileAtomic -Path $centralAuth -Content $profileRaw
        Write-Host "Codex auto-recovery: restaurado ~/.codex/auth.json a partir de $activeName" -ForegroundColor DarkGray
        return $true
    } catch {
        return $false
    }
}

function Get-CodexProfiles {
    $profilesRoot  = Join-Path $Script:UserProfileRoot ".codex-profiles"
    $realCodexDir  = Join-Path $Script:UserProfileRoot ".codex"
    $activeLink    = Join-Path $profilesRoot "active"
    if (-not (Test-Path -LiteralPath $profilesRoot)) {
        return @()
    }

    # Oportunidade de recuperar auth central zerado antes de expor o estado ao painel
    try { [void](Restore-CodexAuthIfEmpty) } catch {}

    # Determinar perfil ativo: ler marker ou comparar account_id do auth.json ativo
    $activeName = ""
    $markerPath = Join-Path $Script:UserProfileRoot ".codex-active-profile"
    if (Test-Path -LiteralPath $markerPath) {
        $activeName = (Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8).Trim()
    }
    # Fallback: comparar account_id do auth.json no diretorio ativo com cada perfil
    if (-not $activeName) {
        $activeAuthPath = Join-Path $activeLink "auth.json"
        if (Test-Path -LiteralPath $activeAuthPath) {
            try {
                $activeAuth = Get-Content -LiteralPath $activeAuthPath -Raw | ConvertFrom-Json
                $activeAccountId = [string]$activeAuth.tokens.account_id
                Get-ChildItem -LiteralPath $profilesRoot -Directory -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notin @("active") -and -not $_.Name.EndsWith(".bak") } |
                    ForEach-Object {
                        $pAuth = Join-Path $_.FullName "auth.json"
                        if (Test-Path -LiteralPath $pAuth) {
                            try {
                                $pa = Get-Content -LiteralPath $pAuth -Raw | ConvertFrom-Json
                                if ([string]$pa.tokens.account_id -eq $activeAccountId) {
                                    $activeName = $_.Name
                                }
                            } catch {}
                        }
                    }
            } catch {}
        }
    }

    # rateLimits e lastUsed vem do diretorio ativo (compartilhado) — só faz sentido para o perfil ativo
    $sharedRateLimits = Get-CodexRateLimits -ProfileDir $activeLink
    $sharedLastUsed   = $null
    $sharedLastUsePath = Join-Path $activeLink ".last-use"
    if (Test-Path -LiteralPath $sharedLastUsePath) {
        try { $sharedLastUsed = (Get-Content -LiteralPath $sharedLastUsePath -Raw -Encoding UTF8).Trim() } catch {}
    }

    $profiles = @()
    Get-ChildItem -LiteralPath $profilesRoot -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @("active") -and -not $_.Name.EndsWith(".bak") } |
        ForEach-Object {
            $name     = $_.Name
            $isActive = ($name -eq $activeName)
            $authInfo = Get-CodexAuthInfo -ProfileDir $_.FullName

            $profiles += [ordered]@{
                name       = $name
                dir        = $_.FullName
                isActive   = $isActive
                hasAuth    = ($null -ne $authInfo)
                email      = if ($authInfo) { $authInfo.email }    else { $null }
                userName   = if ($authInfo) { $authInfo.name }     else { $null }
                planType   = if ($authInfo) { $authInfo.planType } else { $null }
                authMode   = if ($authInfo) { $authInfo.authMode } else { $null }
                accessTokenExpiresAt = if ($authInfo) { $authInfo.accessTokenExpiresAt } else { $null }
                accessTokenExpiresIn = if ($authInfo) { $authInfo.accessTokenExpiresIn } else { $null }
                lastUsed   = $sharedLastUsed
                rateLimits = $sharedRateLimits
            }
        }

    return $profiles
}

function Get-RunningInstances {
    # Detecta processos Claude Code / Codex em execução e tenta resolver o
    # perfil ativo de cada um inspecionando variáveis de ambiente no CommandLine.
    $result = [ordered]@{
        claude = [ordered]@{ count = 0; processes = @() }
        codex  = [ordered]@{ count = 0; processes = @() }
    }

    $procs = @()
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name = 'node.exe' OR Name = 'claude.exe' OR Name = 'codex.exe'" -ErrorAction SilentlyContinue
    } catch { return $result }

    foreach ($p in $procs) {
        $cmd = [string]$p.CommandLine
        if (-not $cmd) { continue }
        $name = [string]$p.Name
        $pid2 = [int]$p.ProcessId
        $started = $null
        try { $started = $p.CreationDate.ToString("o") } catch {}

        $isClaude = $false
        $isCodex = $false

        # Match por nome de executável direto
        if ($name -eq 'claude.exe') { $isClaude = $true }
        elseif ($name -eq 'codex.exe') { $isCodex = $true }
        else {
            # node.exe — inspecionar commandline
            if ($cmd -match 'claude[\\/]cli\.js|\\claude\\cli\\|claude-code|@anthropic-ai[\\/]claude') { $isClaude = $true }
            elseif ($cmd -match 'codex[\\/]cli\.js|\bcodex\b.*\.js|@openai[\\/]codex') { $isCodex = $true }
        }

        if (-not ($isClaude -or $isCodex)) { continue }

        $entry = [ordered]@{
            pid = $pid2
            name = $name
            startedAt = $started
            configDir = $null
            profile = $null
        }

        # Tentar extrair CLAUDE_CONFIG_DIR / CODEX_HOME do CommandLine (útil se user setou explicitamente).
        # Como Win32_Process não expõe env vars do processo filho, o melhor é usar o marker
        # .claude-active-dir / .codex-active-profile como proxy (estado do sistema no momento).
        if ($isClaude) {
            $markerPath = Join-Path $Script:UserProfileRoot ".claude-active-dir"
            if (Test-Path -LiteralPath $markerPath) {
                try {
                    $activeDir = (Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8).Trim()
                    $entry.configDir = $activeDir
                    $leaf = Split-Path $activeDir -Leaf
                    if ($leaf -eq 'active') {
                        try {
                            $j = Get-Item -LiteralPath $activeDir -Force -ErrorAction SilentlyContinue
                            if ($j -and ($j.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                                $raw = [string]$j.Target
                                if ($raw.StartsWith('\??\')) { $raw = $raw.Substring(4) }
                                $leaf = Split-Path $raw -Leaf
                            }
                        } catch {}
                    }
                    if ($leaf -match '^claude-') { $entry.profile = $leaf }
                } catch {}
            }
            $result.claude.count++
            $result.claude.processes += $entry
        } elseif ($isCodex) {
            $markerPath = Join-Path $Script:UserProfileRoot ".codex-active-profile"
            if (Test-Path -LiteralPath $markerPath) {
                try {
                    $entry.profile = (Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8).Trim()
                } catch {}
            }
            $result.codex.count++
            $result.codex.processes += $entry
        }
    }

    return $result
}

function Add-CodexProfile {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($Name -match '[/\\<>:"|?*]' -or $Name.Trim() -eq '' -or $Name -eq 'active') {
        throw "Nome de perfil Codex invalido: '$Name'"
    }

    $profilesRoot = Join-Path $Script:UserProfileRoot ".codex-profiles"
    Ensure-Directory -Path $profilesRoot

    $profileDir = Join-Path $profilesRoot $Name
    if (Test-Path -LiteralPath $profileDir) {
        throw "Perfil Codex ja existe: $Name"
    }

    $dirCreated = $false
    try {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
        $dirCreated = $true

        # Novo perfil: só guarda auth.json (vazio por enquanto — user faz login depois)
        $authPath = Join-Path $profileDir "auth.json"
        Set-FileAtomic -Path $authPath -Content "{}"

        # Garantir que CODEX_HOME e junction estao corretos (sessions sempre em ~/.codex)
        $realCodexDir = Join-Path $Script:UserProfileRoot ".codex"
        $activeLink   = Join-Path $profilesRoot "active"
        if (-not (Test-Path -LiteralPath $activeLink)) {
            if (Test-Path -LiteralPath $realCodexDir) {
                New-Item -ItemType Junction -Path $activeLink -Target $realCodexDir | Out-Null
            }
            [System.Environment]::SetEnvironmentVariable("CODEX_HOME", $activeLink, "User")
        }
    } catch {
        Write-Host "Add-CodexProfile falhou: $_. Revertendo..." -ForegroundColor Yellow
        if ($dirCreated -and (Test-Path -LiteralPath $profileDir)) {
            try {
                Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction Stop
            } catch { Write-Host "  rollback dir falhou: $_" -ForegroundColor Red }
        }
        throw
    }

    Write-Host "Perfil Codex criado: $Name (faca login para associar uma conta)"
    return [ordered]@{
        added   = $true
        name    = $Name
        dir     = $profileDir
    }
}

function Remove-CodexProfile {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $profilesRoot = Join-Path $Script:UserProfileRoot ".codex-profiles"
    $profileDir   = Join-Path $profilesRoot $Name

    if (-not (Test-Path -LiteralPath $profileDir)) {
        throw "Perfil Codex nao encontrado: $Name"
    }

    # Impedir remocao do perfil ativo
    $profiles = @(Get-CodexProfiles)
    $active = $profiles | Where-Object { $_.isActive } | Select-Object -First 1
    if ($active -and $active.name -eq $Name) {
        throw "Nao e possivel remover o perfil Codex ativo: $Name. Ative outro perfil primeiro."
    }

    Remove-Item -LiteralPath $profileDir -Recurse -Force
    Write-Host "Perfil Codex removido: $Name"
    return [ordered]@{ removed = $true; name = $Name }
}

function Ensure-CodexDefaultProfile {
    # Garante estrutura mínima: codex-a com auth.json e junction active -> ~/.codex
    $profilesRoot    = Join-Path $Script:UserProfileRoot ".codex-profiles"
    $realCodexDir    = Join-Path $Script:UserProfileRoot ".codex"
    Ensure-Directory -Path $profilesRoot

    $defaultName = "codex-a"
    $defaultDir  = Join-Path $profilesRoot $defaultName
    $activeLink  = Join-Path $profilesRoot "active"

    # Criar diretório do perfil padrão se não existir
    if (-not (Test-Path -LiteralPath $defaultDir -PathType Container)) {
        New-Item -ItemType Directory -Path $defaultDir -Force | Out-Null
    }

    # Copiar auth.json do diretorio ativo (active = junction OU dir real) para codex-a se vazio
    $profileAuth   = Join-Path $defaultDir "auth.json"
    $originalAuth  = Join-Path $activeLink "auth.json"
    if (-not (Test-Path -LiteralPath $profileAuth) -or (Get-Content -LiteralPath $profileAuth -Raw).Trim() -in @('', '{}')) {
        if (Test-Path -LiteralPath $originalAuth) {
            $content = [System.IO.File]::ReadAllText($originalAuth)
            if ($content.Trim().Length -gt 10 -and $content.Trim() -ne '{}') {
                Set-FileAtomic -Path $profileAuth -Content $content
            }
        }
        if (-not (Test-Path -LiteralPath $profileAuth)) {
            Set-FileAtomic -Path $profileAuth -Content "{}"
        }
    }

    # Garantir que active existe. Se for junction com target errado, reapontar.
    # Se for diretorio real (modo recovery), DEIXAR como esta - tentar refazer junction
    # triggera bug "~ ENOENT" no worker do Codex Desktop e destruiria o estado vivo.
    if (Test-Path -LiteralPath $activeLink) {
        $j = Get-Item -LiteralPath $activeLink -Force -ErrorAction SilentlyContinue
        if ($j -and ($j.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $t = [string]($j.Target | Select-Object -First 1)
            if ($t.StartsWith('\??\')) { $t = $t.Substring(4) }
            if ($t.TrimEnd('\') -ne $realCodexDir.TrimEnd('\')) {
                [System.IO.Directory]::Delete($activeLink, $false)
                if (-not (Test-Path -LiteralPath $realCodexDir)) { New-Item -ItemType Directory -Path $realCodexDir -Force | Out-Null }
                New-Item -ItemType Junction -Path $activeLink -Target $realCodexDir | Out-Null
                Write-Host "Junction corrigida: active -> ~/.codex"
            }
        }
        # se for dir real (não-reparse-point), nao mexer
    } else {
        if (-not (Test-Path -LiteralPath $realCodexDir)) { New-Item -ItemType Directory -Path $realCodexDir -Force | Out-Null }
        New-Item -ItemType Junction -Path $activeLink -Target $realCodexDir | Out-Null
        Write-Host "Junction criada: active -> ~/.codex"
    }

    # Garantir CODEX_HOME
    $currentEnv = [System.Environment]::GetEnvironmentVariable("CODEX_HOME", "User")
    if ($currentEnv -ne $activeLink) {
        [System.Environment]::SetEnvironmentVariable("CODEX_HOME", $activeLink, "User")
        Write-Host "CODEX_HOME corrigido -> $activeLink"
    }

    # Garantir marker de perfil ativo
    $markerPath = Join-Path $Script:UserProfileRoot ".codex-active-profile"
    if (-not (Test-Path -LiteralPath $markerPath)) {
        Set-FileAtomic -Path $markerPath -Content $defaultName
    }
}

function Get-ClaudeProfileDefinitions {
    $config = Get-ClaudeOrchestratorConfig
    if ($null -eq $config -or $null -eq $config.profiles) {
        return @()
    }

    $profiles = @()
    foreach ($profile in $config.profiles) {
        if (-not $profile.name -or -not $profile.config_dir) {
            continue
        }
        $profiles += [pscustomobject]@{
            name = [string]$profile.name
            configDir = [string]$profile.config_dir
        }
    }

    return $profiles
}

# ── Tier & Credentials helpers ──────────────────────────────────────────────

function Get-ClaudeProfileCredentials {
    param([string]$ConfigDir)
    $credPath = Join-Path $ConfigDir ".credentials.json"
    if (-not (Test-Path -LiteralPath $credPath)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $credPath -Raw | ConvertFrom-Json
        $oauth = $raw.claudeAiOauth
        if (-not $oauth) { return $null }
        return [ordered]@{
            subscriptionType = [string]$oauth.subscriptionType
            rateLimitTier    = [string]$oauth.rateLimitTier
        }
    } catch { return $null }
}

function Get-ClaudeAuthInfo {
    # Lê .credentials.json, decodifica JWT do accessToken e devolve expiração.
    param([string]$ConfigDir)
    $credPath = Join-Path $ConfigDir ".credentials.json"
    if (-not (Test-Path -LiteralPath $credPath)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $credPath -Raw | ConvertFrom-Json
        $oauth = $raw.claudeAiOauth
        if (-not $oauth) { return $null }

        $expiresAt = $null
        $expiresIn = $null

        # Preferir expiresAt direto se presente (epoch em ms)
        if ($oauth.PSObject.Properties['expiresAt'] -and $oauth.expiresAt) {
            $ms = [long]$oauth.expiresAt
            $expiresAt = [DateTimeOffset]::FromUnixTimeMilliseconds($ms).ToString("o")
            $expiresIn = [int]([math]::Round(($ms / 1000.0) - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()))
        } else {
            $token = [string]$oauth.accessToken
            if ($token) {
                $parts = $token.Split('.')
                if ($parts.Count -ge 2) {
                    $payload = $parts[1]
                    $mod = $payload.Length % 4
                    if ($mod -ne 0) { $payload += '=' * (4 - $mod) }
                    $payload = $payload.Replace('-', '+').Replace('_', '/')
                    $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
                    if ($decoded.exp) {
                        $exp = [long]$decoded.exp
                        $expiresAt = [DateTimeOffset]::FromUnixTimeSeconds($exp).ToString("o")
                        $expiresIn = [int]($exp - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
                    }
                }
            }
        }

        return [ordered]@{
            accessTokenExpiresAt = $expiresAt
            accessTokenExpiresIn = $expiresIn
            scopes               = @($oauth.scopes)
        }
    } catch { return $null }
}

function Get-ClaudeTierMultiplier {
    param([string]$RateLimitTier)
    switch ($RateLimitTier) {
        "default_claude_max_20x" { return 20 }
        "default_claude_max_5x"  { return 5 }
        "default_claude_ai"      { return 1 }
        default                  { return 1 }
    }
}

function Get-ClaudeTierLabel {
    param([string]$RateLimitTier)
    switch ($RateLimitTier) {
        "default_claude_max_20x" { return "MAX 20x" }
        "default_claude_max_5x"  { return "MAX 5x" }
        "default_claude_ai"      { return "PRO" }
        default                  { return "PRO" }
    }
}

# ── Rate Limit Decay Estimation ─────────────────────────────────────────────

function Estimate-SingleRateLimit {
    param($RateLimitData, [System.Nullable[DateTimeOffset]]$SeenAt, [long]$NowEpoch)
    $obsVal = $null; $resetsAtVal = $null; $estVal = $null; $resetInVal = $null
    $hasData = $false
    if ($RateLimitData) {
        try { $hasData = $null -ne $RateLimitData.usedPercentage -and $RateLimitData.usedPercentage -ne "" } catch { $hasData = $false }
    }
    if ($hasData) {
        $obsVal = [double]$RateLimitData.usedPercentage
        $resetsAtVal = [long]$RateLimitData.resetsAt
        $resetInVal = $resetsAtVal - $NowEpoch
        if ($resetsAtVal -le $NowEpoch) {
            $estVal = 0.0
        } elseif ($SeenAt) {
            $seenEpoch = $SeenAt.ToUnixTimeSeconds()
            $totalWindow = $resetsAtVal - $seenEpoch
            if ($totalWindow -gt 0) {
                $remaining = $resetsAtVal - $NowEpoch
                $estVal = [math]::Max(0.0, [math]::Round($obsVal * ($remaining / $totalWindow), 1))
            } else { $estVal = $obsVal }
        } else { $estVal = $obsVal }
    }
    return [ordered]@{
        estimated      = $estVal
        observed       = $obsVal
        resetsAt       = $resetsAtVal
        resetInSeconds = $resetInVal
    }
}

function Get-ClaudeEstimatedRateLimits {
    param($Latest)
    $empty = [ordered]@{
        fiveHour = [ordered]@{ estimated = $null; observed = $null; resetsAt = $null; resetInSeconds = $null }
        sevenDay = [ordered]@{ estimated = $null; observed = $null; resetsAt = $null; resetInSeconds = $null }
        dataFreshness = "stale"; observedAt = $null; ageSeconds = $null
    }
    if (-not $Latest) { return $empty }

    $now = [DateTimeOffset]::UtcNow
    $nowEpoch = $now.ToUnixTimeSeconds()
    $observedAt = $null
    foreach ($field in @("rateLimitsSeenAt","observedAt","lastSeenAt")) {
        $val = $Latest.PSObject.Properties[$field]
        if ($val -and $val.Value) {
            try { $observedAt = [DateTimeOffset]::Parse([string]$val.Value); break } catch {}
        }
    }
    $ageSeconds = if ($observedAt) { [int]($now - $observedAt).TotalSeconds } else { 99999 }
    $freshness = if ($ageSeconds -lt 300) { "fresh" } elseif ($ageSeconds -lt 1800) { "warm" } else { "stale" }

    # Filtrar hashtables vazias vindas do transcript (rateLimits = @{ fiveHour = @{}; sevenDay = @{} })
    $rl = $Latest.rateLimits
    $fh = $null; $sd = $null
    if ($rl) {
        try { $fh = $rl.fiveHour } catch {}
        try { $sd = $rl.sevenDay } catch {}
    }
    if ($fh -is [hashtable] -and $fh.Count -eq 0) { $fh = $null }
    if ($sd -is [hashtable] -and $sd.Count -eq 0) { $sd = $null }

    return [ordered]@{
        fiveHour      = Estimate-SingleRateLimit -RateLimitData $fh -SeenAt $observedAt -NowEpoch $nowEpoch
        sevenDay      = Estimate-SingleRateLimit -RateLimitData $sd -SeenAt $observedAt -NowEpoch $nowEpoch
        dataFreshness = $freshness
        observedAt    = if ($observedAt) { $observedAt.ToString("o") } else { $null }
        ageSeconds    = $ageSeconds
    }
}

# ─────────────────────────────────────────────────────────────────────────────

function Get-ClaudeCliForAuth {
    $config = Get-ClaudeOrchestratorConfig
    if ($config -and $config.commands -and $config.commands.claude -and $config.commands.claude.path) {
        $candidate = [string]$config.commands.claude.path
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    $pathCommand = Get-Command "claude.exe" -ErrorAction SilentlyContinue
    if ($pathCommand) {
        return $pathCommand.Source
    }

    $pathFallback = Get-Command "claude" -ErrorAction SilentlyContinue
    if ($pathFallback) {
        return $pathFallback.Source
    }

    return Get-LatestClaudeCliPath
}

function Get-ClaudeUsageCollectorScriptPath {
    return Join-Path $Script:ClaudeStatuslineToolsRoot "claude_statusline_collector.py"
}

function Get-ClaudeUsageCollectorWrapperPath {
    return Join-Path $Script:ClaudeStatuslineToolsRoot "claude_statusline_collector.ps1"
}

function Get-ClaudeUsageCollectorSourceScriptPath {
    return Join-Path $Script:AllSkillsRoot "orchestrate\scripts\claude_statusline_collector.py"
}

function Get-ClaudeUsageCollectorSourceWrapperPath {
    return Join-Path $Script:AllSkillsRoot "orchestrate\scripts\claude_statusline_collector.ps1"
}

function Get-ClaudeMaxProfileCount {
    return 10
}

function Get-ClaudeAllowedProfileNames {
    $names = @()
    for ($index = 0; $index -lt (Get-ClaudeMaxProfileCount); $index++) {
        $names += ("claude-" + [char]([int][char]'a' + $index))
    }
    return $names
}

function Save-ClaudeOrchestratorConfig {
    param(
        [object]$Config,
        [string]$ConfigPath
    )

    $configPath = if ($ConfigPath) { $ConfigPath } else { Get-ClaudeOrchestratorConfigPath }
    Ensure-Directory -Path (Split-Path -Parent $configPath)
    Write-JsonFile -Path $configPath -Data $Config
}

function Ensure-ClaudeOrchestratorConfig {
    param(
        [string]$ConfigPath
    )

    $configPath = if ($ConfigPath) { $ConfigPath } else { Get-ClaudeOrchestratorConfigPath }
    $config = Get-ClaudeOrchestratorConfig -ConfigPath $configPath
    if ($config) {
        # Back-fill new fields on legacy configs so toggles persist correctly.
        if (-not ($config.PSObject.Properties.Name -contains 'autoRotateEnabled')) {
            $config | Add-Member -NotePropertyName 'autoRotateEnabled' -NotePropertyValue $false -Force
            Save-ClaudeOrchestratorConfig -Config $config -ConfigPath $configPath
        }
        return $config
    }

    $profileRoot = Join-UserProfilePath ".claude-profiles"
    $config = [ordered]@{
        version = 1
        claude_base_dir = (Join-UserProfilePath ".claude")
        profile_root = $profileRoot
        state_file = (Join-Path $Script:ClaudeOrchestratorRoot "state.json")
        shared_claude_subdirs = @("skills", "plugins", "commands")
        shared_claude_files = @("settings.json", "trustedFolders.json")
        profiles = @()
        autoRotateEnabled = $false
        commands = [ordered]@{
            claude = [ordered]@{ path = (Get-LatestClaudeCliPath) }
            codex = [ordered]@{ path = (Get-NpmCmdShimPath -CommandName "codex") }
            gemini = [ordered]@{ path = (Get-NpmCmdShimPath -CommandName "gemini") }
            qwen = [ordered]@{ path = (Get-NpmCmdShimPath -CommandName "qwen") }
        }
    }
    Save-ClaudeOrchestratorConfig -Config $config -ConfigPath $configPath
    return Get-ClaudeOrchestratorConfig -ConfigPath $configPath
}

function Copy-ClaudeProfileSeedFiles {
    param(
        [string]$TargetProfileDir,
        [string]$TemplateProfileDir = ""
    )

    Ensure-Directory -Path $TargetProfileDir
    $seedCandidates = @()
    if ($TemplateProfileDir -and (Test-Path -LiteralPath $TemplateProfileDir)) {
        $seedCandidates += $TemplateProfileDir
    }
    $seedCandidates += (Join-UserProfilePath ".claude")

    foreach ($seedDir in $seedCandidates | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $seedDir)) {
            continue
        }

        foreach ($fileName in @("settings.json", "trustedFolders.json")) {
            $sourcePath = Join-Path $seedDir $fileName
            $targetPath = Join-Path $TargetProfileDir $fileName
            if ((Test-Path -LiteralPath $sourcePath) -and -not (Test-Path -LiteralPath $targetPath)) {
                Copy-Item -LiteralPath $sourcePath -Destination $targetPath -Force
            }
        }

        break
    }
}

function Sync-ClaudeProfileHooks {
    param([string[]]$ProfileNames = @())

    $autoRotatePath = Join-Path $Script:HubRoot "auto-rotate.ps1"
    $autoRotateCmd = "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$autoRotatePath`""
    $config = Get-ClaudeOrchestratorConfig
    if (-not $config -or -not $config.profiles) { return @() }

    $targets = if ($ProfileNames.Count -gt 0) {
        @($config.profiles | Where-Object { $ProfileNames -contains $_.name })
    } else {
        @($config.profiles)
    }

    $results = @()
    foreach ($prof in $targets) {
        $settingsPath = Join-Path ([string]$prof.config_dir) "settings.json"
        if (-not (Test-Path -LiteralPath $settingsPath)) {
            $results += [ordered]@{ profile = $prof.name; status = "skipped (no settings.json)" }
            continue
        }

        try {
            $raw = Get-Content $settingsPath -Raw -Encoding UTF8
            $raw = $raw.TrimStart([char]0xFEFF)
            $settings = $raw | ConvertFrom-Json

            # Garantir estrutura hooks.Stop
            if (-not $settings.PSObject.Properties['hooks']) {
                $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force
            }
            if (-not $settings.hooks.PSObject.Properties['Stop']) {
                $settings.hooks | Add-Member -NotePropertyName Stop -NotePropertyValue @() -Force
            }

            # Verificar se hook ja existe (qualquer entry com o comando auto-rotate)
            $stopHooks = @($settings.hooks.Stop)
            $alreadyPresent = $stopHooks | ForEach-Object {
                @($_.hooks) | Where-Object { $_.command -like "*auto-rotate.ps1*" }
            } | Select-Object -First 1

            if ($alreadyPresent) {
                $results += [ordered]@{ profile = $prof.name; status = "already present" }
                continue
            }

            # Adicionar novo grupo de hook ou inserir no primeiro grupo existente
            $newHook = [pscustomobject]@{
                type    = "command"
                command = $autoRotateCmd
                async   = $true
            }

            if ($stopHooks.Count -eq 0) {
                $settings.hooks.Stop = @([pscustomobject]@{ hooks = @($newHook) })
            } else {
                # Adicionar ao primeiro grupo existente
                $firstGroup = $stopHooks[0]
                if (-not $firstGroup.PSObject.Properties['hooks']) {
                    $firstGroup | Add-Member -NotePropertyName hooks -NotePropertyValue @() -Force
                }
                $firstGroup.hooks = @($firstGroup.hooks) + $newHook
                $settings.hooks.Stop[0] = $firstGroup
            }

            Set-JsonFileAtomic -Path $settingsPath -Data $settings -Depth 20
            $results += [ordered]@{ profile = $prof.name; status = "hook added" }
        } catch {
            $results += [ordered]@{ profile = $prof.name; status = "error: $_" }
        }
    }
    return $results
}

function Add-ClaudeProfile {
    $config = Ensure-ClaudeOrchestratorConfig
    if ($null -eq $config.profiles) {
        $config | Add-Member -NotePropertyName profiles -NotePropertyValue @()
    }

    $existingNames = @($config.profiles | ForEach-Object { [string]$_.name })
    $nextName = Get-ClaudeAllowedProfileNames | Where-Object { $existingNames -notcontains $_ } | Select-Object -First 1
    if (-not $nextName) {
        throw "Limite maximo atingido: $(Get-ClaudeMaxProfileCount) perfis Claude."
    }

    $profileRoot = if ($config.profile_root) { [string]$config.profile_root } else { Join-UserProfilePath ".claude-profiles" }
    $newProfileDir = Join-Path $profileRoot $nextName

    $templateProfile = $config.profiles | Select-Object -First 1
    $templateDir = if ($templateProfile -and $templateProfile.config_dir) { [string]$templateProfile.config_dir } else { "" }

    $dirCreated = $false
    $configAppended = $false
    try {
        $dirPreExisted = Test-Path -LiteralPath $newProfileDir
        Copy-ClaudeProfileSeedFiles -TargetProfileDir $newProfileDir -TemplateProfileDir $templateDir
        $dirCreated = -not $dirPreExisted
        Sync-ClaudeProfileHooks -ProfileNames @($nextName) | Out-Null
        Reconcile-SharedSkills

        $config.profiles += [pscustomobject]@{
            name = $nextName
            config_dir = $newProfileDir
        }
        $configAppended = $true
        Save-ClaudeOrchestratorConfig -Config $config

        $accountState = Get-ClaudeAccountStateStore
        if (-not $accountState.profiles.Contains($nextName)) {
            $accountState.profiles[$nextName] = New-ClaudeProfileRuntimeState -ProfileName $nextName -ConfigDir $newProfileDir
        } else {
            $accountState.profiles[$nextName]["profileId"] = $nextName
            $accountState.profiles[$nextName]["configDir"] = $newProfileDir
            Normalize-ClaudeProfileRuntimeState -State $accountState.profiles[$nextName] -Source "state" | Out-Null
        }
        Save-ClaudeAccountStateStore -State $accountState
        $collectorResult = Sync-ClaudeUsageCollector -ProfileNames @($nextName) -Force:$true
    } catch {
        Write-Host "Add-ClaudeProfile falhou: $_. Revertendo..." -ForegroundColor Yellow
        if ($configAppended) {
            try {
                $config.profiles = @($config.profiles | Where-Object { [string]$_.name -ne $nextName })
                Save-ClaudeOrchestratorConfig -Config $config
            } catch { Write-Host "  rollback config falhou: $_" -ForegroundColor Red }
        }
        if ($dirCreated -and (Test-Path -LiteralPath $newProfileDir)) {
            try {
                Remove-Item -LiteralPath $newProfileDir -Recurse -Force -ErrorAction Stop
            } catch { Write-Host "  rollback dir falhou: $_" -ForegroundColor Red }
        }
        throw
    }

    return [ordered]@{
        added = $true
        profile = $nextName
        configDir = $newProfileDir
        totalProfiles = @($config.profiles).Count
        maxProfiles = Get-ClaudeMaxProfileCount
        collector = $collectorResult
    }
}

function Remove-ClaudeProfile {
    <#
    Soft-delete um perfil Claude. Move ~/.claude-profiles/<Name> para
    ~/.claude-profiles-removed/<Name>-<timestamp>, atualiza orchestrator/config.json
    e state.json. Bloqueia se for o perfil ativo ou o ultimo restante.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Name,
        [string]$ProfilesRoot,
        [string]$BackupRoot
    )

    $trimmed = ($Name | Out-String).Trim()
    if (-not $trimmed) { throw "Nome de perfil Claude invalido." }

    if (-not $ProfilesRoot) {
        $ProfilesRoot = Join-Path $Script:UserProfileRoot ".claude-profiles"
    }
    if (-not $BackupRoot) {
        $BackupRoot = Join-Path $Script:UserProfileRoot ".claude-profiles-removed"
    }

    $profileDir = Join-Path $ProfilesRoot $trimmed
    if (-not (Test-Path -LiteralPath $profileDir -PathType Container)) {
        throw "Perfil Claude nao encontrado: $trimmed"
    }

    $active = Get-ActiveClaudeProfileName
    if ($active -and $active -eq $trimmed) {
        throw "Nao posso remover o perfil ativo. Troque o ativo primeiro."
    }

    $config = Ensure-ClaudeOrchestratorConfig
    $existingNames = @()
    if ($config -and $config.profiles) {
        $existingNames = @($config.profiles | ForEach-Object { [string]$_.name })
    }
    if ($existingNames.Count -le 1 -and ($existingNames -contains $trimmed)) {
        throw "Nao posso remover o ultimo perfil Claude. Adicione outro perfil primeiro."
    }

    Ensure-Directory -Path $BackupRoot
    $ts = (Get-Date).ToString("yyyyMMdd-HHmmss")
    $backupDir = Join-Path $BackupRoot ("{0}-{1}" -f $trimmed, $ts)

    Move-Item -LiteralPath $profileDir -Destination $backupDir -Force

    if ($config -and $config.profiles) {
        try {
            $config.profiles = @($config.profiles | Where-Object { [string]$_.name -ne $trimmed })
            Save-ClaudeOrchestratorConfig -Config $config
        } catch {
            Write-Host "Aviso: falha ao atualizar config.json apos remover '$trimmed': $_" -ForegroundColor Yellow
        }
    }

    try {
        $store = Get-ClaudeAccountStateStore
        if ($store -and $store.profiles -and $store.profiles.Contains($trimmed)) {
            $store.profiles.Remove($trimmed) | Out-Null
            Save-ClaudeAccountStateStore -State $store
        }
    } catch {
        Write-Host "Aviso: falha ao atualizar state.json apos remover '$trimmed': $_" -ForegroundColor Yellow
    }

    Write-Host "Perfil Claude removido (soft): $trimmed -> $backupDir"
    return [ordered]@{
        removed   = $true
        name      = $trimmed
        backupDir = $backupDir
    }
}

function Get-ClaudeUsageProfileRoot {
    param([string]$ProfileName)
    return Join-Path $Script:ClaudeUsageStateRoot "profiles\$ProfileName"
}

function Get-ClaudeUsageLatestPath {
    param([string]$ProfileName)
    return Join-Path (Get-ClaudeUsageProfileRoot -ProfileName $ProfileName) "latest.json"
}

function Get-ClaudeUsageSessionsRoot {
    param([string]$ProfileName)
    return Join-Path (Get-ClaudeUsageProfileRoot -ProfileName $ProfileName) "sessions"
}

function Get-ClaudeProfileSettingsPath {
    param([string]$ProfileName)

    $profile = Get-ClaudeProfileDefinitions | Where-Object { $_.name -eq $ProfileName } | Select-Object -First 1
    if (-not $profile) {
        throw "Perfil Claude nao encontrado: $ProfileName"
    }

    return Join-Path $profile.configDir "settings.json"
}

function Get-ClaudeUsageCollectorCommand {
    param([string]$ProfileName)

    # Usar wrapper combinado (collector + renderer visual) se existir
    $combinedPath = (Join-Path $Script:ClaudeStatuslineToolsRoot "combined-statusline.sh") -replace "\\", "/"
    if (Test-Path -LiteralPath $combinedPath) {
        return "bash `"$combinedPath`" `"$ProfileName`""
    }

    # Fallback: collector puro via PowerShell
    $wrapperPath = (Get-ClaudeUsageCollectorWrapperPath) -replace "\\", "/"
    $stateRoot = $Script:ClaudeUsageStateRoot -replace "\\", "/"
    return "powershell -NoProfile -ExecutionPolicy Bypass -File `"$wrapperPath`" -ProfileName `"$ProfileName`" -StateRoot `"$stateRoot`""
}

function Get-ClaudeUsageCollectorStatus {
    param([string]$ProfileName)

    $settingsPath = Get-ClaudeProfileSettingsPath -ProfileName $ProfileName
    $expectedCommand = Get-ClaudeUsageCollectorCommand -ProfileName $ProfileName
    $latestSnapshotPath = Get-ClaudeUsageLatestPath -ProfileName $ProfileName
    $sessionsRoot = Get-ClaudeUsageSessionsRoot -ProfileName $ProfileName
    $sessionCount = 0
    if (Test-Path -LiteralPath $sessionsRoot) {
        $sessionCount = @(Get-ChildItem -LiteralPath $sessionsRoot -File -Filter *.json -ErrorAction SilentlyContinue).Count
    }
    $status = [ordered]@{
        installed = $false
        conflict = $false
        settingsPath = $settingsPath
        expectedCommand = $expectedCommand
        currentCommand = ""
        scriptPath = Get-ClaudeUsageCollectorScriptPath
        wrapperPath = Get-ClaudeUsageCollectorWrapperPath
        sourceScriptPath = Get-ClaudeUsageCollectorSourceScriptPath
        sourceWrapperPath = Get-ClaudeUsageCollectorSourceWrapperPath
        latestSnapshotPath = $latestSnapshotPath
        hasOfficialSnapshots = (Test-Path -LiteralPath $latestSnapshotPath)
        officialSessionCount = $sessionCount
    }

    if (-not (Test-Path -LiteralPath $settingsPath)) {
        return $status
    }

    try {
        $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        if ($settings -and $settings.statusLine -and $settings.statusLine.type -eq "command") {
            $currentCommand = [string]$settings.statusLine.command
            $status.currentCommand = $currentCommand
            if ($currentCommand.Trim() -eq $expectedCommand.Trim()) {
                $status.installed = $true
            }
            elseif ($currentCommand.Trim()) {
                $status.conflict = $true
            }
        }
    } catch {
        $status.error = $_.Exception.Message
    }

    return $status
}

function Get-ClaudeUsageLatestSnapshot {
    param([string]$ProfileName)

    $path = Get-ClaudeUsageLatestPath -ProfileName $ProfileName
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-ClaudeUsageSessions {
    param(
        [string]$ProfileName,
        [int]$Limit = 200
    )

    $sessionsRoot = Get-ClaudeUsageSessionsRoot -ProfileName $ProfileName
    if (-not (Test-Path -LiteralPath $sessionsRoot)) {
        return @()
    }

    $items = @()
    $sessionFiles = @(
        Get-ChildItem -LiteralPath $sessionsRoot -File -Filter *.json -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First $Limit
    )

    foreach ($file in $sessionFiles) {
        try {
            $items += (Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json)
        } catch {
        }
    }

    return $items
}

function Convert-ClaudeModelDisplayName {
    param([string]$ModelId)

    $value = [string]$ModelId
    if (-not $value) {
        return ""
    }

    switch -Regex ($value) {
        '^claude-opus-(\d+)-(\d+)$' { return "Claude Opus $($Matches[1]).$($Matches[2])" }
        '^claude-sonnet-(\d+)-(\d+)$' { return "Claude Sonnet $($Matches[1]).$($Matches[2])" }
        '^claude-haiku-(\d+)-(\d+)$' { return "Claude Haiku $($Matches[1]).$($Matches[2])" }
        default { return $value }
    }
}

function Get-ClaudeTranscriptContextWindowSize {
    param([string]$ProfileName)

    $profile = Get-ClaudeProfileDefinitions | Where-Object { $_.name -eq $ProfileName } | Select-Object -First 1
    if (-not $profile) {
        return 200000
    }

    $claudeJsonPath = Join-Path $profile.configDir ".claude.json"
    if (-not (Test-Path -LiteralPath $claudeJsonPath)) {
        return 200000
    }

    try {
        $json = Get-Content -LiteralPath $claudeJsonPath -Raw | ConvertFrom-Json
        $featureValue = $json.cachedGrowthBookFeatures.tengu_hawthorn_window
        if ($featureValue) {
            return [int]$featureValue
        }
    } catch {
    }

    return 200000
}

function Get-ClaudeTranscriptUsageData {
    param([string]$ProfileName)

    $profile = Get-ClaudeProfileDefinitions | Where-Object { $_.name -eq $ProfileName } | Select-Object -First 1
    if (-not $profile) {
        return [ordered]@{
            latest = $null
            sessions = @()
        }
    }

    $projectsRoot = Join-Path $profile.configDir "projects"
    if (-not (Test-Path -LiteralPath $projectsRoot)) {
        return [ordered]@{
            latest = $null
            sessions = @()
        }
    }

    $contextWindowSize = Get-ClaudeTranscriptContextWindowSize -ProfileName $ProfileName
    $sessionsById = @{}
    $jsonlFiles = @(Get-ChildItem -LiteralPath $projectsRoot -Recurse -File -Filter *.jsonl -ErrorAction SilentlyContinue)

    foreach ($file in $jsonlFiles) {
        foreach ($line in (Get-Content -LiteralPath $file.FullName -ErrorAction SilentlyContinue)) {
            if (-not $line.Trim()) {
                continue
            }

            $entry = $null
            try {
                $entry = $line | ConvertFrom-Json
            } catch {
                continue
            }

            if (-not $entry -or [string]$entry.type -ne "assistant" -or -not $entry.message) {
                continue
            }

            $usage = $entry.message.usage
            if (-not $usage) {
                continue
            }

            $modelId = [string]$entry.message.model
            if (-not $modelId -or $modelId -eq "<synthetic>") {
                continue
            }

            $sessionId = [string]$entry.sessionId
            if (-not $sessionId) {
                continue
            }

            if (-not $sessionsById.ContainsKey($sessionId)) {
                $sessionsById[$sessionId] = [ordered]@{
                    profile = $ProfileName
                    sessionId = $sessionId
                    observedAt = [string]$entry.timestamp
                    firstSeenAt = [string]$entry.timestamp
                    lastSeenAt = [string]$entry.timestamp
                    transcriptPath = [string]$file.FullName
                    cwd = [string]$entry.cwd
                    workspace = [ordered]@{
                        currentDir = [string]$entry.cwd
                        projectDir = [string]$entry.cwd
                    }
                    model = [ordered]@{
                        id = $modelId
                        displayName = (Convert-ClaudeModelDisplayName -ModelId $modelId)
                    }
                    version = [string]$entry.version
                    outputStyle = [ordered]@{ name = "" }
                    agent = [ordered]@{ name = "" }
                    worktree = [ordered]@{
                        name = ""
                        path = ""
                        branch = [string]$entry.gitBranch
                        originalCwd = ""
                        originalBranch = ""
                    }
                    cost = [ordered]@{
                        totalCostUsd = 0.0
                        totalDurationMs = 0
                        totalApiDurationMs = 0
                        totalLinesAdded = 0
                        totalLinesRemoved = 0
                    }
                    contextWindow = [ordered]@{
                        totalInputTokens = 0
                        totalOutputTokens = 0
                        contextWindowSize = $contextWindowSize
                        usedPercentage = $null
                        remainingPercentage = $null
                        currentUsage = [ordered]@{
                            inputTokens = 0
                            outputTokens = 0
                            cacheCreationInputTokens = 0
                            cacheReadInputTokens = 0
                        }
                    }
                    rateLimits = [ordered]@{
                        fiveHour = @{}
                        sevenDay = @{}
                    }
                    rateLimitsSeenAt = ""
                    exceeds200kTokens = $false
                }
            }

            $session = $sessionsById[$sessionId]
            $timestampText = [string]$entry.timestamp
            if ($timestampText) {
                if (-not $session.firstSeenAt -or $timestampText -lt $session.firstSeenAt) {
                    $session.firstSeenAt = $timestampText
                }
                if (-not $session.lastSeenAt -or $timestampText -gt $session.lastSeenAt) {
                    $session.lastSeenAt = $timestampText
                    $session.observedAt = $timestampText
                }
            }

            $inputTokens = [int]$usage.input_tokens
            $outputTokens = [int]$usage.output_tokens
            $cacheCreationTokens = [int]$usage.cache_creation_input_tokens
            $cacheReadTokens = [int]$usage.cache_read_input_tokens

            $session.contextWindow.totalInputTokens += $inputTokens
            $session.contextWindow.totalOutputTokens += $outputTokens
            $session.contextWindow.currentUsage.inputTokens += $inputTokens
            $session.contextWindow.currentUsage.outputTokens += $outputTokens
            $session.contextWindow.currentUsage.cacheCreationInputTokens += $cacheCreationTokens
            $session.contextWindow.currentUsage.cacheReadInputTokens += $cacheReadTokens

            $effectiveTokens = (
                [int]$session.contextWindow.totalInputTokens +
                [int]$session.contextWindow.totalOutputTokens +
                [int]$session.contextWindow.currentUsage.cacheCreationInputTokens +
                [int]$session.contextWindow.currentUsage.cacheReadInputTokens
            )

            if ($contextWindowSize -gt 0) {
                $usedPct = [math]::Min(100.0, [math]::Round(($effectiveTokens / $contextWindowSize) * 100.0, 1))
                $session.contextWindow.usedPercentage = $usedPct
                $session.contextWindow.remainingPercentage = [math]::Max(0.0, [math]::Round(100.0 - $usedPct, 1))
            } else {
                $session.contextWindow.usedPercentage = $null
                $session.contextWindow.remainingPercentage = $null
            }
            $session.exceeds200kTokens = $effectiveTokens -gt 200000
        }
    }

    $sessions = @($sessionsById.Values | Sort-Object lastSeenAt -Descending)
    $latest = if ($sessions.Count -gt 0) { $sessions[0] } else { $null }

    return [ordered]@{
        latest = $latest
        sessions = $sessions
    }
}

function Get-ClaudeUsageProfileData {
    param([string]$ProfileName)

    $officialLatest = Get-ClaudeUsageLatestSnapshot -ProfileName $ProfileName
    $officialSessions = @(Get-ClaudeUsageSessions -ProfileName $ProfileName)
    $transcriptUsage = Get-ClaudeTranscriptUsageData -ProfileName $ProfileName
    $latest = if ($officialLatest) { $officialLatest } else { $transcriptUsage.latest }
    $sessions = @()

    if ($officialLatest -and $transcriptUsage.latest) {
        if (($null -eq $latest.contextWindow.totalInputTokens) -and $transcriptUsage.latest.contextWindow.totalInputTokens) {
            $latest.contextWindow = $transcriptUsage.latest.contextWindow
        }
        if (($null -eq $latest.cost.totalCostUsd) -and $transcriptUsage.latest.cost.totalCostUsd) {
            $latest.cost = $transcriptUsage.latest.cost
        }
        if (-not $latest.model.displayName) {
            $latest.model = $transcriptUsage.latest.model
        }
    }

    if ($officialSessions.Count -gt 0) {
        $transcriptBySessionId = @{}
        foreach ($transcriptSession in @($transcriptUsage.sessions)) {
            if ($transcriptSession.sessionId) {
                $transcriptBySessionId[[string]$transcriptSession.sessionId] = $transcriptSession
            }
        }

        foreach ($officialSession in $officialSessions) {
            $sessionId = [string]$officialSession.sessionId
            $transcriptSession = $null
            if ($sessionId -and $transcriptBySessionId.ContainsKey($sessionId)) {
                $transcriptSession = $transcriptBySessionId[$sessionId]
            }

            if ($transcriptSession) {
                if (($null -eq $officialSession.contextWindow.totalInputTokens) -and $transcriptSession.contextWindow.totalInputTokens) {
                    $officialSession.contextWindow = $transcriptSession.contextWindow
                }
                if (($null -eq $officialSession.cost.totalCostUsd) -and $transcriptSession.cost.totalCostUsd) {
                    $officialSession.cost = $transcriptSession.cost
                }
                if (-not $officialSession.model.displayName) {
                    $officialSession.model = $transcriptSession.model
                }
            }

            $sessions += $officialSession
        }

        foreach ($transcriptSession in @($transcriptUsage.sessions)) {
            $sessionId = [string]$transcriptSession.sessionId
            if ($sessionId -and (@($sessions | Where-Object { [string]$_.sessionId -eq $sessionId }).Count -gt 0)) {
                continue
            }
            $sessions += $transcriptSession
        }
    } else {
        $sessions = @($transcriptUsage.sessions)
    }

    return [ordered]@{
        collector = Get-ClaudeUsageCollectorStatus -ProfileName $ProfileName
        latest = $latest
        sessions = $sessions
    }
}

function Sync-ClaudeUsageCollector {
    param(
        [string[]]$ProfileNames = @(),
        [switch]$Force
    )

    Ensure-Directory -Path $Script:ClaudeUsageStateRoot
    Ensure-Directory -Path $Script:ClaudeStatuslineToolsRoot

    $wrapperSourcePath = Get-ClaudeUsageCollectorSourceWrapperPath
    $scriptSourcePath = Get-ClaudeUsageCollectorSourceScriptPath
    $wrapperPath = Get-ClaudeUsageCollectorWrapperPath
    $scriptPath = Get-ClaudeUsageCollectorScriptPath
    if (-not (Test-Path -LiteralPath $wrapperSourcePath)) {
        throw "Wrapper do coletor nao encontrado: $wrapperSourcePath"
    }
    if (-not (Test-Path -LiteralPath $scriptSourcePath)) {
        throw "Script do coletor nao encontrado: $scriptSourcePath"
    }

    Copy-Item -LiteralPath $wrapperSourcePath -Destination $wrapperPath -Force
    Copy-Item -LiteralPath $scriptSourcePath -Destination $scriptPath -Force

    $selectedProfiles = @(
        Get-ClaudeProfileDefinitions |
        Where-Object { $ProfileNames.Count -eq 0 -or $ProfileNames -contains $_.name }
    )
    if ($selectedProfiles.Count -eq 0) {
        throw "Nenhum perfil Claude encontrado para instalar a coleta."
    }

    $results = @()
    foreach ($profile in $selectedProfiles) {
        $settingsPath = Join-Path $profile.configDir "settings.json"
        $currentStatus = Get-ClaudeUsageCollectorStatus -ProfileName $profile.name
        $command = Get-ClaudeUsageCollectorCommand -ProfileName $profile.name
        $result = [ordered]@{
            profile = $profile.name
            settingsPath = $settingsPath
            command = $command
            installed = $false
            conflict = $false
            changed = $false
        }

        $settings = if (Test-Path -LiteralPath $settingsPath) {
            Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        } else {
            [pscustomobject]@{}
        }

        if ($currentStatus.conflict -and -not $Force) {
            $result.conflict = $true
            $result.currentCommand = $currentStatus.currentCommand
            $results += $result
            continue
        }

        $statusLine = [pscustomobject]@{
            type = "command"
            command = $command
            padding = 1
        }

        if ($settings.PSObject.Properties.Name -contains "statusLine") {
            $settings.statusLine = $statusLine
        } else {
            Add-Member -InputObject $settings -NotePropertyName "statusLine" -NotePropertyValue $statusLine
        }

        Ensure-Directory -Path $profile.configDir
        Write-JsonFile -Path $settingsPath -Data $settings

        $result.installed = $true
        $result.changed = (-not $currentStatus.installed)
        $results += $result
    }

    return [ordered]@{
        stateRoot = $Script:ClaudeUsageStateRoot
        profiles = $results
    }
}

function Get-QuotedCmdArgument {
    param([string]$Value)

    return '"' + $Value.Replace('"', '""') + '"'
}

function Invoke-ClaudeAuthCommand {
    param(
        [string]$ConfigDir,
        [string[]]$Arguments
    )

    $claudeCli = Get-ClaudeCliForAuth
    if (-not $claudeCli) {
        throw "Claude CLI nao encontrado para autenticacao."
    }

    $previousConfigDir = $env:CLAUDE_CONFIG_DIR
    try {
        $env:CLAUDE_CONFIG_DIR = $ConfigDir
        $output = & $claudeCli @Arguments 2>&1
        $text = [string]::Join("`n", @($output | ForEach-Object { $_.ToString() }))
        $exitCode = $LASTEXITCODE
    } finally {
        if ($null -eq $previousConfigDir) {
            Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
        } else {
            $env:CLAUDE_CONFIG_DIR = $previousConfigDir
        }
    }

    return [pscustomobject]@{
        output = $text.Trim()
        exitCode = $exitCode
        cliPath = $claudeCli
    }
}

function Get-ClaudeAuthUrlFromText {
    param([string]$Text)

    if (-not $Text) {
        return $null
    }

    $match = [regex]::Match($Text, 'https://(?:claude\.ai/oauth/authorize|claude\.com/cai/oauth/authorize)[^\s]+')
    if ($match.Success) {
        return $match.Value
    }

    return $null
}

function Get-RecentAuthLoginUrls {
    [CmdletBinding()]
    param(
        [int]$Limit = 10,
        [string]$StateRoot = $Script:ClaudeAuthStateRoot
    )

    if (-not (Test-Path -LiteralPath $StateRoot)) {
        return @()
    }

    $sessions = @(Get-ChildItem -LiteralPath $StateRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First ($Limit * 3))

    $results = @()
    foreach ($s in $sessions) {
        $metaPath   = Join-Path $s.FullName 'meta.json'
        $stdoutPath = Join-Path $s.FullName 'stdout.log'
        $donePath   = Join-Path $s.FullName 'done.txt'

        if (-not (Test-Path -LiteralPath $metaPath)) { continue }

        try {
            $meta = Get-Content -LiteralPath $metaPath -Raw -ErrorAction Stop | ConvertFrom-Json
        } catch { continue }

        $stdout = if (Test-Path -LiteralPath $stdoutPath) { Read-SharedTextFile -Path $stdoutPath } else { "" }
        $tool = if ($meta.PSObject.Properties['tool']) { [string]$meta.tool } else { 'claude' }

        $url = if ($tool -eq 'codex') {
            Get-CodexAuthUrlFromText -Text $stdout
        } elseif ($tool -eq 'gemini') {
            Get-GeminiAuthUrlFromText -Text $stdout
        } else {
            Get-ClaudeAuthUrlFromText -Text $stdout
        }

        if (-not $url) { continue }

        $results += [ordered]@{
            sessionId = $meta.sessionId
            tool      = $tool
            profile   = if ($meta.PSObject.Properties['profile']) { [string]$meta.profile } else { '' }
            createdAt = if ($meta.PSObject.Properties['createdAt']) { [string]$meta.createdAt } else { '' }
            done      = (Test-Path -LiteralPath $donePath)
            loginUrl  = $url
            sessionDir = $s.FullName
        }

        if ($results.Count -ge $Limit) { break }
    }

    return $results
}

function Read-SharedTextFile {
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return ""
    }

    $stream = $null
    $reader = $null

    try {
        $stream = [System.IO.File]::Open([string]$Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
        return $reader.ReadToEnd()
    } catch {
        return ""
    } finally {
        if ($reader) {
            $reader.Dispose()
        } elseif ($stream) {
            $stream.Dispose()
        }
    }
}

function Get-ClaudeAuthStatusForConfigDir {
    param([string]$ConfigDir)

    try {
        $result = Invoke-ClaudeAuthCommand -ConfigDir $ConfigDir -Arguments @("auth", "status", "--json")
        if (-not $result.output) {
            return $null
        }

        $parsed = $result.output | ConvertFrom-Json
        return [ordered]@{
            loggedIn = [bool]$parsed.loggedIn
            authMethod = [string]$parsed.authMethod
            apiProvider = [string]$parsed.apiProvider
            email = [string]$parsed.email
            orgId = [string]$parsed.orgId
            orgName = [string]$parsed.orgName
            subscriptionType = [string]$parsed.subscriptionType
            rawOutput = [string]$result.output
        }
    } catch {
        return $null
    }
}

function Get-ClaudeAuthStatus {
    $profiles = Get-ClaudeProfileDefinitions
    $accountState = Get-ClaudeAccountStateStore
    $items = @()
    $stateChanged = $false

    foreach ($profile in $profiles) {
        $runtimeState = $accountState.profiles[$profile.name]
        $cliStatusApplied = $false
        $status = [ordered]@{
            name = $profile.name
            configDir = $profile.configDir
            cliPath = Get-ClaudeCliForAuth
            exists = (Test-Path -LiteralPath $profile.configDir)
            loggedIn = if ($runtimeState) { [bool]$runtimeState.loggedIn } else { $false }
            state = if ($runtimeState) { [string]$runtimeState.state } else { "auth_required" }
            cooldownUntil = if ($runtimeState) { $runtimeState.cooldownUntil } else { $null }
            lastFailureKind = if ($runtimeState) { [string]$runtimeState.lastFailureKind } else { "" }
            leaseOwner = if ($runtimeState) { [string]$runtimeState.leaseOwner } else { "" }
            leaseExpiresAt = if ($runtimeState) { $runtimeState.leaseExpiresAt } else { $null }
            authMethod = "unknown"
            apiProvider = ""
            email = ""
            orgId = ""
            orgName = ""
            subscriptionType = ""
            rawOutput = ""
            exitCode = $null
            usage = Get-ClaudeUsageProfileData -ProfileName $profile.name
        }

        if (-not $status.exists) {
            $items += $status
            continue
        }

        try {
            $result = Invoke-ClaudeAuthCommand -ConfigDir $profile.configDir -Arguments @("auth", "status", "--json")
            $status.rawOutput = $result.output
            $status.exitCode = $result.exitCode

            $parsed = $null
            try {
                $parsed = $result.output | ConvertFrom-Json
            } catch {
                $parsed = $null
            }

            if ($parsed) {
                $status.loggedIn = [bool]$parsed.loggedIn
                $status.authMethod = [string]$parsed.authMethod
                $status.apiProvider = [string]$parsed.apiProvider
                $status.email = [string]$parsed.email
                $status.orgId = [string]$parsed.orgId
                $status.orgName = [string]$parsed.orgName
                $status.subscriptionType = [string]$parsed.subscriptionType
                $cliStatusApplied = $true
            }
        } catch {
            $status.rawOutput = $_.Exception.Message
        }

        if ($cliStatusApplied) {
            Normalize-ClaudeProfileRuntimeState -State $status -Source "cli" | Out-Null
        }

        if ($runtimeState) {
            if ([bool]$runtimeState.loggedIn -ne [bool]$status.loggedIn) {
                $runtimeState["loggedIn"] = [bool]$status.loggedIn
                $stateChanged = $true
            }
            if ([string]$runtimeState.state -ne [string]$status.state) {
                $runtimeState["state"] = [string]$status.state
                $stateChanged = $true
            }
            if ([bool]$status.loggedIn -and [string]$runtimeState.lastFailureKind) {
                $runtimeState["lastFailureKind"] = ""
                $stateChanged = $true
            }
        }

        # Enriquecer com tier de .credentials.json e estimativa de decaimento
        $credentials = Get-ClaudeProfileCredentials -ConfigDir $profile.configDir
        $rateLimitTier = if ($credentials) { [string]$credentials.rateLimitTier } else { "" }
        $status["rateLimitTier"]      = $rateLimitTier
        $status["tierMultiplier"]     = Get-ClaudeTierMultiplier -RateLimitTier $rateLimitTier
        $status["tierLabel"]          = Get-ClaudeTierLabel -RateLimitTier $rateLimitTier
        $status["estimatedRateLimits"] = Get-ClaudeEstimatedRateLimits -Latest $status.usage.latest

        # Expiração do OAuth (JWT decode do accessToken)
        $authInfo = Get-ClaudeAuthInfo -ConfigDir $profile.configDir
        $status["accessTokenExpiresAt"] = if ($authInfo) { $authInfo.accessTokenExpiresAt } else { $null }
        $status["accessTokenExpiresIn"] = if ($authInfo) { $authInfo.accessTokenExpiresIn } else { $null }

        $items += $status
    }

    if ($stateChanged) {
        Save-ClaudeAccountStateStore -State $accountState
    }

    # Detectar perfil ativo via CLAUDE_CONFIG_DIR — resolve junction se necessario
    $configDirEnv = [System.Environment]::GetEnvironmentVariable("CLAUDE_CONFIG_DIR", "User")
    $activeProfileName = ""
    if ($configDirEnv) {
        $parts = $configDirEnv -split '[/\\]'
        $matched = $parts | Where-Object { $_ -match '^claude-[a-z]' } | Select-Object -Last 1
        if ($matched) {
            $activeProfileName = $matched
        } else {
            try {
                $jItem = Get-Item -LiteralPath $configDirEnv -Force -ErrorAction SilentlyContinue
                if ($jItem -and ($jItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $rawTarget = $jItem.Target
                    if ($rawTarget -is [System.Array]) { $rawTarget = $rawTarget[0] }
                    $rawTarget = [string]$rawTarget
                    if ($rawTarget.StartsWith('\??\'))  { $rawTarget = $rawTarget.Substring(4) }
                    elseif ($rawTarget.StartsWith('\\?\')) { $rawTarget = $rawTarget.Substring(4) }
                    $targetLeaf = Split-Path $rawTarget -Leaf
                    if ($targetLeaf -match '^claude-') { $activeProfileName = $targetLeaf }
                }
            } catch {}
        }
    }

    foreach ($item in $items) {
        $item["isActive"] = ($item.name -eq $activeProfileName)
    }

    # ── Pool agregado ponderado por tier ──
    $totalCapacity = 0
    $weightedAvailable = 0.0
    $tierBreakdown = [ordered]@{}

    foreach ($item in $items) {
        $mult = [int]$item.tierMultiplier
        if ($mult -le 0) { $mult = 1 }
        $totalCapacity += $mult

        $est5h = 0.0
        if ($item.estimatedRateLimits -and $null -ne $item.estimatedRateLimits.fiveHour.estimated) {
            $est5h = [double]$item.estimatedRateLimits.fiveHour.estimated
        }
        $profileAvailable = $mult * (1.0 - ($est5h / 100.0))
        $weightedAvailable += $profileAvailable

        $label = [string]$item.tierLabel
        if (-not $label) { $label = "PRO" }
        if (-not $tierBreakdown.Contains($label)) {
            $tierBreakdown[$label] = [ordered]@{
                count = 0; multiplier = $mult; totalCapacity = 0
                totalAvailable = 0.0; profiles = @()
            }
        }
        $tierBreakdown[$label].count += 1
        $tierBreakdown[$label].totalCapacity += $mult
        $tierBreakdown[$label].totalAvailable += $profileAvailable
        $tierBreakdown[$label].profiles += $item.name
    }

    $poolAvailPct = if ($totalCapacity -gt 0) {
        [math]::Round(($weightedAvailable / $totalCapacity) * 100.0, 1)
    } else { 0.0 }

    return [ordered]@{
        configPath    = Get-ClaudeOrchestratorConfigPath
        cliPath       = Get-ClaudeCliForAuth
        activeProfile = $activeProfileName
        profiles      = $items
        aggregatePool = [ordered]@{
            totalCapacity        = $totalCapacity
            weightedAvailable    = [math]::Round($weightedAvailable, 2)
            availabilityPercentage = $poolAvailPct
            tierBreakdown        = $tierBreakdown
        }
    }
}

function New-ClaudeAuthLoginSession {
    param(
        [string]$ProfileName,
        [string]$Email = ""
    )

    $profile = Get-ClaudeProfileDefinitions | Where-Object { $_.name -eq $ProfileName } | Select-Object -First 1
    if (-not $profile) {
        throw "Perfil Claude nao encontrado: $ProfileName"
    }

    $claudeCli = Get-LatestClaudeCliPath
    if (-not $claudeCli) {
        $claudeCli = Get-ClaudeCliForAuth
    }
    if (-not $claudeCli) {
        throw "Claude CLI nao encontrado."
    }

    Ensure-Directory -Path $Script:ClaudeAuthStateRoot

    $sessionId = [guid]::NewGuid().ToString()
    $sessionDir = Join-Path $Script:ClaudeAuthStateRoot $sessionId
    Ensure-Directory -Path $sessionDir

    $stdoutPath = Join-Path $sessionDir "stdout.log"
    $stderrPath = Join-Path $sessionDir "stderr.log"
    $inputPath = Join-Path $sessionDir "stdin.txt"
    $scriptPath = Join-Path $sessionDir "run-login.ps1"
    $metaPath = Join-Path $sessionDir "meta.json"

    $argList = @("auth", "login")
    if ($Email.Trim()) {
        $argList += @("--email", $Email.Trim())
    }

    Set-Content -LiteralPath $inputPath -Value "" -Encoding ASCII

    $argumentsString = (($argList | ForEach-Object { '''' + ($_ -replace '''', '''''') + '''' }) -join ' ')
    $sq = "'"  # helper para aspas simples dentro do array de linhas
    $scriptLines = @(
        'try {',
        ('$env:CLAUDE_CONFIG_DIR = ' + $sq + $profile.configDir + $sq),
        'Write-Host ''''',
        ('Write-Host ''=== Login Claude - Perfil: ' + $ProfileName + ' ==='' -ForegroundColor Cyan'),
        'Write-Host ''O navegador sera aberto automaticamente. Complete o login no navegador.'' -ForegroundColor Yellow',
        'Write-Host ''Se o navegador nao abrir, copie o link que aparecera abaixo.'' -ForegroundColor Yellow',
        'Write-Host ''''',
        ('& ' + $sq + $claudeCli + $sq + ' ' + $argumentsString + ' 2>&1 | Tee-Object -FilePath ' + $sq + $stdoutPath + $sq),
        '} catch {',
        '    Write-Host "ERRO: $_" -ForegroundColor Red',
        ('    $_ | Out-File -FilePath ' + $sq + $stderrPath + $sq + ' -Encoding UTF8'),
        '}',
        'Write-Host ''''',
        'Write-Host ''Processo concluido. Esta janela fechara em 15 segundos...'' -ForegroundColor Green',
        'Start-Sleep -Seconds 15'
    )
    Set-Content -LiteralPath $scriptPath -Value ($scriptLines -join "`r`n") -Encoding UTF8

    $preAuthStatus = $null
    try {
        $preAuthStatus = Get-ClaudeAuthStatusForConfigDir -ConfigDir $profile.configDir
    } catch {}

    # IMPORTANTE: usar string unica em -ArgumentList para preservar aspas em caminhos com espacos
    $argString = '-NoProfile -ExecutionPolicy Bypass -File "' + $scriptPath + '"'
    $process = Start-Process -FilePath "powershell.exe" -ArgumentList $argString -PassThru -WindowStyle Normal

    $meta = [ordered]@{
        sessionId          = $sessionId
        profile            = $profile.name
        configDir          = $profile.configDir
        cliPath            = $claudeCli
        email              = $Email.Trim()
        pid                = $process.Id
        createdAt          = (Get-Date).ToString("o")
        stdoutPath         = $stdoutPath
        stderrPath         = $stderrPath
        inputPath          = $inputPath
        scriptPath         = $scriptPath
        wasAlreadyLoggedIn = ($preAuthStatus -and [bool]$preAuthStatus.loggedIn)
    }
    Write-JsonFile -Path $metaPath -Data $meta

    return Get-ClaudeAuthLoginSession -SessionId $sessionId
}

function Get-ClaudeAuthLoginSession {
    param([string]$SessionId)

    $sessionDir = Join-Path $Script:ClaudeAuthStateRoot $SessionId
    $metaPath = Join-Path $sessionDir "meta.json"
    if (-not (Test-Path -LiteralPath $metaPath)) {
        throw "Sessao de autenticacao nao encontrada: $SessionId"
    }

    $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
    $stdout = Read-SharedTextFile -Path ([string]$meta.stdoutPath)
    $stderr = Read-SharedTextFile -Path ([string]$meta.stderrPath)
    $process = Get-Process -Id $meta.pid -ErrorAction SilentlyContinue
    $running = $null -ne $process
    $stdoutText = [string]$stdout
    $stderrText = [string]$stderr
    $combined = (($stdoutText, $stderrText) -join "`n").Trim()
    $loginUrl = Get-ClaudeAuthUrlFromText -Text $combined
    $authStatus = Get-ClaudeAuthStatusForConfigDir -ConfigDir ([string]$meta.configDir)
    $wasAlreadyLoggedIn = [bool]($meta.PSObject.Properties['wasAlreadyLoggedIn'] -and $meta.wasAlreadyLoggedIn)
    $loginSucceeded = ($combined -match "Login successful") -or
        (-not $wasAlreadyLoggedIn -and $authStatus -and [bool]$authStatus.loggedIn)

    if ($loginSucceeded -and $running) {
        try {
            Stop-Process -Id $meta.pid -Force -ErrorAction SilentlyContinue
        } catch {
        }
        Start-Sleep -Milliseconds 150
        $process = Get-Process -Id $meta.pid -ErrorAction SilentlyContinue
        $running = $null -ne $process
    }

    # Hook: disparar sync VPS uma única vez quando o login acabou de concluir
    # (marcador em vps-synced.flag evita re-trigger no polling subsequente).
    if ($loginSucceeded -and -not $wasAlreadyLoggedIn) {
        $syncedFlag = Join-Path $sessionDir "vps-synced.flag"
        if (-not (Test-Path -LiteralPath $syncedFlag)) {
            $flagContent = "noop"
            try {
                $syncResult = Invoke-VpsAuthSyncForProfile -ProfileName ([string]$meta.profile) -OnlyIfActive
                $flagContent = ($syncResult | ConvertTo-Json -Depth 6 -Compress)
            } catch {
                $flagContent = "error:$($_.Exception.Message)"
            }
            try {
                Set-Content -LiteralPath $syncedFlag -Value $flagContent -Encoding UTF8 -Force
            } catch {}
        }
    }

    return [ordered]@{
        sessionId = $meta.sessionId
        profile = $meta.profile
        configDir = $meta.configDir
        email = $meta.email
        pid = $meta.pid
        createdAt = $meta.createdAt
        running = $running
        loginSucceeded = $loginSucceeded
        loginUrl = $loginUrl
        awaitingCode = [bool]($running -and -not $loginSucceeded -and ($combined -match "Opening browser to sign in"))
        authStatus = $authStatus
        stdout = $stdoutText
        stderr = $stderrText
    }
}

function Submit-ClaudeAuthLoginCode {
    param(
        [string]$SessionId,
        [string]$Code
    )

    if (-not $Code -or -not $Code.Trim()) {
        throw "Informe o codigo retornado pelo Claude."
    }

    $sessionDir = Join-Path $Script:ClaudeAuthStateRoot $SessionId
    $metaPath = Join-Path $sessionDir "meta.json"
    if (-not (Test-Path -LiteralPath $metaPath)) {
        throw "Sessao de autenticacao nao encontrada: $SessionId"
    }

    $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
    if (-not $meta.inputPath) {
        throw "Esta sessao nao aceita codigo interativo."
    }

    [System.IO.File]::WriteAllText([string]$meta.inputPath, $Code.Trim(), [System.Text.Encoding]::UTF8)
    Start-Sleep -Milliseconds 200
    return Get-ClaudeAuthLoginSession -SessionId $SessionId
}

function Get-CodexAuthUrlFromText {
    param([string]$Text)

    if (-not $Text) {
        return $null
    }

    $match = [regex]::Match($Text, 'https://[^\s]+')
    if ($match.Success) {
        return $match.Value
    }

    return $null
}

function Start-CodexAuthLogin {
    param(
        [string]$ProfileName
    )

    $profilesRoot = Join-Path $Script:UserProfileRoot ".codex-profiles"
    $profileDir   = Join-Path $profilesRoot $ProfileName

    if (-not (Test-Path -LiteralPath $profileDir -PathType Container)) {
        throw "Perfil Codex nao encontrado: $ProfileName"
    }

    Ensure-Directory -Path $Script:ClaudeAuthStateRoot

    $sessionId  = [guid]::NewGuid().ToString()
    $sessionDir = Join-Path $Script:ClaudeAuthStateRoot "codex-$sessionId"
    Ensure-Directory -Path $sessionDir

    $donePath   = Join-Path $sessionDir "done.txt"
    $scriptPath = Join-Path $sessionDir "run-login.ps1"
    $stdoutPath = Join-Path $sessionDir "stdout.log"
    $metaPath   = Join-Path $sessionDir "meta.json"

    # Script executado DENTRO da janela de terminal (precisa de TTY para Codex CLI).
    # Redireciona via cmd.exe para preservar bytes nativos do stdout do node.exe,
    # sem o word-wrap do formatter do PowerShell (que quebra URLs longas no meio).
    $stdoutJson = ConvertTo-Json -Compress $stdoutPath
    $doneJson   = ConvertTo-Json -Compress $donePath
    $scriptLines = @(
        '$ErrorActionPreference = "Continue"',
        ('$env:CODEX_HOME = ' + (ConvertTo-Json -Compress $profileDir)),
        ('$env:PATH = "C:\Program Files\nodejs;" + $env:APPDATA + "\npm;" + $env:PATH'),
        ('$stdoutPath = ' + $stdoutJson),
        'Write-Host ""',
        ('Write-Host "=== Login Codex - Perfil: ' + $ProfileName + ' ===" -ForegroundColor Cyan'),
        'Write-Host "O link de autenticacao aparecera no painel Auth Hub em instantes." -ForegroundColor Yellow',
        'Write-Host "Se o navegador abrir sozinho, ignore ou feche - use o link do painel." -ForegroundColor Yellow',
        'Write-Host ""',
        '"" | Set-Content -LiteralPath $stdoutPath -Encoding UTF8',
        '# Redireciona stdout+stderr do codex login direto para o arquivo via cmd.exe.',
        '# Assim o PowerShell nao aplica wrap no URL OAuth (que excede 120 colunas).',
        '$cmdLine = ''codex login > "'' + $stdoutPath + ''" 2>&1''',
        '$proc = Start-Process -FilePath cmd.exe -ArgumentList ''/c'', $cmdLine -NoNewWindow -PassThru',
        'Write-Host "Aguardando o Codex CLI imprimir o link..." -ForegroundColor DarkGray',
        '$shown = 0',
        'while (-not $proc.HasExited) {',
        '    Start-Sleep -Milliseconds 500',
        '    try {',
        '        $raw = [System.IO.File]::ReadAllText($stdoutPath)',
        '        if ($raw.Length -gt $shown) {',
        '            [Console]::Write($raw.Substring($shown))',
        '            $shown = $raw.Length',
        '        }',
        '    } catch {}',
        '}',
        'try {',
        '    $raw = [System.IO.File]::ReadAllText($stdoutPath)',
        '    if ($raw.Length -gt $shown) { [Console]::Write($raw.Substring($shown)) }',
        '} catch {}',
        ('Set-Content -LiteralPath ' + $doneJson + ' -Value "done" -Encoding UTF8'),
        'Write-Host ""',
        'Write-Host "Login concluido. Esta janela sera fechada em 5 segundos..." -ForegroundColor Green',
        'Start-Sleep -Seconds 5'
    )
    Set-Content -LiteralPath $scriptPath -Value ($scriptLines -join "`r`n") -Encoding UTF8

    # Tentar Windows Terminal primeiro, fallback para powershell.exe com janela visivel
    $wtPath  = "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe"
    $wtFound = Test-Path -LiteralPath $wtPath

    if ($wtFound) {
        $argList = "new-tab powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
        Start-Process -FilePath $wtPath -ArgumentList $argList
    } else {
        Start-Process -FilePath "powershell.exe" -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $scriptPath + '"')
    }

    $meta = [ordered]@{
        sessionId   = $sessionId
        tool        = "codex"
        profile     = $ProfileName
        profileDir  = $profileDir
        createdAt   = (Get-Date).ToString("o")
        donePath    = $donePath
        scriptPath  = $scriptPath
        stdoutPath  = $stdoutPath
    }
    Write-JsonFile -Path $metaPath -Data $meta

    return Get-CodexAuthLoginSession -SessionId $sessionId
}

function Get-CodexAuthLoginSession {
    param([string]$SessionId)

    $sessionDir = Join-Path $Script:ClaudeAuthStateRoot "codex-$SessionId"
    $metaPath   = Join-Path $sessionDir "meta.json"
    if (-not (Test-Path -LiteralPath $metaPath)) {
        throw "Sessao Codex nao encontrada: $SessionId"
    }

    $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json

    # Detectar login via auth.json populado
    $authJsonPath = Join-Path ([string]$meta.profileDir) "auth.json"
    $hasRealAuth  = $false
    if (Test-Path -LiteralPath $authJsonPath) {
        try {
            $authContent = [System.IO.File]::ReadAllText($authJsonPath).Trim()
            $hasRealAuth = ($authContent.Length -gt 5 -and $authContent -ne '{}')
        } catch {}
    }

    $loginSucceeded = $hasRealAuth

    # "running" = login ainda pendente e dentro do timeout de 10 minutos
    $donePath2 = if ($meta.donePath) { [string]$meta.donePath } else { Join-Path $sessionDir "done.txt" }
    $done    = Test-Path -LiteralPath $donePath2
    $created = [System.DateTimeOffset]::Parse([string]$meta.createdAt)
    $elapsed = ([System.DateTimeOffset]::UtcNow - $created).TotalMinutes
    $running = -not $loginSucceeded -and -not $done -and ($elapsed -lt 10)

    # Hook unico pos-login Codex. Dois efeitos:
    # 1) copiar o token recem-gravado em .codex-profiles/<perfil>/auth.json para
    #    ~/.codex/auth.json (via Set-CodexProfileJunction). Sem isso, o CLI roda
    #    em CODEX_HOME=active (junction -> ~/.codex) com auth.json stale/vazio.
    # 2) sincronizar VPS com o token novo.
    if ($loginSucceeded) {
        $syncedFlag = Join-Path $sessionDir "vps-synced.flag"
        if (-not (Test-Path -LiteralPath $syncedFlag)) {
            $localSyncNote = "skipped"
            try {
                Set-CodexProfileJunction -ProfileName ([string]$meta.profile) | Out-Null
                $localSyncNote = "ok"
            } catch {
                $localSyncNote = "error:$($_.Exception.Message)"
            }

            $flagContent = "noop"
            try {
                # Pos-login Codex: empurrar o auth.json novo para a VPS via --codex-source.
                # Antes chamavamos Invoke-VpsAuthSyncForActiveClaude, mas isso so pushava
                # Claude — a VPS continuava com refresh_token Codex stale (loop 401).
                $syncResult = Invoke-VpsAuthSyncForCodex -ProfileName ([string]$meta.profile)
                $flagContent = ($syncResult | ConvertTo-Json -Depth 6 -Compress)
            } catch {
                $flagContent = "error:$($_.Exception.Message)"
            }
            try {
                Set-Content -LiteralPath $syncedFlag -Value ("local:" + $localSyncNote + "`nvps:" + $flagContent) -Encoding UTF8 -Force
            } catch {}
        }
    }

    $stdoutPath3 = if ($meta.PSObject.Properties['stdoutPath'] -and $meta.stdoutPath) {
        [string]$meta.stdoutPath
    } else {
        Join-Path $sessionDir "stdout.log"
    }
    $stdoutText = [string](Read-SharedTextFile -Path $stdoutPath3)
    $loginUrl   = Get-CodexAuthUrlFromText -Text $stdoutText

    return [ordered]@{
        sessionId      = $meta.sessionId
        profile        = $meta.profile
        profileDir     = $meta.profileDir
        createdAt      = $meta.createdAt
        running        = $running
        loginSucceeded = $loginSucceeded
        loginUrl       = $loginUrl
        stdout         = $stdoutText
        stderr         = ""
    }
}

# ── Gemini auth helpers ──────────────────────────────────────────────────────
# Reuse the existing claude-auth state root (legacy name) — sessions live in
# state/claude-auth/gemini-<id>/. Login is performed by launching the CLI in
# interactive mode within a custom GEMINI_CONFIG_DIR; the first run prints the
# Google OAuth URL on stdout, which we capture via Get-GeminiAuthUrlFromText.

function Get-GeminiAuthUrlFromText {
    param([string]$Text)

    if (-not $Text) {
        return $null
    }

    # Prefer canonical Google OAuth URLs; fall back to first https:// link
    # ignoring known noise (PowerShell transcript header, MS docs, etc).
    $match = [regex]::Match($Text, 'https://(?:accounts\.google\.com|oauth2\.googleapis\.com)/[^\s]+')
    if ($match.Success) {
        return $match.Value
    }

    $noiseDomains = @(
        'go.microsoft.com', 'aka.ms', 'github.com/PowerShell',
        'docs.microsoft.com', 'learn.microsoft.com', 'www.microsoft.com',
        'localhost', '127.0.0.1'
    )
    foreach ($m in [regex]::Matches($Text, 'https://[^\s]+')) {
        $url = $m.Value
        $skip = $false
        foreach ($n in $noiseDomains) {
            if ($url -like "*$n*") { $skip = $true; break }
        }
        if (-not $skip) { return $url }
    }

    return $null
}

function Get-GeminiProfiles {
    [CmdletBinding()]
    param(
        [string]$ProfilesRoot
    )

    if (-not $ProfilesRoot) {
        $ProfilesRoot = Join-Path $Script:UserProfileRoot ".gemini-profiles"
    }

    if (-not (Test-Path -LiteralPath $ProfilesRoot)) {
        return @()
    }

    # Active profile is determined by current GEMINI_CONFIG_DIR (User scope).
    $activeDir = [System.Environment]::GetEnvironmentVariable('GEMINI_CONFIG_DIR', 'User')
    if (-not $activeDir) {
        $activeDir = $env:GEMINI_CONFIG_DIR
    }

    $profiles = @()
    Get-ChildItem -LiteralPath $ProfilesRoot -Directory -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            $name      = $_.Name
            $configDir = $_.FullName
            $authPath  = Join-Path $configDir "oauth_creds.json"
            $isActive  = $false
            if ($activeDir) {
                try {
                    $a = [System.IO.Path]::GetFullPath($activeDir).TrimEnd('\','/')
                    $b = [System.IO.Path]::GetFullPath($configDir).TrimEnd('\','/')
                    $isActive = ($a -ieq $b)
                } catch { $isActive = ($activeDir -ieq $configDir) }
            }

            $profiles += [ordered]@{
                name      = $name
                configDir = $configDir
                hasAuth   = (Test-Path -LiteralPath $authPath)
                isActive  = $isActive
            }
        }

    return $profiles
}

function Add-GeminiProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [string]$ProfilesRoot
    )

    $trimmed = ($Name | Out-String).Trim()
    # Accept either "gemini-<letra>" or generic "[a-z][a-z0-9-]*". Use -cmatch
    # (case-sensitive) so names like "GEMINI-X" or "Work01" are rejected.
    if (-not ($trimmed -cmatch '^gemini-[a-z]$' -or $trimmed -cmatch '^[a-z][a-z0-9-]*$')) {
        throw "Nome de perfil Gemini invalido: '$Name' (use letras minusculas, digitos, hifens; ex: gemini-a)"
    }
    if ($trimmed -eq 'active') {
        throw "Nome de perfil Gemini reservado: 'active'"
    }

    if (-not $ProfilesRoot) {
        $ProfilesRoot = Join-Path $Script:UserProfileRoot ".gemini-profiles"
    }
    Ensure-Directory -Path $ProfilesRoot

    $profileDir = Join-Path $ProfilesRoot $trimmed
    if (Test-Path -LiteralPath $profileDir) {
        throw "Perfil Gemini ja existe: $trimmed"
    }

    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null

    # Pre-popular settings.json com selectedType=oauth-personal para pular o
    # picker "Select Auth Method" do gemini CLI 0.37.1 na primeira invocacao.
    # Sem isso, o gemini abre dialog interativo TUI e o OAuth nunca dispara
    # ate o user navegar com setas e teclar Enter em "Login with Google".
    # Ref: https://github.com/google-gemini/gemini-cli/issues/14365
    $settingsJson = @{
        security = @{
            auth = @{
                selectedType = 'oauth-personal'
            }
        }
    } | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath (Join-Path $profileDir 'settings.json') -Value $settingsJson -Encoding UTF8

    Write-Host "Perfil Gemini criado: $trimmed (faca login para associar uma conta Google)"
    return [ordered]@{
        added     = $true
        name      = $trimmed
        configDir = $profileDir
        hasAuth   = $false
        isActive  = $false
    }
}

function Remove-GeminiProfile {
    <#
    Soft-delete um perfil Gemini. Move ~/.gemini-profiles/<Name> para
    ~/.gemini-profiles-removed/<Name>-<timestamp>. Nao bloqueia se for ativo
    (Gemini nao tem state critico — proxima invocacao re-resolve).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Name,
        [string]$ProfilesRoot,
        [string]$BackupRoot
    )

    $trimmed = ($Name | Out-String).Trim()
    if (-not $trimmed) { throw "Nome de perfil Gemini invalido." }

    if (-not $ProfilesRoot) {
        $ProfilesRoot = Join-Path $Script:UserProfileRoot ".gemini-profiles"
    }
    if (-not $BackupRoot) {
        $BackupRoot = Join-Path $Script:UserProfileRoot ".gemini-profiles-removed"
    }

    $profileDir = Join-Path $ProfilesRoot $trimmed
    if (-not (Test-Path -LiteralPath $profileDir -PathType Container)) {
        throw "Perfil Gemini nao encontrado: $trimmed"
    }

    Ensure-Directory -Path $BackupRoot
    $ts = (Get-Date).ToString("yyyyMMdd-HHmmss")
    $backupDir = Join-Path $BackupRoot ("{0}-{1}" -f $trimmed, $ts)

    Move-Item -LiteralPath $profileDir -Destination $backupDir -Force

    Write-Host "Perfil Gemini removido (soft): $trimmed -> $backupDir"
    return [ordered]@{
        removed   = $true
        name      = $trimmed
        backupDir = $backupDir
    }
}

function Start-GeminiAuthLogin {
    param(
        [Parameter(Mandatory)]
        [string]$ProfileName
    )

    $profilesRoot = Join-Path $Script:UserProfileRoot ".gemini-profiles"
    $profileDir   = Join-Path $profilesRoot $ProfileName

    if (-not (Test-Path -LiteralPath $profileDir -PathType Container)) {
        throw "Perfil Gemini nao encontrado: $ProfileName"
    }

    Ensure-Directory -Path $Script:ClaudeAuthStateRoot

    $sessionId  = [guid]::NewGuid().ToString()
    $sessionDir = Join-Path $Script:ClaudeAuthStateRoot "gemini-$sessionId"
    Ensure-Directory -Path $sessionDir

    $donePath   = Join-Path $sessionDir "done.txt"
    $scriptPath = Join-Path $sessionDir "run-login.ps1"
    $stdoutPath = Join-Path $sessionDir "stdout.log"
    $metaPath   = Join-Path $sessionDir "meta.json"

    $stdoutJson    = ConvertTo-Json -Compress $stdoutPath
    $doneJson      = ConvertTo-Json -Compress $donePath
    $oauthCredsJson = ConvertTo-Json -Compress (Join-Path $profileDir "oauth_creds.json")
    $scriptLines = @(
        '$ErrorActionPreference = "Continue"',
        ('$env:GEMINI_CONFIG_DIR = ' + (ConvertTo-Json -Compress $profileDir)),
        ('$env:PATH = "C:\Program Files\nodejs;" + $env:APPDATA + "\npm;" + $env:PATH'),
        ('$stdoutPath = ' + $stdoutJson),
        ('$donePath   = ' + $doneJson),
        ('$oauthCreds = ' + $oauthCredsJson),
        'Write-Host ""',
        ('Write-Host "=== Login Gemini - Perfil: ' + $ProfileName + ' ===" -ForegroundColor Cyan'),
        'Write-Host ""',
        'Write-Host "Profile dir ja tem settings.json com selectedType=oauth-personal" -ForegroundColor DarkGray',
        'Write-Host "(picker Select Auth Method foi pulado automaticamente)" -ForegroundColor DarkGray',
        'Write-Host ""',
        'Write-Host "INSTRUCOES:" -ForegroundColor Yellow',
        'Write-Host "  1. O Gemini CLI abrira em modo interativo." -ForegroundColor Yellow',
        'Write-Host "  2. O browser deve abrir SOZINHO para o login Google." -ForegroundColor Yellow',
        'Write-Host "     Se nao abrir, o link aparecera na janela - copie e cole no browser." -ForegroundColor Yellow',
        'Write-Host "  3. Apos autorizar no Google, o gemini detecta e volta ao prompt." -ForegroundColor Yellow',
        'Write-Host "  4. Digite ''/quit'' (com a barra) no prompt do Gemini para sair." -ForegroundColor Yellow',
        'Write-Host ""',
        'Write-Host "TIP: oauth_creds.json sera gravado em:" -ForegroundColor DarkGray',
        ('Write-Host "  ' + $profileDir + '\oauth_creds.json" -ForegroundColor DarkGray'),
        'Write-Host "Polling externo detecta o arquivo automaticamente." -ForegroundColor DarkGray',
        'Write-Host ""',
        'Write-Host "Pressione ENTER para iniciar o Gemini..." -ForegroundColor Cyan',
        '[Console]::ReadKey($true) | Out-Null',
        'Write-Host ""',
        '',
        '# Gemini CLI em modo TTY real. NAO usar Start-Transcript (nao captura Node nativo)',
        '# nem redirect > (forca non-interactive). Polling externo de oauth_creds.json e a',
        '# fonte de verdade — wrapper so abre a janela e marca done.txt no fim.',
        '& gemini',
        '$rc = $LASTEXITCODE',
        '',
        '# Confirmacao final',
        'if (Test-Path -LiteralPath $oauthCreds) {',
        '    Write-Host ""',
        '    Write-Host "Login OK! oauth_creds.json gravado." -ForegroundColor Green',
        '} else {',
        '    Write-Host ""',
        '    Write-Host "oauth_creds.json AUSENTE. Login pode nao ter completado." -ForegroundColor Red',
        '    Write-Host "Verifique o browser e tente de novo." -ForegroundColor Red',
        '}',
        'Set-Content -LiteralPath $donePath -Value "done" -Encoding UTF8',
        'Write-Host ""',
        'Write-Host "Pressione qualquer tecla para fechar esta janela." -ForegroundColor DarkGray',
        '[Console]::ReadKey($true) | Out-Null'
    )
    Set-Content -LiteralPath $scriptPath -Value ($scriptLines -join "`r`n") -Encoding UTF8

    $wtPath  = "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe"
    $wtFound = Test-Path -LiteralPath $wtPath

    if ($wtFound) {
        $argList = "new-tab powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
        Start-Process -FilePath $wtPath -ArgumentList $argList
    } else {
        Start-Process -FilePath "powershell.exe" -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $scriptPath + '"')
    }

    $meta = [ordered]@{
        sessionId  = $sessionId
        tool       = "gemini"
        profile    = $ProfileName
        profileDir = $profileDir
        createdAt  = (Get-Date).ToString("o")
        donePath   = $donePath
        scriptPath = $scriptPath
        stdoutPath = $stdoutPath
    }
    Write-JsonFile -Path $metaPath -Data $meta

    return Get-GeminiAuthLoginSession -SessionId $sessionId
}

function Get-GeminiAuthLoginSession {
    param([string]$SessionId)

    $sessionDir = Join-Path $Script:ClaudeAuthStateRoot "gemini-$SessionId"
    $metaPath   = Join-Path $sessionDir "meta.json"
    if (-not (Test-Path -LiteralPath $metaPath)) {
        throw "Sessao Gemini nao encontrada: $SessionId"
    }

    $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json

    # Login succeeded once oauth_creds.json appears with content
    $authPath = Join-Path ([string]$meta.profileDir) "oauth_creds.json"
    $loginSucceeded = $false
    if (Test-Path -LiteralPath $authPath) {
        try {
            $authContent = [System.IO.File]::ReadAllText($authPath).Trim()
            $loginSucceeded = ($authContent.Length -gt 5 -and $authContent -ne '{}')
        } catch {}
    }

    $donePath2 = if ($meta.donePath) { [string]$meta.donePath } else { Join-Path $sessionDir "done.txt" }
    $done    = Test-Path -LiteralPath $donePath2
    $created = [System.DateTimeOffset]::Parse([string]$meta.createdAt)
    $elapsed = ([System.DateTimeOffset]::UtcNow - $created).TotalMinutes
    $running = -not $loginSucceeded -and -not $done -and ($elapsed -lt 10)

    $stdoutPath3 = if ($meta.PSObject.Properties['stdoutPath'] -and $meta.stdoutPath) {
        [string]$meta.stdoutPath
    } else {
        Join-Path $sessionDir "stdout.log"
    }
    $stdoutText = [string](Read-SharedTextFile -Path $stdoutPath3)
    $loginUrl   = Get-GeminiAuthUrlFromText -Text $stdoutText
    # Override Gemini timeout para 15 min (aiox-master fix 2026-05-10):
    # user pode demorar no consent Google se conta nao esta logada no browser.
    $running = -not $loginSucceeded -and -not $done -and ($elapsed -lt 15)

    return [ordered]@{
        sessionId      = $meta.sessionId
        profile        = $meta.profile
        profileDir     = $meta.profileDir
        createdAt      = $meta.createdAt
        running        = $running
        loginSucceeded = $loginSucceeded
        loginUrl       = $loginUrl
        stdout         = $stdoutText
        stderr         = ""
    }
}

function Set-GeminiActiveProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProfileName
    )

    $profilesRoot = Join-Path $Script:UserProfileRoot ".gemini-profiles"
    $profileDir   = Join-Path $profilesRoot $ProfileName
    if (-not (Test-Path -LiteralPath $profileDir -PathType Container)) {
        throw "Perfil Gemini nao encontrado: $ProfileName"
    }

    # Determine current "from" profile from GEMINI_CONFIG_DIR (User), if any
    $fromProfile = '<unknown>'
    $current = [System.Environment]::GetEnvironmentVariable('GEMINI_CONFIG_DIR', 'User')
    if ($current) {
        $leaf = Split-Path -Leaf $current
        if ($leaf -and (Test-Path -LiteralPath (Join-Path $profilesRoot $leaf))) {
            $fromProfile = $leaf
        }
    }

    # Use the shared CliRuntime helper (SwapMethod = env, EnvVarName = GEMINI_CONFIG_DIR)
    $runtimePath = Join-Path $Script:HubRoot 'aiox-shared\CliRuntime.psm1'
    Import-Module $runtimePath -Force -ErrorAction Stop
    $result = Invoke-CliRotation -CliType 'gemini' -FromProfile $fromProfile -ToProfile $ProfileName

    return [ordered]@{
        success       = $true
        activeProfile = $ProfileName
        configDir     = $profileDir
        action        = $result.Action
        envVar        = if ($result.PSObject.Properties['EnvVarName']) { $result.EnvVarName } else { 'GEMINI_CONFIG_DIR' }
    }
}

# ── VPS auth sync (ClowdBot) ─────────────────────────────────────────────────

$Script:VpsAuthSyncScriptPath = Join-Path $Script:UserProfileRoot "Diego\VPS\Oracle\ClowdBot\scripts\vps_ai_auth_sync.py"
$Script:VpsAuthSyncStatusPath = Join-Path $Script:ClaudeOrchestratorRoot "vps-sync-status.json"

function Get-ActiveClaudeProfileName {
    $activeLink = Join-Path $Script:UserProfileRoot ".claude-profiles\active"
    if (-not (Test-Path -LiteralPath $activeLink)) { return $null }
    try {
        $item = Get-Item -LiteralPath $activeLink -Force -ErrorAction Stop
        $target = $item.Target
        if ($target) {
            $targetPath = if ($target -is [array]) { $target[0] } else { [string]$target }
            if ($targetPath) {
                return Split-Path -Leaf $targetPath
            }
        }
    } catch {
    }
    return $null
}

function Resolve-PythonExe {
    $cmd = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($ver in @("Python313", "Python312", "Python311")) {
        $fallback = Join-Path $Script:UserProfileRoot "AppData\Local\Programs\Python\$ver\python.exe"
        if (Test-Path -LiteralPath $fallback) { return $fallback }
    }
    $cmd = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Read-VpsAuthSyncStatusMap {
    if (-not (Test-Path -LiteralPath $Script:VpsAuthSyncStatusPath)) {
        return @{}
    }
    try {
        $raw = Get-Content -LiteralPath $Script:VpsAuthSyncStatusPath -Raw
        if (-not $raw -or -not $raw.Trim()) { return @{} }
        $parsed = $raw | ConvertFrom-Json
        $out = @{}
        foreach ($p in $parsed.PSObject.Properties) {
            $out[$p.Name] = $p.Value
        }
        return $out
    } catch {
        return @{}
    }
}

function Write-VpsAuthSyncStatusMap {
    param([hashtable]$Map)

    Ensure-Directory -Path $Script:ClaudeOrchestratorRoot

    $ordered = [ordered]@{}
    foreach ($key in ($Map.Keys | Sort-Object)) {
        $ordered[$key] = $Map[$key]
    }
    $json = $ordered | ConvertTo-Json -Depth 6
    Set-FileAtomic -Path $Script:VpsAuthSyncStatusPath -Content $json
}

function Update-VpsAuthSyncStatus {
    param(
        [Parameter(Mandatory)] [string]$ProfileName,
        [Parameter(Mandatory)] $Entry
    )

    $map = Read-VpsAuthSyncStatusMap
    $map[$ProfileName] = $Entry
    Write-VpsAuthSyncStatusMap -Map $map
}

function Get-VpsAuthSyncStatus {
    $map = Read-VpsAuthSyncStatusMap
    $out = [ordered]@{}
    foreach ($key in ($map.Keys | Sort-Object)) {
        $out[$key] = $map[$key]
    }
    return $out
}

function Invoke-VpsAuthSyncForActiveClaude {
    <#
    Disparador usado pelos hooks Codex. O script Python cobre claude+codex numa
    unica chamada, entao sincronizar via "profile Claude ativo" basta: o Codex
    eh lido de ~/.codex/ default (que Set-CodexProfileJunction mantem apontando
    para o profile Codex ativo do painel).
    #>
    $active = Get-ActiveClaudeProfileName
    $nowUtc = (Get-Date).ToUniversalTime().ToString("o")
    if (-not $active) {
        $entry = [ordered]@{
            status    = "skip"
            reason    = "no_active_claude"
            lastRunAt = $nowUtc
        }
        Update-VpsAuthSyncStatus -ProfileName "__codex_trigger__" -Entry $entry
        return $entry
    }
    return Invoke-VpsAuthSyncForProfile -ProfileName $active
}

function Invoke-VpsAuthSyncForProfile {
    param(
        [Parameter(Mandatory)] [string]$ProfileName,
        [switch]$OnlyIfActive
    )

    $nowUtc = (Get-Date).ToUniversalTime().ToString("o")

    if ($OnlyIfActive) {
        $active = Get-ActiveClaudeProfileName
        if (-not $active -or $active -ne $ProfileName) {
            $entry = [ordered]@{
                status        = "skip"
                reason        = "profile_not_active"
                activeProfile = $active
                lastRunAt     = $nowUtc
            }
            Update-VpsAuthSyncStatus -ProfileName $ProfileName -Entry $entry
            return $entry
        }
    }

    $profileDir = Join-Path $Script:UserProfileRoot ".claude-profiles\$ProfileName"
    if (-not (Test-Path -LiteralPath $profileDir -PathType Container)) {
        $entry = [ordered]@{
            status     = "skip"
            reason     = "profile_dir_not_found"
            profileDir = $profileDir
            lastRunAt  = $nowUtc
        }
        Update-VpsAuthSyncStatus -ProfileName $ProfileName -Entry $entry
        return $entry
    }

    $credentialsPath = Join-Path $profileDir ".credentials.json"
    if (-not (Test-Path -LiteralPath $credentialsPath)) {
        $entry = [ordered]@{
            status    = "skip"
            reason    = "no_credentials"
            lastRunAt = $nowUtc
        }
        Update-VpsAuthSyncStatus -ProfileName $ProfileName -Entry $entry
        return $entry
    }

    if (-not (Test-Path -LiteralPath $Script:VpsAuthSyncScriptPath)) {
        $entry = [ordered]@{
            status     = "error"
            reason     = "sync_script_missing"
            scriptPath = $Script:VpsAuthSyncScriptPath
            lastRunAt  = $nowUtc
        }
        Update-VpsAuthSyncStatus -ProfileName $ProfileName -Entry $entry
        return $entry
    }

    $python = Resolve-PythonExe
    if (-not $python) {
        $entry = [ordered]@{
            status    = "error"
            reason    = "python_not_found"
            lastRunAt = $nowUtc
        }
        Update-VpsAuthSyncStatus -ProfileName $ProfileName -Entry $entry
        return $entry
    }

    $startedAt = Get-Date
    $output = ""
    $exitCode = -1
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $python
        $psi.Arguments = ('"{0}" --apply --json --only=claude --claude-source "{1}"' -f $Script:VpsAuthSyncScriptPath, $profileDir)
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(60000)) {
            try { $proc.Kill($true) } catch {}
            $entry = [ordered]@{
                status    = "error"
                reason    = "timeout_60s"
                lastRunAt = $nowUtc
            }
            Update-VpsAuthSyncStatus -ProfileName $ProfileName -Entry $entry
            return $entry
        }
        $output = $stdoutTask.Result
        $stderrOutput = $stderrTask.Result
        $exitCode = $proc.ExitCode
    } catch {
        $entry = [ordered]@{
            status    = "error"
            reason    = "invocation_failed"
            stderr    = $_.Exception.Message
            lastRunAt = $nowUtc
        }
        Update-VpsAuthSyncStatus -ProfileName $ProfileName -Entry $entry
        return $entry
    }

    $jsonLine = $null
    foreach ($line in ($output -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith("{")) { $jsonLine = $trimmed }
    }

    $entry = [ordered]@{
        status          = if ($exitCode -eq 0) { "ok" } else { "error" }
        exitCode        = $exitCode
        pushClaude      = $false
        pushCodex       = $false
        runOpenclawSync = $false
        applied         = $false
        durationMs      = [int]((Get-Date) - $startedAt).TotalMilliseconds
        lastRunAt       = $nowUtc
    }
    if ($stderrOutput) { $entry.stderr = $stderrOutput.Trim() }

    if ($jsonLine) {
        try {
            $parsed = $jsonLine | ConvertFrom-Json
            if ($parsed.PSObject.Properties['push_claude']) { $entry.pushClaude = [bool]$parsed.push_claude }
            if ($parsed.PSObject.Properties['push_codex']) { $entry.pushCodex = [bool]$parsed.push_codex }
            if ($parsed.PSObject.Properties['run_openclaw_sync']) { $entry.runOpenclawSync = [bool]$parsed.run_openclaw_sync }
            if ($parsed.PSObject.Properties['applied']) { $entry.applied = [bool]$parsed.applied }
            if ($parsed.PSObject.Properties['status'] -and [string]$parsed.status -eq "error") {
                $entry.status = "error"
                if ($parsed.PSObject.Properties['reason']) { $entry.reason = [string]$parsed.reason }
            }
        } catch {
            $entry.parseError = $_.Exception.Message
        }
    } else {
        $entry.rawOutput = $output.Trim()
    }

    # Hot-reload do openclaw apos sync bem-sucedido (gateway nao detecta mudanca
    # em auth-profiles.json sem restart). Falha do restart NAO derruba o sync —
    # arquivo ja foi enviado; user pode reiniciar manualmente se necessario.
    if ($entry.applied -and $entry.status -eq 'ok') {
        try {
            $entry.gatewayRestart = Invoke-VpsGatewayRestart
        } catch {
            $entry.gatewayRestart = [ordered]@{
                status = 'error'
                reason = 'helper_threw'
                error  = $_.Exception.Message
            }
        }
    }

    Update-VpsAuthSyncStatus -ProfileName $ProfileName -Entry $entry
    return $entry
}

function Invoke-VpsGatewayRestart {
    <#
    Reinicia o openclaw-gateway na VPS via SSH apos sync bem-sucedido.
    Necessario porque o gateway carrega auth-profiles.json em memoria no
    startup e nao tem hot-reload — sem restart, o token novo no disco e
    ignorado e o gateway continua usando o cache do auth velho ate proxima
    reinicializacao manual.

    Retorna @{ status='ok'|'error'|'skipped'; reason?; durationMs }.
    Falha de SSH NAO derruba o sync (helper isolado, log estruturado).
    #>
    [CmdletBinding()]
    param(
        [string]$Host = '79.72.71.20',
        [string]$User = 'marce',
        [string]$IdentityFile = (Join-Path $env:USERPROFILE '.ssh\id_ed25519'),
        [int]$TimeoutSec = 30
    )

    $startedAt = Get-Date
    if (-not (Test-Path -LiteralPath $IdentityFile)) {
        return [ordered]@{
            status    = 'skipped'
            reason    = 'ssh_identity_missing'
            identity  = $IdentityFile
            durationMs = 0
        }
    }

    try {
        $sshCmd = 'systemctl --user restart openclaw-gateway && sleep 2 && systemctl --user is-active openclaw-gateway'
        $output = & ssh -i $IdentityFile -o ConnectTimeout=$TimeoutSec -o BatchMode=yes "$User@$Host" $sshCmd 2>&1
        $exitCode = $LASTEXITCODE
        $durationMs = [int]((Get-Date) - $startedAt).TotalMilliseconds

        if ($exitCode -ne 0) {
            return [ordered]@{
                status     = 'error'
                reason     = 'ssh_or_systemctl_failed'
                exitCode   = $exitCode
                output     = ([string]$output).Trim()
                durationMs = $durationMs
            }
        }

        $finalState = ([string]$output).Trim().Split("`n") | Select-Object -Last 1
        return [ordered]@{
            status     = if ($finalState -eq 'active') { 'ok' } else { 'error' }
            finalState = $finalState
            durationMs = $durationMs
        }
    } catch {
        return [ordered]@{
            status     = 'error'
            reason     = 'invocation_failed'
            error      = $_.Exception.Message
            durationMs = [int]((Get-Date) - $startedAt).TotalMilliseconds
        }
    }
}

function Invoke-VpsAuthSyncProcess {
    <#
    Helper isolado e mockavel que invoca o Python script de sync VPS.
    Retorna [pscustomobject] @{ ExitCode; Stdout; Stderr; TimedOut; InvocationError }.
    Os callers (Invoke-VpsAuthSyncForProfile / Invoke-VpsAuthSyncForCodex)
    constroem a Argumentos string e interpretam o JSON do stdout.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$PythonExe,
        [Parameter(Mandatory)] [string]$Arguments,
        [int]$TimeoutMs = 60000
    )

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $PythonExe
        $psi.Arguments = $Arguments
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutMs)) {
            try { $proc.Kill($true) } catch {}
            return [pscustomobject]@{
                ExitCode        = -1
                Stdout          = ""
                Stderr          = ""
                TimedOut        = $true
                InvocationError = $null
            }
        }
        return [pscustomobject]@{
            ExitCode        = $proc.ExitCode
            Stdout          = $stdoutTask.Result
            Stderr          = $stderrTask.Result
            TimedOut        = $false
            InvocationError = $null
        }
    } catch {
        return [pscustomobject]@{
            ExitCode        = -1
            Stdout          = ""
            Stderr          = ""
            TimedOut        = $false
            InvocationError = $_.Exception.Message
        }
    }
}

function Invoke-VpsAuthSyncForCodex {
    <#
    Sincroniza o auth.json do perfil Codex indicado (ou ativo) com a VPS via
    --codex-source <path>. Modelado em Invoke-VpsAuthSyncForProfile. Diferenca:
    aponta para ~/.codex-profiles/<name>/auth.json em vez de .credentials.json.
    Usa o prefixo "codex:" no status JSON para nao colidir com perfis Claude.
    #>
    [CmdletBinding()]
    param(
        [string]$ProfileName,
        [string]$ProfilesRoot
    )

    if (-not $ProfilesRoot) {
        $ProfilesRoot = Join-Path $Script:UserProfileRoot ".codex-profiles"
    }

    $nowUtc = (Get-Date).ToUniversalTime().ToString("o")

    if (-not $ProfileName) {
        $markerPath = Join-Path $Script:UserProfileRoot ".codex-active-profile"
        if (Test-Path -LiteralPath $markerPath) {
            try { $ProfileName = (Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8).Trim() } catch {}
        }
        if (-not $ProfileName) {
            $entry = [ordered]@{
                status    = "skip"
                reason    = "no_active_codex"
                lastRunAt = $nowUtc
            }
            Update-VpsAuthSyncStatus -ProfileName "__codex_trigger__" -Entry $entry
            return $entry
        }
    }

    $statusKey = "codex:$ProfileName"
    $profileDir = Join-Path $ProfilesRoot $ProfileName

    if (-not (Test-Path -LiteralPath $profileDir -PathType Container)) {
        $entry = [ordered]@{
            status     = "skip"
            reason     = "profile_dir_not_found"
            profileDir = $profileDir
            lastRunAt  = $nowUtc
        }
        Update-VpsAuthSyncStatus -ProfileName $statusKey -Entry $entry
        return $entry
    }

    $authJsonPath = Join-Path $profileDir "auth.json"
    if (-not (Test-Path -LiteralPath $authJsonPath)) {
        $entry = [ordered]@{
            status    = "skip"
            reason    = "no_auth_json"
            lastRunAt = $nowUtc
        }
        Update-VpsAuthSyncStatus -ProfileName $statusKey -Entry $entry
        return $entry
    }

    if (-not (Test-Path -LiteralPath $Script:VpsAuthSyncScriptPath)) {
        $entry = [ordered]@{
            status     = "error"
            reason     = "sync_script_missing"
            scriptPath = $Script:VpsAuthSyncScriptPath
            lastRunAt  = $nowUtc
        }
        Update-VpsAuthSyncStatus -ProfileName $statusKey -Entry $entry
        return $entry
    }

    $python = Resolve-PythonExe
    if (-not $python) {
        $entry = [ordered]@{
            status    = "error"
            reason    = "python_not_found"
            lastRunAt = $nowUtc
        }
        Update-VpsAuthSyncStatus -ProfileName $statusKey -Entry $entry
        return $entry
    }

    $startedAt = Get-Date
    $arguments = ('"{0}" --apply --json --only=codex --codex-source "{1}"' -f $Script:VpsAuthSyncScriptPath, $authJsonPath)
    $procResult = Invoke-VpsAuthSyncProcess -PythonExe $python -Arguments $arguments -TimeoutMs 60000

    if ($procResult.TimedOut) {
        $entry = [ordered]@{
            status    = "error"
            reason    = "timeout_60s"
            lastRunAt = $nowUtc
        }
        Update-VpsAuthSyncStatus -ProfileName $statusKey -Entry $entry
        return $entry
    }
    if ($procResult.InvocationError) {
        $entry = [ordered]@{
            status    = "error"
            reason    = "invocation_failed"
            stderr    = $procResult.InvocationError
            lastRunAt = $nowUtc
        }
        Update-VpsAuthSyncStatus -ProfileName $statusKey -Entry $entry
        return $entry
    }

    $output = [string]$procResult.Stdout
    $stderrOutput = [string]$procResult.Stderr
    $exitCode = [int]$procResult.ExitCode

    $jsonLine = $null
    foreach ($line in ($output -split "`r?`n")) {
        $tl = $line.Trim()
        if ($tl.StartsWith("{")) { $jsonLine = $tl }
    }

    $entry = [ordered]@{
        status          = if ($exitCode -eq 0) { "ok" } else { "error" }
        exitCode        = $exitCode
        pushClaude      = $false
        pushCodex       = $false
        runOpenclawSync = $false
        applied         = $false
        durationMs      = [int]((Get-Date) - $startedAt).TotalMilliseconds
        lastRunAt       = $nowUtc
        codexSource     = $authJsonPath
    }
    if ($stderrOutput) { $entry.stderr = $stderrOutput.Trim() }

    if ($jsonLine) {
        try {
            $parsed = $jsonLine | ConvertFrom-Json
            if ($parsed.PSObject.Properties['push_claude']) { $entry.pushClaude = [bool]$parsed.push_claude }
            if ($parsed.PSObject.Properties['push_codex']) { $entry.pushCodex = [bool]$parsed.push_codex }
            if ($parsed.PSObject.Properties['run_openclaw_sync']) { $entry.runOpenclawSync = [bool]$parsed.run_openclaw_sync }
            if ($parsed.PSObject.Properties['applied']) { $entry.applied = [bool]$parsed.applied }
            if ($parsed.PSObject.Properties['status'] -and [string]$parsed.status -eq "error") {
                $entry.status = "error"
                if ($parsed.PSObject.Properties['reason']) { $entry.reason = [string]$parsed.reason }
            }
        } catch {
            $entry.parseError = $_.Exception.Message
        }
    } else {
        $entry.rawOutput = $output.Trim()
    }

    # Hot-reload do openclaw apos sync Codex bem-sucedido (gateway nao detecta
    # mudanca em auth-profiles.json sem restart). Falha do restart NAO derruba
    # o sync — arquivo ja foi enviado.
    if ($entry.applied -and $entry.status -eq 'ok') {
        try {
            $entry.gatewayRestart = Invoke-VpsGatewayRestart
        } catch {
            $entry.gatewayRestart = [ordered]@{
                status = 'error'
                reason = 'helper_threw'
                error  = $_.Exception.Message
            }
        }
    }

    Update-VpsAuthSyncStatus -ProfileName $statusKey -Entry $entry
    return $entry
}

function Sync-NativeSuperpowers {
    Ensure-Directory -Path $Script:NativeIntegrationsRoot

    $repoPath = Get-SuperpowersCheckoutPath
    $repoUrl = "https://github.com/obra/superpowers.git"
    $actions = @()

    if ($Install) {
        if (Test-Path -LiteralPath $repoPath) {
            Write-Step "Atualizando checkout local de superpowers"
            $pullOut = & git -C $repoPath pull --ff-only 2>&1
            if ($LASTEXITCODE -ne 0) {
                $tail = ($pullOut | Select-Object -Last 5) -join "`n"
                throw "Falha ao atualizar o checkout local de superpowers. Saida git:`n$tail"
            }
            $actions += "checkout-updated"
        }
        else {
            Write-Step "Clonando superpowers para $repoPath"
            $cloneOut = & git clone --depth 1 $repoUrl $repoPath 2>&1
            if ($LASTEXITCODE -ne 0) {
                $tail = ($cloneOut | Select-Object -Last 5) -join "`n"
                throw "Falha ao clonar o repositorio superpowers. Saida git:`n$tail"
            }
            $actions += "checkout-cloned"
        }
    }

    $skillDirs = @(Get-SuperpowersSkillDirs -RepoPath $repoPath)
    if ($Install -and $skillDirs.Count -gt 0) {
        foreach ($target in Get-GlobalTargetDefinitions | Where-Object { $_.Label -in @("codex-user", "codex-legacy") }) {
            Ensure-Directory -Path $target.Root
            foreach ($skillDir in $skillDirs) {
                $linkPath = Join-Path $target.Root $skillDir.Name
                Ensure-Junction -LinkPath $linkPath -TargetPath $skillDir.FullName -BackupLabel "native-superpowers-$($target.Label)-$($skillDir.Name)"
            }
        }
        $actions += "codex-synced"
    }

    if ($Install) {
        $statusBeforeInstall = Get-SuperpowersNativeStatus
        $claudeCli = Get-LatestClaudeCliPath
        if ($claudeCli -and -not $statusBeforeInstall.claude.installed) {
            Write-Step "Tentando instalar o plugin superpowers no Claude"
            try {
                & $claudeCli plugins install "superpowers@claude-plugins-official" | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    $actions += "claude-plugin-install"
                }
            } catch {
                Write-Step "Aviso: falha ao instalar superpowers no Claude: $($_.Exception.Message)"
            }
        }
        elseif ($statusBeforeInstall.claude.installed) {
            $actions += "claude-plugin-already-installed"
        }

        $geminiCmd = Get-NpmCmdShimPath -CommandName "gemini"
        $geminiManifestPath = Join-Path $repoPath "gemini-extension.json"
        if ($geminiCmd -and (Test-Path -LiteralPath $geminiManifestPath) -and -not $statusBeforeInstall.gemini.installed) {
            $quotedCommand = '"' + $geminiCmd + '" extensions link "' + $repoPath + '"'
            if ($Force) {
                $quotedCommand += " --consent"
            }
            Write-Step "Tentando vincular superpowers como extensao do Gemini"
            try {
                & cmd /d /s /c $quotedCommand | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    $actions += "gemini-extension-link"
                }
            } catch {
                Write-Step "Aviso: falha ao vincular superpowers no Gemini: $($_.Exception.Message)"
            }
        }
        elseif ($statusBeforeInstall.gemini.installed) {
            $actions += "gemini-extension-already-linked"
        }
    }

    $status = Get-SuperpowersNativeStatus
    return [pscustomobject]@{
        status = "ok"
        installRequested = [bool]$Install
        actions = @($actions)
        superpowers = $status
    }
}

function ConvertTo-StringArray {
    param([object]$Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Array]) {
        return @($Value | ForEach-Object { $_.ToString() } | Where-Object { $_ })
    }

    return @($Value.ToString()) | Where-Object { $_ }
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        if ($DryRun) {
            Write-Step "[dry-run] mkdir $Path"
            return
        }
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-UserSourceDefinitions {
    return @(
        @{ Label = "agents"; Root = (Join-UserProfilePath ".agents\skills"); Skip = @(".stfolder") },
        @{ Label = "qwen"; Root = (Join-UserProfilePath ".qwen\skills"); Skip = @(".stfolder") },
        @{ Label = "claude"; Root = (Join-UserProfilePath ".claude\skills"); Skip = @(".stfolder") },
        @{ Label = "codex"; Root = (Join-UserProfilePath ".codex\skills"); Skip = @(".stfolder", ".system") },
        @{ Label = "antigravity"; Root = (Join-UserProfilePath ".antigravity\skills"); Skip = @() }
    )
}

function Get-GlobalTargetDefinitions {
    $targets = @(
        @{ Label = "codex-user"; Root = (Join-UserProfilePath ".agents\skills"); Skip = @(".stfolder") },
        @{ Label = "codex-legacy"; Root = (Join-UserProfilePath ".codex\skills"); Skip = @(".stfolder", ".system") },
        @{ Label = "claude"; Root = (Join-UserProfilePath ".claude\skills"); Skip = @(".stfolder") },
        @{ Label = "qwen"; Root = (Join-UserProfilePath ".qwen\skills"); Skip = @(".stfolder") },
        @{ Label = "antigravity"; Root = (Join-UserProfilePath ".antigravity\skills"); Skip = @() }
    )

    # Incluir automaticamente todos os perfis Claude existentes
    $profilesRoot = Join-UserProfilePath ".claude-profiles"
    if (Test-Path -LiteralPath $profilesRoot) {
        Get-ChildItem -LiteralPath $profilesRoot -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne "active" } |
            ForEach-Object {
                $targets += @{ Label = "claude-profile-$($_.Name)"; Root = (Join-Path $_.FullName "skills"); Skip = @(".stfolder") }
            }
    }

    return $targets
}

function Get-ManagedCatalogRoots {
    return @($Script:AllSkillsRoot)
}

function Get-ProjectManagedRoots {
    param([string]$ProjectAgentsRoot)

    return @($ProjectAgentsRoot, $Script:AllSkillsRoot)
}

function Get-ProjectTargetDefinitions {
    param([string]$ResolvedProjectPath)
    return @(
        @{ Label = "claude-project"; Root = (Join-Path $ResolvedProjectPath ".claude\skills"); Skip = @() },
        @{ Label = "qwen-project"; Root = (Join-Path $ResolvedProjectPath ".qwen\skills"); Skip = @() }
    )
}

function Get-ImmediateSkillDirs {
    param(
        [string]$Root,
        [string[]]$SkipNames = @()
    )

    if (-not (Test-Path -LiteralPath $Root)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $Root -Directory -Force | Where-Object {
        $SkipNames -notcontains $_.Name
    })
}

function Get-TreeLastWriteTimeUtc {
    param([string]$Path)

    $max = (Get-Item -LiteralPath $Path -Force).LastWriteTimeUtc
    foreach ($item in Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue) {
        if ($item.LastWriteTimeUtc -gt $max) {
            $max = $item.LastWriteTimeUtc
        }
    }
    return $max
}

function Get-SourcePriority {
    param([string]$Label)

    $order = @{
        catalog = 0
        agents = 1
        claude = 2
        antigravity = 3
        codex = 4
        qwen = 5
    }

    if ($order.ContainsKey($Label)) {
        return $order[$Label]
    }
    return 99
}

function Backup-ExistingPath {
    param(
        [string]$Path,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    Ensure-Directory -Path $Script:BackupsRoot

    $safeLabel = ($Label -replace '[^a-zA-Z0-9._-]', '_')
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss_fff"
    $backupPath = Join-Path $Script:BackupsRoot "$timestamp-$safeLabel"

    if ($DryRun) {
        Write-Step "[dry-run] backup $Path -> $backupPath"
        return $backupPath
    }

    Move-Item -LiteralPath $Path -Destination $backupPath
    return $backupPath
}

function Copy-SkillTree {
    param(
        [string]$SourcePath,
        [string]$DestinationPath,
        [string]$BackupLabel
    )

    if ((Normalize-FullPath $SourcePath) -eq (Normalize-FullPath $DestinationPath)) {
        return
    }

    if (Test-Path -LiteralPath $DestinationPath) {
        Backup-ExistingPath -Path $DestinationPath -Label $BackupLabel | Out-Null
    }

    Ensure-Directory -Path (Split-Path -Parent $DestinationPath)

    if ($DryRun) {
        Write-Step "[dry-run] copy $SourcePath -> $DestinationPath"
        return
    }

    New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    & robocopy $SourcePath $DestinationPath /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -gt 7) {
        throw "robocopy failed copying $SourcePath to $DestinationPath (exit $LASTEXITCODE)"
    }
}

function Get-LinkTargets {
    param([string]$Path)

    $item = Get-Item -LiteralPath $Path -Force
    if ($null -eq $item.Target) {
        return @()
    }
    if ($item.Target -is [System.Array]) {
        return @($item.Target | ForEach-Object { $_.ToString() })
    }
    return @($item.Target.ToString())
}

function Is-PathUnder {
    param(
        [string]$ChildPath,
        [string]$ParentPath
    )

    $child = (Normalize-FullPath $ChildPath).TrimEnd('\')
    $parent = (Normalize-FullPath $ParentPath).TrimEnd('\')
    return $child.StartsWith($parent, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-ManagedLink {
    param(
        [string]$Path,
        [string[]]$ManagedRoots
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    $item = Get-Item -LiteralPath $Path -Force
    if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        return $false
    }

    $targets = @(Get-LinkTargets -Path $Path)
    if ($targets.Count -eq 0) {
        # .Target unreadable — assume this ReparsePoint is one of ours
        return $true
    }

    foreach ($target in $targets) {
        foreach ($managedRoot in $ManagedRoots) {
            if (Is-PathUnder -ChildPath $target -ParentPath $managedRoot) {
                return $true
            }
        }
    }

    return $false
}

function Ensure-Junction {
    param(
        [string]$LinkPath,
        [string]$TargetPath,
        [string]$BackupLabel
    )

    Ensure-Directory -Path (Split-Path -Parent $LinkPath)

    $item = try { Get-Item -LiteralPath $LinkPath -Force -ErrorAction Stop } catch { $null }
    if ($null -ne $item) {
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            $targets = @(Get-LinkTargets -Path $LinkPath)
            if ($targets.Count -eq 0) {
                # .Target unreadable — assume this is our junction and it is correct
                return
            }
            foreach ($target in $targets) {
                if ((Normalize-FullPath $target).TrimEnd('\') -ieq (Normalize-FullPath $TargetPath).TrimEnd('\')) {
                    return
                }
            }
        }
        Backup-ExistingPath -Path $LinkPath -Label $BackupLabel | Out-Null
    }

    if ($DryRun) {
        Write-Step "[dry-run] junction $LinkPath -> $TargetPath"
        return
    }

    Write-Step "Linking $LinkPath -> $TargetPath"
    New-Item -ItemType Junction -Path $LinkPath -Target $TargetPath | Out-Null
}

function Remove-ManagedLinkIfNeeded {
    param(
        [string]$Path,
        [string[]]$ManagedRoots,
        [string]$BackupLabel
    )

    if (-not (Test-ManagedLink -Path $Path -ManagedRoots $ManagedRoots)) {
        return
    }

    Backup-ExistingPath -Path $Path -Label $BackupLabel | Out-Null
}

function Get-SkillFrontmatter {
    param([string]$SkillDir)

    $skillFile = Join-Path $SkillDir "SKILL.md"
    if (-not (Test-Path -LiteralPath $skillFile)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $skillFile -Raw
    if ($raw -and $raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF) {
        $raw = $raw.Substring(1)
    }
    $frontmatter = $null
    $body = $raw

    if ($raw -match "(?s)\A---\s*\r?\n(.*?)\r?\n---\s*\r?\n(.*)$") {
        $frontmatter = $Matches[1]
        $body = $Matches[2]
    }

    $name = Split-Path $SkillDir -Leaf
    $description = ""

    if ($frontmatter) {
        foreach ($line in ($frontmatter -split "\r?\n")) {
            if ($line -match "^\s*name\s*:\s*(.+?)\s*$") {
                $name = $Matches[1].Trim(" `"'")
            }
            elseif ($line -match "^\s*description\s*:\s*(.+?)\s*$") {
                $description = $Matches[1].Trim(" `"'")
            }
        }
    }

    return [pscustomobject]@{
        Name = $name
        Description = $description
        Body = $body.Trim()
    }
}

function Convert-SkillToGeminiSection {
    param([string]$SkillDir)

    $skill = Get-SkillFrontmatter -SkillDir $SkillDir
    if ($null -eq $skill) {
        return $null
    }

    $lines = @(
        "## Skill: $($skill.Name)"
    )

    if ($skill.Description) {
        $lines += "Use when: $($skill.Description)"
    }

    $lines += ""
    $lines += $skill.Body
    $lines += ""

    return ($lines -join "`r`n").Trim()
}

function Set-FileAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content,
        [switch]$NoBom
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $encoding = [System.Text.UTF8Encoding]::new($false)

    $tmp = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.File]::WriteAllText($tmp, $Content, $encoding)
        if (Test-Path -LiteralPath $Path) {
            Move-Item -LiteralPath $tmp -Destination $Path -Force
        } else {
            Move-Item -LiteralPath $tmp -Destination $Path
        }
    } catch {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Set-JsonFileAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Data,
        [int]$Depth = 20
    )

    $json = $Data | ConvertTo-Json -Depth $Depth
    $null = $json | ConvertFrom-Json
    Set-FileAtomic -Path $Path -Content $json -NoBom
}

function Write-Utf8File {
    param(
        [string]$Path,
        [string]$Content
    )

    if ($DryRun) {
        Write-Step "[dry-run] write $Path"
        return
    }

    Write-Step "Writing $Path"
    Set-FileAtomic -Path $Path -Content $Content -NoBom
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Data
    )

    $json = $Data | ConvertTo-Json -Depth 12
    Write-Utf8File -Path $Path -Content $json
}

function New-ManagedTargetsState {
    return [ordered]@{
        version = 1
        updatedAt = $null
        skills = [ordered]@{}
    }
}

function Get-ManagedTargetsState {
    $state = New-ManagedTargetsState

    if (-not (Test-Path -LiteralPath $Script:ManagedTargetsStateJson)) {
        return $state
    }

    $raw = Get-Content -LiteralPath $Script:ManagedTargetsStateJson -Raw | ConvertFrom-Json
    if ($null -ne $raw.version) {
        $state.version = [int]$raw.version
    }
    if ($null -ne $raw.updatedAt) {
        $state.updatedAt = [string]$raw.updatedAt
    }
    if ($null -ne $raw.skills) {
        foreach ($prop in $raw.skills.PSObject.Properties) {
            $targets = @()
            if ($prop.Value -is [System.Array]) {
                $targets = @($prop.Value | ForEach-Object { $_.ToString() })
            }
            elseif ($null -ne $prop.Value) {
                $targets = @($prop.Value.ToString())
            }
            $state.skills[$prop.Name] = @($targets | Sort-Object -Unique)
        }
    }

    return $state
}

function Save-ManagedTargetsState {
    param([System.Collections.IDictionary]$State)

    $normalized = New-ManagedTargetsState
    $normalized.updatedAt = (Get-Date).ToString("o")

    foreach ($entry in $State.skills.GetEnumerator() | Sort-Object Key) {
        $targets = @($entry.Value | Where-Object { $_ } | Sort-Object -Unique)
        if ($targets.Count -gt 0) {
            $normalized.skills[$entry.Key] = $targets
        }
    }

    Write-JsonFile -Path $Script:ManagedTargetsStateJson -Data $normalized
}

function Get-ManagedTargetsForSkill {
    param(
        [System.Collections.IDictionary]$State,
        [string]$SkillName
    )

    if ($State.skills.Contains($SkillName)) {
        return @($State.skills[$SkillName])
    }

    return @()
}

function Set-ManagedTargetsForSkill {
    param(
        [System.Collections.IDictionary]$State,
        [string]$SkillName,
        [string[]]$Targets
    )

    $normalizedTargets = @($Targets | Where-Object { $_ } | Sort-Object -Unique)
    if ($normalizedTargets.Count -eq 0) {
        if ($State.skills.Contains($SkillName)) {
            $State.skills.Remove($SkillName)
        }
        return
    }

    $State.skills[$SkillName] = $normalizedTargets
}

function Get-ManualManagedTargetsFromFilesystem {
    $state = New-ManagedTargetsState
    $globalNames = @(
        Get-ImmediateSkillDirs -Root $Script:GlobalSkillsRoot |
        Select-Object -ExpandProperty Name
    )

    foreach ($target in Get-GlobalTargetDefinitions) {
        foreach ($existing in Get-ImmediateSkillDirs -Root $target.Root -SkipNames $target.Skip) {
            if ($globalNames -contains $existing.Name) {
                continue
            }
            if (-not (Test-ManagedLink -Path $existing.FullName -ManagedRoots (Get-ManagedCatalogRoots))) {
                continue
            }

            $currentTargets = Get-ManagedTargetsForSkill -State $state -SkillName $existing.Name
            Set-ManagedTargetsForSkill -State $state -SkillName $existing.Name -Targets (@($currentTargets) + @($target.Label))
        }
    }

    return $state
}

function Seed-ManagedTargetsState {
    $state = Get-ManualManagedTargetsFromFilesystem
    Save-ManagedTargetsState -State $state
}

function Set-DesiredTargetsForSkill {
    param(
        [string]$SkillName,
        [string[]]$RequestedTargets
    )

    $managedState = Get-ManagedTargetsState
    $desiredTargets = @($RequestedTargets | Where-Object { $_ } | Sort-Object -Unique)
    $globalNames = @(
        Get-ImmediateSkillDirs -Root $Script:GlobalSkillsRoot |
        Select-Object -ExpandProperty Name
    )
    $isGlobal = $globalNames -contains $SkillName
    $nextManagedTargets = @()

    foreach ($target in Get-GlobalTargetDefinitions) {
        $label = $target.Label
        $targetPath = Join-Path $target.Root $SkillName
        $wantsInstalled = $desiredTargets -contains $label
        $exists = Test-Path -LiteralPath $targetPath
        $isManaged = $false

        if ($exists) {
            $isManaged = Test-ManagedLink -Path $targetPath -ManagedRoots (Get-ManagedCatalogRoots)
        }

        if ($wantsInstalled) {
            if (-not $exists -or $isManaged) {
                $nextManagedTargets += $label
            }
            continue
        }

        if ($exists -and -not $isGlobal) {
            Backup-ExistingPath -Path $targetPath -Label "target-removed-$($label)-$SkillName" | Out-Null
        }
    }

    Set-ManagedTargetsForSkill -State $managedState -SkillName $SkillName -Targets $nextManagedTargets
    Save-ManagedTargetsState -State $managedState
    Reconcile-SharedSkills

    return @($nextManagedTargets | Sort-Object -Unique)
}

function Sync-ManagedTargetState {
    $state = Get-ManagedTargetsState
    $globalNames = @(
        Get-ImmediateSkillDirs -Root $Script:GlobalSkillsRoot |
        Select-Object -ExpandProperty Name
    )

    foreach ($target in Get-GlobalTargetDefinitions) {
        Ensure-Directory -Path $target.Root

        foreach ($entry in $state.skills.GetEnumerator()) {
            $skillName = $entry.Key
            if ($globalNames -contains $skillName) {
                continue
            }

            $targets = @($entry.Value)
            if ($targets -notcontains $target.Label) {
                continue
            }

            $catalogPath = Join-Path $Script:AllSkillsRoot $skillName
            if (-not (Test-Path -LiteralPath $catalogPath)) {
                continue
            }

            $linkPath = Join-Path $target.Root $skillName
            Ensure-Junction -LinkPath $linkPath -TargetPath $catalogPath -BackupLabel "managed-$($target.Label)-$skillName"
        }

        foreach ($existing in Get-ImmediateSkillDirs -Root $target.Root -SkipNames $target.Skip) {
            if ($globalNames -contains $existing.Name) {
                continue
            }

            $expectedTargets = Get-ManagedTargetsForSkill -State $state -SkillName $existing.Name
            if ($expectedTargets -contains $target.Label) {
                continue
            }

            Remove-ManagedLinkIfNeeded -Path $existing.FullName -ManagedRoots (Get-ManagedCatalogRoots) -BackupLabel "managed-stale-$($target.Label)-$($existing.Name)"
        }
    }
}

function Reconcile-SharedSkills {
    Sync-GlobalSkills
    Sync-ManagedTargetState
    Sync-LegacyGeminiSkills
}

function Ensure-GeminiImportBlock {
    param(
        [string]$HostFile,
        [string]$GeneratedFile,
        [string]$BlockName
    )

    $startMarker = "<!-- AI-SKILLS-HUB:$BlockName START -->"
    $endMarker = "<!-- AI-SKILLS-HUB:$BlockName END -->"
    $importLine = "@" + ($GeneratedFile -replace "\\", "/")
    $block = @(
        $startMarker
        $importLine
        $endMarker
    ) -join "`r`n"

    $content = ""
    if (Test-Path -LiteralPath $HostFile) {
        $content = Get-Content -LiteralPath $HostFile -Raw
        if ($null -eq $content) {
            $content = ""
        }
    }
    else {
        $content = "# GEMINI Context`r`n"
    }

    $pattern = [regex]::Escape($startMarker) + "(?s).*?" + [regex]::Escape($endMarker)
    if ($content -match $pattern) {
        $content = [regex]::Replace($content, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $block })
    }
    else {
        $trimmed = $content.TrimEnd()
        if ($trimmed.Length -gt 0) {
            $content = $trimmed + "`r`n`r`n" + $block + "`r`n"
        }
        else {
            $content = $block + "`r`n"
        }
    }

    Write-Utf8File -Path $HostFile -Content $content
}

function Write-GeminiGeneratedFile {
    param(
        [System.IO.DirectoryInfo[]]$SkillDirs,
        [string]$OutputFile,
        [string]$Title
    )

    $sections = @()
    foreach ($skillDir in ($SkillDirs | Sort-Object Name)) {
        $section = Convert-SkillToGeminiSection -SkillDir $skillDir.FullName
        if ($section) {
            $sections += $section
        }
    }

    $lines = @(
        "# $Title"
        ""
        "Generated automatically by AI-Skills-Hub."
        "Edit the source skill in the catalog or in the project's `.agents/skills`."
        "Generated at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        ""
    )

    if ($sections.Count -eq 0) {
        $lines += "No selected skills."
    }
    else {
        $lines += ($sections -join "`r`n`r`n")
    }

    Write-Utf8File -Path $OutputFile -Content ($lines -join "`r`n")
}

function Update-ClaudeDesktopTrustedFolders {
    param([string]$ResolvedProjectPath)

    $configPath = Join-Path $Script:RoamingAppDataRoot "Claude\claude_desktop_config.json"
    if (-not (Test-Path -LiteralPath $configPath)) {
        return
    }

    $raw = Get-Content -LiteralPath $configPath -Raw
    $config = $raw | ConvertFrom-Json

    if ($null -eq $config.preferences) {
        $config | Add-Member -MemberType NoteProperty -Name preferences -Value ([pscustomobject]@{})
    }

    if ($null -eq $config.preferences.localAgentModeTrustedFolders) {
        $config.preferences | Add-Member -MemberType NoteProperty -Name localAgentModeTrustedFolders -Value @()
    }

    $folders = @($config.preferences.localAgentModeTrustedFolders)
    if ($folders -contains $ResolvedProjectPath) {
        return
    }

    $config.preferences.localAgentModeTrustedFolders = @($folders + $ResolvedProjectPath)
    Backup-ExistingPath -Path $configPath -Label "claude-desktop-config" | Out-Null
    Write-JsonFile -Path $configPath -Data $config
}

function Import-ExistingSkills {
    Ensure-Directory -Path $Script:AllSkillsRoot
    Ensure-Directory -Path $Script:StateRoot

    $candidatesBySkill = @{}

    foreach ($catalogDir in Get-ImmediateSkillDirs -Root $Script:AllSkillsRoot) {
        $candidatesBySkill[$catalogDir.Name] = @([pscustomobject]@{
            SkillName = $catalogDir.Name
            SourceLabel = "catalog"
            SourcePath = $catalogDir.FullName
            LastWriteTimeUtc = (Get-TreeLastWriteTimeUtc -Path $catalogDir.FullName)
        })
    }

    foreach ($source in Get-UserSourceDefinitions) {
        foreach ($skillDir in Get-ImmediateSkillDirs -Root $source.Root -SkipNames $source.Skip) {
            if (-not $candidatesBySkill.ContainsKey($skillDir.Name)) {
                $candidatesBySkill[$skillDir.Name] = @()
            }

            $candidatesBySkill[$skillDir.Name] += [pscustomobject]@{
                SkillName = $skillDir.Name
                SourceLabel = $source.Label
                SourcePath = $skillDir.FullName
                LastWriteTimeUtc = (Get-TreeLastWriteTimeUtc -Path $skillDir.FullName)
            }
        }
    }

    $report = @()

    foreach ($skillName in ($candidatesBySkill.Keys | Sort-Object)) {
        $candidates = @($candidatesBySkill[$skillName] | Sort-Object `
            @{ Expression = "LastWriteTimeUtc"; Descending = $true }, `
            @{ Expression = { Get-SourcePriority -Label $_.SourceLabel } })

        $selected = $candidates[0]
        $destination = Join-Path $Script:AllSkillsRoot $skillName

        if ((Normalize-FullPath $selected.SourcePath) -ne (Normalize-FullPath $destination)) {
            Write-Step "Importing $skillName from $($selected.SourceLabel) ($($selected.SourcePath))"
            Copy-SkillTree -SourcePath $selected.SourcePath -DestinationPath $destination -BackupLabel "catalog-$skillName"
        }
        else {
            Write-Step "Keeping catalog version of $skillName"
        }

        $report += [pscustomobject]@{
            skillName = $skillName
            selectedSourceLabel = $selected.SourceLabel
            selectedSourcePath = $selected.SourcePath
            selectedLastWriteTimeUtc = $selected.LastWriteTimeUtc
            sources = @($candidates | ForEach-Object {
                [pscustomobject]@{
                    label = $_.SourceLabel
                    path = $_.SourcePath
                    lastWriteTimeUtc = $_.LastWriteTimeUtc
                }
            })
        }
    }

    Write-JsonFile -Path $Script:ImportReportJson -Data ([pscustomobject]@{
        generatedAt = (Get-Date).ToString("o")
        hubRoot = $Script:HubRoot
        skills = $report
    })

    $mdLines = @(
        "# Import Report",
        "",
        "Generated at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        ""
    )
    foreach ($entry in $report) {
        $mdLines += "## $($entry.skillName)"
        $mdLines += ""
        $mdLines += ('- Selected: {0} -> {1}' -f $entry.selectedSourceLabel, $entry.selectedSourcePath)
        $mdLines += ('- Last write (UTC): {0}' -f $entry.selectedLastWriteTimeUtc)
        foreach ($source in $entry.sources) {
            $mdLines += ('- Candidate: {0} -> {1} ({2})' -f $source.label, $source.path, $source.lastWriteTimeUtc)
        }
        $mdLines += ""
    }
    Write-Utf8File -Path $Script:ImportReportMd -Content ($mdLines -join "`r`n")
}

function Enable-GlobalSkills {
    param([string[]]$SkillNames)

    Ensure-Directory -Path $Script:GlobalSkillsRoot

    foreach ($skillName in ($SkillNames | Where-Object { $_ } | Sort-Object -Unique)) {
        $catalogPath = Join-Path $Script:AllSkillsRoot $skillName
        if (-not (Test-Path -LiteralPath $catalogPath)) {
            throw "Skill '$skillName' was not found in $Script:AllSkillsRoot"
        }

        $linkPath = Join-Path $Script:GlobalSkillsRoot $skillName
        Ensure-Junction -LinkPath $linkPath -TargetPath $catalogPath -BackupLabel "global-selection-$skillName"
    }
}

function Disable-GlobalSkills {
    param([string[]]$SkillNames)

    foreach ($skillName in ($SkillNames | Where-Object { $_ } | Sort-Object -Unique)) {
        $linkPath = Join-Path $Script:GlobalSkillsRoot $skillName
        if (Test-ManagedLink -Path $linkPath -ManagedRoots (Get-ManagedCatalogRoots)) {
            Backup-ExistingPath -Path $linkPath -Label "global-selection-removed-$skillName" | Out-Null
        }
    }
}

function Sync-GlobalSkills {
    $selectedSkillDirs = Get-ImmediateSkillDirs -Root $Script:GlobalSkillsRoot
    $selectedNames = @($selectedSkillDirs | Select-Object -ExpandProperty Name)

    foreach ($target in Get-GlobalTargetDefinitions) {
        Ensure-Directory -Path $target.Root

        foreach ($skillDir in $selectedSkillDirs) {
            $catalogPath = Join-Path $Script:AllSkillsRoot $skillDir.Name
            $linkPath = Join-Path $target.Root $skillDir.Name
            Ensure-Junction -LinkPath $linkPath -TargetPath $catalogPath -BackupLabel "global-$($target.Label)-$($skillDir.Name)"
        }

        foreach ($existing in Get-ImmediateSkillDirs -Root $target.Root -SkipNames $target.Skip) {
            if ($selectedNames -contains $existing.Name) {
                continue
            }
            Remove-ManagedLinkIfNeeded -Path $existing.FullName -ManagedRoots (Get-ManagedCatalogRoots) -BackupLabel "global-stale-$($target.Label)-$($existing.Name)"
        }
    }

    Ensure-Directory -Path $Script:GeminiRoot
    Write-GeminiGeneratedFile -SkillDirs $selectedSkillDirs -OutputFile $Script:GlobalGeminiGenerated -Title "Global Gemini Context"
    Ensure-GeminiImportBlock -HostFile (Join-Path $Script:GeminiRoot "GEMINI.md") -GeneratedFile $Script:GlobalGeminiGenerated -BlockName "GLOBAL"
}

function Sync-LegacyGeminiSkills {
    $managedRoots = @(
        $Script:HubRoot
        (Join-UserProfilePath ".agents\skills")
    )

    Ensure-Directory -Path $Script:GeminiLegacySkillsRoot

    foreach ($skillName in $Script:LegacyGeminiSkillNames) {
        $catalogPath = Join-Path $Script:AllSkillsRoot $skillName
        if (-not (Test-Path -LiteralPath $catalogPath)) {
            continue
        }

        $linkPath = Join-Path $Script:GeminiLegacySkillsRoot $skillName
        Ensure-Junction -LinkPath $linkPath -TargetPath $catalogPath -BackupLabel "gemini-legacy-$skillName"
    }

    foreach ($existing in Get-ImmediateSkillDirs -Root $Script:GeminiLegacySkillsRoot -SkipNames @(".stfolder")) {
        if ($Script:LegacyGeminiSkillNames -contains $existing.Name) {
            continue
        }

        Remove-ManagedLinkIfNeeded -Path $existing.FullName -ManagedRoots $managedRoots -BackupLabel "gemini-legacy-stale-$($existing.Name)"
    }
}

function Add-ProjectSkills {
    param(
        [string]$ResolvedProjectPath,
        [string[]]$SkillNames
    )

    $projectAgentsRoot = Join-Path $ResolvedProjectPath ".agents\skills"
    Ensure-Directory -Path $projectAgentsRoot

    foreach ($skillName in ($SkillNames | Where-Object { $_ } | Sort-Object -Unique)) {
        $catalogPath = Join-Path $Script:AllSkillsRoot $skillName
        if (-not (Test-Path -LiteralPath $catalogPath)) {
            throw "Skill '$skillName' was not found in $Script:AllSkillsRoot"
        }

        $linkPath = Join-Path $projectAgentsRoot $skillName
        Ensure-Junction -LinkPath $linkPath -TargetPath $catalogPath -BackupLabel "project-selection-$skillName"
    }

    Update-ClaudeDesktopTrustedFolders -ResolvedProjectPath $ResolvedProjectPath
    Sync-ProjectSkills -ResolvedProjectPath $ResolvedProjectPath
}

function Remove-ProjectSkills {
    param(
        [string]$ResolvedProjectPath,
        [string[]]$SkillNames
    )

    $projectAgentsRoot = Join-Path $ResolvedProjectPath ".agents\skills"
    foreach ($skillName in ($SkillNames | Where-Object { $_ } | Sort-Object -Unique)) {
        $linkPath = Join-Path $projectAgentsRoot $skillName
        if (Test-Path -LiteralPath $linkPath) {
            Backup-ExistingPath -Path $linkPath -Label "project-selection-removed-$skillName" | Out-Null
        }
    }

    Sync-ProjectSkills -ResolvedProjectPath $ResolvedProjectPath
}

function Sync-ProjectSkills {
    param([string]$ResolvedProjectPath)

    $projectAgentsRoot = Join-Path $ResolvedProjectPath ".agents\skills"
    Ensure-Directory -Path $projectAgentsRoot

    $selectedSkillDirs = Get-ImmediateSkillDirs -Root $projectAgentsRoot
    $selectedNames = @($selectedSkillDirs | Select-Object -ExpandProperty Name)

    foreach ($target in Get-ProjectTargetDefinitions -ResolvedProjectPath $ResolvedProjectPath) {
        Ensure-Directory -Path $target.Root

        foreach ($skillDir in $selectedSkillDirs) {
            $linkPath = Join-Path $target.Root $skillDir.Name
            Ensure-Junction -LinkPath $linkPath -TargetPath $skillDir.FullName -BackupLabel "project-$($target.Label)-$($skillDir.Name)"
        }

        foreach ($existing in Get-ImmediateSkillDirs -Root $target.Root -SkipNames $target.Skip) {
            if ($selectedNames -contains $existing.Name) {
                continue
            }
            Remove-ManagedLinkIfNeeded -Path $existing.FullName -ManagedRoots (Get-ProjectManagedRoots -ProjectAgentsRoot $projectAgentsRoot) -BackupLabel "project-stale-$($target.Label)-$($existing.Name)"
        }
    }

    $projectAgentsMetaRoot = Join-Path $ResolvedProjectPath ".agents"
    Ensure-Directory -Path $projectAgentsMetaRoot

    $generatedGemini = Join-Path $projectAgentsMetaRoot "gemini.generated.md"
    Write-GeminiGeneratedFile -SkillDirs $selectedSkillDirs -OutputFile $generatedGemini -Title "Project Gemini Context"
    Ensure-GeminiImportBlock -HostFile (Join-Path $ResolvedProjectPath "GEMINI.md") -GeneratedFile $generatedGemini -BlockName "PROJECT"

    Update-ClaudeDesktopTrustedFolders -ResolvedProjectPath $ResolvedProjectPath
}

function Show-Status {
    param([string]$ResolvedProjectPath)

    Write-Step "Hub root: $Script:HubRoot"
    Write-Step "Catalog skills:"
    Get-ImmediateSkillDirs -Root $Script:AllSkillsRoot | Sort-Object Name | ForEach-Object {
        Write-Host "  - $($_.Name)"
    }

    Write-Step "Global selected skills:"
    Get-ImmediateSkillDirs -Root $Script:GlobalSkillsRoot | Sort-Object Name | ForEach-Object {
        Write-Host "  - $($_.Name)"
    }

    if ($ResolvedProjectPath) {
        $projectAgentsRoot = Join-Path $ResolvedProjectPath ".agents\skills"
        Write-Step "Project selected skills: $ResolvedProjectPath"
        Get-ImmediateSkillDirs -Root $projectAgentsRoot | Sort-Object Name | ForEach-Object {
            Write-Host "  - $($_.Name)"
        }
    }

    $superpowers = Get-SuperpowersNativeStatus
    Write-Step "Native integrations:"
    Write-Host "  - superpowers repo: $($superpowers.repoPresent) [$($superpowers.checkoutPath)]"
    Write-Host "  - superpowers Claude marketplace: $($superpowers.claude.marketplaceAvailable) | installed: $($superpowers.claude.installed)"
    Write-Host "  - superpowers Codex synced (user): $((@($superpowers.codex.userSynced) -join ', '))"
    Write-Host "  - superpowers Codex synced (legacy): $((@($superpowers.codex.legacySynced) -join ', '))"
    Write-Host "  - superpowers Gemini manifest: $($superpowers.gemini.manifestPresent) | installed: $($superpowers.gemini.installed)"

    $claudeAuth = Get-ClaudeAuthStatus
    Write-Step "Claude auth profiles:"
    foreach ($profile in @($claudeAuth.profiles) | Sort-Object name) {
        Write-Host "  - $($profile.name): state=$($profile.state) loggedIn=$($profile.loggedIn) leaseOwner=$($profile.leaseOwner) leaseExpiresAt=$($profile.leaseExpiresAt) cooldownUntil=$($profile.cooldownUntil)"
    }
}

function Show-Help {
    @"
AI-Skills-Hub

Commands:
  help
  import-existing
  list-all
  seed-global
  seed-managed-state
  enable-global -Skills skill1,skill2
  disable-global -Skills skill1,skill2
  sync-global
  reconcile
  sync-native-superpowers [-Install] [-Force]
  sync-claude-usage-collector [-Skills claude-a,claude-b,...,claude-j] [-Force]
  add-claude-profile
  add-project-skills -ProjectPath C:\repo -Skills skill1,skill2
  remove-project-skills -ProjectPath C:\repo -Skills skill1,skill2
  sync-project -ProjectPath C:\repo
  status [-ProjectPath C:\repo]

Notes:
  - Edit global source skills only in: $Script:AllSkillsRoot
  - Global active set lives in:      $Script:GlobalSkillsRoot
  - Project source skills live in:   <project>\.agents\skills
  - Use sync-native-superpowers para pacotes multi-skill ou extensoes nativas como superpowers.
  - Use -DryRun to preview actions.
"@ | Write-Host
}

Ensure-Directory -Path $Script:AllSkillsRoot
Ensure-Directory -Path $Script:GlobalSkillsRoot
Ensure-Directory -Path $Script:BackupsRoot
Ensure-Directory -Path $Script:StateRoot
Ensure-Directory -Path $Script:NativeIntegrationsRoot
Ensure-Directory -Path $Script:ClaudeOrchestratorRoot
Ensure-Directory -Path $Script:ClaudeAuthStateRoot

$resolvedProjectPath = $null
if ($ProjectPath) {
    $resolvedProjectPath = Normalize-FullPath $ProjectPath
}

function Start-SkillManagerUI {
    $port = 8765
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$port/")
    $listener.Start()

    Write-Host "AI Skills Hub Manager rodando em http://localhost:$port/"
    Write-Host "Pressione Ctrl+C para parar."
    Write-Step "Runtime user profile root: $Script:UserProfileRoot"
    Write-Step "Runtime appdata root: $Script:RoamingAppDataRoot"

    Start-Process "http://localhost:$port/"

    try {
        while ($listener.IsListening) {
            $context = $listener.GetContext()
            $request = $context.Request
            $response = $context.Response

            $method = $request.HttpMethod
            $url = $request.Url.LocalPath

            try {
                Set-NoCacheHeaders -Response $response

                if ($method -eq "GET" -and $url -eq "/") {
                    $htmlPath = Join-Path $Script:HubRoot "ui\index.html"
                    if (Test-Path $htmlPath) {
                        $content = Get-Content $htmlPath -Raw
                        $buffer = [System.Text.Encoding]::UTF8.GetBytes($content)
                        $response.ContentType = "text/html; charset=utf-8"
                        $response.ContentLength64 = $buffer.Length
                        $response.OutputStream.Write($buffer, 0, $buffer.Length)
                    } else {
                        $response.StatusCode = 404
                    }
                }
                elseif ($method -eq "GET" -and $url -eq "/api/status") {
                    $globalDefs = Get-GlobalTargetDefinitions
                    $allSkills = Get-ImmediateSkillDirs -Root $Script:AllSkillsRoot
                    $globalSkills = Get-ImmediateSkillDirs -Root $Script:GlobalSkillsRoot
                    $globalNames = $globalSkills | Select-Object -ExpandProperty Name

                    $skills = @()
                    foreach ($dir in $allSkills) {
                        $name = $dir.Name
                        $isGlobal = $globalNames -contains $name

                        $installed = @{}
                        $isNative = @{}
                        $broken = $false

                        foreach ($tgt in $globalDefs) {
                            $targetPath = Join-Path $tgt["Root"] $name
                            if (Test-Path -LiteralPath $targetPath) {
                                $installed[$tgt["Label"]] = $true
                                # Verifica se e junction gerenciada
                                $isManaged = Test-ManagedLink -Path $targetPath -ManagedRoots (Get-ManagedCatalogRoots)
                                $isNative[$tgt["Label"]] = -not $isManaged
                                # Detecta junction quebrada: link existe mas alvo nao resolve
                                try {
                                    $item = Get-Item -LiteralPath $targetPath -Force -ErrorAction Stop
                                    if ($item.LinkType -and $item.Target) {
                                        $linkTarget = if ($item.Target -is [array]) { $item.Target[0] } else { $item.Target }
                                        $resolved = Normalize-FullPath $linkTarget
                                        if (-not (Test-Path -LiteralPath $resolved)) {
                                            $broken = $true
                                        }
                                    }
                                } catch {}
                            } else {
                                $installed[$tgt["Label"]] = $false
                                $isNative[$tgt["Label"]] = $false
                            }
                        }

                        $frontmatter = Get-SkillFrontmatter -SkillDir $dir.FullName

                        $skills += @{
                            name = $name
                            description = if ($frontmatter) { $frontmatter.Description } else { "" }
                            isGlobal = $isGlobal
                            installed = $installed
                            isNative = $isNative
                            broken = $broken
                        }
                    }

                    $resData = @{
                        skills = $skills
                        targets = @($globalDefs | ForEach-Object { $_["Label"] })
                        runtime = Get-RuntimeInfo
                        nativeIntegrations = @{
                            superpowers = Get-SuperpowersNativeStatus
                        }
                    }

                    $json = $resData | ConvertTo-Json -Depth 5 -Compress
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "POST" -and $url -eq "/api/toggle-global") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                    $bodyStr = $reader.ReadToEnd()
                    $body = $bodyStr | ConvertFrom-Json
                    Write-Step "API toggle-global skill=$($body.skill) enable=$($body.enable)"

                    $managedState = Get-ManagedTargetsState
                    if ($body.enable -and $managedState.skills.Contains($body.skill)) {
                        $managedState.skills.Remove($body.skill)
                        Save-ManagedTargetsState -State $managedState
                    }

                    if ($body.enable) {
                        Enable-GlobalSkills -SkillNames @($body.skill)
                    } else {
                        Disable-GlobalSkills -SkillNames @($body.skill)
                    }
                    Reconcile-SharedSkills

                    $buffer = [System.Text.Encoding]::UTF8.GetBytes('{"success":true}')
                    $response.ContentType = "application/json"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "POST" -and $url -eq "/api/install") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                    $bodyStr = $reader.ReadToEnd()
                    $body = $bodyStr | ConvertFrom-Json
                    $requestedTargets = ConvertTo-StringArray -Value $body.targets
                    Write-Step "API install skill=$($body.skill) targets=$($requestedTargets -join ',')"

                    $managedState = Get-ManagedTargetsState
                    $currentTargets = Get-ManagedTargetsForSkill -State $managedState -SkillName $body.skill
                    Set-ManagedTargetsForSkill -State $managedState -SkillName $body.skill -Targets (@($currentTargets) + @($requestedTargets))
                    Save-ManagedTargetsState -State $managedState
                    Reconcile-SharedSkills

                    $buffer = [System.Text.Encoding]::UTF8.GetBytes('{"success":true}')
                    $response.ContentType = "application/json"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "POST" -and $url -eq "/api/uninstall") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                    $bodyStr = $reader.ReadToEnd()
                    $body = $bodyStr | ConvertFrom-Json
                    $requestedTargets = ConvertTo-StringArray -Value $body.targets

                    $managedState = Get-ManagedTargetsState
                    $currentTargets = Get-ManagedTargetsForSkill -State $managedState -SkillName $body.skill
                    $remainingTargets = @($currentTargets | Where-Object { @($requestedTargets) -notcontains $_ })
                    Write-Step "API uninstall skill=$($body.skill) current=$($currentTargets -join ',') remove=$($requestedTargets -join ',') remaining=$($remainingTargets -join ',')"
                    Set-ManagedTargetsForSkill -State $managedState -SkillName $body.skill -Targets $remainingTargets
                    Save-ManagedTargetsState -State $managedState
                    Reconcile-SharedSkills

                    $buffer = [System.Text.Encoding]::UTF8.GetBytes('{"success":true}')
                    $response.ContentType = "application/json"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "POST" -and $url -eq "/api/set-managed-targets") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                    $bodyStr = $reader.ReadToEnd()
                    $body = $bodyStr | ConvertFrom-Json
                    $requestedTargets = ConvertTo-StringArray -Value $body.targets
                    Write-Step "API set-managed-targets skill=$($body.skill) targets=$($requestedTargets -join ',')"

                    $effectiveManagedTargets = Set-DesiredTargetsForSkill -SkillName $body.skill -RequestedTargets $requestedTargets

                    $resData = @{
                        success = $true
                        skill = $body.skill
                        targets = @($effectiveManagedTargets)
                    }
                    $json = $resData | ConvertTo-Json -Compress
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "POST" -and $url -eq "/api/project-install") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                    $bodyStr = $reader.ReadToEnd()
                    $body = $bodyStr | ConvertFrom-Json

                    $projectPath = [string]$body.projectPath
                    $skillNames = ConvertTo-StringArray -Value $body.skills

                    if (-not $projectPath.Trim()) {
                        throw "Informe o caminho do projeto."
                    }
                    if ($skillNames.Count -eq 0) {
                        throw "Selecione ao menos uma skill."
                    }

                    $resolvedProjectPath = Normalize-FullPath $projectPath
                    if (-not (Test-Path -LiteralPath $resolvedProjectPath)) {
                        throw "Projeto nao encontrado: $resolvedProjectPath"
                    }

                    Write-Step "API project-install path=$resolvedProjectPath skills=$($skillNames -join ',')"
                    Add-ProjectSkills -ResolvedProjectPath $resolvedProjectPath -SkillNames $skillNames

                    $resData = @{
                        success = $true
                        projectPath = $resolvedProjectPath
                        skills = @($skillNames)
                    }
                    $json = $resData | ConvertTo-Json -Compress
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "POST" -and $url -eq "/api/github-import") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                    $bodyStr = $reader.ReadToEnd()
                    $body = $bodyStr | ConvertFrom-Json

                    if ($body.url -match "github\.com/([^/]+)/([^/.]+)") {
                        $repoName = $Matches[2]
                        if ($repoName.EndsWith(".git")) {
                            $repoName = $repoName.Substring(0, $repoName.Length - 4)
                        }

                        # Task 10: route known upstream catalogs through the importer
                        # which understands the per-source folder layout. Generic
                        # URLs continue to use the legacy "clone whole repo as a
                        # single skill" path for back-compat.
                        $detectedSource = 'generic'
                        if (Get-Command -Name Resolve-UpstreamSource -ErrorAction SilentlyContinue) {
                            $detectedSource = Resolve-UpstreamSource -Url $body.url
                        }

                        if ($detectedSource -ne 'generic' -and (Get-Command -Name Import-FromUpstream -ErrorAction SilentlyContinue)) {
                            $skillNameArg = if ($body.PSObject.Properties['skillName'] -and $body.skillName) { [string]$body.skillName } else { $repoName }
                            $importResult = Import-FromUpstream -Url $body.url `
                                                                -SkillName $skillNameArg `
                                                                -AllSkillsRoot $Script:AllSkillsRoot

                            $frontmatter = Get-SkillFrontmatter -SkillDir $importResult.target
                            $desc = if ($frontmatter) { $frontmatter.Description } else { "" }

                            $resData = @{
                                success     = $true
                                name        = $importResult.skillName
                                description = $desc
                                source      = $importResult.source
                                commit      = $importResult.commit
                            }
                        }
                        else {
                            $destPath = Join-Path $Script:AllSkillsRoot $repoName

                            if (Test-Path -LiteralPath $destPath) {
                                throw "A skill '$repoName' ja existe no catalogo."
                            }

                            $gitArgs = @("clone", "--depth", "1", $body.url, $destPath)
                            & git $gitArgs | Out-Null
                            if ($LASTEXITCODE -ne 0) {
                                throw "Erro ao clonar o repositorio."
                            }

                            $frontmatter = Get-SkillFrontmatter -SkillDir $destPath
                            $validation = Get-RepoImportValidation -RepoPath $destPath -RepoName $repoName
                            if (-not $validation.IsValid) {
                                Backup-ExistingPath -Path $destPath -Label "invalid-import-$repoName" | Out-Null
                                throw $validation.Reason
                            }

                            $desc = if ($frontmatter) { $frontmatter.Description } else { "" }
                            $resData = @{ success = $true; name = $repoName; description = $desc; source = 'generic' }
                        }

                        $json = $resData | ConvertTo-Json -Compress
                        $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                        $response.ContentType = "application/json"
                        $response.ContentLength64 = $buffer.Length
                        $response.OutputStream.Write($buffer, 0, $buffer.Length)
                    } else {
                        throw "URL invalida. Use https://github.com/..."
                    }
                }
                elseif ($method -eq "GET" -and $url -match "^/api/skill-detail/(.*)$") {
                    $skillName = [System.Uri]::UnescapeDataString($Matches[1])
                    $skillDir = Join-Path $Script:AllSkillsRoot $skillName
                    $skillMd = Join-Path $skillDir "SKILL.md"

                    $content = ""
                    if (Test-Path -LiteralPath $skillMd) {
                        $content = Get-Content -LiteralPath $skillMd -Raw
                    } else {
                        $content = "Skill $skillName não encontrada no catálogo (SKILL.md faltando)."
                    }

                    $resData = @{ content = $content }
                    $json = $resData | ConvertTo-Json -Compress
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                else {
                    $response.StatusCode = 404
                }
            } catch {
                $handlerError = $_
                Write-Host "  [skill-ui] erro no handler: $($handlerError.Exception.Message)" -ForegroundColor Yellow
                try {
                    $response.StatusCode = 500
                    $err = @{ error = $handlerError.Exception.Message } | ConvertTo-Json -Compress
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($err)
                    $response.ContentType = "application/json"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                } catch {
                    try { $response.Abort() } catch {}
                }
            } finally {
                try { $response.Close() } catch {}
            }
        }
    } catch {
        Write-Host "Servidor parado: $_" -ForegroundColor Yellow
    } finally {
        try { $listener.Stop() } catch {}
    }
}

function Start-ClaudeAuthUI {
    $port = 8766
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$port/")
    $listener.Start()

    # Garantir perfil Codex padrao na inicializacao
    try { Ensure-CodexDefaultProfile } catch { Write-Host "Aviso: nao foi possivel garantir perfil Codex padrao: $_" }

    Write-Host "Claude Auth UI rodando em http://localhost:$port/"
    Write-Host "Pressione Ctrl+C para parar."
    Write-Step "Runtime user profile root: $Script:UserProfileRoot"
    Write-Step "Runtime appdata root: $Script:RoamingAppDataRoot"

    Start-Process "http://localhost:$port/"

    try {
        while ($listener.IsListening) {
            $context = $listener.GetContext()
            $request = $context.Request
            $response = $context.Response

            $method = $request.HttpMethod
            $url = $request.Url.LocalPath

            try {
                Set-NoCacheHeaders -Response $response

                if ($method -eq "GET" -and $url -eq "/") {
                    $htmlPath = Join-Path $Script:HubRoot "ui\claude-auth.html"
                    if (Test-Path $htmlPath) {
                        $content = Get-Content $htmlPath -Raw
                        $buffer = [System.Text.Encoding]::UTF8.GetBytes($content)
                        $response.ContentType = "text/html; charset=utf-8"
                        $response.ContentLength64 = $buffer.Length
                        $response.OutputStream.Write($buffer, 0, $buffer.Length)
                    } else {
                        $response.StatusCode = 404
                    }
                }
                elseif ($method -eq "POST" -and $url -eq "/api/claude-auth/set-active") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                    $bodyStr = $reader.ReadToEnd()
                    $body = $bodyStr | ConvertFrom-Json
                    $profileName = [string]$body.profile
                    $profileDefs = Get-ClaudeProfileDefinitions
                    $profileDef = $profileDefs | Where-Object { $_.name -eq $profileName } | Select-Object -First 1
                    if (-not $profileDef) {
                        throw "Perfil nao encontrado: $profileName"
                    }
                    # Usar junction 'active' para hot-swap sem alterar CLAUDE_CONFIG_DIR
                    Set-ClaudeProfileJunction -ProfileName $profileName

                    # Hook: sincronizar o novo profile ativo com a VPS
                    $vpsSyncResult = $null
                    try {
                        $vpsSyncResult = Invoke-VpsAuthSyncForProfile -ProfileName $profileName
                    } catch {
                        $vpsSyncResult = [ordered]@{
                            status    = "error"
                            reason    = "invocation_exception"
                            stderr    = $_.Exception.Message
                            lastRunAt = (Get-Date).ToUniversalTime().ToString("o")
                        }
                    }

                    $respObj = [ordered]@{
                        success = $true
                        vpsSync = $vpsSyncResult
                    }
                    $json = $respObj | ConvertTo-Json -Depth 6 -Compress
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "POST" -and $url -eq "/api/claude-auth/sync-vps") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                    $bodyStr = $reader.ReadToEnd()
                    $body = if ($bodyStr.Trim()) { $bodyStr | ConvertFrom-Json } else { $null }
                    $profileName = $null
                    if ($body -and $body.PSObject.Properties['profile']) {
                        $candidate = [string]$body.profile
                        if ($candidate.Trim()) { $profileName = $candidate.Trim() }
                    }
                    if (-not $profileName) {
                        $profileName = Get-ActiveClaudeProfileName
                    }
                    if (-not $profileName) {
                        throw "Nenhum profile informado e nao ha profile ativo."
                    }
                    $resData = Invoke-VpsAuthSyncForProfile -ProfileName $profileName
                    $json = $resData | ConvertTo-Json -Depth 6 -Compress
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "GET" -and $url -eq "/api/claude-auth/vps-sync-status") {
                    $resData = Get-VpsAuthSyncStatus
                    $activeProfile = Get-ActiveClaudeProfileName
                    $wrapper = [ordered]@{
                        activeProfile = $activeProfile
                        profiles      = $resData
                    }
                    $json = $wrapper | ConvertTo-Json -Depth 6 -Compress
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "GET" -and $url -eq "/api/claude-auth/status") {
                    $resData = Get-ClaudeAuthStatus
                    $json = $resData | ConvertTo-Json -Depth 10 -Compress
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "GET" -and $url -eq "/api/runtime/instances") {
                    $resData = Get-RunningInstances
                    $json = $resData | ConvertTo-Json -Depth 6 -Compress
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "POST" -and $url -eq "/api/claude-auth/install-collector") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                    $bodyStr = $reader.ReadToEnd()
                    $body = if ($bodyStr.Trim()) { $bodyStr | ConvertFrom-Json } else { $null }
                    $profileNames = @()
                    if ($body -and $body.profile) {
                        $profileNames = @([string]$body.profile)
                    }
                    $forceCollector = $false
                    if ($body -and $body.force) {
                        $forceCollector = [bool]$body.force
                    }

                    $resData = Sync-ClaudeUsageCollector -ProfileNames $profileNames -Force:$forceCollector
                    $json = $resData | ConvertTo-Json -Depth 8 -Compress
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "POST" -and $url -eq "/api/claude-auth/add-profile") {
                    $resData = Add-ClaudeProfile
                    $json = $resData | ConvertTo-Json -Depth 6 -Compress
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "POST" -and $url -eq "/api/claude-auth/login") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                    $bodyStr = $reader.ReadToEnd()
                    $body = $bodyStr | ConvertFrom-Json
                    $profile = [string]$body.profile
                    $emailProp = $body.PSObject.Properties['email']
                    $email = if ($emailProp) { [string]$emailProp.Value } else { "" }

                    if (-not $profile.Trim()) {
                        throw "Informe o perfil Claude."
                    }

                    $resData = New-ClaudeAuthLoginSession -ProfileName $profile -Email $email
                    $json = $resData | ConvertTo-Json -Depth 6 -Compress
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "GET" -and $url -match "^/api/claude-auth/session/([A-Fa-f0-9-]+)$") {
                    $sessionId = $Matches[1]
                    $resData = Get-ClaudeAuthLoginSession -SessionId $sessionId
                    $json = $resData | ConvertTo-Json -Depth 6 -Compress
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "POST" -and $url -match "^/api/claude-auth/session/([A-Fa-f0-9-]+)/submit-code$") {
                    $sessionId = $Matches[1]
                    $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                    $bodyStr = $reader.ReadToEnd()
                    $body = $bodyStr | ConvertFrom-Json
                    $codeProp = $body.PSObject.Properties['code']
                    $code = if ($codeProp) { [string]$codeProp.Value } else { "" }
                    $resData = Submit-ClaudeAuthLoginCode -SessionId $sessionId -Code $code
                    $json = $resData | ConvertTo-Json -Depth 8 -Compress
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "POST" -and $url -eq "/api/force-rotate") {
                    Write-Step "API force-rotate"
                    $rotateScript = Join-Path $Script:HubRoot "auto-rotate.ps1"
                    $lines = @()
                    try {
                        $lines = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $rotateScript -Force 2>&1 |
                            ForEach-Object { $_.ToString() }
                        $success = $true
                    } catch {
                        $lines = @("Erro ao executar auto-rotate.ps1: $_")
                        $success = $false
                    }
                    $result = @{ success = $success; output = ($lines -join "`n") }
                    $json = $result | ConvertTo-Json -Depth 3 -Compress
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "GET" -and $url -eq "/api/codex-auth/profiles") {
                    $profiles = @(Get-CodexProfiles)
                    $activeProfile = $profiles | Where-Object { $_.isActive } | Select-Object -First 1
                    $resData = [ordered]@{
                        activeProfile = if ($activeProfile) { $activeProfile.name } else { "" }
                        profiles      = $profiles
                    }
                    $json = $resData | ConvertTo-Json -Depth 5 -Compress
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "POST" -and $url -eq "/api/codex-auth/set-active") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                    $bodyStr = $reader.ReadToEnd()
                    $body = $bodyStr | ConvertFrom-Json
                    $profileName = [string]$body.name
                    if (-not $profileName.Trim()) { throw "Informe o nome do perfil Codex." }
                    Set-CodexProfileJunction -ProfileName $profileName

                    # Hook: sincronizar VPS com o novo profile Codex ativo
                    $vpsSyncResult = $null
                    try {
                        $vpsSyncResult = Invoke-VpsAuthSyncForActiveClaude
                    } catch {
                        $vpsSyncResult = [ordered]@{
                            status    = "error"
                            reason    = "invocation_exception"
                            stderr    = $_.Exception.Message
                            lastRunAt = (Get-Date).ToUniversalTime().ToString("o")
                        }
                    }

                    $respObj = [ordered]@{
                        success = $true
                        vpsSync = $vpsSyncResult
                    }
                    $json = $respObj | ConvertTo-Json -Depth 6 -Compress
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "POST" -and $url -eq "/api/codex-auth/add-profile") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                    $bodyStr = $reader.ReadToEnd()
                    $body = $bodyStr | ConvertFrom-Json
                    $profileName = [string]$body.name
                    if (-not $profileName.Trim()) { throw "Informe o nome do novo perfil Codex." }
                    $resData = Add-CodexProfile -Name $profileName
                    $json = $resData | ConvertTo-Json -Depth 4 -Compress
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "DELETE" -and $url -eq "/api/codex-auth/remove-profile") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                    $bodyStr = $reader.ReadToEnd()
                    $body = $bodyStr | ConvertFrom-Json
                    $profileName = [string]$body.name
                    if (-not $profileName.Trim()) { throw "Informe o nome do perfil Codex a remover." }
                    $resData = Remove-CodexProfile -Name $profileName
                    $json = $resData | ConvertTo-Json -Depth 4 -Compress
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "DELETE" -and $url -eq "/api/claude-auth/remove-profile") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                    $bodyStr = $reader.ReadToEnd()
                    $body = $bodyStr | ConvertFrom-Json
                    $profileName = [string]$body.name
                    if (-not $profileName.Trim()) { throw "Informe o nome do perfil Claude a remover." }
                    $resData = Remove-ClaudeProfile -Name $profileName
                    $json = $resData | ConvertTo-Json -Depth 4 -Compress
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "POST" -and $url -eq "/api/codex-auth/sync-vps") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                    $bodyStr = $reader.ReadToEnd()
                    $body = if ($bodyStr.Trim()) { $bodyStr | ConvertFrom-Json } else { $null }
                    $profileName = $null
                    if ($body -and $body.PSObject.Properties['profile']) {
                        $candidate = [string]$body.profile
                        if ($candidate.Trim()) { $profileName = $candidate.Trim() }
                    } elseif ($body -and $body.PSObject.Properties['name']) {
                        $candidate = [string]$body.name
                        if ($candidate.Trim()) { $profileName = $candidate.Trim() }
                    }
                    $resData = if ($profileName) {
                        Invoke-VpsAuthSyncForCodex -ProfileName $profileName
                    } else {
                        Invoke-VpsAuthSyncForCodex
                    }
                    $json = $resData | ConvertTo-Json -Depth 6 -Compress
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "POST" -and $url -eq "/api/codex-auth/login") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                    $bodyStr = $reader.ReadToEnd()
                    $body = $bodyStr | ConvertFrom-Json
                    $profileName = [string]$body.name
                    if (-not $profileName.Trim()) { throw "Informe o nome do perfil Codex." }
                    $resData = Start-CodexAuthLogin -ProfileName $profileName
                    $json = $resData | ConvertTo-Json -Depth 5 -Compress
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "GET" -and $url -match '^/api/codex-auth/sessions/([^/]+)$') {
                    $sessionId = [System.Uri]::UnescapeDataString($Matches[1])
                    $resData = Get-CodexAuthLoginSession -SessionId $sessionId
                    $json = $resData | ConvertTo-Json -Depth 5 -Compress
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "GET" -and $url -eq "/api/gemini-auth/profiles") {
                    $gemProfiles = @(Get-GeminiProfiles)
                    $activeGem = $gemProfiles | Where-Object { $_.isActive } | Select-Object -First 1
                    $resData = [ordered]@{
                        active   = if ($activeGem) { $activeGem.name } else { $null }
                        profiles = $gemProfiles
                    }
                    $json = $resData | ConvertTo-Json -Depth 5 -Compress
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "POST" -and $url -eq "/api/gemini-auth/add-profile") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                    $bodyStr = $reader.ReadToEnd()
                    $body = $bodyStr | ConvertFrom-Json
                    $profileName = [string]$body.name
                    if (-not $profileName.Trim()) { throw "Informe o nome do novo perfil Gemini." }
                    $resData = Add-GeminiProfile -Name $profileName
                    $json = $resData | ConvertTo-Json -Depth 4 -Compress
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "DELETE" -and $url -eq "/api/gemini-auth/remove-profile") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                    $bodyStr = $reader.ReadToEnd()
                    $body = $bodyStr | ConvertFrom-Json
                    $profileName = [string]$body.name
                    if (-not $profileName.Trim()) { throw "Informe o nome do perfil Gemini a remover." }
                    $resData = Remove-GeminiProfile -Name $profileName
                    $json = $resData | ConvertTo-Json -Depth 4 -Compress
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "POST" -and $url -eq "/api/gemini-auth/login") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                    $bodyStr = $reader.ReadToEnd()
                    $body = $bodyStr | ConvertFrom-Json
                    $profileName = [string]$body.name
                    if (-not $profileName.Trim()) { throw "Informe o nome do perfil Gemini." }
                    $resData = Start-GeminiAuthLogin -ProfileName $profileName
                    $json = $resData | ConvertTo-Json -Depth 5 -Compress
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "POST" -and $url -eq "/api/gemini-auth/set-active") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                    $bodyStr = $reader.ReadToEnd()
                    $body = $bodyStr | ConvertFrom-Json
                    # Accept either {profile} (spec) or {name} (Codex parity) for ergonomics.
                    $profileName = if ($body.PSObject.Properties['profile'] -and $body.profile) {
                        [string]$body.profile
                    } elseif ($body.PSObject.Properties['name'] -and $body.name) {
                        [string]$body.name
                    } else { '' }
                    if (-not $profileName.Trim()) { throw "Informe o nome do perfil Gemini." }
                    $resData = Set-GeminiActiveProfile -ProfileName $profileName
                    $json = $resData | ConvertTo-Json -Depth 4 -Compress
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "GET" -and $url -match '^/api/gemini-auth/sessions/([^/]+)$') {
                    $sessionId = [System.Uri]::UnescapeDataString($Matches[1])
                    $resData = Get-GeminiAuthLoginSession -SessionId $sessionId
                    $json = $resData | ConvertTo-Json -Depth 5 -Compress
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "GET" -and $url -eq "/api/auth-login-urls") {
                    $limit = 10
                    if ($request.Url.Query) {
                        $m = [regex]::Match($request.Url.Query, 'limit=(\d+)')
                        if ($m.Success) {
                            try { $limit = [int]$m.Groups[1].Value } catch { $limit = 10 }
                        }
                    }
                    $urls = Get-RecentAuthLoginUrls -Limit $limit
                    $resData = [ordered]@{ urls = @($urls) }
                    $json = $resData | ConvertTo-Json -Compress -Depth 6
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "GET" -and $url -eq "/api/auto-rotate/status") {
                    $config = Ensure-ClaudeOrchestratorConfig
                    $taskState = @{}
                    foreach ($n in @('ClaudeAutoRotate','CodexAutoRotate')) {
                        try {
                            $t = Get-ScheduledTask -TaskName $n -ErrorAction Stop
                            $taskState[$n] = [string]$t.State
                        } catch {
                            $taskState[$n] = 'NotRegistered'
                        }
                    }
                    $resData = [ordered]@{
                        enabled = [bool]$config.autoRotateEnabled
                        tasks = $taskState
                    }
                    $json = $resData | ConvertTo-Json -Compress -Depth 4
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($method -eq "POST" -and $url -eq "/api/auto-rotate/toggle") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                    $bodyStr = $reader.ReadToEnd()
                    $body = if ($bodyStr.Trim()) { $bodyStr | ConvertFrom-Json } else { $null }
                    $desired = $false
                    if ($body -and ($body.PSObject.Properties.Name -contains 'enabled')) {
                        $desired = [bool]$body.enabled
                    }

                    $config = Ensure-ClaudeOrchestratorConfig
                    if (-not ($config.PSObject.Properties.Name -contains 'autoRotateEnabled')) {
                        $config | Add-Member -NotePropertyName 'autoRotateEnabled' -NotePropertyValue $false -Force
                    }
                    $config.autoRotateEnabled = $desired
                    Save-ClaudeOrchestratorConfig -Config $config

                    # Apply state to the Windows Task Scheduler immediately so the UI is the
                    # single source of truth. SilentlyContinue: if a task was uninstalled
                    # we still persist the user preference and surface the gap via /status.
                    $taskState = @{}
                    foreach ($n in @('ClaudeAutoRotate','CodexAutoRotate')) {
                        try {
                            if ($desired) {
                                Enable-ScheduledTask -TaskName $n -ErrorAction Stop | Out-Null
                            } else {
                                Disable-ScheduledTask -TaskName $n -ErrorAction Stop | Out-Null
                            }
                            $t = Get-ScheduledTask -TaskName $n -ErrorAction Stop
                            $taskState[$n] = [string]$t.State
                        } catch {
                            $taskState[$n] = 'NotRegistered'
                        }
                    }

                    $resData = [ordered]@{
                        enabled = [bool]$config.autoRotateEnabled
                        tasks = $taskState
                    }
                    $json = $resData | ConvertTo-Json -Compress -Depth 4
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                else {
                    $response.StatusCode = 404
                }
            } catch {
                $handlerError = $_
                Write-Host "  [claude-auth-ui] erro no handler: $($handlerError.Exception.Message)" -ForegroundColor Yellow
                try {
                    $response.StatusCode = 500
                    $payload = [ordered]@{ error = $handlerError.Exception.Message } | ConvertTo-Json -Compress
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($payload)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                } catch {
                    # Headers ja enviados ou response ja fechado — abortar sem derrubar o servidor
                    try { $response.Abort() } catch {}
                }
            } finally {
                try { $response.Close() } catch {}
            }
        }
    } catch {
        Write-Host "Servidor Claude Auth parado: $_" -ForegroundColor Yellow
    } finally {
        try { $listener.Stop() } catch {}
    }
}

switch ($Command.ToLowerInvariant()) {
    "ui" {
        Start-SkillManagerUI
    }
    "claude-auth-ui" {
        Start-ClaudeAuthUI
    }
    "help" {
        Show-Help
    }
    "sync-profile-hooks" {
        $results = Sync-ClaudeProfileHooks
        $results | ForEach-Object { Write-Host "$($_.profile): $($_.status)" }
    }
    "import-existing" {
        Import-ExistingSkills
    }
    "list-all" {
        Get-ImmediateSkillDirs -Root $Script:AllSkillsRoot | Sort-Object Name | ForEach-Object {
            Write-Host $_.Name
        }
    }
    "seed-global" {
        Enable-GlobalSkills -SkillNames $Script:RecommendedGlobalSkills
        Reconcile-SharedSkills
    }
    "seed-managed-state" {
        Seed-ManagedTargetsState
    }
    "enable-global" {
        if ($Skills.Count -eq 0) {
            throw "Use -Skills skill1,skill2"
        }
        Enable-GlobalSkills -SkillNames $Skills
        Reconcile-SharedSkills
    }
    "disable-global" {
        if ($Skills.Count -eq 0) {
            throw "Use -Skills skill1,skill2"
        }
        Disable-GlobalSkills -SkillNames $Skills
        Reconcile-SharedSkills
    }
    "sync-global" {
        Reconcile-SharedSkills
    }
    "reconcile" {
        Reconcile-SharedSkills
    }
    "sync-native-superpowers" {
        $result = Sync-NativeSuperpowers
        $result | ConvertTo-Json -Depth 8 | Write-Host
    }
    "sync-claude-usage-collector" {
        $result = Sync-ClaudeUsageCollector -ProfileNames $Skills -Force:$Force
        $result | ConvertTo-Json -Depth 8 | Write-Host
    }
    "add-claude-profile" {
        $result = Add-ClaudeProfile
        $result | ConvertTo-Json -Depth 8 | Write-Host
    }
    "add-project-skills" {
        if (-not $resolvedProjectPath) {
            throw "Use -ProjectPath C:\repo"
        }
        if ($Skills.Count -eq 0) {
            throw "Use -Skills skill1,skill2"
        }
        Add-ProjectSkills -ResolvedProjectPath $resolvedProjectPath -SkillNames $Skills
    }
    "remove-project-skills" {
        if (-not $resolvedProjectPath) {
            throw "Use -ProjectPath C:\repo"
        }
        if ($Skills.Count -eq 0) {
            throw "Use -Skills skill1,skill2"
        }
        Remove-ProjectSkills -ResolvedProjectPath $resolvedProjectPath -SkillNames $Skills
    }
    "sync-project" {
        if (-not $resolvedProjectPath) {
            throw "Use -ProjectPath C:\repo"
        }
        Sync-ProjectSkills -ResolvedProjectPath $resolvedProjectPath
    }
    "status" {
        Show-Status -ResolvedProjectPath $resolvedProjectPath
    }
    default {
        throw "Unknown command: $Command"
    }
}
