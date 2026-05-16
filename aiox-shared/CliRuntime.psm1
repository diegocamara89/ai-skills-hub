# aiox-shared/CliRuntime.psm1 — Abstracao multi-CLI para perfis e rotacao
#
# Plano: docs/superpowers/plans/2026-05-10-evolution-d.md  Task 7
#
# Responsabilidade:
#   Modela a diferenca entre como cada CLI persiste credenciais e como o
#   "perfil ativo" deve ser trocado:
#
#     CLI      Pasta padrao do CLI            Auth file                 Swap method
#     ───────  ─────────────────────────────  ───────────────────────   ───────────
#     claude   ~/.claude (real config)        .credentials.json         junction
#     codex    ~/.codex                       auth.json                 copy
#     gemini   ~/.gemini                      oauth_creds.json          env
#
#   - junction: ha uma junction NTFS ~/.<cli>-profiles/active -> <perfil>.
#               Trocar = recriar a junction. Mais barato, atomico-ish.
#   - copy:     copia <perfil>/<auth_file> sobre ~/.<cli>/<auth_file>.
#               Necessario quando a CLI nao respeita um diretorio externo.
#   - env:      define ~/.<cli>-profiles/active via env var (ex: GEMINI_API_KEY_DIR).
#               Mais lightweight; a CLI le a env var em cada invocacao.
#
#   Get-CliProfile  -> retorna metadata sobre onde o perfil mora e como trocar
#   Invoke-CliRotation -> roteia para o swap helper correto baseado em SwapMethod
#
# Notas:
#   - claude e codex hoje usam scripts proprios (auto-rotate.ps1 / auto-rotate-codex.ps1)
#     com logica historica. Este modulo NAO substitui o fluxo do claude — e usado
#     somente pelo script auto-rotate-gemini.ps1 e por testes que validam o
#     contrato. claude/codex podem migrar para ele em uma task futura.
#   - Quando o perfil ainda nao existe no disco, Get-CliProfile retorna a
#     hashtable populada (caminho calculado) sem tocar no FS. Quem CRIA pasta e
#     Invoke-CliRotation (com -DryRun:$false e fonte valida) ou o usuario via UI.
#   - Para SwapMethod='env', o nome da env var por CLI segue convencao oficial:
#       gemini -> GEMINI_CONFIG_DIR (Google CLI honra essa variavel para custom config dirs)
#   - Para SwapMethod='junction', JunctionPath aponta para ~/.<cli>-profiles/active.
#   - Para SwapMethod='copy', nao ha JunctionPath nem EnvVarName — o swap e file copy.

Set-StrictMode -Version Latest

# ── Catalogo de CLIs suportadas ───────────────────────────────────────────────
# Alterar este hashtable e o ponto unico de extensao para suportar uma nova CLI.
$Script:CliCatalog = @{
    'claude' = @{
        ProfilesRoot = '.claude-profiles'
        AuthFile     = '.credentials.json'
        SwapMethod   = 'junction'
        JunctionName = 'active'
        EnvVarName   = 'CLAUDE_CONFIG_DIR'
    }
    'codex'  = @{
        ProfilesRoot = '.codex-profiles'
        AuthFile     = 'auth.json'
        SwapMethod   = 'copy'
        # Codex le auth.json de ~/.codex; "copy" sobrescreve ~/.codex/auth.json
        # com o conteudo do perfil escolhido.
        TargetDir    = '.codex'
        EnvVarName   = 'CODEX_HOME'
    }
    'gemini' = @{
        ProfilesRoot = '.gemini-profiles'
        AuthFile     = 'oauth_creds.json'
        SwapMethod   = 'env'
        EnvVarName   = 'GEMINI_CONFIG_DIR'
    }
    # NOTE: Qwen removido em 2026-05-10 — OAuth portal.qwen.ai descontinuado em
    # 15/04/2026 sem caminho de migracao via OAuth (DashScope/OpenRouter requerem
    # API key, fora de escopo desta abstracao). Folder ~/.qwen/skills/ e Syncthing
    # folder skills-qwen mantidos intactos.
}

