# AI-Skills-Hub Evolution D — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax. Each task has an **Implementation agent** and **Validation agent** assigned. Validation agent NEVER implements — only verifies via Pester tests + manual checks.

**Goal:** Evoluir o AI-Skills-Hub V1 sem migrar — corrigir bugs, portar 3 features de teamclaude/ccpi/ccpm, separar fisicamente skills ↔ auth, e desabilitar auto-rotate até que toggle UI esteja pronto.

**Architecture:** PowerShell 7 + Pester 5 (testes), arquitetura mantém-se Windows-first com junctions NTFS. Split físico: `~\Diego\skill-manager\` (porta 8765) + `~\Diego\claude-auth-manager\` (porta 8766) + `~\Diego\aiox-shared\` (helpers comuns importados via `using module`). Auto-rotate fica desligado por default; UI ganha toggle persistido em `~/.claude-orchestrator/config.json`.

**Tech Stack:** PowerShell 7+, Pester 5.x, .NET 8 [System.Threading.Mutex], JSON-lines logging, Windows Task Scheduler (já configurado).

**Validation strategy:** Cada task tem 2 fases: Implementation (agent A escreve código + testes Pester) e Validation (agent B roda testes em ambiente limpo, valida outputs reais, e só aprova se cobertura ≥ 80% das linhas tocadas).

**Pre-requisites:**
- Pester 5: `Install-Module Pester -MinimumVersion 5.0 -Force -SkipPublisherCheck`
- aiox-core 5.0.8: já instalado globalmente
- superpowers v5.1.0: já instalado

---

## File Structure

```
~\Diego\
├── skill-manager\              (NOVO — pasta separada)
│   ├── skill-manager.bat
│   ├── skill-manager.ps1       (renomeado de manage-skills.ps1, sem AUTH)
│   ├── ui\index.html
│   ├── all-skills\             (junction → AI-Skills-Hub-LEGACY\all-skills)
│   ├── tests\                  (Pester)
│   │   ├── SkillManager.Tests.ps1
│   │   └── FrontmatterValidator.Tests.ps1
│   └── lib\
│       ├── frontmatter-validator.ps1   (NOVO — port ccpm)
│       └── upstream-importer.ps1       (NOVO — port ccpi)
│
├── claude-auth-manager\        (NOVO — pasta separada)
│   ├── claude-auth-manager.bat
│   ├── claude-auth-manager.ps1 (auth + auto-rotate, multi-CLI)
│   ├── ui\index.html
│   ├── auto-rotate.ps1
│   ├── auto-rotate-codex.ps1
│   ├── auto-rotate-gemini.ps1  (NOVO — Task 7)
│   ├── auto-rotate-qwen.ps1    (NOVO — Task 7)
│   ├── tests\
│   │   ├── AutoRotate.Tests.ps1
│   │   ├── ProfileSelector.Tests.ps1
│   │   ├── OAuthRefresh.Tests.ps1
│   │   └── RollbackOnFailure.Tests.ps1
│   └── lib\
│       ├── cli-runtime.ps1     (NOVO — abstração CliType)
│       ├── oauth-refresh.ps1   (NOVO — port teamclaude)
│       └── structured-logger.ps1 (NOVO — JSON-lines)
│
├── aiox-shared\                (NOVO — helpers comuns)
│   ├── PathHelpers.psm1        (Normalize-FullPath, Join-UserProfilePath)
│   ├── HttpHelpers.psm1        (Set-NoCacheHeaders, Write-JsonResponse)
│   ├── FileHelpers.psm1        (Set-FileAtomic, Write-Utf8File, Write-JsonFile)
│   ├── Mutex.psm1              (NOVO — Acquire/Release-FileLock)
│   └── tests\
│       ├── PathHelpers.Tests.ps1
│       └── Mutex.Tests.ps1
│
└── AI-Skills-Hub-LEGACY\       (renomeado do AI-Skills-Hub atual — só leitura, não tocar)
```

**Migration path:** AI-Skills-Hub-LEGACY mantém Syncthing folder ativo (`ai-skills-hub` aponta pra ele). skill-manager e claude-auth-manager **lêem** de lá via junctions — quando estiverem 100% validados, o folder Syncthing é repointado pra cá e o LEGACY é arquivado.

---

## Task 1: Desabilitar auto-rotate por default + toggle UI

**Files:**
- Modify: `C:\Users\marce\Diego\AI-Skills-Hub\manage-skills.ps1` (Start-ClaudeAuthUI por linha 4489+)
- Modify: `C:\Users\marce\Diego\AI-Skills-Hub\ui\claude-auth.html`
- Create: `C:\Users\marce\Diego\AI-Skills-Hub\tests\AutoRotateToggle.Tests.ps1`
- Read state from: `~/.claude-orchestrator/config.json` (campo novo `autoRotateEnabled: false`)

**Implementation agent:** subagent-driven-development com persona de "Backend Developer"
**Validation agent:** subagent-driven-development com persona "QA Engineer"

- [ ] **Step 1: Confirmar que tasks ScheduledTask estão Disabled**

Run:
```powershell
Get-ScheduledTask -TaskName 'ClaudeAutoRotate','CodexAutoRotate' | Select-Object TaskName, State
```
Expected:
```
TaskName            State
--------            -----
ClaudeAutoRotate    Disabled
CodexAutoRotate     Disabled
```

- [ ] **Step 2: Escrever teste Pester para campo `autoRotateEnabled` no config**

```powershell
# tests/AutoRotateToggle.Tests.ps1
BeforeAll {
    . "$PSScriptRoot/../manage-skills.ps1"
}

