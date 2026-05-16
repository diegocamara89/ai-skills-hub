# auto-rotate.ps1 — Rotacao automatica de perfil Claude + CLI interativo
# Executado periodicamente via Windows Task Scheduler (a cada 10 minutos) no
# modo automatico, OU manualmente via os modos CLI abaixo. Nao requer elevacao
# (admin). Atualiza CLAUDE_CONFIG_DIR na User env var.
#
# Modos:
#   (default)     Modo automatico: rota apenas se uso 5h ou 7d >= -Threshold
#   -Status       Mostra perfil ativo + uso atual (5h/7d %) e sai
#   -List         Lista todos perfis com estado/cooldown e sai
#   -Preview      Mostra qual seria o proximo perfil disponivel sem aplicar
#   -Switch <p>   Troca manual para o perfil <p> (ex: claude-b) e sai
#   -DryRun       Apenas loga, nao aplica mudancas (combinavel com -Switch)
#   -Force        Ignora threshold no modo automatico, rota imediatamente

param(
    [int]$Threshold = 95,   # % de uso que dispara rotacao
    [switch]$DryRun,        # Apenas logar, nao aplicar mudancas
    [switch]$Force,         # Ignora threshold — rota imediatamente para o proximo perfil disponivel
    [switch]$Status,        # CLI mode: mostra perfil ativo + uso atual e sai
    [switch]$List,          # CLI mode: lista todos perfis com estado/cooldown e sai
    [switch]$Preview,       # CLI mode: mostra qual seria o proximo perfil sem aplicar e sai
    [string]$Switch         # CLI mode: troca manual para o perfil informado (ex: claude-b) e sai
)

$OrchestratorRoot = Join-Path $env:USERPROFILE ".claude-orchestrator"
$StateFile      = Join-Path $OrchestratorRoot "state.json"
$ConfigFile     = Join-Path $OrchestratorRoot "config.json"
$UsageRoot      = Join-Path $OrchestratorRoot "usage\profiles"
$LogFile        = Join-Path $OrchestratorRoot "usage\logs\rotation.log"
$Script:JsonLogFile = Join-Path $OrchestratorRoot "usage\logs\rotation.jsonl"

# Optional structured logger (Task 2). Used by Read-CooldownFile to emit
# 'corrupt-cooldown' events. Falls back to plain Write-Host + log file if the
# module is missing, so this script keeps working in isolation.
$Script:HasStructuredLogger = $false
$loggerPath = Join-Path $PSScriptRoot 'aiox-shared\StructuredLogger.psm1'
if (Test-Path -LiteralPath $loggerPath) {
    Import-Module $loggerPath -Force -ErrorAction SilentlyContinue
    if (Get-Command -Name Write-StructuredLog -ErrorAction SilentlyContinue) {
        $Script:HasStructuredLogger = $true
    }
}

# Optional cross-process mutex helper (Task 4). Serializes junction swaps so
# concurrent invocations (Task Scheduler + manual run, or 2 schedulers racing)
# do not collide on Remove-Item / New-Item -Junction. If the module is missing
# the script still runs but loses race protection.
$Script:HasFileLock = $false
$mutexPath = Join-Path $PSScriptRoot 'aiox-shared\Mutex.psm1'
if (Test-Path -LiteralPath $mutexPath) {
    Import-Module $mutexPath -Force -DisableNameChecking -ErrorAction SilentlyContinue 3>$null
    if ((Get-Command -Name Acquire-FileLock -ErrorAction SilentlyContinue) -and
        (Get-Command -Name Release-FileLock -ErrorAction SilentlyContinue)) {
        $Script:HasFileLock = $true
    }
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $line = "$ts [$Level] $Message"
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8

    # Mirror to rotation.jsonl as a generic 'log' event for structured tooling.
    # Callers wanting richer fields call Write-StructuredLog directly.
    if ($Script:HasStructuredLogger) {
        $structuredLevel = $Level.ToLowerInvariant()
        if ($structuredLevel -notin @('info','warn','error','debug')) { $structuredLevel = 'info' }
        try {
            Write-StructuredLog -Path $Script:JsonLogFile -Event 'log' -Level $structuredLevel -Properties @{ msg = $Message }
        } catch {
            # never fail rotation due to logging
        }
    }

    Write-Host $line
}

# ── BUG-A fix: validar nome de perfil de forma case-insensitive ───────────────
# `-match` em PowerShell e case-insensitive por default, entao caracteres
# Claude-A / CLAUDE-A passam. O regex anterior estava embutido em call-sites
# e dependia do default — extracao aqui torna o contrato explicito e testavel.
function Test-IsValidProfileName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    return [bool]($Name -match '^claude-[a-z]$')
}