function Get-CliProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('claude','codex','gemini')]
        [string]$CliType,

        [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
        [string]$ProfileName,

        # Test hook: permite simular HOME diferente sem tocar $env:USERPROFILE.
        [string]$UserProfileOverride
    )

    $userProfile = if ($UserProfileOverride) { $UserProfileOverride } else { $env:USERPROFILE }
    $entry = $Script:CliCatalog[$CliType]
    if (-not $entry) {
        # Defensivo: ValidateSet ja barra entradas invalidas, mas se alguem
        # bypass-ar com Invoke-Expression / chamada interna, falhamos cedo.
        throw "Get-CliProfile: CliType '$CliType' nao esta no catalogo"
    }

    $profilesRoot = Join-Path $userProfile $entry.ProfilesRoot
    $configDir    = Join-Path $profilesRoot $ProfileName

    $result = [ordered]@{
        CliType     = $CliType
        ProfileName = $ProfileName
        ConfigDir   = $configDir
        AuthFile    = $entry.AuthFile
        SwapMethod  = $entry.SwapMethod
        Exists      = (Test-Path -LiteralPath $configDir)
    }

    switch ($entry.SwapMethod) {
        'junction' {
            $result.JunctionPath = Join-Path $profilesRoot $entry.JunctionName
            $result.EnvVarName   = $entry.EnvVarName
        }
        'copy' {
            $result.TargetDir  = Join-Path $userProfile $entry.TargetDir
            $result.EnvVarName = $entry.EnvVarName
        }
        'env' {
            $result.EnvVarName = $entry.EnvVarName
        }
    }

    return [hashtable]$result
}

# ── Swap helpers ──────────────────────────────────────────────────────────────
# Cada um implementa exatamente UMA estrategia de troca. Sao chamados por
# Invoke-CliRotation; podem tambem ser usados standalone por testes/REPL.

function Swap-ViaJunction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('claude','codex','gemini')][string]$CliType,
        [Parameter(Mandatory)][string]$ToProfile,
        [switch]$DryRun,
        [string]$UserProfileOverride
    )

    $target = Get-CliProfile -CliType $CliType -ProfileName $ToProfile -UserProfileOverride:$UserProfileOverride
    if ($target.SwapMethod -ne 'junction') {
        throw "Swap-ViaJunction: CLI '$CliType' usa SwapMethod='$($target.SwapMethod)'"
    }
    if (-not $target.Exists) {
        throw "Swap-ViaJunction: pasta de perfil nao existe: $($target.ConfigDir)"
    }

    $junction = $target.JunctionPath

    if ($DryRun) {
        return [pscustomobject]@{
            Action       = 'junction-swap'
            DryRun       = $true
            CliType      = $CliType
            ToProfile    = $ToProfile
            ConfigDir    = $target.ConfigDir
            JunctionPath = $junction
        }
    }

    # Remover junction existente (somente se for reparse point — evita rm -rf
    # acidental se alguem materializou a pasta como diretorio normal).
    if (Test-Path -LiteralPath $junction) {
        $jItem = Get-Item -LiteralPath $junction -Force
        if (($jItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            [System.IO.Directory]::Delete($junction, $false)
        } else {
            throw "Swap-ViaJunction: '$junction' existe mas nao e reparse point — recusando excluir"
        }
    }
    New-Item -ItemType Junction -Path $junction -Target $target.ConfigDir -ErrorAction Stop | Out-Null

    return [pscustomobject]@{
        Action       = 'junction-swap'
        DryRun       = $false
        CliType      = $CliType
        ToProfile    = $ToProfile
        ConfigDir    = $target.ConfigDir
        JunctionPath = $junction
    }
}

function Swap-ViaCopy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('claude','codex','gemini')][string]$CliType,
        [Parameter(Mandatory)][string]$ToProfile,
        [switch]$DryRun,
        [string]$UserProfileOverride
    )

    $target = Get-CliProfile -CliType $CliType -ProfileName $ToProfile -UserProfileOverride:$UserProfileOverride
    if ($target.SwapMethod -ne 'copy') {
        throw "Swap-ViaCopy: CLI '$CliType' usa SwapMethod='$($target.SwapMethod)'"
    }
    if (-not $target.Exists) {
        throw "Swap-ViaCopy: pasta de perfil nao existe: $($target.ConfigDir)"
    }

    $sourceAuth = Join-Path $target.ConfigDir $target.AuthFile
    if (-not (Test-Path -LiteralPath $sourceAuth)) {
        throw "Swap-ViaCopy: arquivo de auth ausente em $sourceAuth"
    }
    $destDir  = $target.TargetDir
    $destAuth = Join-Path $destDir $target.AuthFile

    if ($DryRun) {
        return [pscustomobject]@{
            Action     = 'auth-copy'
            DryRun     = $true
            CliType    = $CliType
            ToProfile  = $ToProfile
            Source     = $sourceAuth
            Destination= $destAuth
        }
    }

    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    Copy-Item -LiteralPath $sourceAuth -Destination $destAuth -Force -ErrorAction Stop

    return [pscustomobject]@{
        Action     = 'auth-copy'
        DryRun     = $false
        CliType    = $CliType
        ToProfile  = $ToProfile
        Source     = $sourceAuth
        Destination= $destAuth
    }
}