Describe "Auto-rotate toggle" {
    It "Defaults autoRotateEnabled to false when config is fresh" {
        $tmp = New-TemporaryFile
        $config = Ensure-ClaudeOrchestratorConfig -ConfigPath $tmp
        $config.autoRotateEnabled | Should -Be $false
    }

    It "Persists autoRotateEnabled=true after Save-ClaudeOrchestratorConfig" {
        $tmp = New-TemporaryFile
        $config = Ensure-ClaudeOrchestratorConfig -ConfigPath $tmp
        $config.autoRotateEnabled = $true
        Save-ClaudeOrchestratorConfig -Config $config -ConfigPath $tmp
        $reloaded = Get-ClaudeOrchestratorConfig -ConfigPath $tmp
        $reloaded.autoRotateEnabled | Should -Be $true
    }
}
```

- [ ] **Step 3: Rodar teste — esperado FAIL (campo ainda não existe)**

Run: `Invoke-Pester ./tests/AutoRotateToggle.Tests.ps1 -Output Detailed`
Expected: 2 testes failing — "autoRotateEnabled is not a property"

- [ ] **Step 4: Adicionar campo `autoRotateEnabled` em Ensure-ClaudeOrchestratorConfig (linha 1368)**

```powershell
function Ensure-ClaudeOrchestratorConfig {
    param([string]$ConfigPath = (Get-ClaudeOrchestratorConfigPath))
    if (Test-Path -LiteralPath $ConfigPath) {
        $config = Get-ClaudeOrchestratorConfig -ConfigPath $ConfigPath
    } else {
        $config = [ordered]@{
            version = 1
            profiles = @()
            autoRotateEnabled = $false   # NOVO
        }
    }
    if (-not $config.PSObject.Properties['autoRotateEnabled']) {
        $config | Add-Member -NotePropertyName 'autoRotateEnabled' -NotePropertyValue $false
    }
    return $config
}
```

- [ ] **Step 5: Rodar teste — esperado PASS**

Run: `Invoke-Pester ./tests/AutoRotateToggle.Tests.ps1 -Output Detailed`
Expected: 2/2 PASS

- [ ] **Step 6: Adicionar endpoint POST /api/auto-rotate/toggle em Start-ClaudeAuthUI**

Em `manage-skills.ps1` dentro de Start-ClaudeAuthUI (porta 8766), adicionar antes do bloco `else { $response.StatusCode = 404 }`:

```powershell
elseif ($method -eq "POST" -and $url -eq "/api/auto-rotate/toggle") {
    $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
    $body = ($reader.ReadToEnd() | ConvertFrom-Json)
    $config = Ensure-ClaudeOrchestratorConfig
    $config.autoRotateEnabled = [bool]$body.enabled
    Save-ClaudeOrchestratorConfig -Config $config

    # Aplica imediatamente no Task Scheduler
    foreach ($n in @('ClaudeAutoRotate','CodexAutoRotate')) {
        if ($body.enabled) { Enable-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue | Out-Null }
        else { Disable-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue | Out-Null }
    }

    $resData = @{ enabled = $config.autoRotateEnabled }
    $json = $resData | ConvertTo-Json -Compress
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
    $response.ContentType = "application/json; charset=utf-8"
    $response.ContentLength64 = $buffer.Length
    $response.OutputStream.Write($buffer, 0, $buffer.Length)
}
elseif ($method -eq "GET" -and $url -eq "/api/auto-rotate/status") {
    $config = Ensure-ClaudeOrchestratorConfig
    $resData = @{ enabled = [bool]$config.autoRotateEnabled }
    $json = $resData | ConvertTo-Json -Compress
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
    $response.ContentType = "application/json; charset=utf-8"
    $response.ContentLength64 = $buffer.Length
    $response.OutputStream.Write($buffer, 0, $buffer.Length)
}
```

- [ ] **Step 7: Adicionar toggle visual na claude-auth.html**

Em `ui/claude-auth.html`, adicionar próximo ao topo (depois do header):

```html
<div class="card" style="margin: 8px 0; padding: 12px; border-left: 4px solid #f0ad4e;">
  <label style="display: flex; align-items: center; gap: 8px;">
    <input type="checkbox" id="auto-rotate-toggle" disabled />
    <strong>Auto-rotate</strong> — rotaciona perfil automaticamente quando uso ≥ 95%
  </label>
  <small id="auto-rotate-status" style="color: #888;">carregando...</small>