# ── BUG-B fix: parse ISO 8601 sempre tratando timestamp como UTC ──────────────
# `[DateTime]::Parse(string)` interpreta strings unqualified como hora local.
# Em maquinas com TZ != UTC isso desloca o cooldown silenciosamente. Forcamos
# AssumeUniversal + AdjustToUniversal para que toda comparacao com $now (UTC)
# seja consistente.
function ConvertTo-UtcDateTime {
    param([Parameter(Mandatory)][string]$IsoString)
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal `
              -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    return [System.DateTime]::Parse(
        $IsoString,
        [System.Globalization.CultureInfo]::InvariantCulture,
        $styles
    )
}

# ── BUG-C fix: ler arquivo .cooldown com log estruturado em caso de erro ─────
# O catch silencioso anterior fazia o perfil sumir do scheduler sem trace.
# Agora retorna $null e escreve um evento 'corrupt-cooldown' (level=error)
# para que falhas sejam visiveis em rotation.jsonl.
function Read-CooldownFile {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            throw "cooldown file empty"
        }
        return [long]$raw.Trim()
    } catch {
        $reason = $_.Exception.Message
        if ($Script:HasStructuredLogger) {
            try {
                Write-StructuredLog -Path $Script:JsonLogFile -Event 'corrupt-cooldown' -Level 'error' -Properties @{
                    path   = $Path
                    reason = $reason
                }
            } catch {
                # logger failed — fall through to plaintext fallback
                Write-Host "[ERROR] corrupt-cooldown: $Path ($reason)"
                try {
                    $parent = Split-Path -Parent $Script:JsonLogFile
                    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                        New-Item -ItemType Directory -Path $parent -Force | Out-Null
                    }
                    Add-Content -LiteralPath $Script:JsonLogFile -Value ("{`"event`":`"corrupt-cooldown`",`"level`":`"error`",`"path`":`"{0}`",`"reason`":`"{1}`"}" -f ($Path -replace '\\','\\'), ($reason -replace '"','\"')) -Encoding UTF8
                } catch {
                    # silent: fallback-do-fallback do Read-CooldownFile; se Add-Content falhar, ja temos Write-Host plaintext acima e nao podemos recursar logging
                    $null = $_
                }
            }
        } else {
            Write-Host "[ERROR] corrupt-cooldown: $Path ($reason)"
            try {
                $parent = Split-Path -Parent $Script:JsonLogFile
                if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                    New-Item -ItemType Directory -Path $parent -Force | Out-Null
                }
                $entry = [ordered]@{
                    ts     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                    level  = 'error'
                    event  = 'corrupt-cooldown'
                    path   = $Path
                    reason = $reason
                }
                Add-Content -LiteralPath $Script:JsonLogFile -Value ($entry | ConvertTo-Json -Compress) -Encoding UTF8
            } catch {
                # silent: fallback do Read-CooldownFile sem structured logger; se Add-Content falhar ja emitimos Write-Host plaintext acima
                $null = $_
            }
        }
        return $null
    }
}

function Read-JsonFile {
    param([string]$Path)
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    # Remover BOM se presente
    if ($raw[0] -eq [char]0xFEFF) { $raw = $raw.Substring(1) }
    return $raw | ConvertFrom-Json
}

