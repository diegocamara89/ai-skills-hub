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
    $packagesRoot = Join-Path $Script:LocalAppDataRoot "Packages"
    if (-not (Test-Path -LiteralPath $packagesRoot)) {
        return $null
    }

    $patterns = @(
        (Join-Path $packagesRoot "Claude_*\LocalCache\Roaming\Claude\claude-code\*\claude.exe"),
        (Join-Path $packagesRoot "Claude*\LocalCache\Roaming\Claude\claude-code\*\claude.exe")
    )

    $candidates = @()
    foreach ($pattern in $patterns) {
        $candidates += @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue)
    }

    if ($candidates.Count -gt 0) {
        $selected = $candidates | Sort-Object @{
            Expression = {
                try {
                    return [version]$_.Directory.Name
                } catch {
                    return [version]"0.0"
                }
            }
        } -Descending | Select-Object -First 1

        return $selected.FullName
    }

    $pathCommand = Get-Command "claude.exe" -ErrorAction SilentlyContinue
    if ($pathCommand) {
        return $pathCommand.Source
    }

    $pathFallback = Get-Command "claude" -ErrorAction SilentlyContinue
    if ($pathFallback) {
        return $pathFallback.Source
    }

    return $null
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
    $configPath = Get-ClaudeOrchestratorConfigPath
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
    [System.IO.File]::WriteAllText($markerPath, $activeLink, (New-Object System.Text.UTF8Encoding $false))

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

    # Garantir que junction 'active' sempre aponta para ~/.codex
    $needRebuild = $true
    if (Test-Path -LiteralPath $activeLink) {
        $item = Get-Item -LiteralPath $activeLink -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $rawTarget = $item.Target
            if ($rawTarget -is [System.Array]) { $rawTarget = $rawTarget[0] }
            $rawTarget = [string]$rawTarget
            if ($rawTarget.StartsWith('\??\'))  { $rawTarget = $rawTarget.Substring(4) }
            if ($rawTarget.TrimEnd('\') -eq $realCodexDir.TrimEnd('\')) { $needRebuild = $false }
        }
        if ($needRebuild) { [System.IO.Directory]::Delete($activeLink, $false) }
    }
    if ($needRebuild) {
        New-Item -ItemType Junction -Path $activeLink -Target $realCodexDir | Out-Null
    }

    # Garantir CODEX_HOME
    $currentEnv = [System.Environment]::GetEnvironmentVariable("CODEX_HOME", "User")
    if ($currentEnv -ne $activeLink) {
        [System.Environment]::SetEnvironmentVariable("CODEX_HOME", $activeLink, "User")
    }

    # Trocar conta: sobrescrever auth.json em ~/.codex com o do perfil selecionado
    if (Test-Path -LiteralPath $profileAuth) {
        $authContent = [System.IO.File]::ReadAllBytes($profileAuth)
        [System.IO.File]::WriteAllBytes((Join-Path $realCodexDir "auth.json"), $authContent)
    }

    # Gravar perfil ativo
    $activeProfileMarker = Join-Path $Script:UserProfileRoot ".codex-active-profile"
    [System.IO.File]::WriteAllText($activeProfileMarker, $ProfileName, (New-Object System.Text.UTF8Encoding $false))

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
    # Decodifica o JWT do auth.json para extrair email, nome e plano
    $authPath = Join-Path $ProfileDir "auth.json"
    if (-not (Test-Path -LiteralPath $authPath)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($authPath).Trim()
        if ($raw.Length -le 5 -or $raw -eq '{}') { return $null }
        $auth = $raw | ConvertFrom-Json
        $token = $auth.tokens.id_token
        if (-not $token) { $token = $auth.tokens.access_token }
        if (-not $token) { return $null }
        # Decodificar payload base64url (segunda parte do JWT)
        $parts = $token.Split('.')
        if ($parts.Count -lt 2) { return $null }
        $payload = $parts[1]
        $mod = $payload.Length % 4
        if ($mod -ne 0) { $payload += '=' * (4 - $mod) }
        $payload = $payload.Replace('-', '+').Replace('_', '/')
        $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
        $openaiAuth = $decoded.'https://api.openai.com/auth'
        return [ordered]@{
            email    = [string]($decoded.email)
            name     = [string]($decoded.name)
            planType = [string]($openaiAuth.chatgpt_plan_type)
            authMode = [string]($auth.auth_mode)
        }
    } catch { return $null }
}

function Get-CodexProfiles {
    $profilesRoot  = Join-Path $Script:UserProfileRoot ".codex-profiles"
    $realCodexDir  = Join-Path $Script:UserProfileRoot ".codex"
    if (-not (Test-Path -LiteralPath $profilesRoot)) {
        return @()
    }

    # Determinar perfil ativo: ler marker ou comparar account_id do auth.json ativo
    $activeName = ""
    $markerPath = Join-Path $Script:UserProfileRoot ".codex-active-profile"
    if (Test-Path -LiteralPath $markerPath) {
        $activeName = (Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8).Trim()
    }
    # Fallback: comparar account_id do auth.json em ~/.codex com cada perfil
    if (-not $activeName) {
        $activeAuthPath = Join-Path $realCodexDir "auth.json"
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

    # rateLimits e lastUsed vem de ~/.codex (compartilhado) — só faz sentido para o perfil ativo
    $sharedRateLimits = Get-CodexRateLimits -ProfileDir $realCodexDir
    $sharedLastUsed   = $null
    $sharedLastUsePath = Join-Path $realCodexDir ".last-use"
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
                lastUsed   = $sharedLastUsed
                rateLimits = $sharedRateLimits
            }
        }

    return $profiles
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

    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null

    # Novo perfil: só guarda auth.json (vazio por enquanto — user faz login depois)
    $authPath = Join-Path $profileDir "auth.json"
    [System.IO.File]::WriteAllText($authPath, "{}", (New-Object System.Text.UTF8Encoding $false))

    # Garantir que CODEX_HOME e junction estao corretos (sessions sempre em ~/.codex)
    $realCodexDir = Join-Path $Script:UserProfileRoot ".codex"
    $activeLink   = Join-Path $profilesRoot "active"
    if (-not (Test-Path -LiteralPath $activeLink)) {
        if (Test-Path -LiteralPath $realCodexDir) {
            New-Item -ItemType Junction -Path $activeLink -Target $realCodexDir | Out-Null
        }
        [System.Environment]::SetEnvironmentVariable("CODEX_HOME", $activeLink, "User")
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

    # Copiar auth.json de ~/.codex para codex-a se ainda estiver vazio
    $profileAuth   = Join-Path $defaultDir "auth.json"
    $originalAuth  = Join-Path $realCodexDir "auth.json"
    if (-not (Test-Path -LiteralPath $profileAuth) -or (Get-Content -LiteralPath $profileAuth -Raw).Trim() -in @('', '{}')) {
        if (Test-Path -LiteralPath $originalAuth) {
            $content = [System.IO.File]::ReadAllText($originalAuth)
            if ($content.Trim().Length -gt 10 -and $content.Trim() -ne '{}') {
                [System.IO.File]::WriteAllText($profileAuth, $content, (New-Object System.Text.UTF8Encoding $false))
            }
        }
        if (-not (Test-Path -LiteralPath $profileAuth)) {
            [System.IO.File]::WriteAllText($profileAuth, "{}", (New-Object System.Text.UTF8Encoding $false))
        }
    }

    # Garantir junction active -> ~/.codex
    $rebuildJunction = $true
    if (Test-Path -LiteralPath $activeLink) {
        $j = Get-Item -LiteralPath $activeLink -Force -ErrorAction SilentlyContinue
        if ($j -and ($j.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $t = [string]($j.Target | Select-Object -First 1)
            if ($t.StartsWith('\??\')) { $t = $t.Substring(4) }
            if ($t.TrimEnd('\') -eq $realCodexDir.TrimEnd('\')) { $rebuildJunction = $false }
        }
        if ($rebuildJunction) { [System.IO.Directory]::Delete($activeLink, $false) }
    }
    if ($rebuildJunction -and (Test-Path -LiteralPath $realCodexDir)) {
        New-Item -ItemType Junction -Path $activeLink -Target $realCodexDir | Out-Null
        Write-Host "Junction corrigida: active -> ~/.codex"
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
        [System.IO.File]::WriteAllText($markerPath, $defaultName, (New-Object System.Text.UTF8Encoding $false))
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
    param([object]$Config)

    $configPath = Get-ClaudeOrchestratorConfigPath
    Ensure-Directory -Path (Split-Path -Parent $configPath)
    Write-JsonFile -Path $configPath -Data $Config
}

function Ensure-ClaudeOrchestratorConfig {
    $config = Get-ClaudeOrchestratorConfig
    if ($config) {
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
        commands = [ordered]@{
            claude = [ordered]@{ path = (Get-LatestClaudeCliPath) }
            codex = [ordered]@{ path = (Get-NpmCmdShimPath -CommandName "codex") }
            gemini = [ordered]@{ path = (Get-NpmCmdShimPath -CommandName "gemini") }
            qwen = [ordered]@{ path = (Get-NpmCmdShimPath -CommandName "qwen") }
        }
    }
    Save-ClaudeOrchestratorConfig -Config $config
    return Get-ClaudeOrchestratorConfig
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

    $autoRotateCmd = "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"C:/Users/marce/Diego/AI-Skills-Hub/auto-rotate.ps1`""
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

            $json = $settings | ConvertTo-Json -Depth 20
            [System.IO.File]::WriteAllText($settingsPath, $json, (New-Object System.Text.UTF8Encoding $false))
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
    Copy-ClaudeProfileSeedFiles -TargetProfileDir $newProfileDir -TemplateProfileDir $templateDir
    Sync-ClaudeProfileHooks -ProfileNames @($nextName) | Out-Null

    $config.profiles += [pscustomobject]@{
        name = $nextName
        config_dir = $newProfileDir
    }
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

    return [ordered]@{
        added = $true
        profile = $nextName
        configDir = $newProfileDir
        totalProfiles = @($config.profiles).Count
        maxProfiles = Get-ClaudeMaxProfileCount
        collector = $collectorResult
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

        $items += $status
    }

    if ($stateChanged) {
        Save-ClaudeAccountStateStore -State $accountState
    }

    # Detectar perfil ativo via CLAUDE_CONFIG_DIR — resolve junction se necessario
    $configDirEnv = [System.Environment]::GetEnvironmentVariable("CLAUDE_CONFIG_DIR", "User")
    $activeProfileName = ""
    if ($configDirEnv) {
        # Tentar extrair nome diretamente do path
        $parts = $configDirEnv -split '[/\\]'
        $matched = $parts | Where-Object { $_ -match '^claude-[a-z]' } | Select-Object -Last 1
        if ($matched) {
            $activeProfileName = $matched
        } else {
            # Path pode ser uma junction (ex: active) — resolver o target
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

    # Marcar isActive em cada perfil (sem escrever em state.json)
    foreach ($item in $items) {
        $item["isActive"] = ($item.name -eq $activeProfileName)
    }

    return [ordered]@{
        configPath = Get-ClaudeOrchestratorConfigPath
        cliPath = Get-ClaudeCliForAuth
        activeProfile = $activeProfileName
        profiles = $items
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

    $claudeCli = Get-ClaudeCliForAuth
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

    $argumentsString = (($argList | ForEach-Object { '"' + ($_ -replace '"', '""') + '"' }) -join ' ')
    $scriptLines = @(
        '$ErrorActionPreference = "Stop"',
        ('$claudeCli = ' + (ConvertTo-Json -Compress $claudeCli)),
        ('$configDir = ' + (ConvertTo-Json -Compress $profile.configDir)),
        ('$stdoutPath = ' + (ConvertTo-Json -Compress $stdoutPath)),
        ('$stderrPath = ' + (ConvertTo-Json -Compress $stderrPath)),
        ('$inputPath = ' + (ConvertTo-Json -Compress $inputPath)),
        ('$argList = @(' + (($argList | ForEach-Object { ConvertTo-Json -Compress $_ }) -join ',') + ')'),
        'function Flush-Reader {',
        '    param([System.IO.StreamReader]$Reader, [string]$Path)',
        '    $buffer = New-Object char[] 4096',
        '    $builder = New-Object System.Text.StringBuilder',
        '    while ($Reader -and $Reader.Peek() -ge 0) {',
        '        $count = $Reader.Read($buffer, 0, $buffer.Length)',
        '        if ($count -le 0) { break }',
        '        [void]$builder.Append($buffer, 0, $count)',
        '    }',
        '    if ($builder.Length -gt 0) {',
        '        [System.IO.File]::AppendAllText($Path, $builder.ToString(), [System.Text.Encoding]::UTF8)',
        '    }',
        '}',
        '$psi = New-Object System.Diagnostics.ProcessStartInfo',
        '$psi.FileName = $claudeCli',
        '$psi.UseShellExecute = $false',
        '$psi.RedirectStandardInput = $true',
        '$psi.RedirectStandardOutput = $true',
        '$psi.RedirectStandardError = $true',
        '$psi.CreateNoWindow = $true',
        ('$psi.Arguments = ''' + ($argumentsString -replace "'", "''") + ''''),
        '$psi.Environment["CLAUDE_CONFIG_DIR"] = $configDir',
        '$process = New-Object System.Diagnostics.Process',
        '$process.StartInfo = $psi',
        '[void]$process.Start()',
        'while (-not $process.HasExited) {',
        '    Flush-Reader -Reader $process.StandardOutput -Path $stdoutPath',
        '    Flush-Reader -Reader $process.StandardError -Path $stderrPath',
        '    if (Test-Path -LiteralPath $inputPath) {',
        '        $code = [System.IO.File]::ReadAllText($inputPath)',
        '        if ($code.Trim()) {',
        '            $process.StandardInput.WriteLine($code.Trim())',
        '            [System.IO.File]::WriteAllText($inputPath, "", [System.Text.Encoding]::UTF8)',
        '        }',
        '    }',
        '    Start-Sleep -Milliseconds 250',
        '}',
        'Flush-Reader -Reader $process.StandardOutput -Path $stdoutPath',
        'Flush-Reader -Reader $process.StandardError -Path $stderrPath',
        'exit $process.ExitCode'
    )
    Set-Content -LiteralPath $scriptPath -Value ($scriptLines -join "`r`n") -Encoding UTF8

    $preAuthStatus = $null
    try {
        $preAuthStatus = Get-ClaudeAuthStatusForConfigDir -ConfigDir $profile.configDir
    } catch {}

    $process = Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scriptPath) -PassThru -WindowStyle Hidden

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
    $metaPath   = Join-Path $sessionDir "meta.json"

    # Script executado DENTRO da janela de terminal (precisa de TTY para Codex CLI)
    $scriptLines = @(
        '$ErrorActionPreference = "Continue"',
        ('$env:CODEX_HOME = ' + (ConvertTo-Json -Compress $profileDir)),
        ('$env:PATH = "C:\Program Files\nodejs;" + $env:APPDATA + "\npm;" + $env:PATH'),
        'Write-Host ""',
        ('Write-Host "=== Login Codex — Perfil: ' + $ProfileName + ' ===" -ForegroundColor Cyan'),
        'Write-Host "O navegador sera aberto automaticamente. Complete o login e feche esta janela." -ForegroundColor Yellow',
        'Write-Host ""',
        '& codex login',
        ('Set-Content -LiteralPath ' + (ConvertTo-Json -Compress $donePath) + ' -Value "done" -Encoding UTF8'),
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
        Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scriptPath)
    }

    $meta = [ordered]@{
        sessionId   = $sessionId
        tool        = "codex"
        profile     = $ProfileName
        profileDir  = $profileDir
        createdAt   = (Get-Date).ToString("o")
        donePath    = $donePath
        scriptPath  = $scriptPath
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

    return [ordered]@{
        sessionId      = $meta.sessionId
        profile        = $meta.profile
        profileDir     = $meta.profileDir
        createdAt      = $meta.createdAt
        running        = $running
        loginSucceeded = $loginSucceeded
        loginUrl       = $null
        stdout         = ""
        stderr         = ""
    }
}

function Sync-NativeSuperpowers {
    Ensure-Directory -Path $Script:NativeIntegrationsRoot

    $repoPath = Get-SuperpowersCheckoutPath
    $repoUrl = "https://github.com/obra/superpowers.git"
    $actions = @()

    if ($Install) {
        if (Test-Path -LiteralPath $repoPath) {
            Write-Step "Atualizando checkout local de superpowers"
            & git -C $repoPath pull --ff-only | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Falha ao atualizar o checkout local de superpowers."
            }
            $actions += "checkout-updated"
        }
        else {
            Write-Step "Clonando superpowers para $repoPath"
            & git clone --depth 1 $repoUrl $repoPath | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Falha ao clonar o repositorio superpowers."
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
    return @(
        @{ Label = "codex-user"; Root = (Join-UserProfilePath ".agents\skills"); Skip = @(".stfolder") },
        @{ Label = "codex-legacy"; Root = (Join-UserProfilePath ".codex\skills"); Skip = @(".stfolder", ".system") },
        @{ Label = "claude"; Root = (Join-UserProfilePath ".claude\skills"); Skip = @(".stfolder") },
        @{ Label = "qwen"; Root = (Join-UserProfilePath ".qwen\skills"); Skip = @(".stfolder") },
        @{ Label = "antigravity"; Root = (Join-UserProfilePath ".antigravity\skills"); Skip = @() }
    )
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

function Write-Utf8File {
    param(
        [string]$Path,
        [string]$Content
    )

    Ensure-Directory -Path (Split-Path -Parent $Path)

    if ($DryRun) {
        Write-Step "[dry-run] write $Path"
        return
    }

    Write-Step "Writing $Path"
    Set-Content -LiteralPath $Path -Value $Content -Encoding UTF8
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
                elseif ($method -eq "GET" -and $url -eq "/claude-auth") {
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

                        foreach ($tgt in $globalDefs) {
                            $targetPath = Join-Path $tgt["Root"] $name
                            if (Test-Path -LiteralPath $targetPath) {
                                $installed[$tgt["Label"]] = $true
                                # Verifica se e junction gerenciada
                                $isManaged = Test-ManagedLink -Path $targetPath -ManagedRoots (Get-ManagedCatalogRoots)
                                $isNative[$tgt["Label"]] = -not $isManaged
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
                elseif ($method -eq "GET" -and $url -eq "/api/claude-auth/status") {
                    $resData = Get-ClaudeAuthStatus
                    $json = $resData | ConvertTo-Json -Depth 10 -Compress
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

                        $resData = @{ success = $true; name = $repoName; description = $desc }
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
                $response.StatusCode = 500
                $err = @{ error = $_.Exception.Message } | ConvertTo-Json -Compress
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($err)
                $response.ContentType = "application/json"
                $response.ContentLength64 = $buffer.Length
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
            } finally {
                $response.Close()
            }
        }
    } catch {
        Write-Host "Servidor parado: $_"
    } finally {
        $listener.Stop()
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
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes('{"success":true}')
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
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes('{"success":true}')
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
                else {
                    $response.StatusCode = 404
                }
            } catch {
                $response.StatusCode = 500
                $payload = [ordered]@{ error = $_.Exception.Message } | ConvertTo-Json -Compress
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($payload)
                $response.ContentType = "application/json; charset=utf-8"
                $response.ContentLength64 = $buffer.Length
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
            } finally {
                $response.Close()
            }
        }
    } catch {
        Write-Host "Servidor Claude Auth parado: $_"
    } finally {
        $listener.Stop()
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