</div>
<script>
async function loadAutoRotateState() {
  const r = await fetch('/api/auto-rotate/status');
  const j = await r.json();
  document.getElementById('auto-rotate-toggle').checked = j.enabled;
  document.getElementById('auto-rotate-toggle').disabled = false;
  document.getElementById('auto-rotate-status').textContent = j.enabled
    ? 'ATIVO — terminal pode aparecer a cada 10 min'
    : 'DESATIVADO — sem rotação automática';
}
document.getElementById('auto-rotate-toggle').addEventListener('change', async (e) => {
  const r = await fetch('/api/auto-rotate/toggle', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({enabled: e.target.checked})
  });
  const j = await r.json();
  document.getElementById('auto-rotate-status').textContent = j.enabled
    ? 'ATIVO — terminal pode aparecer a cada 10 min'
    : 'DESATIVADO — sem rotação automática';
});
loadAutoRotateState();
</script>
```

- [ ] **Step 8: Teste manual da UI**

Run: `start C:\Users\marce\Diego\AI-Skills-Hub\claude-auth-manager.bat`
Expected: navegador abre em http://localhost:8766/, toggle aparece desativado, status diz "DESATIVADO".
Click toggle → `Get-ScheduledTask ClaudeAutoRotate` retorna State=Ready (Enabled). Click novamente → Disabled.

- [ ] **Step 9: Commit**

```bash
git add manage-skills.ps1 ui/claude-auth.html tests/AutoRotateToggle.Tests.ps1
git commit -m "feat(auth): toggle auto-rotate on/off via UI + Task Scheduler integration"
```

- [ ] **Step 10: Validation agent verifica**

Validation agent abre a UI, alterna toggle 5x, e confirma:
1. ScheduledTask state muda em tempo real (`Get-ScheduledTask | Select State`)
2. config.json persiste o valor (sobrevive reload)
3. Status text na UI bate com estado real do task
4. Pester passa em ambiente limpo (`Invoke-Pester ./tests -Output Detailed`)

---

## Task 2: Logs estruturados JSON-lines (Melhoria #1)

**Files:**
- Create: `aiox-shared\StructuredLogger.psm1`
- Modify: `auto-rotate.ps1` (linha 17-22 — função Write-Log)
- Modify: `auto-rotate-codex.ps1` (linha 13-18)
- Test: `aiox-shared\tests\StructuredLogger.Tests.ps1`

**Implementation:** Backend Developer agent
**Validation:** QA Engineer agent

- [ ] **Step 1: Escrever teste para JSON-lines logger**

```powershell
# aiox-shared/tests/StructuredLogger.Tests.ps1
BeforeAll {
    Import-Module "$PSScriptRoot/../StructuredLogger.psm1" -Force
}

Describe "Write-StructuredLog" {
    BeforeEach {
        $script:logFile = New-TemporaryFile
    }

    It "Writes JSON object per line with required fields" {
        Write-StructuredLog -Path $script:logFile -Event 'rotate' -Properties @{
            from = 'claude-a'; to = 'claude-b'; usedPct = 97
        }
        $line = Get-Content -LiteralPath $script:logFile -Tail 1
        $obj = $line | ConvertFrom-Json
        $obj.event | Should -Be 'rotate'
        $obj.from | Should -Be 'claude-a'
        $obj.to | Should -Be 'claude-b'
        $obj.usedPct | Should -Be 97
        $obj.ts | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
        $obj.level | Should -Be 'info'
    }

    It "Appends — does not overwrite previous entries" {
        Write-StructuredLog -Path $script:logFile -Event 'a'
        Write-StructuredLog -Path $script:logFile -Event 'b'
        $lines = Get-Content -LiteralPath $script:logFile
        $lines.Count | Should -Be 2
    }

    It "Each line is valid standalone JSON" {
        Write-StructuredLog -Path $script:logFile -Event 'rotate' -Level 'warn'
        $line = Get-Content -LiteralPath $script:logFile -Tail 1
        { $line | ConvertFrom-Json } | Should -Not -Throw
    }
}
```

- [ ] **Step 2: Rodar — esperado FAIL (módulo ainda não existe)**

Run: `Invoke-Pester ./aiox-shared/tests/StructuredLogger.Tests.ps1 -Output Detailed`
Expected: import falha "module not found"

- [ ] **Step 3: Implementar StructuredLogger.psm1**

```powershell
# aiox-shared/StructuredLogger.psm1
function Write-StructuredLog {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Event,
        [ValidateSet('info','warn','error','debug')][string]$Level = 'info',
        [hashtable]$Properties = @{}
    )

    $entry = [ordered]@{
        ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        level = $Level
        event = $Event
    }
    foreach ($k in $Properties.Keys) {
        $entry[$k] = $Properties[$k]
    }

    $json = $entry | ConvertTo-Json -Compress -Depth 5
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Add-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

Export-ModuleMember -Function Write-StructuredLog
```

- [ ] **Step 4: Rodar — esperado PASS**

Run: `Invoke-Pester ./aiox-shared/tests/StructuredLogger.Tests.ps1 -Output Detailed`
Expected: 3/3 PASS

- [ ] **Step 5: Substituir Write-Log no auto-rotate.ps1 (linha 17-22)**

```powershell
# auto-rotate.ps1
Import-Module "$PSScriptRoot/../aiox-shared/StructuredLogger.psm1" -Force

# Manter compat: Write-Log antigo agora chama o novo
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $structuredLevel = $Level.ToLowerInvariant()
    if ($structuredLevel -notin @('info','warn','error','debug')) { $structuredLevel = 'info' }
    Write-StructuredLog -Path $Script:JsonLogFile -Event 'log' -Level $structuredLevel -Properties @{ msg = $Message }
    Write-Host "$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) [$Level] $Message"
}