function Save-JsonFile {
    param([string]$Path, [object]$Data)
    $Data | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

# ── Task 6: Apply-ProfileSwitch com snapshot + rollback ────────────────────────
# Refatora a logica inline de junction-swap para uma funcao reusavel que:
#   1. Snapshot do state.json (raw bytes para restauracao byte-perfect)
#   2. Snapshot do alvo da junction atual
#   3. Tenta: remove junction, recria apontando para novo perfil, salva state
#   4. Em caso de erro: restaura junction antiga + restaura state.json + emite
#      evento estruturado 'rollback' (level=error) e re-throw a excecao.
#
# Compatibilidade:
# - Task 3 (CLI -Switch) chama esta funcao diretamente.
# - Task 4 (mutex) envelope esta funcao com Acquire-FileLock externamente.
# - Task 5 reusa Test-IsValidProfileName.
function Apply-ProfileSwitch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfileName,
        [switch]$DryRun,
        # Test hooks: permitem rodar a funcao sem tocar HKCU (CLAUDE_CONFIG_DIR
        # User-scope env var) nem o ~/.claude-orchestrator real. Producao nao
        # precisa passar — defaults vem de $Script:* / $env:USERPROFILE.
        [string]$StateFileOverride,
        [string]$ConfigFileOverride,
        [string]$ProfilesRootOverride
    )

    # Resolver paths a partir do escopo do script. Quando chamado por testes
    # que dot-sourceiam apenas a funcao, $Script:OrchestratorRoot pode nao
    # existir — fall back para defaults computados.
    $orchRoot   = if ($Script:OrchestratorRoot) { $Script:OrchestratorRoot } else { Join-Path $env:USERPROFILE ".claude-orchestrator" }
    $stateFile  = if ($StateFileOverride)       { $StateFileOverride }       elseif ($Script:StateFile)  { $Script:StateFile }  else { Join-Path $orchRoot "state.json" }
    $configFile = if ($ConfigFileOverride)      { $ConfigFileOverride }      elseif ($Script:ConfigFile) { $Script:ConfigFile } else { Join-Path $orchRoot "config.json" }

    if (-not (Test-Path -LiteralPath $stateFile)) {
        throw "Apply-ProfileSwitch: state.json nao encontrado em $stateFile"
    }
    if (-not (Test-Path -LiteralPath $configFile)) {
        throw "Apply-ProfileSwitch: config.json nao encontrado em $configFile"
    }

    # ── 1. Validar nome do perfil (Task 5 reuse) ──────────────────────────────
    if (Get-Command -Name Test-IsValidProfileName -ErrorAction SilentlyContinue) {
        if (-not (Test-IsValidProfileName -Name $ProfileName)) {
            throw "Apply-ProfileSwitch: nome de perfil invalido '$ProfileName'"
        }
    }

    # ── 2. Resolver config_dir do alvo ────────────────────────────────────────
    $configObj = Read-JsonFile -Path $configFile
    $targetEntry = $configObj.profiles | Where-Object { $_.name -eq $ProfileName } | Select-Object -First 1
    if (-not $targetEntry) {
        throw "Apply-ProfileSwitch: perfil '$ProfileName' nao encontrado em config.json"
    }
    $newProfileDir = $targetEntry.config_dir
    if (-not $newProfileDir) {
        throw "Apply-ProfileSwitch: config_dir ausente para perfil '$ProfileName'"
    }

    # ── 3. Localizar junction 'active' ────────────────────────────────────────
    if ($ProfilesRootOverride) {
        $profilesRoot = $ProfilesRootOverride
    } else {
        $envConfigDir = [System.Environment]::GetEnvironmentVariable("CLAUDE_CONFIG_DIR", "User")
        if ($envConfigDir) {
            $profilesRoot = Split-Path $envConfigDir -Parent
        } else {
            $profilesRoot = Join-Path $env:USERPROFILE ".claude-profiles"
        }
    }
    $activeJunction = Join-Path $profilesRoot "active"

    # ── 4. SNAPSHOT antes de mexer ────────────────────────────────────────────
    # state.json: raw bytes para restauracao byte-identica em caso de rollback
    $stateRaw    = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8
    $stateBefore = $stateRaw | ConvertFrom-Json

    # junction target: $null se a junction nao existir ainda
    $junctionBefore = $null
    if (Test-Path -LiteralPath $activeJunction) {
        try {
            $jItem = Get-Item -LiteralPath $activeJunction -Force -ErrorAction Stop
            if (($jItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                $junctionBefore = $jItem.Target | Select-Object -First 1
            }
        } catch {
            # snapshot best-effort; se falhar, $junctionBefore = $null
            $null = $_
        }
    }

    if ($DryRun) {
        Write-Log "[DRY-RUN] Apply-ProfileSwitch: trocaria junction para $ProfileName ($newProfileDir)"
        return [pscustomobject]@{
            DryRun         = $true
            ProfileName    = $ProfileName
            NewTarget      = $newProfileDir
            JunctionBefore = $junctionBefore
        }
    }

    # ── 5. Tentar a troca ─────────────────────────────────────────────────────
    try {
        # Remover junction existente (apenas se for reparse point)
        if (Test-Path -LiteralPath $activeJunction) {
            $jItem = Get-Item -LiteralPath $activeJunction -Force
            if (($jItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                [System.IO.Directory]::Delete($activeJunction, $false)
            }
        }

        # Criar nova junction. -ErrorAction Stop garante que mocks que
        # `throw` sejam capturados pelo catch.
        New-Item -ItemType Junction -Path $activeJunction -Target $newProfileDir -ErrorAction Stop | Out-Null

        # Atualizar state.json: marcar novo perfil como active_profile
        $store = Read-JsonFile -Path $stateFile
        if ($store.profiles -and $store.profiles.PSObject.Properties[$ProfileName]) {
            $store.profiles.$ProfileName.state = 'available'
        }
        $store.active_profile = $ProfileName
        $store.updatedAt      = (Get-Date).ToUniversalTime().ToString("o")
        Save-JsonFile -Path $stateFile -Data $store

        return [pscustomobject]@{
            DryRun         = $false
            ProfileName    = $ProfileName
            NewTarget      = $newProfileDir
            JunctionBefore = $junctionBefore
        }
    } catch {
        $errMsg = $_.Exception.Message

        # ── Rollback ─────────────────────────────────────────────────────────
        if ($Script:HasStructuredLogger) {
            try {
                Write-StructuredLog -Path $Script:JsonLogFile -Event 'rollback' -Level 'error' -Properties @{
                    target         = $ProfileName
                    newTarget      = $newProfileDir
                    junctionBefore = $junctionBefore
                    reason         = $errMsg
                }
            } catch {
                $null = $_
            }
        }

        # 1) Restaurar junction antiga
        if ($junctionBefore) {
            try {
                if (Test-Path -LiteralPath $activeJunction) {
                    $jItem = Get-Item -LiteralPath $activeJunction -Force -ErrorAction SilentlyContinue
                    if ($jItem -and (($jItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
                        [System.IO.Directory]::Delete($activeJunction, $false)
                    }
                }
                # Usar -ErrorAction SilentlyContinue para nao mascarar a
                # excecao original quando a recriacao tambem falha.
                New-Item -ItemType Junction -Path $activeJunction -Target $junctionBefore -ErrorAction SilentlyContinue | Out-Null
            } catch {
                $null = $_
            }
        }

        # 2) Restaurar state.json byte-identico ao snapshot
        try {
            Set-Content -LiteralPath $stateFile -Value $stateRaw -Encoding UTF8 -NoNewline
        } catch {
            $null = $_
        }

        # 3) Re-throw para que o caller saiba que falhou
        throw
    }
}

function ConvertFrom-UnixTimestamp {
    param([long]$Timestamp)
    return [System.DateTimeOffset]::FromUnixTimeSeconds($Timestamp).UtcDateTime
}

function Show-RotationToast {
    param([string]$Title, [string]$Message)
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType=WindowsRuntime] | Out-Null
        $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
            [Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $template.SelectSingleNode('//text[@id=1]').InnerText = $Title
        $template.SelectSingleNode('//text[@id=2]').InnerText = $Message
        $toast = [Windows.UI.Notifications.ToastNotification]::new($template)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Claude Auto-Rotate').Show($toast)
    } catch {
        Write-Log "Toast nao disponivel: $_" "WARN"
    }
}

# ── Task 3: CLI helpers (Status / List / Preview / Switch) ────────────────────
# Estes helpers leem state.json/config.json/latest.json diretamente — mesmas
# fontes de verdade do modo automatico — para manter auto-rotate.ps1 standalone
# (sem depender de dot-source de manage-skills.ps1). A funcao
# `Find-NextAvailableProfile` e a versao "silenciosa" do loop de selecao
# principal (linhas ~511-548); usada por Show-Preview e tambem pode ser
# reusada futuramente (Task 7) sem o ruido de Write-Log do modo automatico.
function Get-ActiveProfileFromJunction {
    # Resolve nome de perfil ativo a partir do CLAUDE_CONFIG_DIR / junction 'active'.
    # Trata 3 cenarios:
    #   1. Path eh junction NTFS -> retorna leaf do TARGET real (ex: claude-a)
    #      e nao do path da junction (que seria 'active' e quebraria validacao).
    #   2. Path eh diretorio comum -> retorna leaf do proprio path.
    #   3. Path inacessivel ou leaf ainda resolve para 'active' (junction
    #      orfa/sendo recriada) -> fallback para state.active_profile.
    # O parametro -ConfigDir permite override em testes; default usa a junction
    # canonica em ~/.claude-profiles/active.
    param(
        [string]$ConfigDir = (Join-Path $env:USERPROFILE ".claude-profiles\active")
    )
    if ([string]::IsNullOrWhiteSpace($ConfigDir)) { return $null }

    $resolved = $ConfigDir
    if (Test-Path -LiteralPath $ConfigDir) {
        try {
            $item = Get-Item -LiteralPath $ConfigDir -Force -ErrorAction Stop
            if ($item.LinkType -in @('Junction','SymbolicLink') -and $item.Target) {
                $target = if ($item.Target -is [array]) { $item.Target[0] } else { [string]$item.Target }
                if ($target) {
                    # Strip Windows internal NT-namespace prefixes ('\??\', '\\?\')
                    if ($target.StartsWith('\??\'))  { $target = $target.Substring(4) }
                    elseif ($target.StartsWith('\\?\')) { $target = $target.Substring(4) }
                    $resolved = $target
                }
            }
        } catch {
            # silent: caller resolve fallback via state.active_profile
            $null = $_
        }
    }

    $name = Split-Path -Leaf $resolved
    if ([string]::IsNullOrWhiteSpace($name) -or $name -eq 'active') {
        # Resolution failed or junction still points to itself (e.g. orfa).
        # Fallback: ler state.active_profile como source-of-truth.
        try {
            $stateFile = Join-Path $env:USERPROFILE '.claude-orchestrator\state.json'
            if (Test-Path -LiteralPath $stateFile) {
                $st = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($st.active_profile) { return [string]$st.active_profile }
            }
        } catch {
            $null = $_
        }
        return $null
    }
    return $name
}

function Get-ProfileUsageSnapshot {
    param([Parameter(Mandatory)][string]$ProfileName)
    $latestPath = Join-Path $UsageRoot "$ProfileName\latest.json"
    if (-not (Test-Path -LiteralPath $latestPath)) { return $null }
    try {
        return Read-JsonFile -Path $latestPath
    } catch {
        return $null
    }
}

function Find-NextAvailableProfile {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)]$Config,
        [string]$ActiveProfile,
        [datetime]$Now = ([System.DateTime]::UtcNow)
    )
    $candidateProfiles = @($Config.profiles)
    foreach ($prof in $candidateProfiles) {
        $name = $prof.name
        if ($ActiveProfile -and $name -eq $ActiveProfile) { continue }
        $pState = $State.profiles.$name
        if (-not $pState) { continue }
        if (-not $pState.loggedIn) { continue }
        if ($pState.cooldownUntil) {
            try {
                $until = ConvertTo-UtcDateTime -IsoString $pState.cooldownUntil
                if ($until -gt $Now) { continue }
            } catch {
                continue
            }
        }
        if ($pState.state -notin @("available", "cooldown")) { continue }
        return [pscustomobject]@{
            Name      = $name
            ConfigDir = $prof.config_dir
        }
    }
    return $null
}

function Show-Status {
    if (-not (Test-Path -LiteralPath $StateFile)) {
        Write-Host "Active: <unknown> (state.json not found at $StateFile)" -ForegroundColor Yellow
        return
    }
    $stateObj = Read-JsonFile -Path $StateFile
    $active = Get-ActiveProfileFromJunction
    if (-not $active) {
        $active = if ($stateObj.active_profile) { [string]$stateObj.active_profile } else { '<unknown>' }
    }
    Write-Host ""
    Write-Host "Active: $active" -ForegroundColor Cyan
    $snapshot = Get-ProfileUsageSnapshot -ProfileName $active
    if ($snapshot -and $snapshot.rateLimits) {
        $five  = $snapshot.rateLimits.fiveHour
        $seven = $snapshot.rateLimits.sevenDay
        $fiveResets  = if ($five.resetsAt)  { (ConvertFrom-UnixTimestamp -Timestamp ([long]$five.resetsAt)).ToString('o') }  else { 'n/a' }
        $sevenResets = if ($seven.resetsAt) { (ConvertFrom-UnixTimestamp -Timestamp ([long]$seven.resetsAt)).ToString('o') } else { 'n/a' }
        Write-Host ("  5h:  {0}%  resets {1}" -f [int]$five.usedPercentage,  $fiveResets)
        Write-Host ("  7d:  {0}%  resets {1}" -f [int]$seven.usedPercentage, $sevenResets)
    } else {
        # Fallback sem snapshot: mostrar o estado em state.json
        $pState = $stateObj.profiles.$active
        if ($pState) {
            $cd = if ($pState.cooldownUntil) { [string]$pState.cooldownUntil } else { 'none' }
            Write-Host ("  state: {0}  cooldownUntil: {1}" -f $pState.state, $cd)
        }
        Write-Host "  5h:  0%  (no usage snapshot)"
        Write-Host "  7d:  0%  (no usage snapshot)"
    }
}

function Show-List {
    if (-not (Test-Path -LiteralPath $StateFile)) {
        Write-Host "state.json not found at $StateFile" -ForegroundColor Yellow
        return
    }
    $stateObj = Read-JsonFile -Path $StateFile
    Write-Host ""
    "{0,-12} {1,-15} {2,-32} {3}" -f "Profile","State","CooldownUntil","LastFailureKind" | Write-Host
    "{0,-12} {1,-15} {2,-32} {3}" -f "-------","-----","-------------","---------------" | Write-Host
    foreach ($prop in $stateObj.profiles.PSObject.Properties | Sort-Object Name) {
        $p   = $prop.Value
        $name = $prop.Name
        $st  = if ($p.state)           { [string]$p.state }           else { '' }
        $cd  = if ($p.cooldownUntil)   { [string]$p.cooldownUntil }   else { '' }
        $lfk = if ($p.lastFailureKind) { [string]$p.lastFailureKind } else { '' }
        "{0,-12} {1,-15} {2,-32} {3}" -f $name, $st, $cd, $lfk | Write-Host
    }
}

function Show-Preview {
    if (-not (Test-Path -LiteralPath $StateFile)) {
        Write-Host "state.json not found at $StateFile" -ForegroundColor Yellow
        return
    }
    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        Write-Host "config.json not found at $ConfigFile" -ForegroundColor Yellow
        return
    }
    $stateObj  = Read-JsonFile -Path $StateFile
    $configObj = Read-JsonFile -Path $ConfigFile
    $active = Get-ActiveProfileFromJunction
    if (-not $active -and $stateObj.active_profile) { $active = [string]$stateObj.active_profile }
    $next = Find-NextAvailableProfile -State $stateObj -Config $configObj -ActiveProfile $active
    Write-Host ""
    if ($next) {
        Write-Host ("Active:                          {0}" -f $active) -ForegroundColor Cyan
        Write-Host ("Next available profile would be: {0}" -f $next.Name) -ForegroundColor Yellow
        Write-Host ("                                 {0}" -f $next.ConfigDir)
        Write-Host "(use -Force or -Switch $($next.Name) to apply)"
    } else {
        Write-Host "No available profile to rotate to (all in cooldown / not logged in)." -ForegroundColor Red
    }
}

# Wrapper CLI sobre Apply-ProfileSwitch (Task 6) que adiciona:
#  - log estruturado 'rotate' com triggerReason='manual-switch' ANTES de aplicar
#  - mensagens de Write-Host para feedback no terminal
#  - retorno limpo via 'return' para nao continuar no modo automatico
function Invoke-CliProfileSwitch {
    param(
        [Parameter(Mandatory)][string]$ProfileName,
        [switch]$DryRun
    )
    if (-not (Test-IsValidProfileName -Name $ProfileName)) {
        Write-Host "Invalid profile name: '$ProfileName' (esperado claude-[a-z])" -ForegroundColor Red
        return
    }
    $stateObj = if (Test-Path -LiteralPath $StateFile) { Read-JsonFile -Path $StateFile } else { $null }
    $fromProfile = Get-ActiveProfileFromJunction
    if (-not $fromProfile -and $stateObj -and $stateObj.active_profile) {
        $fromProfile = [string]$stateObj.active_profile
    }

    Write-Host ""
    Write-Host ("[CLI -Switch] {0} -> {1}{2}" -f $fromProfile, $ProfileName, $(if ($DryRun) { ' (dry-run)' } else { '' })) -ForegroundColor Cyan

    $applyOk = $false
    try {
        $result = Apply-ProfileSwitch -ProfileName $ProfileName -DryRun:$DryRun
        $applyOk = $true
        if ($DryRun) {
            Write-Host "[DRY-RUN] junction nao foi tocada; state.json intacto." -ForegroundColor Yellow
        } else {
            Write-Host ("OK -> active aponta para {0}" -f $result.NewTarget) -ForegroundColor Green
        }
    } catch {
        Write-Host ("FAIL: {0}" -f $_.Exception.Message) -ForegroundColor Red
        # Apply-ProfileSwitch ja escreveu evento 'rollback'; nao reabrir excecao
        # para nao quebrar o terminal interativo.
    }

    # Log estruturado do evento DEPOIS de aplicar para garantir que o evento
    # 'rotate' fique como ultima linha em rotation.jsonl (Apply-ProfileSwitch
    # internamente chama Write-Log que ja escreve um evento 'log' generico).
    # Em caso de falha ainda emitimos 'rotate' com applied=false para deixar
    # o intent registrado proximo do 'rollback' que Apply-ProfileSwitch emitiu.
    if ($Script:HasStructuredLogger) {
        try {
            Write-StructuredLog -Path $Script:JsonLogFile -Event 'rotate' -Level 'info' -Properties @{
                from          = $fromProfile
                to            = $ProfileName
                triggerReason = 'manual-switch'
                dryRun        = [bool]$DryRun
                applied       = [bool]$applyOk
            }
        } catch {
            $null = $_
        }
    }
}

# ── Garantir que diretorio de logs existe ──────────────────────────────────────
$logDir = Split-Path $LogFile -Parent
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

# ── Task 3: dispatch de modos CLI ─────────────────────────────────────────────
# Os modos -Status / -List / -Preview / -Switch sao mutuamente exclusivos com
# o modo automatico (Task Scheduler). Eles imprimem informacao OU aplicam um
# switch manual e saem (exit 0) — nao caem no fluxo principal de rotacao.
# Importante: este branch fica DEPOIS da criacao do diretorio de logs (para
# que Write-StructuredLog tenha onde escrever) e ANTES de Write-Log "iniciado"
# (para nao poluir rotation.log/jsonl com mensagens de modo automatico).
if ($Status)  { Show-Status;  exit 0 }
if ($List)    { Show-List;    exit 0 }
if ($Preview) { Show-Preview; exit 0 }
if ($Switch)  {
    Invoke-CliProfileSwitch -ProfileName $Switch -DryRun:$DryRun
    exit 0
}

Write-Log "auto-rotate iniciado (threshold=$Threshold%$(if ($DryRun) {', dry-run'})$(if ($Force) {', FORCE'}))"

# ── Ler state.json ─────────────────────────────────────────────────────────────
if (-not (Test-Path -LiteralPath $StateFile)) {
    Write-Log "state.json nao encontrado: $StateFile" "ERROR"
    exit 1
}
$state = Read-JsonFile -Path $StateFile
$now   = [System.DateTime]::UtcNow

# ── 1. Reset de cooldowns expirados ───────────────────────────────────────────
$resetted = @()
foreach ($prop in $state.profiles.PSObject.Properties) {
    $p = $prop.Value
    if ($p.state -eq "cooldown" -and $p.cooldownUntil) {
        $until = ConvertTo-UtcDateTime -IsoString $p.cooldownUntil
        if ($until -le $now) {
            Write-Log "Cooldown expirado para $($p.profileId) — restaurando para available"
            if (-not $DryRun) {
                $p.state        = "available"
                $p.cooldownUntil = $null
            }
            $resetted += $p.profileId
        }
    }
}

# ── 2. Identificar perfil ativo via CLAUDE_CONFIG_DIR ─────────────────────────
$configDir = [System.Environment]::GetEnvironmentVariable("CLAUDE_CONFIG_DIR", "User")
if (-not $configDir) {
    Write-Log "CLAUDE_CONFIG_DIR nao definido — usando claude-a como fallback" "WARN"
    $configDir = Join-Path $env:USERPROFILE ".claude-profiles\claude-a"
}

# Extrair nome do perfil do caminho (ex: ...claude-profiles\claude-a => claude-a)
# BUG-A: usa Test-IsValidProfileName (case-insensitive) em vez de regex literal
# para nao rejeitar Claude-A / CLAUDE-A em paths em maiusculo.
# BUG-D (junction resolution): se CLAUDE_CONFIG_DIR aponta para a junction
# 'active', um split simples retorna 'active' (que falha em Test-IsValidProfileName).
# Get-ActiveProfileFromJunction resolve o target NTFS real e cai para
# state.active_profile se a junction estiver orfa.
$activeProfile = Get-ActiveProfileFromJunction -ConfigDir $configDir
if (-not $activeProfile) {
    # Fallback secundario: split tradicional (compativel com paths sem junction
    # como o claude-a fallback definido logo acima quando CLAUDE_CONFIG_DIR e nulo).
    $activeProfile = ($configDir -split '[/\\]' | Where-Object { Test-IsValidProfileName $_ } | Select-Object -Last 1)
}
if (-not $activeProfile) {
    Write-Log "Nao foi possivel extrair nome do perfil de: $configDir" "ERROR"
    exit 1
}

Write-Log "Perfil ativo: $activeProfile (CLAUDE_CONFIG_DIR=$configDir)"

# ── 3. Ler latest.json do perfil ativo ────────────────────────────────────────
$latestPath = Join-Path $UsageRoot "$activeProfile\latest.json"
if (-not (Test-Path -LiteralPath $latestPath)) {
    Write-Log "latest.json nao encontrado para $activeProfile — nada a fazer" "WARN"
    if ($resetted.Count -gt 0 -and -not $DryRun) {
        $state.updatedAt = $now.ToString("o")
        Save-JsonFile -Path $StateFile -Data $state
    }
    exit 0
}

$latest    = Read-JsonFile -Path $latestPath
$fiveHour  = $latest.rateLimits.fiveHour
$sevenDay  = $latest.rateLimits.sevenDay
$fivePct   = [double]($fiveHour.usedPercentage)
$sevenPct  = [double]($sevenDay.usedPercentage)

# Verificar idade do snapshot
$snapshotAge = $null
$snapshotField = if ($latest.rateLimitsSeenAt) { $latest.rateLimitsSeenAt } elseif ($latest.lastSeenAt) { $latest.lastSeenAt } else { $latest.observedAt }
if ($snapshotField) {
    try {
        $snapshotDt  = ConvertTo-UtcDateTime -IsoString $snapshotField
        $snapshotAge = [int]($now - $snapshotDt).TotalMinutes
        if ($snapshotAge -gt 30 -and -not $Force) {
            Write-Log "AVISO: dados de $activeProfile com $snapshotAge min de idade — valores podem estar desatualizados. Use -Force para rotar manualmente." "WARN"
        }
    } catch {
        if ($Script:HasStructuredLogger) {
            try {
                Write-StructuredLog -Path $Script:JsonLogFile -Event 'silent-catch' -Level 'warn' -Properties @{
                    location = 'auto-rotate.ps1:241'
                    reason   = $_.Exception.Message
                    note     = 'snapshot-age-calc-failed'
                }
            } catch {
                # silent: nested logger failure on warn path
                $null = $_
            }
        }
    }
}

$ageLabel = if ($null -ne $snapshotAge) { " (dados com ${snapshotAge}min)" } else { "" }
Write-Log "Uso atual de $activeProfile — 5h: $fivePct% | 7d: $sevenPct%$ageLabel"

# ── 4. Verificar se rotacao e necessaria ──────────────────────────────────────
$triggerLimit  = $null
$triggerPct    = 0

if ($Force) {
    $triggerLimit = "FORCE"
    $triggerPct   = $fivePct
    Write-Log "Rotacao forcada manualmente — ignorando threshold" "WARN"
} elseif ($fivePct -ge $Threshold) {
    $triggerLimit = "5h"
    $triggerPct   = $fivePct
} elseif ($sevenPct -ge $Threshold) {
    $triggerLimit = "7d"
    $triggerPct   = $sevenPct
}

if (-not $triggerLimit) {
    Write-Log "Uso 5h ($fivePct%) e 7d ($sevenPct%) abaixo do threshold ($Threshold%) — sem rotacao necessaria"
    if ($resetted.Count -gt 0 -and -not $DryRun) {
        $state.updatedAt = $now.ToString("o")
        Save-JsonFile -Path $StateFile -Data $state
    }
    exit 0
}

if (-not $Force) {
    Write-Log "THRESHOLD ATINGIDO: $triggerLimit $triggerPct% >= $Threshold% — iniciando rotacao" "WARN"
}

# Structured event: threshold check resolved -> rotation will be attempted
if ($Script:HasStructuredLogger) {
    try {
        Write-StructuredLog -Path $Script:JsonLogFile -Event 'threshold-trigger' -Level 'warn' -Properties @{
            from          = $activeProfile
            usedPct       = $triggerPct
            window        = $triggerLimit
            threshold     = $Threshold
            triggerReason = if ($Force) { 'manual-force' } else { 'threshold' }
            dryRun        = [bool]$DryRun
        }
    } catch {
        # silent: structured logger best-effort para evento 'rotate-decision'; logging nao deve interromper rotacao
        $null = $_
    }
}

# ── 5. Encontrar proximo perfil disponivel ────────────────────────────────────
$config   = Read-JsonFile -Path $ConfigFile
$profiles = @($config.profiles)  # array ordenado do config.json

$nextProfile    = $null
$nextConfigDir  = $null

foreach ($prof in $profiles) {
    $name = $prof.name
    if ($name -eq $activeProfile) { continue }

    $pState = $state.profiles.$name
    if (-not $pState) {
        Write-Log "Perfil $name esta no config.json mas nao em state.json — ignorando" "WARN"
        continue
    }

    # Checar loggedIn
    if (-not $pState.loggedIn) {
        Write-Log "Perfil $name nao esta logado — pulando"
        continue
    }

    # Checar cooldown
    if ($pState.cooldownUntil) {
        $until = ConvertTo-UtcDateTime -IsoString $pState.cooldownUntil
        if ($until -gt $now) {
            $remaining = [int]($until - $now).TotalMinutes
            Write-Log "Perfil $name em cooldown por mais $remaining min — pulando"
            continue
        }
    }

    # Checar state
    if ($pState.state -notin @("available", "cooldown")) {
        # auth_required ou outro estado invalido
        Write-Log "Perfil $name em estado '$($pState.state)' — pulando"
        continue
    }

    # Candidato valido
    $nextProfile   = $name
    $nextConfigDir = $prof.config_dir
    break
}

if (-not $nextProfile) {
    $msg = "TODOS OS PERFIS EM COOLDOWN ou indisponiveis — nao e possivel rotar"
    Write-Log $msg "ERROR"
    if (-not $DryRun) {
        Show-RotationToast "Claude: limite atingido" "Todos os perfis em cooldown. Limite $triggerLimit : $triggerPct%"
        if ($resetted.Count -gt 0) {
            $state.updatedAt = $now.ToString("o")
            Save-JsonFile -Path $StateFile -Data $state
        }
    }
    exit 2
}

Write-Log "Proximo perfil selecionado: $nextProfile ($nextConfigDir)"

# ── 6. Aplicar rotacao ────────────────────────────────────────────────────────
if ($DryRun) {
    Write-Log "[DRY-RUN] Trocaria CLAUDE_CONFIG_DIR para $nextConfigDir"
    Write-Log "[DRY-RUN] Marcaria $activeProfile com cooldown ate $(ConvertFrom-UnixTimestamp -Timestamp $fiveHour.resetsAt)"
    exit 0
}

# 6a. Calcular cooldownUntil: usa resetsAt do limite que disparou a rotacao
$cooldownUntil = $null
$resetsAtSrc   = if ($triggerLimit -eq "7d") { $sevenDay.resetsAt } else { $fiveHour.resetsAt }

if ($resetsAtSrc) {
    $resetDt       = ConvertFrom-UnixTimestamp -Timestamp ([long]$resetsAtSrc)
    $cooldownUntil = $resetDt.ToString("o")
    Write-Log "Cooldown de $activeProfile ate $cooldownUntil (resetsAt=$resetsAtSrc, limite=$triggerLimit)"
} else {
    # Fallback: 5 horas a partir de agora
    $cooldownUntil = $now.AddHours(5).ToString("o")
    Write-Log "resetsAt ausente — usando fallback: cooldown por 5h" "WARN"
}

# Structured event: cooldown decided for outgoing profile
if ($Script:HasStructuredLogger) {
    try {
        Write-StructuredLog -Path $Script:JsonLogFile -Event 'cooldown-set' -Level 'info' -Properties @{
            profile        = $activeProfile
            cooldownUntil  = $cooldownUntil
            window         = $triggerLimit
            resetsAtSource = if ($resetsAtSrc) { [long]$resetsAtSrc } else { $null }
            fallback       = (-not $resetsAtSrc)
        }
    } catch {
        # silent: structured logger best-effort para evento 'cooldown-set'; logging nao deve interromper rotacao
        $null = $_
    }
}

# 6b. Atualizar state.json: marcar perfil ativo como cooldown
$activeState               = $state.profiles.$activeProfile
$activeState.state         = "cooldown"
$activeState.cooldownUntil = $cooldownUntil

# 6c. Atualizar junction 'active' para o novo perfil (hot-swap sem alterar CLAUDE_CONFIG_DIR)
$profilesRoot = Split-Path $configDir -Parent
$activeLink   = Join-Path $profilesRoot "active"

# Garantir que CLAUDE_CONFIG_DIR aponta para a junction (valor fixo)
$envVal = [System.Environment]::GetEnvironmentVariable("CLAUDE_CONFIG_DIR", "User")
if ($envVal -ne $activeLink) {
    [System.Environment]::SetEnvironmentVariable("CLAUDE_CONFIG_DIR", $activeLink, "User")
    Write-Log "CLAUDE_CONFIG_DIR fixado em $activeLink"
}

# Recriar junction apontando para o novo perfil — protegido por mutex global
# para evitar race entre instancias concorrentes (Task Scheduler + manual).
# Quando o lock nao e adquirido em 30s, logamos 'lock-timeout' e abortamos sem
# aplicar — outra instancia ja esta rotacionando.
$Script:LockHandle = $null
try {
    if ($Script:HasFileLock) {
        $Script:LockHandle = Acquire-FileLock -Name 'claude-profile-swap' -Timeout 30
    }

    if (Test-Path -LiteralPath $activeLink) {
        $jItem = Get-Item -LiteralPath $activeLink -Force
        if (($jItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            [System.IO.Directory]::Delete($activeLink, $false)
        }
    }
    New-Item -ItemType Junction -Path $activeLink -Target $nextConfigDir | Out-Null
    Write-Log "Junction atualizada: active -> $nextProfile ($nextConfigDir)"

    # Structured event: actual rotation applied (junction swapped)
    if ($Script:HasStructuredLogger) {
        try {
            Write-StructuredLog -Path $Script:JsonLogFile -Event 'rotate' -Level 'info' -Properties @{
                from          = $activeProfile
                to            = $nextProfile
                usedPct       = $triggerPct
                window        = $triggerLimit
                triggerReason = if ($Force) { 'manual-force' } else { 'threshold' }
                target        = $nextConfigDir
                junction      = $activeLink
            }
        } catch {
            # silent: structured logger best-effort para evento 'rotate'; logging nao deve interromper rotacao
            $null = $_
        }
    }
} catch [System.TimeoutException] {
    Write-Log "Lock 'claude-profile-swap' nao adquirido em 30s — outra instancia esta rotacionando. Abortando." "WARN"
    if ($Script:HasStructuredLogger) {
        try {
            Write-StructuredLog -Path $Script:JsonLogFile -Event 'lock-timeout' -Level 'warn' -Properties @{
                lock    = 'claude-profile-swap'
                timeout = 30
                from    = $activeProfile
                to      = $nextProfile
            }
        } catch {
            $null = $_
        }
    }
    return
} finally {
    if ($Script:LockHandle) {
        Release-FileLock -Handle $Script:LockHandle
        $Script:LockHandle = $null
    }
}

# Atualizar marker sem BOM
$markerPath = Join-Path $env:USERPROFILE ".claude-active-dir"
[System.IO.File]::WriteAllText($markerPath, $activeLink, (New-Object System.Text.UTF8Encoding $false))

# 6d. Atualizar active_profile no state.json
$state.active_profile = $nextProfile
$state.updatedAt      = $now.ToString("o")
Save-JsonFile -Path $StateFile -Data $state

Write-Log "ROTACAO CONCLUIDA: $activeProfile -> $nextProfile" "INFO"
Write-Log "Cooldown de $activeProfile ate $cooldownUntil" "INFO"
Write-Log "Novos terminais usarao perfil: $nextProfile"

Show-RotationToast "Claude: perfil trocado" "$activeProfile -> $nextProfile  ($triggerLimit : $triggerPct%)"