function Swap-ViaEnvVar {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('claude','codex','gemini')][string]$CliType,
        [Parameter(Mandatory)][string]$ToProfile,
        [switch]$DryRun,
        [string]$UserProfileOverride,
        # Test hook: permite testar sem tocar HKCU. Default = User-scope.
        [ValidateSet('Process','User','Machine')][string]$Scope = 'User'
    )

    $target = Get-CliProfile -CliType $CliType -ProfileName $ToProfile -UserProfileOverride:$UserProfileOverride
    if ($target.SwapMethod -ne 'env') {
        throw "Swap-ViaEnvVar: CLI '$CliType' usa SwapMethod='$($target.SwapMethod)'"
    }
    if (-not $target.Exists) {
        throw "Swap-ViaEnvVar: pasta de perfil nao existe: $($target.ConfigDir)"
    }

    $envVar = $target.EnvVarName
    if (-not $envVar) {
        throw "Swap-ViaEnvVar: catalogo nao define EnvVarName para CliType '$CliType'"
    }

    if ($DryRun) {
        return [pscustomobject]@{
            Action     = 'env-set'
            DryRun     = $true
            CliType    = $CliType
            ToProfile  = $ToProfile
            EnvVarName = $envVar
            ConfigDir  = $target.ConfigDir
            Scope      = $Scope
        }
    }

    [System.Environment]::SetEnvironmentVariable($envVar, $target.ConfigDir, $Scope)

    return [pscustomobject]@{
        Action     = 'env-set'
        DryRun     = $false
        CliType    = $CliType
        ToProfile  = $ToProfile
        EnvVarName = $envVar
        ConfigDir  = $target.ConfigDir
        Scope      = $Scope
    }
}

# ── Roteador principal ────────────────────────────────────────────────────────
function Invoke-CliRotation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('claude','codex','gemini')][string]$CliType,
        [Parameter(Mandatory)][string]$FromProfile,
        [Parameter(Mandatory)][string]$ToProfile,
        [switch]$DryRun,
        [string]$UserProfileOverride
    )

    if ($FromProfile -eq $ToProfile) {
        # Idempotente: tentar trocar para o perfil ja ativo e no-op.
        return [pscustomobject]@{
            Action      = 'noop'
            CliType     = $CliType
            FromProfile = $FromProfile
            ToProfile   = $ToProfile
            DryRun      = [bool]$DryRun
            Reason      = 'from-equals-to'
        }
    }

    $target = Get-CliProfile -CliType $CliType -ProfileName $ToProfile -UserProfileOverride:$UserProfileOverride

    switch ($target.SwapMethod) {
        'junction' { return Swap-ViaJunction -CliType $CliType -ToProfile $ToProfile -DryRun:$DryRun -UserProfileOverride:$UserProfileOverride }
        'copy'     { return Swap-ViaCopy     -CliType $CliType -ToProfile $ToProfile -DryRun:$DryRun -UserProfileOverride:$UserProfileOverride }
        'env'      { return Swap-ViaEnvVar   -CliType $CliType -ToProfile $ToProfile -DryRun:$DryRun -UserProfileOverride:$UserProfileOverride }
        default    { throw "Invoke-CliRotation: SwapMethod desconhecido '$($target.SwapMethod)'" }
    }
}

Export-ModuleMember -Function `
    Get-CliProfile, `
    Invoke-CliRotation, `
    Swap-ViaJunction, `
    Swap-ViaCopy, `
    Swap-ViaEnvVar