$Script:JsonLogFile = Join-Path $OrchestratorRoot "usage\logs\rotation.jsonl"
```

- [ ] **Step 6: Adicionar eventos estruturados nos pontos críticos do auto-rotate.ps1**

Em vez de `Write-Log "Rotating from $from to $to"`, usar:

```powershell
Write-StructuredLog -Path $Script:JsonLogFile -Event 'rotate' -Properties @{
    from = $from
    to = $to
    usedPct = $usedPct
    window = '5h'  # ou '7d'
    triggerReason = if ($Force) { 'manual-force' } else { 'threshold' }
}
```

Substituir nas linhas 149-154 (threshold check), 252-255 (cooldown set), 268-276 (junction swap).

- [ ] **Step 7: Mesmo no auto-rotate-codex.ps1**

- [ ] **Step 8: Rodar e verificar logs estruturados**

```powershell
$env:FORCE = '1'
& powershell -NoProfile -File ./auto-rotate.ps1 -DryRun
Get-Content "$env:USERPROFILE\.claude-orchestrator\usage\logs\rotation.jsonl" -Tail 5
```
Expected: 5 linhas JSON válido, cada uma parsável com `ConvertFrom-Json`.

- [ ] **Step 9: Commit**

```bash
git add aiox-shared/StructuredLogger.psm1 auto-rotate.ps1 auto-rotate-codex.ps1 aiox-shared/tests/
git commit -m "feat(logs): JSON-lines structured logging in auto-rotate scripts"
```

---

## Task 3: CLI interativo + modo `-Preview` (Melhoria #5)

**Files:**
- Modify: `auto-rotate.ps1` (param block + branching)
- Create: `tests/AutoRotateCli.Tests.ps1`

- [ ] **Step 1: Escrever testes**

```powershell
# tests/AutoRotateCli.Tests.ps1
Describe "auto-rotate CLI modes" {
    It "-Status returns active profile + percent without changes" {
        $output = & pwsh -NoProfile -File ./auto-rotate.ps1 -Status -DryRun 2>&1
        $output | Should -Match 'Active:'
        $output | Should -Match '\d+%'
    }

    It "-List enumerates all profiles with state" {
        $output = & pwsh -NoProfile -File ./auto-rotate.ps1 -List 2>&1
        $output | Should -Match 'claude-a'
        $output | Should -Match '(available|cooldown|auth_required)'
    }

    It "-Preview shows next profile without applying" {
        $before = (Get-Item "$env:USERPROFILE/.claude-profiles/active").Target
        & pwsh -NoProfile -File ./auto-rotate.ps1 -Preview | Out-Null
        $after = (Get-Item "$env:USERPROFILE/.claude-profiles/active").Target
        $after | Should -Be $before
    }

    It "-Switch <profile> changes active and logs structured event" {
        & pwsh -NoProfile -File ./auto-rotate.ps1 -Switch 'claude-b' -DryRun
        $log = Get-Content "$env:USERPROFILE/.claude-orchestrator/usage/logs/rotation.jsonl" -Tail 1 | ConvertFrom-Json
        $log.event | Should -Be 'rotate'
        $log.triggerReason | Should -Be 'manual-switch'
    }
}
```

- [ ] **Step 2: Rodar — FAIL (params não existem)**

- [ ] **Step 3: Adicionar params no auto-rotate.ps1**

```powershell
# auto-rotate.ps1 — bloco param ampliado
param(
    [int]$Threshold = 95,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$Status,
    [switch]$List,
    [switch]$Preview,
    [string]$Switch
)

# Helper de output formatado
function Show-Status {
    $store = Get-ClaudeAccountStateStore
    $active = Get-ActiveClaudeProfileName
    $latest = Get-ClaudeUsageLatestSnapshot -ProfileName $active
    Write-Host ""
    Write-Host "Active: $active" -ForegroundColor Cyan
    Write-Host "  5h:  $($latest.fiveHour.usedPercentage)%  resets $($latest.fiveHour.resetsAt)"
    Write-Host "  7d:  $($latest.sevenDay.usedPercentage)%  resets $($latest.sevenDay.resetsAt)"
}

function Show-List {
    $store = Get-ClaudeAccountStateStore
    Write-Host ""
    "{0,-12} {1,-15} {2,-25} {3}" -f "Profile","State","CooldownUntil","LastFailureKind" | Write-Host
    "{0,-12} {1,-15} {2,-25} {3}" -f "-------","-----","-------------","---------------" | Write-Host
    foreach ($p in $store.profiles.Values | Sort-Object profileId) {
        "{0,-12} {1,-15} {2,-25} {3}" -f $p.profileId, $p.state, $p.cooldownUntil, $p.lastFailureKind | Write-Host
    }
}

function Show-Preview {
    $next = Find-NextAvailableProfile  # função extraída na Task 4
    Write-Host ""
    Write-Host "Next available profile would be: $next" -ForegroundColor Yellow
    Write-Host "(use -Force or -Switch $next to apply)"
}

# Branching de modos no topo, antes da lógica principal
if ($Status) { Show-Status; return }
if ($List)   { Show-List;   return }
if ($Preview){ Show-Preview; return }
if ($Switch) {
    Write-StructuredLog -Path $Script:JsonLogFile -Event 'rotate' -Properties @{
        from = (Get-ActiveClaudeProfileName); to = $Switch; triggerReason = 'manual-switch'
    }
    Apply-ProfileSwitch -ProfileName $Switch -DryRun:$DryRun
    return
}
# ... resto do script (modo automático default)
```

- [ ] **Step 4: Rodar testes — PASS**

- [ ] **Step 5: Documentar no help do script**

```powershell
# auto-rotate.ps1 — comentário cabeçalho atualizado
# auto-rotate.ps1 — Rotação automática + CLI interativo
# Modos:
#   (default)     Roda em modo automático (Task Scheduler) — só rota se >= threshold
#   -Status       Mostra perfil ativo + uso % atual
#   -List         Lista todos perfis com estado/cooldown
#   -Preview      Mostra qual seria o próximo perfil sem aplicar
#   -Switch <p>   Troca manual para o perfil <p>
#   -DryRun       Apenas loga, não aplica
#   -Force        Ignora threshold, rota imediatamente
```

- [ ] **Step 6: Commit**

```bash
git add auto-rotate.ps1 tests/AutoRotateCli.Tests.ps1
git commit -m "feat(rotate): interactive CLI modes -Status/-List/-Preview/-Switch"
```

---

## Task 4: File locking + race condition fix

**Files:**
- Create: `aiox-shared\Mutex.psm1`
- Modify: `auto-rotate.ps1` (envelopar lógica de junction recreate em mutex)
- Modify: `manage-skills.ps1` Set-ClaudeProfileJunction (linha 567)
- Test: `aiox-shared\tests\Mutex.Tests.ps1`

**Bug que resolve:** race condition em auto-rotate.ps1:262-276 quando 2 instâncias rodam simultaneamente

- [ ] **Step 1: Teste de mutex**

```powershell
Describe "Acquire-FileLock" {
    It "Blocks second acquirer until first releases" {
        $lockName = "test-lock-$(Get-Random)"
        $job1 = Start-Job -ScriptBlock {
            param($n) Import-Module Mutex.psm1
            $h = Acquire-FileLock -Name $n -Timeout 5
            Start-Sleep -Seconds 2
            Release-FileLock -Handle $h
            return 'job1-done'
        } -ArgumentList $lockName

        Start-Sleep -Milliseconds 200
        $start = Get-Date
        $h2 = Acquire-FileLock -Name $lockName -Timeout 10
        $elapsed = (Get-Date) - $start
        Release-FileLock -Handle $h2
        $elapsed.TotalSeconds | Should -BeGreaterThan 1.5

        Wait-Job $job1 | Out-Null
    }

    It "Throws TimeoutException if cannot acquire in -Timeout seconds" {
        $h1 = Acquire-FileLock -Name 'test-x' -Timeout 1
        { Acquire-FileLock -Name 'test-x' -Timeout 1 } | Should -Throw -ExceptionType ([System.TimeoutException])
        Release-FileLock -Handle $h1
    }
}
```

- [ ] **Step 2: Implementar Mutex.psm1**

```powershell
# aiox-shared/Mutex.psm1
function Acquire-FileLock {
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$Timeout = 30
    )
    $mutexName = "Global\aiox-$Name"
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    if (-not $mutex.WaitOne([TimeSpan]::FromSeconds($Timeout))) {
        $mutex.Dispose()
        throw [System.TimeoutException]::new("Could not acquire lock '$Name' within ${Timeout}s")
    }
    return $mutex
}

function Release-FileLock {
    param([Parameter(Mandatory)]$Handle)
    try { $Handle.ReleaseMutex() } catch {}
    $Handle.Dispose()
}

Export-ModuleMember -Function Acquire-FileLock, Release-FileLock
```

- [ ] **Step 3: Envelopar junction swap no auto-rotate.ps1**

```powershell
# auto-rotate.ps1 — em torno das linhas 262-276
Import-Module "$PSScriptRoot/../aiox-shared/Mutex.psm1" -Force

$lockHandle = $null
try {
    $lockHandle = Acquire-FileLock -Name 'claude-profile-swap' -Timeout 30
    # lógica original de recriar junction aqui
    Remove-Item -LiteralPath $activeJunction -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Junction -Path $activeJunction -Target $newProfileDir -ErrorAction Stop | Out-Null
    Save-ClaudeAccountStateStore -Store $store
} catch [System.TimeoutException] {
    Write-StructuredLog -Path $Script:JsonLogFile -Event 'lock-timeout' -Level 'warn' -Properties @{ lock = 'claude-profile-swap' }
    return
} finally {
    if ($lockHandle) { Release-FileLock -Handle $lockHandle }
}
```

- [ ] **Step 4: Rodar testes — PASS**

- [ ] **Step 5: Teste de stress (10 instâncias paralelas, todas tentam rotacionar)**

```powershell
1..10 | ForEach-Object -Parallel {
    & pwsh -NoProfile -File ./auto-rotate.ps1 -DryRun -Force 2>&1
} -ThrottleLimit 10
```
Expected: nenhum erro de "junction already exists" — exatamente UM teve sucesso, 9 viram lock-timeout no log.

- [ ] **Step 6: Commit**

---

## Task 5: Bugs críticos miscelâneos

**Files:**
- Modify: `auto-rotate.ps1`
- Test: `tests/AutoRotateBugs.Tests.ps1`

**Bugs:**
- BUG-A: regex `^claude-[a-z]$` falha em maiúsculo
- BUG-B: `[System.DateTime]::Parse` sem DateTimeKind diverge em timezone
- BUG-C: catch silencioso em `.cooldown` corrupto

- [ ] **Step 1: Testes para os 3 bugs**

```powershell
Describe "Profile name regex (BUG-A)" {
    It "Accepts uppercase profile names" {
        Test-IsValidProfileName 'Claude-A' | Should -Be $true
    }
    It "Accepts mixed case" {
        Test-IsValidProfileName 'Claude-a' | Should -Be $true
    }
}

Describe "DateTime parsing (BUG-B)" {
    It "Treats ISO 8601 strings as UTC always" {
        $dt = ConvertTo-UtcDateTime '2026-05-10T15:30:00Z'
        $dt.Kind | Should -Be 'Utc'
    }
}

Describe "Cooldown file read (BUG-C)" {
    It "Returns null + logs error if .cooldown is corrupt" {
        $tmp = New-TemporaryFile
        Set-Content -LiteralPath $tmp -Value 'NOT_A_NUMBER'
        $logBefore = (Get-Item $Script:JsonLogFile).Length
        $result = Read-CooldownFile -Path $tmp
        $result | Should -BeNullOrEmpty
        (Get-Item $Script:JsonLogFile).Length | Should -BeGreaterThan $logBefore
    }
}
```

- [ ] **Step 2: Aplicar fixes**

```powershell
# Fix BUG-A: regex case-insensitive
function Test-IsValidProfileName {
    param([string]$Name)
    return $Name -match '^claude-[a-z]$'  # antes: hardcoded lowercase; agora -match é case-insensitive default no PS
}

# Fix BUG-B: parsing UTC explícito
function ConvertTo-UtcDateTime {
    param([string]$IsoString)
    return [System.DateTime]::Parse($IsoString, $null, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
}

# Fix BUG-C: log + null em vez de catch silencioso
function Read-CooldownFile {
    param([string]$Path)
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        return [long]$raw.Trim()
    } catch {
        Write-StructuredLog -Path $Script:JsonLogFile -Event 'corrupt-cooldown' -Level 'error' -Properties @{
            path = $Path; reason = $_.Exception.Message
        }
        return $null
    }
}
```

- [ ] **Step 3: Substituir todos os call-sites com regex literal pelo Test-IsValidProfileName**

Grep `'\^claude-\[a-z\]\$'` no projeto e substituir.

- [ ] **Step 4: Substituir todos `[System.DateTime]::Parse` por `ConvertTo-UtcDateTime`**

- [ ] **Step 5: Substituir leituras de `.cooldown` por `Read-CooldownFile`**

- [ ] **Step 6: Tests PASS, commit**

---

## Task 6: Retry com rollback se junction falhar (Melhoria #8)

**Files:**
- Modify: `auto-rotate.ps1`
- Test: `tests/RollbackOnFailure.Tests.ps1`

- [ ] **Step 1: Teste**

```powershell
Describe "Rollback on junction failure" {
    It "Restores previous active profile if New-Item -Junction throws" {
        Mock New-Item { throw "permission denied" } -ParameterFilter { $ItemType -eq 'Junction' }
        $beforeProfile = Get-ActiveClaudeProfileName
        { Apply-ProfileSwitch -ProfileName 'claude-b' } | Should -Throw
        $afterProfile = Get-ActiveClaudeProfileName
        $afterProfile | Should -Be $beforeProfile
    }

    It "Restores state.json cooldown if rollback happens" {
        # ... similar
    }
}
```

- [ ] **Step 2: Wrapper com snapshot/restore**

```powershell
function Apply-ProfileSwitch {
    param([string]$ProfileName, [switch]$DryRun)
    $stateBefore = Get-ClaudeAccountStateStore
    $junctionBefore = (Get-Item $activeJunction -Force).Target
    try {
        if ($DryRun) { return }
        Remove-Item -LiteralPath $activeJunction -Force
        New-Item -ItemType Junction -Path $activeJunction -Target $newProfileDir -ErrorAction Stop | Out-Null
        # marcar antigo como cooldown
        $store = Get-ClaudeAccountStateStore
        $store.profiles[$ProfileName].state = 'available'
        Save-ClaudeAccountStateStore -Store $store
    } catch {
        # rollback
        Write-StructuredLog -Path $Script:JsonLogFile -Event 'rollback' -Level 'error' -Properties @{
            target = $ProfileName; reason = $_.Exception.Message
        }
        if ($junctionBefore) {
            Remove-Item -LiteralPath $activeJunction -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Junction -Path $activeJunction -Target $junctionBefore -ErrorAction SilentlyContinue | Out-Null
        }
        Save-ClaudeAccountStateStore -Store $stateBefore
        throw
    }
}
```

- [ ] **Step 3-4: Tests, commit**

---

## Task 7: Suporte Gemini/Qwen abstraído (Melhoria #7)

**Files:**
- Create: `aiox-shared\CliRuntime.psm1`
- Create: `claude-auth-manager\auto-rotate-gemini.ps1`
- Create: `claude-auth-manager\auto-rotate-qwen.ps1`
- Test: `aiox-shared\tests\CliRuntime.Tests.ps1`

- [ ] **Step 1: Definir contrato (interface)**

```powershell
# aiox-shared/CliRuntime.psm1 — abstração que cada CLI implementa
function Get-CliProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('claude','codex','gemini','qwen')][string]$CliType,
        [Parameter(Mandatory)][string]$ProfileName
    )
    switch ($CliType) {
        'claude' { return @{ ConfigDir = "$env:USERPROFILE\.claude-profiles\$ProfileName"; AuthFile = '.credentials.json'; SwapMethod = 'junction' } }
        'codex'  { return @{ ConfigDir = "$env:USERPROFILE\.codex-profiles\$ProfileName"; AuthFile = 'auth.json'; SwapMethod = 'copy' } }
        'gemini' { return @{ ConfigDir = "$env:USERPROFILE\.gemini-profiles\$ProfileName"; AuthFile = 'oauth_creds.json'; SwapMethod = 'env' } }
        'qwen'   { return @{ ConfigDir = "$env:USERPROFILE\.qwen-profiles\$ProfileName"; AuthFile = 'creds.json'; SwapMethod = 'env' } }
    }
}

function Invoke-CliRotation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('claude','codex','gemini','qwen')][string]$CliType,
        [Parameter(Mandatory)][string]$FromProfile,
        [Parameter(Mandatory)][string]$ToProfile,
        [switch]$DryRun
    )
    $profileDef = Get-CliProfile -CliType $CliType -ProfileName $ToProfile
    switch ($profileDef.SwapMethod) {
        'junction' { Swap-ViaJunction -CliType $CliType -To $ToProfile -DryRun:$DryRun }
        'copy'     { Swap-ViaCopy -CliType $CliType -To $ToProfile -DryRun:$DryRun }
        'env'      { Swap-ViaEnvVar -CliType $CliType -To $ToProfile -DryRun:$DryRun }
    }
}

Export-ModuleMember -Function Get-CliProfile, Invoke-CliRotation
```

- [ ] **Step 2: Testes para cada CliType**

```powershell
Describe "CliRuntime abstraction" {
    It "Returns correct config dir for claude" { (Get-CliProfile -CliType 'claude' -ProfileName 'claude-a').SwapMethod | Should -Be 'junction' }
    It "Returns copy method for codex" { (Get-CliProfile -CliType 'codex' -ProfileName 'codex-a').SwapMethod | Should -Be 'copy' }
    It "Returns env method for gemini" { (Get-CliProfile -CliType 'gemini' -ProfileName 'g1').SwapMethod | Should -Be 'env' }
}
```

- [ ] **Step 3-4: Implementar Swap-ViaJunction/Copy/EnvVar reusando código existente**

- [ ] **Step 5: Criar auto-rotate-gemini.ps1 e auto-rotate-qwen.ps1 (~30 linhas cada)**

```powershell
# auto-rotate-gemini.ps1
param([int]$Threshold = 95, [switch]$DryRun, [switch]$Force, [switch]$Status, [switch]$List, [switch]$Preview, [string]$Switch)
Import-Module "$PSScriptRoot/../aiox-shared/CliRuntime.psm1" -Force
# delegação ao runtime abstraído
Invoke-CliAutoRotate -CliType 'gemini' -Threshold $Threshold -DryRun:$DryRun -Force:$Force -Status:$Status -List:$List -Preview:$Preview -SwitchTo $Switch
```

- [ ] **Step 6: Tasks no Scheduler para Gemini e Qwen (mas Disabled por default)**

- [ ] **Step 7-8: Tests, commit**

---

## Task 8: Refresh OAuth automático (port do teamclaude)

**Files:**
- Create: `claude-auth-manager\lib\oauth-refresh.ps1`
- Modify: `Get-ClaudeAuthInfo` (linha 1171) e `Get-CodexAuthInfo` (linha 733) para retornar `accessTokenExpiresIn`
- Test: `tests/OAuthRefresh.Tests.ps1`

- [ ] **Step 1: Teste**

```powershell
Describe "OAuth refresh trigger" {
    It "Triggers refresh if expiresIn < 300s" {
        Mock Get-ClaudeAuthInfo { @{ profileId='claude-a'; accessTokenExpiresIn = 200 } }
        Mock Invoke-ClaudeAuthRefresh { @{ success = $true } }
        Invoke-OAuthRefreshIfNeeded -ProfileName 'claude-a'
        Should -Invoke Invoke-ClaudeAuthRefresh -Times 1
    }
    It "Skips refresh if expiresIn >= 300s" {
        Mock Get-ClaudeAuthInfo { @{ profileId='claude-a'; accessTokenExpiresIn = 600 } }
        Mock Invoke-ClaudeAuthRefresh {}
        Invoke-OAuthRefreshIfNeeded -ProfileName 'claude-a'
        Should -Invoke Invoke-ClaudeAuthRefresh -Times 0
    }
}
```

- [ ] **Step 2: Implementar Invoke-OAuthRefreshIfNeeded com retry exponencial**

- [ ] **Step 3: Adicionar Scheduled Task `OAuthRefresh` (Disabled por default, a cada 5 min)**

- [ ] **Step 4: Toggle UI também controla esse task**

- [ ] **Step 5-6: Tests, commit**

---

## Task 9: skills.lock.json (port do ccpi)

**Files:**
- Create: `skill-manager\lib\skill-lockfile.ps1`
- Create: `tests/SkillLockfile.Tests.ps1`

- [ ] **Step 1: Esquema do lockfile**

```json
{
  "version": 1,
  "updatedAt": "2026-05-10T18:00:00Z",
  "skills": {
    "spreadsheet": {
      "source": "anthropics/skills",
      "ref": "main",
      "commit": "abc123",
      "sha256_tree": "...",
      "version": "1.2.0",
      "installedAt": "2026-05-10T17:00:00Z"
    }
  }
}
```

- [ ] **Step 2-7: TDD para Add/Remove/Update do lockfile, integrar em Add-ProjectSkills**

---

## Task 10: Adapters Import-FromCcpi/Ccpm/Alireza

**Files:**
- Create: `skill-manager\lib\upstream-importer.ps1`
- Modify: `/api/github-import` em Start-SkillManagerUI

- [ ] **Step 1: Detectar URL e rotear para adapter correto**

```powershell
function Resolve-UpstreamSource {
    param([string]$Url)
    if ($Url -match 'jeremylongshore/claude-code-plugins') { return 'ccpi' }
    if ($Url -match 'daymade/claude-code-skills') { return 'ccpm' }
    if ($Url -match 'alirezarezvani/claude-skills') { return 'alireza' }
    if ($Url -match 'anthropics/skills') { return 'anthropics' }
    return 'generic'
}
```

- [ ] **Step 2-N: TDD para cada adapter**

---

## Task 11: Frontmatter validator robusto (port do ccpm)

**Files:**
- Create: `skill-manager\lib\frontmatter-validator.ps1`
- Test: `tests/FrontmatterValidator.Tests.ps1`

- [ ] **Step 1: Validações**
- name é string, kebab-case, < 64 chars
- description é string, < 1024 chars
- references/* paths existem e são relativos
- Sem trailing whitespace
- Sem BOM (já tem fix mas reforçar)
- Versão semântica se presente

---

## Task 12: Split físico em 3 pastas

**Files:**
- Move: `manage-skills.ps1` → `skill-manager\skill-manager.ps1` (parte SKILL) e `claude-auth-manager\claude-auth-manager.ps1` (parte AUTH)
- Move: `auto-rotate*.ps1` → `claude-auth-manager\`
- Move: helpers comuns → `aiox-shared\*.psm1`

**ESTA TASK ÚLTIMA** — só fazer depois que todas as outras estão verdes.

- [ ] **Step 1: Renomear AI-Skills-Hub atual → AI-Skills-Hub-LEGACY**
- [ ] **Step 2: Criar 3 pastas vazias**
- [ ] **Step 3: Copiar arquivos com `Move-Item` preservando timestamps**
- [ ] **Step 4: Atualizar `using module` paths nos scripts movidos**
- [ ] **Step 5: Atualizar Scheduled Task actions para apontar pra `~\Diego\claude-auth-manager\auto-rotate.ps1`**
- [ ] **Step 6: Atualizar `~\AppData\Local\Syncthing\config.xml` folder `ai-skills-hub` para path = `C:\Users\marce\Diego\skill-manager`** (precisa pausar Syncthing antes)
- [ ] **Step 7: Pester full suite verde em ambiente novo**
- [ ] **Step 8: Smoke test manual: skill-manager.bat e claude-auth-manager.bat sobem corretamente**
- [ ] **Step 9: Commit + tag v2.0.0**

---

## Verificação ponta-a-ponta

Após todas as tasks:

```powershell
# 1. Pester full suite
Invoke-Pester -Path .\tests, .\aiox-shared\tests, .\skill-manager\tests, .\claude-auth-manager\tests -Output Detailed
# Expected: 100% PASS

# 2. UI live test
Start-Process .\skill-manager\skill-manager.bat
Start-Process .\claude-auth-manager\claude-auth-manager.bat
# Expected: porta 8765 e 8766 sobem, ambas independentes

# 3. Toggle auto-rotate
Invoke-RestMethod -Method Post -Uri 'http://localhost:8766/api/auto-rotate/toggle' -Body '{"enabled":true}' -ContentType 'application/json'
Get-ScheduledTask ClaudeAutoRotate | Select State
# Expected: Ready

# 4. Manual rotate via CLI
.\claude-auth-manager\auto-rotate.ps1 -List
.\claude-auth-manager\auto-rotate.ps1 -Preview
.\claude-auth-manager\auto-rotate.ps1 -Status

# 5. Verify structured log
Get-Content "$env:USERPROFILE\.claude-orchestrator\usage\logs\rotation.jsonl" -Tail 10 | ForEach-Object { $_ | ConvertFrom-Json }
# Expected: cada linha JSON válido com ts/level/event

# 6. Verify Gemini/Qwen support
.\claude-auth-manager\auto-rotate-gemini.ps1 -List
.\claude-auth-manager\auto-rotate-qwen.ps1 -List
```

---

## Riscos e mitigações

| Risco | Mitigação |
|---|---|
| Pester 5 não instalado / versão errada | Step 0: `Install-Module Pester -MinimumVersion 5.0 -Force` |
| Mock de `New-Item -Junction` não funciona | Pester 5 suporta Mock condicional via -ParameterFilter; testado em CI |
| Mutex global trava em outras sessões | Nome qualificado `Global\aiox-*` é processo-scoped, não machine-scoped — mas precisamos confirmar em Windows |
| Refresh OAuth pode falhar 401 | Retry com backoff exponencial 3 tentativas, log estruturado de cada falha |
| Move-Item de arquivos abertos pelo Syncthing | Pausar folder Syncthing via API REST antes de mover, reativar depois |
| Pasta LEGACY conflita com Syncthing | Aliasing via junction `AI-Skills-Hub` → `AI-Skills-Hub-LEGACY` durante transição |
| Bugs introduzidos em produção | TODA task tem teste Pester antes do commit; Validation agent re-roda em ambiente limpo |
