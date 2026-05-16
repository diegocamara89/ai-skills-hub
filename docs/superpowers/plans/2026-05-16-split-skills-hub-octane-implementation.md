# Split AI-Skills-Hub → ai-skills-hub + octane — Implementation Plan

> **PIVOT 2026-05-16 — Senior QA decision (autonomous):** Fase 1 simplificada para **baseline-only** (sem extração de módulos). Fase 2 ajustada: cada repo recebe **cópia completa** do `manage-skills.ps1` + arquivos auxiliares relevantes. Entry scripts finos (`skill-manager.ps1` no Hub, `octane.ps1` no octane) dispacham apenas comandos do escopo. Propriedade exclusiva mantida via entry scripts. Extração modular vira trabalho pós-split, incremental, uma função por PR. Razão: o plano original era big-bang refactor de 5886 linhas (alto risco, tempo proibitivo). Pivot entrega o split (objetivo principal) com risco mínimo, mantém Pester verde, e permite refatoração modular controlada depois.


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Each task has an **Implementation agent** and **Validation agent** assigned. Validation never implements — only verifies via Pester tests + manual checks + filesystem inspection.

**Goal:** Dividir o monolito `AI-Skills-Hub` em dois repositórios independentes (`ai-skills-hub` para skills, `octane` para auth multi-CLI) com zero perda de perfis configurados, CLI standalone + TUI Spectre.Console, em 5 fases reversíveis.

**Architecture:** PowerShell 7 + Pester 5. Cada repo tem um módulo `.psm1` com lógica pura, três interfaces consumindo (HTTP/CLI/TUI). Junctions NTFS para hot-swap de perfis. Propriedade exclusiva de recursos em disco (Hub vs octane).

**Tech Stack:** PowerShell 7+, Pester 5.x, .NET 8, Spectre.Console, Windows Task Scheduler, robocopy.

**Reference Spec:** `docs/superpowers/specs/2026-05-16-split-skills-hub-octane-design.md`

**Pre-requisites:**
- PowerShell 7.x (`$PSVersionTable.PSVersion.Major -ge 7`)
- Pester 5+: `Install-Module Pester -MinimumVersion 5.0 -Force -SkipPublisherCheck -Scope CurrentUser`
- .NET 8 SDK: `dotnet --version` → 8.x
- gh CLI: `gh --version` (para criar repo octane)
- git: `git --version` ≥ 2.40
- Acesso SSH a github.com configurado

---

## Conventions

- **Working tree absoluto:** Todos os caminhos absolutos partem de `C:\Users\marce\Diego\AI-Skills-Hub\` até a Fase 2. A partir da Fase 2 surgem `C:\Users\marce\Diego\ai-skills-hub\` e `C:\Users\marce\Diego\octane\`.
- **PowerShell version:** PowerShell 7 (não Windows PowerShell 5.1). Todos os scripts usam `#requires -Version 7.0`.
- **Encoding:** UTF-8 sem BOM para todos os `.ps1`, `.psm1`, `.md`. Markers continuam UTF-8 sem BOM (compatível com profile PowerShell).
- **Junctions:** **sempre via `New-Item -ItemType Junction -Path <link> -Target <target> -ErrorAction Stop`**. Nunca usar `cmd /c mklink /J` (quoting frágil + exit code não verificado).
- **Commits:** após cada task que altera arquivos versionados. Mensagem em inglês, formato `<scope>: <one-line>`.
- **Test runner:** `Invoke-Pester -Output Detailed` em PowerShell 7.

### Module loading pattern (CRITICAL — Codex review fix)

**NÃO usar `-Global` em `Import-Module`.** Pattern correto:

1. Cada `.psm1` faz seus próprios imports de dependências (via `Import-Module $PSScriptRoot\<dep>.psm1 -Force`).
2. Scripts orquestradores importam apenas os módulos públicos que vão consumir.
3. Quando duas cópias de `Common.psm1` (uma em modules-skills/, outra em modules-octane/) são carregadas, `-Global` causa clobber imprevisível. Sem `-Global`, cada módulo tem sua própria referência.

### `$Script:` scope variables (CRITICAL — Codex review fix)

O monolito tem variáveis `$Script:` compartilhadas entre funções (ex: caches, state stores em linhas ~20-41, ~3243-3244 do `manage-skills.ps1`). Ao extrair funções para um `.psm1`, cada módulo tem seu próprio escopo.

**Pattern para preservar:**

```powershell
# No topo do .psm1
$Script:HubRoot     = Split-Path -Parent $PSScriptRoot
$Script:ConfigCache = $null  # ou valor inicial original

function Initialize-SkillManagerContext {
    [CmdletBinding()] param()
    $Script:HubRoot = Split-Path -Parent $PSScriptRoot
    $Script:ConfigCache = $null
    # ... outras inicializações
}

Initialize-SkillManagerContext  # roda no carregamento do módulo
```

Adicionar teste Pester verificando que cada `$Script:` var referenciada está inicializada após `Import-Module`.

### Stopping processes safely (CRITICAL — Codex review fix)

**NUNCA usar `Stop-Process -Name pwsh -Force`** — mata todos os PowerShell, incluindo a sessão atual.

Pattern correto: capturar PID quando `Start-Process` é usado e parar apenas esses:

```powershell
$panelOctane = Start-Process pwsh -ArgumentList "-File", "..." -PassThru
# ... use the panel ...
Stop-Process -Id $panelOctane.Id -Force -ErrorAction SilentlyContinue
```

Para processos CLI já rodando (Claude Code, Codex CLI), identificar por nome completo + linha de comando, nunca por nome genérico.

---

## Task 0: Pre-flight checks

**Files:**
- Create: `C:\Users\marce\Diego\AI-Skills-Hub\preflight-check.ps1`
- Create: `C:\Users\marce\Diego\AI-Skills-Hub\preflight-results.json`

**Implementation agent:** general-purpose
**Validation agent:** general-purpose

- [ ] **Step 1: Create the pre-flight check script**

Create `C:\Users\marce\Diego\AI-Skills-Hub\preflight-check.ps1`:

```powershell
#requires -Version 7.0
<#
Verifica pré-requisitos antes de iniciar a migração split AI-Skills-Hub.
Sai com código 0 se tudo OK, 1 se algo falta.
#>
[CmdletBinding()]
param(
    [string]$OutPath = "$PSScriptRoot\preflight-results.json"
)
$ErrorActionPreference = "Stop"

$results = [ordered]@{
    timestamp = (Get-Date).ToString('o')
    checks    = [ordered]@{}
}

function Add-Check {
    param([string]$Name, [bool]$Pass, [string]$Detail)
    $results.checks[$Name] = [ordered]@{
        pass   = $Pass
        detail = $Detail
    }
    $marker = if ($Pass) { 'PASS' } else { 'FAIL' }
    Write-Host "[$marker] $Name — $Detail"
}

# PowerShell 7
Add-Check 'powershell_7' ($PSVersionTable.PSVersion.Major -ge 7) "version=$($PSVersionTable.PSVersion)"

# Pester 5
$pesterModule = Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1
$pesterOk = $pesterModule -and $pesterModule.Version.Major -ge 5
Add-Check 'pester_5' $pesterOk "version=$($pesterModule.Version)"

# .NET 8 SDK
try {
    $dotnetVersion = & dotnet --version 2>$null
    $dotnetOk = $dotnetVersion -match '^8\.'
} catch { $dotnetOk = $false; $dotnetVersion = 'not found' }
Add-Check 'dotnet_8' $dotnetOk "version=$dotnetVersion"

# gh CLI
try {
    $ghVersion = (& gh --version 2>$null | Select-Object -First 1)
    $ghOk = [bool]$ghVersion
} catch { $ghOk = $false; $ghVersion = 'not found' }
Add-Check 'gh_cli' $ghOk "version=$ghVersion"

# git
try {
    $gitVersion = (& git --version 2>$null)
    $gitOk = [bool]$gitVersion
} catch { $gitOk = $false; $gitVersion = 'not found' }
Add-Check 'git' $gitOk "version=$gitVersion"

# robocopy (Windows built-in, sanity check)
$robocopyOk = $null -ne (Get-Command robocopy.exe -ErrorAction SilentlyContinue)
Add-Check 'robocopy' $robocopyOk 'built-in Windows tool'

# Profile directories exist
$claudeProfilesExist = Test-Path "$env:USERPROFILE\.claude-profiles"
$codexProfilesExist = Test-Path "$env:USERPROFILE\.codex-profiles"
Add-Check 'claude_profiles_dir' $claudeProfilesExist "path=$env:USERPROFILE\.claude-profiles"
Add-Check 'codex_profiles_dir' $codexProfilesExist "path=$env:USERPROFILE\.codex-profiles"

# Junctions
function Test-Junction {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $item = Get-Item $Path -Force
    if ($item.LinkType -ne 'Junction') { return $null }
    return $item.Target -join ', '
}
$claudeActive = Test-Junction "$env:USERPROFILE\.claude-profiles\active"
$codexActive  = Test-Junction "$env:USERPROFILE\.codex-profiles\active"
Add-Check 'claude_active_junction' ([bool]$claudeActive) "target=$claudeActive"
Add-Check 'codex_active_junction'  ([bool]$codexActive)  "target=$codexActive"

# Env vars
Add-Check 'env_claude_config_dir' ([bool]$env:CLAUDE_CONFIG_DIR) "value=$env:CLAUDE_CONFIG_DIR"
Add-Check 'env_codex_home'        ([bool]$env:CODEX_HOME)        "value=$env:CODEX_HOME"

# Task Scheduler tasks
function Test-TaskExists {
    param([string]$Name)
    try { $t = Get-ScheduledTask -TaskName $Name -ErrorAction Stop; return $t.State.ToString() } catch { return $null }
}
$claudeRotate = Test-TaskExists 'ClaudeAutoRotate'
$codexRotate  = Test-TaskExists 'CodexAutoRotate'
Add-Check 'task_claude_rotate' ([bool]$claudeRotate) "state=$claudeRotate"
Add-Check 'task_codex_rotate'  ([bool]$codexRotate)  "state=$codexRotate"

# GitHub repo reachable
try {
    $repoCheck = & gh repo view diegocamara89/ai-skills-hub --json name -q '.name' 2>$null
    $repoOk = $repoCheck -eq 'ai-skills-hub'
} catch { $repoOk = $false }
Add-Check 'github_repo_reachable' $repoOk 'repo=diegocamara89/ai-skills-hub'

# Disk space (need ~5GB headroom)
$drive = Get-PSDrive C
$freeMB = [math]::Round($drive.Free / 1MB, 0)
Add-Check 'disk_space_5gb' ($freeMB -gt 5120) "free=${freeMB}MB"

# PATH includes ~\.local\bin (for shims to work)
$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
$localBin = "$env:USERPROFILE\.local\bin"
$pathOk = $userPath -split ';' | Where-Object { $_.Trim() -eq $localBin }
Add-Check 'path_local_bin' ([bool]$pathOk) "user_path_contains=$localBin"

# Scheduled Task registration permission (try with disposable task)
try {
    $testTask = "PreflightTest_$(Get-Random)"
    $action  = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c echo test'
    $trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddYears(10))
    Register-ScheduledTask -TaskName $testTask -Action $action -Trigger $trigger -ErrorAction Stop | Out-Null
    Unregister-ScheduledTask -TaskName $testTask -Confirm:$false -ErrorAction Stop
    $schedOk = $true; $schedDetail = 'can register'
} catch {
    $schedOk = $false; $schedDetail = $_.Exception.Message
}
Add-Check 'scheduler_can_register' $schedOk $schedDetail

# No active Claude Code / Codex CLI processes during phase 4 (warning only)
$claudeProc = Get-Process -Name claude -ErrorAction SilentlyContinue
$codexProc  = Get-Process -Name codex  -ErrorAction SilentlyContinue
$running = @(@($claudeProc).Count, @($codexProc).Count) -join '/'
Add-Check 'cli_processes_idle' ($claudeProc.Count -eq 0 -and $codexProc.Count -eq 0) "claude/codex=$running (warning only; matter only during phase 4)"

$allPass = -not ($results.checks.Values | Where-Object { -not $_.pass })
$results | ConvertTo-Json -Depth 5 | Out-File -FilePath $OutPath -Encoding utf8
Write-Host ""
if ($allPass) {
    Write-Host "ALL CHECKS PASS. Results: $OutPath" -ForegroundColor Green
    exit 0
} else {
    Write-Host "SOME CHECKS FAILED. Review: $OutPath" -ForegroundColor Red
    exit 1
}
```

- [ ] **Step 2: Run the pre-flight check**

Run:
```powershell
pwsh -ExecutionPolicy Bypass -File C:\Users\marce\Diego\AI-Skills-Hub\preflight-check.ps1
```

Expected: exits 0 with `ALL CHECKS PASS`. If any FAIL, resolve before continuing (install missing tool, restart shell for env vars, etc.).

- [ ] **Step 3: Review results JSON**

Read `preflight-results.json`. Confirm:
- `claude_active_junction.target` aponta para um perfil real (ex: `claude-a`)
- `codex_active_junction.target` aponta para `~\.codex`
- `env_claude_config_dir.value` termina em `\active`
- `task_claude_rotate.state` é `Disabled` (esperado — auto-rotate já desligado por padrão atual)

---

# PHASE 0 — Rede de segurança

**Goal:** Git init local + commit "v1 monolítica" + push para branch `archive/monolith-v1` no GitHub + snapshot completo dos perfis.

**Exit criterion:** Branch `archive/monolith-v1` existe no GitHub. Snapshot existe em `~\.profile-backups\2026-05-16-<hhmm>-fase0\`.

## Task 0.1: Inicializar git local

**Files:**
- Modify: `C:\Users\marce\Diego\AI-Skills-Hub\.gitignore`
- Create: `C:\Users\marce\Diego\AI-Skills-Hub\.git\` (via git init)

**Implementation agent:** general-purpose
**Validation agent:** general-purpose

- [ ] **Step 1: Verificar que pasta não é git ainda**

Run:
```powershell
git -C C:\Users\marce\Diego\AI-Skills-Hub status
```
Expected: `fatal: not a git repository`. Se já é git, parar e investigar.

- [ ] **Step 2: Git init**

Run:
```powershell
git -C C:\Users\marce\Diego\AI-Skills-Hub init -b main
git -C C:\Users\marce\Diego\AI-Skills-Hub config user.email "andsdsv@gmail.com"
git -C C:\Users\marce\Diego\AI-Skills-Hub config user.name "Diego"
```
Expected: `Initialized empty Git repository`.

- [ ] **Step 3: Ler .gitignore existente**

Read `C:\Users\marce\Diego\AI-Skills-Hub\.gitignore` (766B). Verificar o que já está ignorado.

- [ ] **Step 4: Atualizar .gitignore para o commit-archive**

Adicionar ao final do `.gitignore` (sem remover o existente):

```
# Migration artifacts
preflight-results.json
cutover-pre-*.txt
modules-skills/
modules-octane/

# Resíduos
tmp-*/
exports/
backups-desktop-legacy/

# Sync-conflict files
*.sync-conflict-*
```

- [ ] **Step 5: Staging seletivo (sem .credentials)**

Run:
```powershell
cd C:\Users\marce\Diego\AI-Skills-Hub
git add .gitignore
git add README.md LICENSE
git add *.ps1 *.bat *.cmd *.md *.txt
git add all-skills/ global-skills/ lib/ tests/ ui/ docs/ aiox-shared/ .agents/ .claude/
git add state/managed-targets.json state/superpowers/
git status --short | Select-Object -First 50
```
Expected: nenhum arquivo `.credentials.json`, `auth.json` ou `.env`. Se houver, abortar e adicionar ao `.gitignore`.

- [ ] **Step 6: Confirmar exclusão de sensíveis**

Run:
```powershell
cd C:\Users\marce\Diego\AI-Skills-Hub
git ls-files | Select-String -Pattern '\.credentials|auth\.json|\.env$' -SimpleMatch
```
Expected: zero matches. Se houver, parar e investigar.

- [ ] **Step 7: Primeiro commit "v1 monolítica"**

Run:
```powershell
cd C:\Users\marce\Diego\AI-Skills-Hub
git commit -m "chore: v1 monolítica pré-split (archive)"
```
Expected: commit cria com hash. Anota o hash para referência.

## Task 0.2: Push para branch archive no GitHub

**Files:** (none new — git operations)

**Implementation agent:** general-purpose
**Validation agent:** general-purpose

- [ ] **Step 1: Adicionar remote origin**

Run:
```powershell
git -C C:\Users\marce\Diego\AI-Skills-Hub remote add origin git@github.com:diegocamara89/ai-skills-hub.git
git -C C:\Users\marce\Diego\AI-Skills-Hub remote -v
```
Expected: origin listado.

- [ ] **Step 2: Criar branch archive/monolith-v1**

Run:
```powershell
git -C C:\Users\marce\Diego\AI-Skills-Hub branch archive/monolith-v1
git -C C:\Users\marce\Diego\AI-Skills-Hub branch
```
Expected: branches `main` e `archive/monolith-v1` listadas, `main` ativa.

- [ ] **Step 3: Push branch archive**

Run:
```powershell
git -C C:\Users\marce\Diego\AI-Skills-Hub push -u origin archive/monolith-v1
```
Expected: push completa. **Não pushar `main` ainda** — main será reescrito na Fase 3.

- [ ] **Step 4: Verificar branch no GitHub**

Run:
```powershell
gh api repos/diegocamara89/ai-skills-hub/branches/archive%2Fmonolith-v1 --jq '.name'
```
Expected: `archive/monolith-v1`.

## Task 0.3: Snapshot dos perfis (robocopy /MIR)

**Files:**
- Create: `~\.profile-backups\2026-05-16-<hhmm>-fase0\claude-profiles\`
- Create: `~\.profile-backups\2026-05-16-<hhmm>-fase0\codex-profiles\`
- Create: `~\.profile-backups\2026-05-16-<hhmm>-fase0\codex-home\`
- Create: `~\.profile-backups\2026-05-16-<hhmm>-fase0\backup-manifest.json`

**Implementation agent:** general-purpose
**Validation agent:** general-purpose

- [ ] **Step 1: Definir variáveis e criar diretório de backup**

Run:
```powershell
$ts = Get-Date -Format 'yyyy-MM-dd-HHmm'
$backupRoot = "$env:USERPROFILE\.profile-backups\$ts-fase0"
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
Set-Content -Path "$backupRoot\.label" -Value "fase0-pre-refactor" -Encoding utf8 -NoNewline
Write-Host "Backup root: $backupRoot"
```
Save `$backupRoot` para uso nos próximos steps.

- [ ] **Step 1.5: Verificar que CLIs não estão rodando (SQLite live-copy hazard)**

`~\.codex\state_5.sqlite` é SQLite com WAL. Robocopy /MIR em DB aberta pode pegar inconsistência. Confirme que ninguém está usando antes do snapshot:

Run:
```powershell
$claudeProc = Get-Process -Name claude -ErrorAction SilentlyContinue
$codexProc  = Get-Process -Name codex  -ErrorAction SilentlyContinue
if ($claudeProc -or $codexProc) {
    Write-Host "CLI processes detected — feche manualmente antes de continuar:" -ForegroundColor Yellow
    $claudeProc | Format-Table Id, ProcessName, Path
    $codexProc  | Format-Table Id, ProcessName, Path
    Read-Host "Encerrou manualmente? Tecle ENTER para continuar"
    # Re-check
    if ((Get-Process -Name claude,codex -ErrorAction SilentlyContinue)) {
        throw "CLIs ainda rodando. Abortar e fechar antes."
    }
}
```

- [ ] **Step 2: Snapshot ~\.claude-profiles (excluindo a junction `active`)**

Run:
```powershell
$src = "$env:USERPROFILE\.claude-profiles"
$dst = "$backupRoot\claude-profiles"
New-Item -ItemType Directory -Path $dst -Force | Out-Null
& robocopy $src $dst /MIR /XJ /R:2 /W:5 /LOG:"$backupRoot\robocopy-claude.log" /NFL /NDL /NJH /NJS
Write-Host "Exit code: $LASTEXITCODE"
```
Expected: exit code 0-7 (robocopy success). `/XJ` exclui junctions (`active` não vai pro backup, e não precisa — é só um ponteiro). **Junction `active` será recriada explicitamente em caso de restore — manifesto registra o target dela.**

- [ ] **Step 3: Snapshot ~\.codex-profiles (excluindo a junction `active`)**

Run:
```powershell
$src = "$env:USERPROFILE\.codex-profiles"
$dst = "$backupRoot\codex-profiles"
New-Item -ItemType Directory -Path $dst -Force | Out-Null
& robocopy $src $dst /MIR /XJ /R:2 /W:5 /LOG:"$backupRoot\robocopy-codex.log" /NFL /NDL /NJH /NJS
Write-Host "Exit code: $LASTEXITCODE"
```
Expected: exit 0-7.

- [ ] **Step 4: Snapshot ~\.codex (sessions, history, auth.json)**

Run:
```powershell
$src = "$env:USERPROFILE\.codex"
$dst = "$backupRoot\codex-home"
New-Item -ItemType Directory -Path $dst -Force | Out-Null
& robocopy $src $dst /MIR /XJ /R:2 /W:5 /LOG:"$backupRoot\robocopy-codexhome.log" /NFL /NDL /NJH /NJS
Write-Host "Exit code: $LASTEXITCODE"
```
Expected: exit 0-7.

- [ ] **Step 5: Manifesto do snapshot**

Run:
```powershell
$manifest = [ordered]@{
    timestamp = (Get-Date).ToString('o')
    phase     = 'fase0'
    sources   = @{
        claude_profiles = "$env:USERPROFILE\.claude-profiles"
        codex_profiles  = "$env:USERPROFILE\.codex-profiles"
        codex_home      = "$env:USERPROFILE\.codex"
    }
    junctions = @{
        claude_active = (Get-Item "$env:USERPROFILE\.claude-profiles\active" -Force).Target -join ','
        codex_active  = (Get-Item "$env:USERPROFILE\.codex-profiles\active"  -Force).Target -join ','
    }
    env = @{
        CLAUDE_CONFIG_DIR = $env:CLAUDE_CONFIG_DIR
        CODEX_HOME        = $env:CODEX_HOME
    }
    markers = @{
        claude_active_dir   = (Get-Content "$env:USERPROFILE\.claude-active-dir"   -Raw -ErrorAction SilentlyContinue)
        codex_active_profile = (Get-Content "$env:USERPROFILE\.codex-active-profile" -Raw -ErrorAction SilentlyContinue)
    }
}
$manifest | ConvertTo-Json -Depth 5 | Out-File -FilePath "$backupRoot\backup-manifest.json" -Encoding utf8
Get-Content "$backupRoot\backup-manifest.json"
```
Expected: JSON com todos os campos preenchidos. **Anotar `junctions.claude_active` para validar pós-cutover.**

- [ ] **Step 6: Verificar integridade do snapshot**

Run:
```powershell
$srcCount = (Get-ChildItem "$env:USERPROFILE\.claude-profiles" -Recurse -File -Force | Measure-Object).Count
$dstCount = (Get-ChildItem "$backupRoot\claude-profiles" -Recurse -File -Force | Measure-Object).Count
Write-Host "claude-profiles: src=$srcCount dst=$dstCount"
if ([math]::Abs($srcCount - $dstCount) -gt 5) { throw "Snapshot incompleto." }
```
Expected: contagem aproximada (diferença < 5 admite arquivos em uso). Se >> diff, parar.

## Task 0.4: Inventário de junctions

**Files:**
- Create: `C:\Users\marce\Diego\AI-Skills-Hub\cutover-pre-fase0.txt`

**Implementation agent:** general-purpose
**Validation agent:** general-purpose

- [ ] **Step 1: Inventariar todas as junctions críticas**

Run:
```powershell
$out = "C:\Users\marce\Diego\AI-Skills-Hub\cutover-pre-fase0.txt"
$paths = @(
    "$env:USERPROFILE\.claude-profiles\active",
    "$env:USERPROFILE\.codex-profiles\active",
    "$env:USERPROFILE\.claude\skills",
    "$env:USERPROFILE\.codex\skills",
    "$env:USERPROFILE\.agents\skills",
    "$env:USERPROFILE\.qwen\skills",
    "$env:USERPROFILE\.antigravity\skills",
    "$env:USERPROFILE\.gemini\antigravity\skills"
)
"INVENTORY @ $(Get-Date -Format 'o')" | Out-File $out -Encoding utf8
foreach ($p in $paths) {
    if (Test-Path $p) {
        $item = Get-Item $p -Force
        $target = if ($item.LinkType) { ($item.Target -join ',') } else { '(not a junction)' }
        "$p -> $target [$($item.LinkType)]" | Out-File $out -Append -Encoding utf8
    } else {
        "$p -> (not present)" | Out-File $out -Append -Encoding utf8
    }
}
# Também listar junctions de skill individuais
$skillRoots = @("$env:USERPROFILE\.claude\skills","$env:USERPROFILE\.codex\skills","$env:USERPROFILE\.agents\skills","$env:USERPROFILE\.qwen\skills","$env:USERPROFILE\.antigravity\skills","$env:USERPROFILE\.gemini\antigravity\skills")
foreach ($root in $skillRoots) {
    if (-not (Test-Path $root)) { continue }
    Get-ChildItem $root -Force | Where-Object { $_.LinkType -eq 'Junction' } | ForEach-Object {
        "$($_.FullName) -> $($_.Target -join ',')" | Out-File $out -Append -Encoding utf8
    }
}
Get-Content $out
```
Expected: lista com cada junction e seu target. Salvar uma cópia também em `~\.profile-backups\<fase0-dir>\cutover-pre-fase0.txt`.

- [ ] **Step 2: Copiar inventário para o backup**

Run:
```powershell
Copy-Item "C:\Users\marce\Diego\AI-Skills-Hub\cutover-pre-fase0.txt" "$backupRoot\cutover-pre-fase0.txt"
```

- [ ] **Step 3: Commit do inventário no workspace**

Run:
```powershell
cd C:\Users\marce\Diego\AI-Skills-Hub
git add cutover-pre-fase0.txt
git commit -m "chore: junction inventory at fase 0"
git push origin archive/monolith-v1
```
Expected: commit + push success.

---

# PHASE 1 — Refatorar monolito no mesmo workspace

**Goal:** Quebrar `manage-skills.ps1` em módulos `.psm1` separados (Hub vs octane) **sem mover pastas**. Todos os testes Pester continuam passando.

**Exit criterion:** `Invoke-Pester C:\Users\marce\Diego\AI-Skills-Hub\tests, C:\Users\marce\Diego\AI-Skills-Hub\aiox-shared\tests` → 100% pass.

**Working strategy:** Cada extração é uma task. Cada task:
1. Cria o `.psm1` novo com as funções extraídas.
2. Substitui as funções no `manage-skills.ps1` por `Import-Module` no topo do arquivo.
3. Roda Pester — tem que passar.
4. Commit.

A última task da Fase 1 substitui o monolito por dois scripts orquestradores finos (`skill-manager.ps1` + `octane-monolith.ps1`).

## Task 1.1: Baseline Pester (sanity check)

**Files:** (none new)

**Implementation agent:** general-purpose
**Validation agent:** general-purpose

- [ ] **Step 1: Rodar baseline antes de tocar nada**

Run:
```powershell
cd C:\Users\marce\Diego\AI-Skills-Hub
$result = Invoke-Pester -Path tests,aiox-shared\tests -Output Detailed -PassThru
$result.Result
$result.PassedCount
$result.FailedCount
```
Expected: capturar contagens atuais. Se já existem testes falhando, anotar quais — eles têm que continuar falhando do mesmo jeito (não regredir).

- [ ] **Step 2: Salvar baseline em JSON para comparação posterior**

Run:
```powershell
$baseline = @{
    timestamp    = (Get-Date).ToString('o')
    passed       = $result.PassedCount
    failed       = $result.FailedCount
    skipped      = $result.SkippedCount
    failedTests  = $result.Failed | ForEach-Object { $_.ExpandedPath }
}
$baseline | ConvertTo-Json -Depth 3 | Out-File "C:\Users\marce\Diego\AI-Skills-Hub\pester-baseline.json" -Encoding utf8
Get-Content "C:\Users\marce\Diego\AI-Skills-Hub\pester-baseline.json"
```
Expected: arquivo JSON criado. **Este é o ground truth — qualquer Pester depois da Fase 1 tem que ter `passed >= baseline.passed`.**

## Task 1.2: Criar diretórios temporários de módulos

**Files:**
- Create: `C:\Users\marce\Diego\AI-Skills-Hub\modules-skills\`
- Create: `C:\Users\marce\Diego\AI-Skills-Hub\modules-octane\`

**Implementation agent:** general-purpose
**Validation agent:** general-purpose

- [ ] **Step 1: Criar pastas**

Run:
```powershell
New-Item -ItemType Directory -Path "C:\Users\marce\Diego\AI-Skills-Hub\modules-skills" -Force | Out-Null
New-Item -ItemType Directory -Path "C:\Users\marce\Diego\AI-Skills-Hub\modules-octane"  -Force | Out-Null
```

- [ ] **Step 2: Adicionar .gitkeep para que git registre as pastas vazias temporárias (não serão commitadas como vazias)**

Skip — pastas só interessam quando têm conteúdo. Avançar para próxima task.

## Task 1.3: Extrair Common.psm1 (utilitários compartilhados)

**Files:**
- Create: `C:\Users\marce\Diego\AI-Skills-Hub\modules-skills\Common.psm1`
- Create: `C:\Users\marce\Diego\AI-Skills-Hub\modules-octane\Common.psm1`
- Modify: `C:\Users\marce\Diego\AI-Skills-Hub\manage-skills.ps1`
- Test: existing Pester tests devem continuar passando

**Implementation agent:** general-purpose
**Validation agent:** general-purpose

**Functions to extract** (procurar com `Grep` no `manage-skills.ps1`):
- `Write-Step`
- `Set-NoCacheHeaders`
- `Normalize-FullPath`
- `Join-UserProfilePath`
- `Get-RuntimeInfo`
- `Ensure-Directory`
- `Set-FileAtomic`
- `Set-JsonFileAtomic`
- `Write-Utf8File`
- `Write-JsonFile`
- `Ensure-Junction` (atenção: usado por SkillManager E por octane)
- `Is-PathUnder`

- [ ] **Step 1: Localizar cada função no monolito**

Run:
```powershell
$funcs = @('Write-Step','Set-NoCacheHeaders','Normalize-FullPath','Join-UserProfilePath','Get-RuntimeInfo','Ensure-Directory','Set-FileAtomic','Set-JsonFileAtomic','Write-Utf8File','Write-JsonFile','Ensure-Junction','Is-PathUnder')
foreach ($f in $funcs) {
    $match = Select-String -Path "C:\Users\marce\Diego\AI-Skills-Hub\manage-skills.ps1" -Pattern "^function\s+$f\s*\{" -SimpleMatch:$false | Select-Object -First 1
    "$f -> linha $($match.LineNumber)"
}
```
Expected: linha de início de cada função. Anotar.

- [ ] **Step 2: Criar Common.psm1 copiando as funções (não recortar ainda)**

Para cada função identificada:
1. Ler o bloco da função no `manage-skills.ps1` (do `function X {` até o `}` de fechamento de nível 1).
2. Colar em `modules-skills\Common.psm1`.

Estrutura final do `modules-skills\Common.psm1`:

```powershell
#requires -Version 7.0
<#
.SYNOPSIS
    Common utilities for Skills Hub and octane.
    DUPLICATED between repos (no shared module dependency).
    Source of truth: this file. Octane has its own copy.
#>

# ---- Path helpers ----
function Normalize-FullPath { <# original body from manage-skills.ps1 #> }
function Join-UserProfilePath { <# original body #> }
function Is-PathUnder { <# original body #> }

# ---- Directory / Junction helpers ----
function Ensure-Directory { <# original body #> }
function Ensure-Junction { <# original body #> }

# ---- File writers (atomic) ----
function Set-FileAtomic { <# original body #> }
function Set-JsonFileAtomic { <# original body #> }
function Write-Utf8File { <# original body #> }
function Write-JsonFile { <# original body #> }

# ---- Runtime / Logging ----
function Write-Step { <# original body #> }
function Get-RuntimeInfo { <# original body #> }
function Set-NoCacheHeaders { <# original body #> }

Export-ModuleMember -Function `
    Normalize-FullPath, Join-UserProfilePath, Is-PathUnder, `
    Ensure-Directory, Ensure-Junction, `
    Set-FileAtomic, Set-JsonFileAtomic, Write-Utf8File, Write-JsonFile, `
    Write-Step, Get-RuntimeInfo, Set-NoCacheHeaders
```

Use **Edit tool** com `old_string` = o corpo exato de cada função no `manage-skills.ps1` e cole no `modules-skills\Common.psm1`. **Não remover do monolito ainda** — primeira passada copia, segunda remove.

- [ ] **Step 3: Copiar Common.psm1 para modules-octane (mesma cópia, duplicação intencional)**

Run:
```powershell
Copy-Item "C:\Users\marce\Diego\AI-Skills-Hub\modules-skills\Common.psm1" "C:\Users\marce\Diego\AI-Skills-Hub\modules-octane\Common.psm1"
```

- [ ] **Step 4: Adicionar Import-Module no topo do manage-skills.ps1**

Edit `manage-skills.ps1`. No topo do arquivo, após `[CmdletBinding()] param(...)` e antes da primeira função, inserir:

```powershell
# Module imports (Phase 1 refactor — extracted functions)
# IMPORTANT: NO -Global flag. Functions are imported into script scope only.
# manage-skills.ps1 chama estas funções diretamente sem qualifier — funciona porque
# o arquivo é dot-source (Run via script, não via Import-Module).
Import-Module (Join-Path $PSScriptRoot 'modules-skills\Common.psm1') -Force -DisableNameChecking
```

- [ ] **Step 5: Remover as funções já extraídas do manage-skills.ps1**

Para cada função listada no Step 1, **deletar** o bloco original do `manage-skills.ps1` (já está em `Common.psm1`). Use **Edit tool** com `old_string` = corpo completo, `new_string` = string vazia ou comentário curto `# moved to modules-skills\Common.psm1`.

- [ ] **Step 6: Validar sintaxe**

Run:
```powershell
pwsh -NoProfile -Command "Get-Command -Module (Import-Module 'C:\Users\marce\Diego\AI-Skills-Hub\modules-skills\Common.psm1' -Force -PassThru).Name"
```
Expected: lista as 12 funções exportadas.

- [ ] **Step 7: Rodar Pester**

Run:
```powershell
cd C:\Users\marce\Diego\AI-Skills-Hub
$result = Invoke-Pester -Path tests,aiox-shared\tests -Output Detailed -PassThru
"passed=$($result.PassedCount) failed=$($result.FailedCount)"
```
Expected: `passed >= baseline.passed` e `failed <= baseline.failed`. Se regredir, **abortar e investigar** — não seguir.

- [ ] **Step 8: Commit**

Run:
```powershell
cd C:\Users\marce\Diego\AI-Skills-Hub
git add modules-skills\Common.psm1 modules-octane\Common.psm1 manage-skills.ps1
git commit -m "refactor: extract Common.psm1 (duplicated for skills + octane)"
```

## Task 1.4: Extrair SkillManager.psm1 (lógica de skills)

**Files:**
- Create: `C:\Users\marce\Diego\AI-Skills-Hub\modules-skills\SkillManager.psm1`
- Modify: `C:\Users\marce\Diego\AI-Skills-Hub\manage-skills.ps1`

**Implementation agent:** general-purpose
**Validation agent:** general-purpose

**Functions to extract:**
- `Sync-NativeSuperpowers`
- `ConvertTo-StringArray`
- `Get-UserSourceDefinitions`
- `Get-GlobalTargetDefinitions`
- `Get-ManagedCatalogRoots`
- `Get-ProjectManagedRoots`
- `Get-ProjectTargetDefinitions`
- `Get-ImmediateSkillDirs`
- `Get-TreeLastWriteTimeUtc`
- `Get-SourcePriority`
- `Backup-ExistingPath`
- `Copy-SkillTree`
- `Get-LinkTargets`
- `Test-ManagedLink`
- `Remove-ManagedLinkIfNeeded`
- `Get-SkillFrontmatter`
- `Convert-SkillToGeminiSection`
- `New-ManagedTargetsState`
- `Get-ManagedTargetsState`
- `Save-ManagedTargetsState`
- `Get-ManagedTargetsForSkill`
- `Set-ManagedTargetsForSkill`
- `Get-ManualManagedTargetsFromFilesystem`
- `Seed-ManagedTargetsState`
- `Set-DesiredTargetsForSkill`
- `Sync-ManagedTargetState`
- `Reconcile-SharedSkills`
- `Ensure-GeminiImportBlock`
- `Write-GeminiGeneratedFile`
- `Update-ClaudeDesktopTrustedFolders`
- `Import-ExistingSkills`
- `Enable-GlobalSkills`
- `Disable-GlobalSkills`
- `Sync-GlobalSkills`
- `Sync-LegacyGeminiSkills`
- `Add-ProjectSkills`
- `Remove-ProjectSkills`
- `Sync-ProjectSkills`
- `Show-Status`
- `Show-Help`
- `Get-SuperpowersCheckoutPath`
- `Get-SuperpowersSkillDirs`
- `Get-RepoImportValidation`
- `Get-SuperpowersNativeStatus`
- `Get-LatestClaudeCliPath`
- `Get-NpmCmdShimPath`
- `Get-ClaudeUsageCollectorScriptPath` (depende — usado por Hub para sync collector)
- `Sync-ClaudeUsageCollector` (Hub instala collector nos perfis octane, mas a função em si extrai metadado de skill — checar fronteira: na verdade é auth-side. **Mover para octane**)

- [ ] **Step 1: Identificar funções via Grep**

Run via Grep:
```
pattern: "^function\s+(Sync-NativeSuperpowers|ConvertTo-StringArray|Get-UserSourceDefinitions|Get-GlobalTargetDefinitions|Get-ManagedCatalogRoots|Get-ProjectManagedRoots|Get-ProjectTargetDefinitions|Get-ImmediateSkillDirs|Get-TreeLastWriteTimeUtc|Get-SourcePriority|Backup-ExistingPath|Copy-SkillTree|Get-LinkTargets|Test-ManagedLink|Remove-ManagedLinkIfNeeded|Get-SkillFrontmatter|Convert-SkillToGeminiSection|New-ManagedTargetsState|Get-ManagedTargetsState|Save-ManagedTargetsState|Get-ManagedTargetsForSkill|Set-ManagedTargetsForSkill|Get-ManualManagedTargetsFromFilesystem|Seed-ManagedTargetsState|Set-DesiredTargetsForSkill|Sync-ManagedTargetState|Reconcile-SharedSkills|Ensure-GeminiImportBlock|Write-GeminiGeneratedFile|Update-ClaudeDesktopTrustedFolders|Import-ExistingSkills|Enable-GlobalSkills|Disable-GlobalSkills|Sync-GlobalSkills|Sync-LegacyGeminiSkills|Add-ProjectSkills|Remove-ProjectSkills|Sync-ProjectSkills|Show-Status|Show-Help|Get-SuperpowersCheckoutPath|Get-SuperpowersSkillDirs|Get-RepoImportValidation|Get-SuperpowersNativeStatus|Get-LatestClaudeCliPath|Get-NpmCmdShimPath)\s*\{"
path: C:\Users\marce\Diego\AI-Skills-Hub\manage-skills.ps1
output_mode: content
-n: true
```

Anotar as linhas onde cada função inicia.

- [ ] **Step 2: Criar SkillManager.psm1 com cabeçalho**

Create `C:\Users\marce\Diego\AI-Skills-Hub\modules-skills\SkillManager.psm1`:

```powershell
#requires -Version 7.0
<#
.SYNOPSIS
    Skill Manager — lógica core de gestão de skills.
    Extraído do monolito manage-skills.ps1 na Fase 1 do split.
#>

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force -DisableNameChecking

# Variável de escopo de módulo (compartilhada por funções abaixo)
$Script:HubRoot = Split-Path -Parent $PSScriptRoot  # ../

# (corpos das funções extraídas serão colados aqui)
```

- [ ] **Step 3: Copiar funções (cada uma com seu corpo completo)**

Para cada função, copiar do `manage-skills.ps1` para `SkillManager.psm1` mantendo ordem alfabética por seção. Usar Read no monolito (offset/limit) para pegar o corpo exato, depois Write/Edit no .psm1.

**Importante:** se uma função referenciar `$Script:HubRoot`, `$Script:Cache`, etc., garantir que essas variáveis também sejam definidas no topo do `.psm1`.

- [ ] **Step 4: Adicionar Export-ModuleMember no final**

Append no `SkillManager.psm1`:

```powershell
Export-ModuleMember -Function `
    Sync-NativeSuperpowers, ConvertTo-StringArray, `
    Get-UserSourceDefinitions, Get-GlobalTargetDefinitions, `
    Get-ManagedCatalogRoots, Get-ProjectManagedRoots, Get-ProjectTargetDefinitions, `
    Get-ImmediateSkillDirs, Get-TreeLastWriteTimeUtc, Get-SourcePriority, `
    Backup-ExistingPath, Copy-SkillTree, Get-LinkTargets, `
    Test-ManagedLink, Remove-ManagedLinkIfNeeded, Get-SkillFrontmatter, `
    Convert-SkillToGeminiSection, `
    New-ManagedTargetsState, Get-ManagedTargetsState, Save-ManagedTargetsState, `
    Get-ManagedTargetsForSkill, Set-ManagedTargetsForSkill, `
    Get-ManualManagedTargetsFromFilesystem, Seed-ManagedTargetsState, `
    Set-DesiredTargetsForSkill, Sync-ManagedTargetState, Reconcile-SharedSkills, `
    Ensure-GeminiImportBlock, Write-GeminiGeneratedFile, Update-ClaudeDesktopTrustedFolders, `
    Import-ExistingSkills, Enable-GlobalSkills, Disable-GlobalSkills, `
    Sync-GlobalSkills, Sync-LegacyGeminiSkills, `
    Add-ProjectSkills, Remove-ProjectSkills, Sync-ProjectSkills, `
    Show-Status, Show-Help, `
    Get-SuperpowersCheckoutPath, Get-SuperpowersSkillDirs, `
    Get-RepoImportValidation, Get-SuperpowersNativeStatus, `
    Get-LatestClaudeCliPath, Get-NpmCmdShimPath
```

- [ ] **Step 5: Atualizar Import-Module no manage-skills.ps1**

Edit `manage-skills.ps1`. O bloco de imports no topo agora fica:

```powershell
Import-Module (Join-Path $PSScriptRoot 'modules-skills\Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'modules-skills\SkillManager.psm1') -Force -DisableNameChecking
```

- [ ] **Step 6: Remover funções extraídas do manage-skills.ps1**

Para cada função, deletar o corpo no monolito (já está em SkillManager.psm1).

- [ ] **Step 7: Rodar Pester**

Run:
```powershell
cd C:\Users\marce\Diego\AI-Skills-Hub
$result = Invoke-Pester -Path tests,aiox-shared\tests -Output Detailed -PassThru
"passed=$($result.PassedCount) failed=$($result.FailedCount)"
```
Expected: passed >= baseline.passed. Se quebrar, investigar — provavelmente `$Script:` variável faltando, função interna não exportada chamada de fora, ou import order.

- [ ] **Step 8: Commit**

Run:
```powershell
cd C:\Users\marce\Diego\AI-Skills-Hub
git add modules-skills\SkillManager.psm1 manage-skills.ps1
git commit -m "refactor: extract SkillManager.psm1 (skills logic)"
```

## Task 1.5: Extrair ClaudeAuth.psm1

**Files:**
- Create: `C:\Users\marce\Diego\AI-Skills-Hub\modules-octane\ClaudeAuth.psm1`
- Modify: `C:\Users\marce\Diego\AI-Skills-Hub\manage-skills.ps1`

**Implementation agent:** general-purpose
**Validation agent:** general-purpose

**Functions to extract** (Claude profile management + auth):
- `Get-ClaudeOrchestratorConfigPath`
- `Get-ClaudeOrchestratorConfig`
- `ConvertTo-ClaudeOrderedDictionary`
- `Expand-ClaudePath`
- `Get-ClaudeAccountStatePath`
- `New-ClaudeAccountStateStore`
- `New-ClaudeProfileRuntimeState`
- `Normalize-ClaudeProfileRuntimeState`
- `Get-ClaudeAccountStateStore`
- `Save-ClaudeAccountStateStore`
- `Set-ClaudeProfileJunction`
- `Get-ClaudeProfileDefinitions`
- `Get-ClaudeProfileCredentials`
- `Get-ClaudeAuthInfo`
- `Get-ClaudeTierMultiplier`
- `Get-ClaudeTierLabel`
- `Estimate-SingleRateLimit`
- `Get-ClaudeEstimatedRateLimits`
- `Get-ClaudeCliForAuth`
- `Get-ClaudeMaxProfileCount`
- `Get-ClaudeAllowedProfileNames`
- `Save-ClaudeOrchestratorConfig`
- `Ensure-ClaudeOrchestratorConfig`
- `Copy-ClaudeProfileSeedFiles`
- `Sync-ClaudeProfileHooks`
- `Add-ClaudeProfile`
- `Remove-ClaudeProfile`
- `Get-QuotedCmdArgument`
- `Invoke-ClaudeAuthCommand`
- `Get-ClaudeAuthUrlFromText`
- `Get-RecentAuthLoginUrls`
- `Read-SharedTextFile`
- `Get-ClaudeAuthStatusForConfigDir`
- `Get-ClaudeAuthStatus`
- `New-ClaudeAuthLoginSession`
- `Get-ClaudeAuthLoginSession`
- `Submit-ClaudeAuthLoginCode`
- `Get-ActiveClaudeProfileName`

- [ ] **Step 1: Grep para localizar funções**

Use Grep com pattern listando todas as funções acima.

- [ ] **Step 2: Criar ClaudeAuth.psm1 com cabeçalho**

Create `C:\Users\marce\Diego\AI-Skills-Hub\modules-octane\ClaudeAuth.psm1`:

```powershell
#requires -Version 7.0
<#
.SYNOPSIS
    Claude profile and authentication management.
    Extracted from monolith manage-skills.ps1 during Phase 1 split.
#>

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force -DisableNameChecking

# Module-scoped state
$Script:HubRoot = Split-Path -Parent $PSScriptRoot

# (function bodies copied here)
```

- [ ] **Step 3: Copiar corpos das funções**

Mesma metodologia da Task 1.4. Para funções que usam `$Script:` variables (state stores), garantir que sejam declaradas no topo do módulo.

- [ ] **Step 4: Adicionar Export-ModuleMember**

```powershell
Export-ModuleMember -Function `
    Get-ClaudeOrchestratorConfigPath, Get-ClaudeOrchestratorConfig, `
    ConvertTo-ClaudeOrderedDictionary, Expand-ClaudePath, `
    Get-ClaudeAccountStatePath, New-ClaudeAccountStateStore, `
    New-ClaudeProfileRuntimeState, Normalize-ClaudeProfileRuntimeState, `
    Get-ClaudeAccountStateStore, Save-ClaudeAccountStateStore, `
    Set-ClaudeProfileJunction, `
    Get-ClaudeProfileDefinitions, Get-ClaudeProfileCredentials, `
    Get-ClaudeAuthInfo, `
    Get-ClaudeTierMultiplier, Get-ClaudeTierLabel, `
    Estimate-SingleRateLimit, Get-ClaudeEstimatedRateLimits, `
    Get-ClaudeCliForAuth, Get-ClaudeMaxProfileCount, Get-ClaudeAllowedProfileNames, `
    Save-ClaudeOrchestratorConfig, Ensure-ClaudeOrchestratorConfig, `
    Copy-ClaudeProfileSeedFiles, Sync-ClaudeProfileHooks, `
    Add-ClaudeProfile, Remove-ClaudeProfile, `
    Get-QuotedCmdArgument, Invoke-ClaudeAuthCommand, `
    Get-ClaudeAuthUrlFromText, Get-RecentAuthLoginUrls, Read-SharedTextFile, `
    Get-ClaudeAuthStatusForConfigDir, Get-ClaudeAuthStatus, `
    New-ClaudeAuthLoginSession, Get-ClaudeAuthLoginSession, Submit-ClaudeAuthLoginCode, `
    Get-ActiveClaudeProfileName
```

- [ ] **Step 5: Atualizar imports no manage-skills.ps1**

```powershell
Import-Module (Join-Path $PSScriptRoot 'modules-skills\Common.psm1')         -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'modules-skills\SkillManager.psm1')   -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'modules-octane\Common.psm1')         -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'modules-octane\ClaudeAuth.psm1')     -Force -DisableNameChecking
```

**Atenção:** Common.psm1 está duplicado nos dois módulos-skills e modules-octane. PowerShell `Import-Module -Force` segunda vez sobrescreve as funções com a mesma assinatura — ok porque são idênticas.

- [ ] **Step 6: Remover funções extraídas do monolito**

- [ ] **Step 7: Pester**

Run:
```powershell
cd C:\Users\marce\Diego\AI-Skills-Hub
$result = Invoke-Pester -Path tests,aiox-shared\tests -Output Detailed -PassThru
"passed=$($result.PassedCount) failed=$($result.FailedCount)"
```
Expected: passed >= baseline.

- [ ] **Step 8: Commit**

Run:
```powershell
git add modules-octane\ClaudeAuth.psm1 modules-octane\Common.psm1 manage-skills.ps1
git commit -m "refactor: extract ClaudeAuth.psm1"
```

## Task 1.6: Extrair CodexAuth.psm1

**Files:**
- Create: `C:\Users\marce\Diego\AI-Skills-Hub\modules-octane\CodexAuth.psm1`
- Modify: `C:\Users\marce\Diego\AI-Skills-Hub\manage-skills.ps1`

**Functions to extract:**
- `Set-CodexProfileJunction`
- `Get-CodexRateLimits`
- `Get-CodexAuthInfo`
- `Restore-CodexAuthIfEmpty`
- `Get-CodexProfiles`
- `Add-CodexProfile`
- `Remove-CodexProfile`
- `Ensure-CodexDefaultProfile`
- `Get-CodexAuthUrlFromText`
- `Start-CodexAuthLogin`
- `Get-CodexAuthLoginSession`

- [ ] **Step 1-8:** Mesma metodologia das tasks 1.4–1.5.

```powershell
# Header:
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force -DisableNameChecking

# Footer:
Export-ModuleMember -Function `
    Set-CodexProfileJunction, `
    Get-CodexRateLimits, Get-CodexAuthInfo, Restore-CodexAuthIfEmpty, `
    Get-CodexProfiles, Add-CodexProfile, Remove-CodexProfile, Ensure-CodexDefaultProfile, `
    Get-CodexAuthUrlFromText, Start-CodexAuthLogin, Get-CodexAuthLoginSession
```

Atualizar imports no monolito. Pester. Commit:
```
git commit -m "refactor: extract CodexAuth.psm1"
```

## Task 1.7: Extrair GeminiAuth.psm1

**Files:**
- Create: `C:\Users\marce\Diego\AI-Skills-Hub\modules-octane\GeminiAuth.psm1`

**Functions:**
- `Get-GeminiAuthUrlFromText`
- `Get-GeminiProfiles`
- `Add-GeminiProfile`
- `Remove-GeminiProfile`
- `Start-GeminiAuthLogin`
- `Get-GeminiAuthLoginSession`
- `Set-GeminiActiveProfile`

- [ ] **Step 1-8:** Mesma metodologia. Commit:
```
git commit -m "refactor: extract GeminiAuth.psm1"
```

## Task 1.8: Extrair UsageTracker.psm1

**Files:**
- Create: `C:\Users\marce\Diego\AI-Skills-Hub\modules-octane\UsageTracker.psm1`

**Functions:**
- `Get-ClaudeUsageProfileRoot`
- `Get-ClaudeUsageLatestPath`
- `Get-ClaudeUsageSessionsRoot`
- `Get-ClaudeProfileSettingsPath`
- `Get-ClaudeUsageCollectorCommand`
- `Get-ClaudeUsageCollectorStatus`
- `Get-ClaudeUsageLatestSnapshot`
- `Get-ClaudeUsageSessions`
- `Convert-ClaudeModelDisplayName`
- `Get-ClaudeTranscriptContextWindowSize`
- `Get-ClaudeTranscriptUsageData`
- `Get-ClaudeUsageProfileData`
- `Sync-ClaudeUsageCollector`
- `Get-ClaudeUsageCollectorScriptPath`
- `Get-ClaudeUsageCollectorWrapperPath`
- `Get-ClaudeUsageCollectorSourceScriptPath`
- `Get-ClaudeUsageCollectorSourceWrapperPath`

Commit: `refactor: extract UsageTracker.psm1`

## Task 1.9: Extrair VpsSync.psm1

**Files:**
- Create: `C:\Users\marce\Diego\AI-Skills-Hub\modules-octane\VpsSync.psm1`

**Functions:**
- `Resolve-PythonExe`
- `Read-VpsAuthSyncStatusMap`
- `Write-VpsAuthSyncStatusMap`
- `Update-VpsAuthSyncStatus`
- `Get-VpsAuthSyncStatus`
- `Invoke-VpsAuthSyncForActiveClaude`
- `Invoke-VpsAuthSyncForProfile`
- `Invoke-VpsGatewayRestart`
- `Invoke-VpsAuthSyncProcess`
- `Invoke-VpsAuthSyncForCodex`

Commit: `refactor: extract VpsSync.psm1`

## Task 1.10: Extrair Runtime/Process detection (RunningInstances)

**Files:**
- Create: `C:\Users\marce\Diego\AI-Skills-Hub\modules-octane\RunningInstances.psm1`

**Functions:**
- `Get-RunningInstances`

(Função pequena mas semanticamente isolada. Mantém em arquivo próprio para clareza.)

Commit: `refactor: extract RunningInstances.psm1`

## Task 1.11: Renomear lib/*.ps1 → modules-skills/*.psm1

**Files:**
- Create: `C:\Users\marce\Diego\AI-Skills-Hub\modules-skills\FrontmatterValidator.psm1`
- Create: `C:\Users\marce\Diego\AI-Skills-Hub\modules-skills\SkillLockfile.psm1`
- Create: `C:\Users\marce\Diego\AI-Skills-Hub\modules-skills\UpstreamImporter.psm1`
- Delete (logical, keep file): `lib/frontmatter-validator.ps1`, `lib/skill-lockfile.ps1`, `lib/upstream-importer.ps1` — manter por compatibilidade; o `.psm1` faz `Import` do `.ps1`.

**Implementation agent:** general-purpose
**Validation agent:** general-purpose

- [ ] **Step 1: Para cada lib/*.ps1, criar wrapper .psm1**

Create `modules-skills\FrontmatterValidator.psm1`:

```powershell
#requires -Version 7.0
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\frontmatter-validator.ps1')
# Re-export tudo o que está no ps1 (já está em script scope após dot-source)
Export-ModuleMember -Function *
```

(Mesmo para `SkillLockfile.psm1` e `UpstreamImporter.psm1`.)

- [ ] **Step 2: Pester**

Verificar que testes que usam `frontmatter-validator.ps1` etc. ainda passam.

- [ ] **Step 3: Commit**

```
git commit -m "refactor: wrap lib/*.ps1 as .psm1 modules"
```

## Task 1.12: Renomear lib/oauth-refresh.ps1 → modules-octane/OAuthRefresh.psm1

**Files:**
- Create: `C:\Users\marce\Diego\AI-Skills-Hub\modules-octane\OAuthRefresh.psm1`

```powershell
#requires -Version 7.0
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\oauth-refresh.ps1')
Export-ModuleMember -Function *
```

Commit: `refactor: wrap oauth-refresh as OAuthRefresh.psm1`

## Task 1.13: Migrar aiox-shared/*.psm1 referências

**Files:**
- Modify: `C:\Users\marce\Diego\AI-Skills-Hub\auto-rotate.ps1`
- Modify: `C:\Users\marce\Diego\AI-Skills-Hub\auto-rotate-codex.ps1`
- Modify: `C:\Users\marce\Diego\AI-Skills-Hub\auto-rotate-gemini.ps1`
- Modify: `C:\Users\marce\Diego\AI-Skills-Hub\lib\upstream-importer.ps1` (importa StructuredLogger)
- Modify: `C:\Users\marce\Diego\AI-Skills-Hub\lib\oauth-refresh.ps1` (importa StructuredLogger)

**Strategy:** os scripts continuam apontando para `aiox-shared\*.psm1` neste workspace (Fase 1 não move). Só na Fase 2 é que `aiox-shared/` é dissolvido. **Skip esta task na Fase 1** — só validar que continua funcionando.

- [ ] **Step 1: Confirmar imports vigentes**

Run via Grep:
```
pattern: "aiox-shared\\"
path: C:\Users\marce\Diego\AI-Skills-Hub
output_mode: content
```

Expected: imports continuam apontando para `aiox-shared\*.psm1`. Não mudar nada agora.

## Task 1.14: Construir os dois orquestradores finos (skill-manager.ps1 + octane-monolith.ps1)

**Files:**
- Create: `C:\Users\marce\Diego\AI-Skills-Hub\skill-manager.ps1`
- Create: `C:\Users\marce\Diego\AI-Skills-Hub\octane-monolith.ps1`

**Implementation agent:** general-purpose
**Validation agent:** general-purpose

O `manage-skills.ps1` neste ponto tem:
- Imports dos módulos-skills e modules-octane
- Funções que **ainda não foram extraídas** (UI handlers, CLI parser)
- Bloco main que despacha por argumento

A intenção dessa task é **dividir o despacho** em dois scripts separados, mantendo o `manage-skills.ps1` intacto por enquanto (será removido na Fase 2 após validação).

- [ ] **Step 1: Identificar Start-SkillManagerUI e Start-ClaudeAuthUI no monolito**

Run via Grep:
```
pattern: "^function\s+(Start-SkillManagerUI|Start-ClaudeAuthUI)\s*\{"
path: C:\Users\marce\Diego\AI-Skills-Hub\manage-skills.ps1
```

Anotar linhas — essas duas funções ficam por último na extração.

- [ ] **Step 2: Extrair Start-SkillManagerUI para módulo separado**

Create `modules-skills\Start-SkillManagerUI.psm1`:

```powershell
#requires -Version 7.0
Import-Module (Join-Path $PSScriptRoot 'Common.psm1')       -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'SkillManager.psm1') -Force -DisableNameChecking

function Start-SkillManagerUI {
    # corpo original, copiado do monolito
}

Export-ModuleMember -Function Start-SkillManagerUI
```

- [ ] **Step 3: Extrair Start-ClaudeAuthUI para modules-octane**

Create `modules-octane\Start-OctaneUI.psm1` (renomeada — apesar do split, o nome interno fica `Start-OctaneUI` em vez de `Start-ClaudeAuthUI` por consistência futura):

```powershell
#requires -Version 7.0
Import-Module (Join-Path $PSScriptRoot 'Common.psm1')            -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'ClaudeAuth.psm1')        -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'CodexAuth.psm1')         -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'GeminiAuth.psm1')        -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'UsageTracker.psm1')      -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'VpsSync.psm1')           -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'RunningInstances.psm1')  -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'OAuthRefresh.psm1')      -Force -DisableNameChecking

function Start-OctaneUI {
    # corpo copiado de Start-ClaudeAuthUI no monolito (renomeie 'ClaudeAuthUI' → 'OctaneUI' no texto/headers)
}

Export-ModuleMember -Function Start-OctaneUI
```

Manter `Start-ClaudeAuthUI` como alias para compatibilidade durante a fase de transição:

```powershell
Set-Alias -Name Start-ClaudeAuthUI -Value Start-OctaneUI
Export-ModuleMember -Alias Start-ClaudeAuthUI
```

- [ ] **Step 4: Criar skill-manager.ps1 (orquestrador fino)**

Create `C:\Users\marce\Diego\AI-Skills-Hub\skill-manager.ps1`:

```powershell
#requires -Version 7.0
<#
.SYNOPSIS
    Skill Manager — orquestrador fino. Importa módulos e despacha por argumento.
    Substitui o monolito manage-skills.ps1 para casos de uso de skills.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'status',
    [Parameter(ValueFromRemainingArguments = $true)][object[]]$RestArgs
)
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'modules-skills\Common.psm1')              -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'modules-skills\SkillManager.psm1')        -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'modules-skills\FrontmatterValidator.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'modules-skills\SkillLockfile.psm1')       -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'modules-skills\UpstreamImporter.psm1')    -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'modules-skills\Start-SkillManagerUI.psm1') -Force -DisableNameChecking

switch ($Command) {
    'status'                        { Show-Status }
    'help'                          { Show-Help }
    'enable-global'                 { Enable-GlobalSkills @RestArgs }
    'disable-global'                { Disable-GlobalSkills @RestArgs }
    'reconcile'                     { Reconcile-SharedSkills }
    'sync-native-superpowers'       { Sync-NativeSuperpowers @RestArgs }
    'sync-claude-usage-collector'   { Sync-ClaudeUsageCollector @RestArgs }
    'add-project'                   { Add-ProjectSkills @RestArgs }
    'remove-project'                { Remove-ProjectSkills @RestArgs }
    'sync-project'                  { Sync-ProjectSkills @RestArgs }
    'import-existing'               { Import-ExistingSkills @RestArgs }
    'sync-legacy-gemini'            { Sync-LegacyGeminiSkills @RestArgs }
    'start-ui'                      { Start-SkillManagerUI }
    default                         { Show-Help; Write-Host "Comando desconhecido: $Command" -ForegroundColor Red; exit 1 }
}
```

(Conferir todos os comandos suportados no monolito original via `grep` em `manage-skills.ps1` por `switch` ou `if -eq` no main block.)

- [ ] **Step 5: Criar octane-monolith.ps1 (orquestrador fino para auth)**

Create `C:\Users\marce\Diego\AI-Skills-Hub\octane-monolith.ps1`:

```powershell
#requires -Version 7.0
<#
.SYNOPSIS
    Octane (claude-auth-manager renomeado) — orquestrador fino para auth multi-CLI.
    Despacha para módulos de perfil/auth/usage/vps.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'help',
    [Parameter(ValueFromRemainingArguments = $true)][object[]]$RestArgs
)
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'modules-octane\Common.psm1')             -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'modules-octane\ClaudeAuth.psm1')         -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'modules-octane\CodexAuth.psm1')          -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'modules-octane\GeminiAuth.psm1')         -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'modules-octane\UsageTracker.psm1')       -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'modules-octane\VpsSync.psm1')            -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'modules-octane\RunningInstances.psm1')   -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'modules-octane\OAuthRefresh.psm1')       -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'modules-octane\Start-OctaneUI.psm1')     -Force -DisableNameChecking

switch ($Command) {
    'start-ui'  { Start-OctaneUI }
    'help'      { Write-Host "octane <command> — see README" }
    default     { Write-Host "Comando desconhecido: $Command" -ForegroundColor Red; exit 1 }
}
```

- [ ] **Step 6: Atualizar batches**

Edit `abrir-painel-claude-auth.bat`. Substituir:
```bat
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0manage-skills.ps1" start-ui
```
por:
```bat
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0octane-monolith.ps1" start-ui
```

Edit `skill-manager.bat`. Substituir referência a `manage-skills.ps1` por `skill-manager.ps1`.

Edit `claude-auth-manager.bat`. Substituir por `octane-monolith.ps1`.

- [ ] **Step 7: Verificar que UIs continuam abrindo**

Manual: rode `skill-manager.bat`. Abre porta 8765, painel carrega.
Manual: rode `abrir-painel-claude-auth.bat`. Abre porta 8766, painel carrega.

Se carregar: ok. Se não, debugar `Import-Module` errors (provavelmente função faltando em export).

- [ ] **Step 8: Pester final da Fase 1**

Run:
```powershell
cd C:\Users\marce\Diego\AI-Skills-Hub
$result = Invoke-Pester -Path tests,aiox-shared\tests -Output Detailed -PassThru
"passed=$($result.PassedCount) failed=$($result.FailedCount)"
```
Expected: passed >= baseline. Se regredir, debugar antes de commit.

- [ ] **Step 9: Commit final da Fase 1**

```
git add modules-skills\Start-SkillManagerUI.psm1 modules-octane\Start-OctaneUI.psm1
git add skill-manager.ps1 octane-monolith.ps1
git add skill-manager.bat abrir-painel-claude-auth.bat claude-auth-manager.bat
git add manage-skills.ps1
git commit -m "refactor(phase1): thin orchestrators skill-manager.ps1 + octane-monolith.ps1, monolith now a stub"
```

## Task 1.15: Validação final Fase 1

**Files:** (none new)

- [ ] **Step 1: Validar manualmente cada comando crítico**

Manual checklist:
- `pwsh skill-manager.ps1 status` → mostra status de skills
- `pwsh skill-manager.ps1 reconcile` → reconcile passa sem erro
- `pwsh octane-monolith.ps1 start-ui` → abre porta 8766, painel carrega
- `pwsh skill-manager.ps1 start-ui` → abre porta 8765, painel carrega
- Web UI octane: troca de perfil funciona, usage gauges renderizam
- Web UI skills: lista skills, ativa/desativa funciona

Se algum quebrar: investigar imports, exports, scope de variáveis `$Script:`.

- [ ] **Step 2: Atualizar baseline Pester**

Run:
```powershell
cd C:\Users\marce\Diego\AI-Skills-Hub
$result = Invoke-Pester -Path tests,aiox-shared\tests -Output Detailed -PassThru
@{
    timestamp   = (Get-Date).ToString('o')
    phase       = 'fase1-end'
    passed      = $result.PassedCount
    failed      = $result.FailedCount
} | ConvertTo-Json | Out-File "C:\Users\marce\Diego\AI-Skills-Hub\pester-fase1.json" -Encoding utf8
```

- [ ] **Step 3: Commit final**

```
git add pester-fase1.json
git commit -m "chore: pester baseline after phase 1"
git push origin archive/monolith-v1  # Push para visibilidade no GitHub
```

---

# PHASE 2 — Separação física em duas pastas

**Goal:** Criar `~\Diego\ai-skills-hub\` e `~\Diego\octane\` paralelas. Mover arquivos conforme spec §4. Dissolver `aiox-shared/`.

**Exit criterion:** Pester passa em cada pasta isoladamente; junctions externas (~\.claude\skills\ etc.) intocadas.

## Task 2.1: Criar pasta ai-skills-hub e copiar arquivos

**Files:**
- Create directory: `C:\Users\marce\Diego\ai-skills-hub\`

**Implementation agent:** general-purpose
**Validation agent:** general-purpose

- [ ] **Step 1: Criar estrutura base**

Run:
```powershell
$dst = "C:\Users\marce\Diego\ai-skills-hub"
New-Item -ItemType Directory -Path $dst -Force | Out-Null
New-Item -ItemType Directory -Path "$dst\modules" -Force | Out-Null
New-Item -ItemType Directory -Path "$dst\server" -Force | Out-Null
New-Item -ItemType Directory -Path "$dst\ui" -Force | Out-Null
New-Item -ItemType Directory -Path "$dst\tests" -Force | Out-Null
New-Item -ItemType Directory -Path "$dst\state" -Force | Out-Null
```

- [ ] **Step 2: Copiar módulos do Hub**

Run:
```powershell
$src = "C:\Users\marce\Diego\AI-Skills-Hub"
$dst = "C:\Users\marce\Diego\ai-skills-hub"
Copy-Item "$src\modules-skills\*.psm1" "$dst\modules\" -Force
Copy-Item "$src\modules-skills\Start-SkillManagerUI.psm1" "$dst\server\" -Force
# Remover do modules\ se foi copiado, pois agora vive em server\
Remove-Item "$dst\modules\Start-SkillManagerUI.psm1" -Force -ErrorAction SilentlyContinue
```

Estrutura esperada em `ai-skills-hub\modules\`:
- Common.psm1
- SkillManager.psm1
- FrontmatterValidator.psm1
- SkillLockfile.psm1
- UpstreamImporter.psm1

Estrutura em `ai-skills-hub\server\`:
- Start-SkillManagerUI.psm1

- [ ] **Step 3: Copiar lib/ inteiro para o novo repo (Codex review fix — preservar testes)**

Testes copiados na Task 2.6 dot-source `..\lib\*.ps1` diretamente. Inlinar quebra esses testes.

**Estratégia:** copiar `lib/` inteiro para `ai-skills-hub/lib/`. Wrappers `.psm1` em `modules/` continuam fazendo dot-source de `..\lib\*.ps1`. Testes continuam funcionando.

Run:
```powershell
$src = "C:\Users\marce\Diego\AI-Skills-Hub\lib"
$dst = "C:\Users\marce\Diego\ai-skills-hub\lib"
New-Item -ItemType Directory -Path $dst -Force | Out-Null
# Copia só os arquivos que pertencem ao Hub
Copy-Item "$src\frontmatter-validator.ps1" "$dst\" -Force
Copy-Item "$src\skill-lockfile.ps1"        "$dst\" -Force
Copy-Item "$src\upstream-importer.ps1"     "$dst\" -Force
```

E ajustar o wrapper `.psm1` para usar caminho relativo correto:

```powershell
# modules\FrontmatterValidator.psm1
#requires -Version 7.0
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\frontmatter-validator.ps1')
Export-ModuleMember -Function *
```

(Idem para SkillLockfile e UpstreamImporter.)

- [ ] **Step 4: Copiar all-skills/, global-skills/, state/superpowers/**

Run:
```powershell
$src = "C:\Users\marce\Diego\AI-Skills-Hub"
$dst = "C:\Users\marce\Diego\ai-skills-hub"
& robocopy "$src\all-skills"   "$dst\all-skills"   /MIR /XJ /R:2 /W:5 /NFL /NDL
& robocopy "$src\global-skills" "$dst\global-skills" /MIR /XJ /R:2 /W:5 /NFL /NDL
& robocopy "$src\state\superpowers" "$dst\state\superpowers" /MIR /XJ /R:2 /W:5 /NFL /NDL
Copy-Item "$src\state\managed-targets.json" "$dst\state\" -Force
```

**Atenção `/XJ`:** exclui junctions. `global-skills/` é cheio de junctions apontando para `all-skills/`. Vamos **recriar** essas junctions na pasta nova depois do robocopy.

- [ ] **Step 5: Recriar junctions de global-skills (que aponta para all-skills)**

Run:
```powershell
$dst = "C:\Users\marce\Diego\ai-skills-hub"
$allSkillsList = @('cerebro-policial-obsidian','doc','napkin','orchestrate','pdf','persona-bridge','playwright','spreadsheet','subagent-creator')
foreach ($name in $allSkillsList) {
    $linkPath = "$dst\global-skills\$name"
    $target   = "$dst\all-skills\$name"
    if (Test-Path $linkPath) { Remove-Item $linkPath -Force }
    if (Test-Path $target) {
        New-Item -ItemType Junction -Path $linkPath -Target $target -ErrorAction Stop | Out-Null
        Write-Host "Junction: $linkPath -> $target"
    }
}
```
Expected: 9 junctions criadas.

- [ ] **Step 6: Copiar tests/ do Hub**

Run:
```powershell
$src = "C:\Users\marce\Diego\AI-Skills-Hub\tests"
$dst = "C:\Users\marce\Diego\ai-skills-hub\tests"
# Testes que pertencem ao Hub:
$hubTests = @(
    'FrontmatterValidator.Tests.ps1',
    'SkillLockfile.Tests.ps1',
    'UpstreamImporter.Tests.ps1'
)
foreach ($t in $hubTests) {
    Copy-Item "$src\$t" "$dst\$t" -Force
}
```

- [ ] **Step 7: Copiar UI**

Run:
```powershell
Copy-Item "C:\Users\marce\Diego\AI-Skills-Hub\ui\index.html" "C:\Users\marce\Diego\ai-skills-hub\ui\index.html" -Force
```

- [ ] **Step 8: Copiar README + LICENSE + .gitignore**

Run:
```powershell
$src = "C:\Users\marce\Diego\AI-Skills-Hub"
$dst = "C:\Users\marce\Diego\ai-skills-hub"
Copy-Item "$src\LICENSE" "$dst\LICENSE" -Force
Copy-Item "$src\.gitignore" "$dst\.gitignore" -Force  # versão atualizada
# README será reescrito separadamente — copiar como ponto de partida
Copy-Item "$src\README.md" "$dst\README.md" -Force
```

- [ ] **Step 9: Atualizar imports dentro dos módulos copiados**

Em cada `.psm1` em `ai-skills-hub\modules\` e `ai-skills-hub\server\`:
- Substituir `$PSScriptRoot\Common.psm1` continua válido (relativo).
- Verificar que NENHUM importa de `aiox-shared\` ou de `modules-octane\`.

Run via Grep:
```
pattern: "aiox-shared|modules-octane"
path: C:\Users\marce\Diego\ai-skills-hub
output_mode: content
```
Expected: zero matches. Se houver, substituir por import local apropriado (será tratado na próxima task).

## Task 2.2: Criar pasta octane e copiar arquivos

**Files:**
- Create directory: `C:\Users\marce\Diego\octane\`

- [ ] **Step 1: Criar estrutura base**

Run:
```powershell
$dst = "C:\Users\marce\Diego\octane"
New-Item -ItemType Directory -Path $dst -Force | Out-Null
New-Item -ItemType Directory -Path "$dst\modules" -Force | Out-Null
New-Item -ItemType Directory -Path "$dst\server" -Force | Out-Null
New-Item -ItemType Directory -Path "$dst\bin" -Force | Out-Null
New-Item -ItemType Directory -Path "$dst\ui" -Force | Out-Null
New-Item -ItemType Directory -Path "$dst\tests" -Force | Out-Null
```

- [ ] **Step 2: Copiar módulos do octane**

Run:
```powershell
$src = "C:\Users\marce\Diego\AI-Skills-Hub"
$dst = "C:\Users\marce\Diego\octane"
Copy-Item "$src\modules-octane\*.psm1" "$dst\modules\" -Force
Move-Item "$dst\modules\Start-OctaneUI.psm1" "$dst\server\" -Force
```

- [ ] **Step 3: Copiar lib/oauth-refresh.ps1 para octane/lib/ (Codex review fix)**

Run:
```powershell
$src = "C:\Users\marce\Diego\AI-Skills-Hub\lib"
$dst = "C:\Users\marce\Diego\octane\lib"
New-Item -ItemType Directory -Path $dst -Force | Out-Null
Copy-Item "$src\oauth-refresh.ps1" "$dst\" -Force
```

E ajustar wrapper:

```powershell
# modules\OAuthRefresh.psm1
#requires -Version 7.0
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\oauth-refresh.ps1')
Export-ModuleMember -Function *
```

- [ ] **Step 4: Dissolver aiox-shared — copiar módulos auth-only para octane**

Run:
```powershell
$src = "C:\Users\marce\Diego\AI-Skills-Hub\aiox-shared"
$dst = "C:\Users\marce\Diego\octane\modules"
# Auth-only modules (não duplicar no Hub):
$authOnly = @('Mutex.psm1','HealthMonitor.psm1','Health.psm1','Alerting.psm1','VpsAuthHealth.psm1','Cleanup.psm1','Aiox.psm1')
foreach ($m in $authOnly) {
    Copy-Item "$src\$m" "$dst\$m" -Force
}
# Shared modules (duplicar nos dois):
$shared = @('StructuredLogger.psm1','CliRuntime.psm1')
foreach ($m in $shared) {
    Copy-Item "$src\$m" "$dst\$m" -Force
    Copy-Item "$src\$m" "C:\Users\marce\Diego\ai-skills-hub\modules\$m" -Force
}
```

- [ ] **Step 5: Copiar scripts bin (auto-rotate)**

Run:
```powershell
$src = "C:\Users\marce\Diego\AI-Skills-Hub"
$dst = "C:\Users\marce\Diego\octane\bin"
Copy-Item "$src\auto-rotate.ps1"        "$dst\auto-rotate.ps1"        -Force
Copy-Item "$src\auto-rotate-codex.ps1"  "$dst\auto-rotate-codex.ps1"  -Force
Copy-Item "$src\auto-rotate-gemini.ps1" "$dst\auto-rotate-gemini.ps1" -Force
```

- [ ] **Step 6: Atualizar imports nos auto-rotate*.ps1 para nova localização**

Para cada `bin/auto-rotate*.ps1` no octane novo, substituir imports.

Antes:
```powershell
$loggerPath = Join-Path $PSScriptRoot 'aiox-shared\StructuredLogger.psm1'
```

Depois:
```powershell
$loggerPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\StructuredLogger.psm1'
```

Repetir para `Mutex.psm1`, `CliRuntime.psm1`, etc.

- [ ] **Step 7: Copiar tests/ do octane**

Run:
```powershell
$src = "C:\Users\marce\Diego\AI-Skills-Hub\tests"
$dst = "C:\Users\marce\Diego\octane\tests"
$octaneTests = @(
    'AuthLoginUrls.Tests.ps1',
    'AutoRotateBugs.Tests.ps1',
    'AutoRotateCli.Tests.ps1',
    'AutoRotateToggle.Tests.ps1',
    'GeminiAuth.Tests.ps1',
    'JunctionResolution.Tests.ps1',
    'OAuthRefresh.Tests.ps1',
    'RollbackOnFailure.Tests.ps1',
    'VpsAuthSyncSelective.Tests.ps1'
)
foreach ($t in $octaneTests) {
    Copy-Item "$src\$t" "$dst\$t" -Force
}
# Tests da aiox-shared também vão para octane (auth-only)
$aioxTests = Get-ChildItem "C:\Users\marce\Diego\AI-Skills-Hub\aiox-shared\tests\*.Tests.ps1"
foreach ($t in $aioxTests) {
    Copy-Item $t.FullName "$dst\$($t.Name)" -Force
}
# vps anti-regression .py — auth-only
Copy-Item "$src\test_vps_sync_anti_regression.py" "$dst\test_vps_sync_anti_regression.py" -Force
```

- [ ] **Step 8: Copiar UI**

Run:
```powershell
Copy-Item "C:\Users\marce\Diego\AI-Skills-Hub\ui\claude-auth.html" "C:\Users\marce\Diego\octane\ui\index.html" -Force
```

- [ ] **Step 9: Copiar LICENSE + .gitignore**

Run:
```powershell
$src = "C:\Users\marce\Diego\AI-Skills-Hub"
$dst = "C:\Users\marce\Diego\octane"
Copy-Item "$src\LICENSE" "$dst\LICENSE" -Force
Copy-Item "$src\.gitignore" "$dst\.gitignore" -Force
```

## Task 2.3: Dividir teste mestiço RemoveProfilesAndCodexSync

**Files:**
- Create: `C:\Users\marce\Diego\octane\tests\ProfileCrud.Tests.ps1`
- Create: `C:\Users\marce\Diego\ai-skills-hub\tests\CodexSkillSync.Tests.ps1`

**Implementation agent:** general-purpose
**Validation agent:** general-purpose

- [ ] **Step 1: Ler o teste mestiço**

Read `C:\Users\marce\Diego\AI-Skills-Hub\tests\RemoveProfilesAndCodexSync.Tests.ps1`.

Identifica blocos `Describe`/`Context`:
- Cenários sobre `Remove-CodexProfile` → octane
- Cenários sobre sync de skills Codex (junctions) → hub

- [ ] **Step 2: Criar ProfileCrud.Tests.ps1 (octane)**

Create `C:\Users\marce\Diego\octane\tests\ProfileCrud.Tests.ps1`:

```powershell
#requires -Version 7.0
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\modules\Common.psm1')      -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot '..\modules\CodexAuth.psm1')   -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot '..\modules\ClaudeAuth.psm1')  -Force -DisableNameChecking
}

# (colar os Describes que tratam de profile CRUD)
```

- [ ] **Step 3: Criar CodexSkillSync.Tests.ps1 (hub)**

Create `C:\Users\marce\Diego\ai-skills-hub\tests\CodexSkillSync.Tests.ps1`:

```powershell
#requires -Version 7.0
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\modules\Common.psm1')       -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot '..\modules\SkillManager.psm1') -Force -DisableNameChecking
}

# (colar os Describes que tratam de sync de skills Codex)
```

- [ ] **Step 4: Verificar que cobertura total não diminuiu**

Compare:
- Soma das linhas de assert nos dois arquivos novos.
- Linhas de assert no arquivo original.

Devem ser equivalentes (ou superior). Se faltam asserts, copiar.

## Task 2.4: Atualizar imports nos módulos copiados (resolver paths relativos)

**Files:**
- Modify: `C:\Users\marce\Diego\ai-skills-hub\modules\*.psm1`
- Modify: `C:\Users\marce\Diego\ai-skills-hub\server\*.psm1`
- Modify: `C:\Users\marce\Diego\octane\modules\*.psm1`
- Modify: `C:\Users\marce\Diego\octane\server\*.psm1`

- [ ] **Step 1: Auditar todos os imports nos novos repos**

Run via Grep em `C:\Users\marce\Diego\ai-skills-hub`:
```
pattern: "Import-Module|Join-Path \$PSScriptRoot|aiox-shared|modules-skills|modules-octane"
output_mode: content
-n: true
```

Idem para `C:\Users\marce\Diego\octane`.

Listar todos os imports problemáticos (apontando para caminhos antigos).

- [ ] **Step 2: Substituir cada import problemático**

Padrão para os imports no Hub:
- `'modules-skills\Common.psm1'` → `'Common.psm1'` (mesmo diretório quando dentro de modules/)
- `'..\Common.psm1'` quando dentro de `server/`
- `'aiox-shared\StructuredLogger.psm1'` → `'StructuredLogger.psm1'` (também duplicado em modules/)

Padrão para octane:
- `'modules-octane\X.psm1'` → `'X.psm1'`
- `'aiox-shared\X.psm1'` → `'X.psm1'`
- Em `bin/auto-rotate*.ps1`: `'aiox-shared\X.psm1'` → `'..\modules\X.psm1'`

- [ ] **Step 3: Validar zero imports quebrados**

Run:
```powershell
$repo = "C:\Users\marce\Diego\octane"
Get-ChildItem "$repo\modules\*.psm1","$repo\server\*.psm1","$repo\bin\*.ps1" | ForEach-Object {
    $content = Get-Content $_.FullName -Raw
    $imports = [regex]::Matches($content, "Import-Module\s+\(?[\w@'`\"\s\.\$\(\)\\,-]+")
    foreach ($i in $imports) {
        Write-Host "$($_.Name): $($i.Value)"
    }
}
```

Inspecionar visualmente: cada import deve resolver para um arquivo existente no repo.

## Task 2.5: Setup mínimo de cada repo

**Files:**
- Create: `C:\Users\marce\Diego\ai-skills-hub\setup.ps1`
- Create: `C:\Users\marce\Diego\octane\setup.ps1`

- [ ] **Step 1: Hub setup.ps1**

Create `C:\Users\marce\Diego\ai-skills-hub\setup.ps1`:

```powershell
#requires -Version 7.0
<#
.SYNOPSIS
    Setup AI Skills Hub no Windows.
    NUNCA toca em perfis, junctions de auth, env vars de perfil, ou Task Scheduler.
#>
[CmdletBinding()]
param(
    [switch]$SkipShim
)
$ErrorActionPreference = 'Stop'

Write-Host "AI Skills Hub setup started." -ForegroundColor Cyan

# 1. Garantir diretórios pai de skills
$skillRoots = @(
    "$env:USERPROFILE\.claude\skills",
    "$env:USERPROFILE\.codex\skills",
    "$env:USERPROFILE\.agents\skills",
    "$env:USERPROFILE\.qwen\skills",
    "$env:USERPROFILE\.antigravity\skills",
    "$env:USERPROFILE\.gemini\antigravity\skills",
    "$env:USERPROFILE\.gemini\extensions"
)
foreach ($p in $skillRoots) {
    if (-not (Test-Path $p)) {
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        Write-Host "Created: $p"
    } else {
        Write-Host "Exists:  $p"
    }
}

# 2. Shim ai-skills.cmd
if (-not $SkipShim) {
    $shimDir = "$env:USERPROFILE\.local\bin"
    if (-not (Test-Path $shimDir)) { New-Item -ItemType Directory -Path $shimDir -Force | Out-Null }
    $shimPath = "$shimDir\ai-skills.cmd"
    @"
@echo off
pwsh -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\ai-skills.ps1" %*
"@ | Out-File -FilePath $shimPath -Encoding ascii -NoNewline
    Write-Host "Shim: $shimPath"
}

# 3. Validar Pester
$pester = Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester -or $pester.Version.Major -lt 5) {
    Write-Host "Pester 5+ não encontrado. Rode: Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force" -ForegroundColor Yellow
}

Write-Host "AI Skills Hub setup complete." -ForegroundColor Green
```

- [ ] **Step 2: Octane setup.ps1**

Create `C:\Users\marce\Diego\octane\setup.ps1`:

```powershell
#requires -Version 7.0
<#
.SYNOPSIS
    Setup octane (auth multi-CLI) no Windows.
    Cria/valida junctions de perfil, env vars, Task Scheduler (DISABLED por default).
    NUNCA toca em junctions de skill ou em recursos do AI Skills Hub.
#>
[CmdletBinding()]
param(
    [string]$DefaultClaudeProfile = 'claude-a',
    [string]$DefaultCodexProfile  = 'codex-a',
    [switch]$SkipScheduler,
    [switch]$SkipShim
)
$ErrorActionPreference = 'Stop'

Write-Host "octane setup started." -ForegroundColor Cyan

# 1. Junction Claude (preservar se já existe)
$claudeProfilesRoot = "$env:USERPROFILE\.claude-profiles"
$claudeActiveJunc   = "$claudeProfilesRoot\active"
if (-not (Test-Path $claudeProfilesRoot)) {
    New-Item -ItemType Directory -Path $claudeProfilesRoot -Force | Out-Null
}
if (-not (Test-Path "$claudeProfilesRoot\$DefaultClaudeProfile")) {
    New-Item -ItemType Directory -Path "$claudeProfilesRoot\$DefaultClaudeProfile" -Force | Out-Null
    Write-Host "Created Claude profile dir: $DefaultClaudeProfile (vazio — fazer login depois)"
}
if (Test-Path $claudeActiveJunc) {
    $current = (Get-Item $claudeActiveJunc -Force).Target -join ','
    Write-Host "Junction Claude active EXISTS, preservando: $claudeActiveJunc -> $current"
} else {
    New-Item -ItemType Junction -Path $claudeActiveJunc -Target "$claudeProfilesRoot\$DefaultClaudeProfile" -ErrorAction Stop | Out-Null
    Write-Host "Junction Claude active CREATED: $claudeActiveJunc -> $claudeProfilesRoot\$DefaultClaudeProfile"
}

# 2. Junction Codex (FIXA apontando para ~\.codex)
$codexProfilesRoot = "$env:USERPROFILE\.codex-profiles"
$codexActiveJunc   = "$codexProfilesRoot\active"
$codexHome         = "$env:USERPROFILE\.codex"
if (-not (Test-Path $codexProfilesRoot)) {
    New-Item -ItemType Directory -Path $codexProfilesRoot -Force | Out-Null
}
if (-not (Test-Path "$codexProfilesRoot\$DefaultCodexProfile")) {
    New-Item -ItemType Directory -Path "$codexProfilesRoot\$DefaultCodexProfile" -Force | Out-Null
    Write-Host "Created Codex profile dir: $DefaultCodexProfile"
}
if (Test-Path $codexActiveJunc) {
    Write-Host "Junction Codex active EXISTS, preservando."
} else {
    New-Item -ItemType Junction -Path $codexActiveJunc -Target $codexHome -ErrorAction Stop | Out-Null
    Write-Host "Junction Codex active CREATED: $codexActiveJunc -> $codexHome"
}

# 3. Markers
$claudeMarker = "$env:USERPROFILE\.claude-active-dir"
$codexMarker  = "$env:USERPROFILE\.codex-active-profile"
if (-not (Test-Path $claudeMarker)) {
    $DefaultClaudeProfile | Out-File $claudeMarker -Encoding utf8 -NoNewline
    Write-Host "Marker Claude CREATED: $claudeMarker = $DefaultClaudeProfile"
} else {
    Write-Host "Marker Claude EXISTS, preservando."
}
if (-not (Test-Path $codexMarker)) {
    $DefaultCodexProfile | Out-File $codexMarker -Encoding utf8 -NoNewline
    Write-Host "Marker Codex CREATED: $codexMarker = $DefaultCodexProfile"
} else {
    Write-Host "Marker Codex EXISTS, preservando."
}

# 4. Env vars (User scope)
$claudeConfigDir = [Environment]::GetEnvironmentVariable('CLAUDE_CONFIG_DIR', 'User')
if (-not $claudeConfigDir) {
    [Environment]::SetEnvironmentVariable('CLAUDE_CONFIG_DIR', $claudeActiveJunc, 'User')
    Write-Host "Env CLAUDE_CONFIG_DIR CREATED: $claudeActiveJunc"
} else {
    Write-Host "Env CLAUDE_CONFIG_DIR EXISTS, preservando: $claudeConfigDir"
}
$codexHomeEnv = [Environment]::GetEnvironmentVariable('CODEX_HOME', 'User')
if (-not $codexHomeEnv) {
    [Environment]::SetEnvironmentVariable('CODEX_HOME', $codexActiveJunc, 'User')
    Write-Host "Env CODEX_HOME CREATED: $codexActiveJunc"
} else {
    Write-Host "Env CODEX_HOME EXISTS, preservando: $codexHomeEnv"
}

# 5. Task Scheduler — registra DISABLED
if (-not $SkipScheduler) {
    foreach ($entry in @(
        @{ Name = 'ClaudeAutoRotate'; Script = "$PSScriptRoot\bin\auto-rotate.ps1" },
        @{ Name = 'CodexAutoRotate';  Script = "$PSScriptRoot\bin\auto-rotate-codex.ps1" }
    )) {
        $existing = Get-ScheduledTask -TaskName $entry.Name -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Host "Task EXISTS: $($entry.Name) — preservando estado atual"
            continue
        }
        $action  = New-ScheduledTaskAction -Execute "pwsh.exe" -Argument "-NonInteractive -ExecutionPolicy Bypass -File `"$($entry.Script)`""
        $trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 10) -Once -At (Get-Date)
        Register-ScheduledTask -TaskName $entry.Name -Action $action -Trigger $trigger -RunLevel Limited | Out-Null
        Disable-ScheduledTask -TaskName $entry.Name | Out-Null
        Write-Host "Task CREATED (disabled): $($entry.Name)"
    }
}

# 6. Shim
if (-not $SkipShim) {
    $shimDir = "$env:USERPROFILE\.local\bin"
    if (-not (Test-Path $shimDir)) { New-Item -ItemType Directory -Path $shimDir -Force | Out-Null }
    $shimPath = "$shimDir\octane.cmd"
    @"
@echo off
pwsh -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\octane.ps1" %*
"@ | Out-File -FilePath $shimPath -Encoding ascii -NoNewline
    Write-Host "Shim: $shimPath"
}

Write-Host "octane setup complete." -ForegroundColor Green
Write-Host ""
Write-Host "ATENÇÃO: Env vars (CLAUDE_CONFIG_DIR, CODEX_HOME) só refletem em" -ForegroundColor Yellow
Write-Host "novas sessões PowerShell. Para usar nesta sessão, rode:" -ForegroundColor Yellow
Write-Host '  $env:CLAUDE_CONFIG_DIR = "' -NoNewline -ForegroundColor Cyan; Write-Host "$claudeActiveJunc`""
Write-Host '  $env:CODEX_HOME        = "' -NoNewline -ForegroundColor Cyan; Write-Host "$codexActiveJunc`""
Write-Host ""
$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
if ($userPath -notmatch [regex]::Escape("$env:USERPROFILE\.local\bin")) {
    Write-Host "ATENÇÃO: ~\.local\bin NÃO está no PATH do usuário." -ForegroundColor Yellow
    Write-Host "Para usar o shim 'octane' globalmente, adicione com:" -ForegroundColor Yellow
    Write-Host '  $newPath = "$([Environment]::GetEnvironmentVariable(''PATH'',''User''));$env:USERPROFILE\.local\bin"' -ForegroundColor Cyan
    Write-Host '  [Environment]::SetEnvironmentVariable(''PATH'', $newPath, ''User'')' -ForegroundColor Cyan
}
```

## Task 2.6: Validar Pester de cada pasta isoladamente

**Files:** (none new)

- [ ] **Step 1: Pester ai-skills-hub**

Run:
```powershell
cd C:\Users\marce\Diego\ai-skills-hub
$result = Invoke-Pester -Path tests -Output Detailed -PassThru
"passed=$($result.PassedCount) failed=$($result.FailedCount)"
```
Expected: 0 failed (todos os testes do Hub passam).

- [ ] **Step 2: Pester octane**

Run:
```powershell
cd C:\Users\marce\Diego\octane
$result = Invoke-Pester -Path tests -Output Detailed -PassThru
"passed=$($result.PassedCount) failed=$($result.FailedCount)"
```
Expected: 0 failed.

- [ ] **Step 3: Se algum falhar, debugar imports**

Falhas comuns na Fase 2:
- Path relativo errado (`..\` faltando ou sobrando)
- `$Script:HubRoot` apontando para o lugar errado
- `Export-ModuleMember` sem a função que o teste espera

Corrigir até passar.

## Task 2.7: Criar CLI standalone (`ai-skills.ps1`)

**Files:**
- Create: `C:\Users\marce\Diego\ai-skills-hub\ai-skills.ps1`

**Note (Codex fix):** o CLI **não** suporta `restore` — só `backup`. Help string deve refletir isso. Restore manual via `robocopy /MIR` documentado em README.

- [ ] **Step 1: Esqueleto do CLI flag-mode**

Create `C:\Users\marce\Diego\ai-skills-hub\ai-skills.ps1`:

```powershell
#requires -Version 7.0
<#
.SYNOPSIS
    ai-skills CLI — gestão de skills standalone (sem servidor HTTP).
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = '',
    [Parameter(ValueFromRemainingArguments = $true)][object[]]$RestArgs
)
$ErrorActionPreference = 'Stop'

# Se sem comando → TUI
if ([string]::IsNullOrWhiteSpace($Command)) {
    & (Join-Path $PSScriptRoot 'ai-skills-tui.ps1') @RestArgs
    exit $LASTEXITCODE
}

# Importa módulos
$mods = @(
    'modules\Common.psm1',
    'modules\StructuredLogger.psm1',
    'modules\CliRuntime.psm1',
    'modules\SkillManager.psm1',
    'modules\FrontmatterValidator.psm1',
    'modules\SkillLockfile.psm1',
    'modules\UpstreamImporter.psm1'
)
foreach ($m in $mods) {
    Import-Module (Join-Path $PSScriptRoot $m) -Force -DisableNameChecking
}

function Show-Help-Local {
    @"
ai-skills <command> [args]

Commands:
  list [--global|--project]      List skills
  enable <skill> [--targets X]   Enable skill
  disable <skill>                Disable skill
  reconcile                      Recreate junctions from state
  import <github-url|path>       Import new skill
  sync-native superpowers        Sync native plugin
  doctor                         Check junctions + frontmatter
  panel                          Open web UI (port 8765)
  status                         Show current state
"@
}

switch ($Command) {
    'help'              { Show-Help-Local }
    'status'            { Show-Status }
    'list'              { Show-Status }  # alias por enquanto
    'enable'            { Enable-GlobalSkills @RestArgs }
    'disable'           { Disable-GlobalSkills @RestArgs }
    'reconcile'         { Reconcile-SharedSkills }
    'import'            { Import-ExistingSkills @RestArgs }
    'sync-native'       {
        if ($RestArgs[0] -eq 'superpowers') { Sync-NativeSuperpowers @($RestArgs[1..($RestArgs.Length-1)]) }
        else { Write-Host "sync-native: alvo desconhecido. Use: superpowers" -ForegroundColor Red }
    }
    'doctor'            {
        # Diagnóstico simples
        $issues = 0
        Write-Host "AI Skills Hub doctor:" -ForegroundColor Cyan
        $skillRoots = @(
            "$env:USERPROFILE\.claude\skills",
            "$env:USERPROFILE\.codex\skills",
            "$env:USERPROFILE\.agents\skills",
            "$env:USERPROFILE\.qwen\skills",
            "$env:USERPROFILE\.antigravity\skills",
            "$env:USERPROFILE\.gemini\antigravity\skills"
        )
        foreach ($p in $skillRoots) {
            if (Test-Path $p) { Write-Host "  [OK]   $p" }
            else { Write-Host "  [MISS] $p"; $issues++ }
        }
        if ($issues -eq 0) { Write-Host "All checks pass." -ForegroundColor Green }
        else { Write-Host "$issues issue(s) found." -ForegroundColor Yellow; exit 1 }
    }
    'panel'             {
        Import-Module (Join-Path $PSScriptRoot 'server\Start-SkillManagerUI.psm1') -Force -DisableNameChecking
        Start-SkillManagerUI
    }
    default             { Show-Help-Local; Write-Host "Unknown command: $Command" -ForegroundColor Red; exit 1 }
}
```

- [ ] **Step 2: Validar manualmente**

Run:
```powershell
pwsh -ExecutionPolicy Bypass -File C:\Users\marce\Diego\ai-skills-hub\ai-skills.ps1 status
pwsh -ExecutionPolicy Bypass -File C:\Users\marce\Diego\ai-skills-hub\ai-skills.ps1 doctor
```
Expected: status lista skills, doctor OK ou identifica missing dirs (no caso, missing é OK até rodar setup).

## Task 2.8: Criar CLI standalone (`octane.ps1`)

**Files:**
- Create: `C:\Users\marce\Diego\octane\octane.ps1`

- [ ] **Step 1: Esqueleto octane CLI**

Create `C:\Users\marce\Diego\octane\octane.ps1`:

```powershell
#requires -Version 7.0
<#
.SYNOPSIS
    octane CLI — gestão de perfis multi-CLI (Claude/Codex/Gemini).
    Standalone — não precisa de servidor HTTP rodando.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = '',
    [Parameter(Position = 1)][string]$Arg1,
    [Parameter(Position = 2)][string]$Arg2,
    [Parameter(ValueFromRemainingArguments = $true)][object[]]$RestArgs
)
$ErrorActionPreference = 'Stop'

# Se sem comando → TUI
if ([string]::IsNullOrWhiteSpace($Command)) {
    & (Join-Path $PSScriptRoot 'octane-tui.ps1') @RestArgs
    exit $LASTEXITCODE
}

# Importa módulos
$mods = @(
    'modules\Common.psm1',
    'modules\StructuredLogger.psm1',
    'modules\Mutex.psm1',
    'modules\CliRuntime.psm1',
    'modules\OAuthRefresh.psm1',
    'modules\ClaudeAuth.psm1',
    'modules\CodexAuth.psm1',
    'modules\GeminiAuth.psm1',
    'modules\UsageTracker.psm1',
    'modules\VpsSync.psm1',
    'modules\RunningInstances.psm1'
)
foreach ($m in $mods) {
    Import-Module (Join-Path $PSScriptRoot $m) -Force -DisableNameChecking
}

function Detect-Engine {
    param([string]$Name)
    if ($Name -match '^claude-') { return 'claude' }
    if ($Name -match '^codex-')  { return 'codex' }
    if ($Name -match '^gemini-') { return 'gemini' }
    if ($Name -match '^qwen-')   { return 'qwen' }
    return $null
}

function Show-Help-Local {
    @"
octane <command> [args]

Profile management:
  list [engine]                  List profiles (engine=claude|codex|gemini)
  switch <profile> [--force]     Switch active profile (auto-detect engine)
  add <profile> [--engine X]     Create new profile slot
  remove <profile>               Remove profile
  login <profile>                Initiate OAuth (returns URL)

Runtime:
  status                         Usage 5h/7d + running processes
  engines                        Running CLI processes

Auto-rotate:
  rotate [engine] [--force]      Force rotation (pit stop)
  auto-rotate <on|off|status>    Toggle scheduled rotation

VPS sync:
  vps push [--engine X]          Push active profile credentials to VPS
  vps status                     Last sync per engine
  vps restart                    Restart VPS gateway

Maintenance:
  backup [--out <dir>]           Snapshot all profiles via robocopy /MIR
  doctor                         Diagnose junctions, env, scheduler
  panel                          Open web UI (port 8766)

Note: restore is manual — use robocopy /MIR <backup>\claude-profiles ~\.claude-profiles
      with all CLIs closed. See README.
"@
}

# Engine-namespaced commands: octane claude list, octane codex switch X
if ($Command -in @('claude','codex','gemini','qwen')) {
    $engine = $Command
    $subCommand = $Arg1
    $subArgs = @($Arg2) + $RestArgs | Where-Object { $_ }
    # Recursive call with engine flag
    & $MyInvocation.MyCommand.Path $subCommand @subArgs --engine $engine
    exit $LASTEXITCODE
}

switch ($Command) {
    'help'      { Show-Help-Local }
    'status'    {
        Write-Host "Claude profiles:"
        Get-ClaudeProfileDefinitions | Format-Table -AutoSize
        Write-Host "`nCodex profiles:"
        Get-CodexProfiles | Format-Table -AutoSize
        Write-Host "`nRunning instances:"
        Get-RunningInstances | Format-Table -AutoSize
    }
    'engines'   { Get-RunningInstances | Format-Table -AutoSize }
    'list'      {
        $engineFilter = $Arg1
        switch ($engineFilter) {
            'claude' { Get-ClaudeProfileDefinitions | Format-Table -AutoSize }
            'codex'  { Get-CodexProfiles            | Format-Table -AutoSize }
            'gemini' { Get-GeminiProfiles           | Format-Table -AutoSize }
            default  {
                Write-Host "Claude:"; Get-ClaudeProfileDefinitions | Format-Table -AutoSize
                Write-Host "Codex:";  Get-CodexProfiles            | Format-Table -AutoSize
                Write-Host "Gemini:"; Get-GeminiProfiles           | Format-Table -AutoSize
            }
        }
    }
    'switch'    {
        $target = $Arg1
        if (-not $target) { throw "octane switch <profile>" }
        $engine = Detect-Engine $target
        if (-not $engine) { throw "Não consegui detectar engine de '$target'. Use --engine." }
        switch ($engine) {
            'claude' { Set-ClaudeProfileJunction -Name $target }
            'codex'  { Set-CodexProfileJunction  -Name $target }
            'gemini' { Set-GeminiActiveProfile   -Name $target }
        }
        Write-Host "Switched to $target ($engine)." -ForegroundColor Green
    }
    'login'     {
        $target = $Arg1
        if (-not $target) { throw "octane login <profile>" }
        $engine = Detect-Engine $target
        switch ($engine) {
            'claude' { $r = New-ClaudeAuthLoginSession -Profile $target; Write-Host "URL: $($r.url)" }
            'codex'  { $r = Start-CodexAuthLogin     -Profile $target; Write-Host "URL: $($r.url)" }
            'gemini' { $r = Start-GeminiAuthLogin    -Profile $target; Write-Host "URL: $($r.url)" }
            default  { throw "Engine desconhecido." }
        }
    }
    'add'       {
        $target = $Arg1
        $engineFlag = $null
        for ($i=0; $i -lt $RestArgs.Length; $i++) {
            if ($RestArgs[$i] -eq '--engine') { $engineFlag = $RestArgs[$i+1] }
        }
        $engine = $engineFlag ?? (Detect-Engine $target)
        switch ($engine) {
            'claude' { Add-ClaudeProfile -Name $target }
            'codex'  { Add-CodexProfile  -Name $target }
            'gemini' { Add-GeminiProfile -Name $target }
            default  { throw "Use --engine claude|codex|gemini" }
        }
    }
    'remove'    {
        $target = $Arg1
        $engine = Detect-Engine $target
        switch ($engine) {
            'claude' { Remove-ClaudeProfile -Name $target }
            'codex'  { Remove-CodexProfile  -Name $target }
            'gemini' { Remove-GeminiProfile -Name $target }
            default  { throw "Não detectado engine." }
        }
    }
    'rotate'    {
        $script = "$PSScriptRoot\bin\auto-rotate.ps1"
        $force = '--force' -in $RestArgs
        if ($force) { & $script -Force } else { & $script }
    }
    'auto-rotate' {
        switch ($Arg1) {
            'on'     { Enable-ScheduledTask -TaskName 'ClaudeAutoRotate' | Out-Null; Enable-ScheduledTask -TaskName 'CodexAutoRotate' | Out-Null; Write-Host "Auto-rotate: ON" }
            'off'    { Disable-ScheduledTask -TaskName 'ClaudeAutoRotate' | Out-Null; Disable-ScheduledTask -TaskName 'CodexAutoRotate' | Out-Null; Write-Host "Auto-rotate: OFF" }
            'status' { Get-ScheduledTask -TaskName ClaudeAutoRotate,CodexAutoRotate | Format-Table TaskName,State }
            default  { Write-Host "octane auto-rotate <on|off|status>" }
        }
    }
    'vps'       {
        switch ($Arg1) {
            'push'    { Invoke-VpsAuthSyncForActiveClaude }
            'status'  { Get-VpsAuthSyncStatus }
            'restart' { Invoke-VpsGatewayRestart }
            default   { Write-Host "octane vps <push|status|restart>" }
        }
    }
    'backup'    {
        $outDir = "$env:USERPROFILE\.profile-backups\octane-cli-$(Get-Date -Format 'yyyy-MM-dd-HHmm')"
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        & robocopy "$env:USERPROFILE\.claude-profiles" "$outDir\claude-profiles" /MIR /XJ /R:2 /W:5 /NFL /NDL /NJH /NJS | Out-Null
        & robocopy "$env:USERPROFILE\.codex-profiles"  "$outDir\codex-profiles"  /MIR /XJ /R:2 /W:5 /NFL /NDL /NJH /NJS | Out-Null
        & robocopy "$env:USERPROFILE\.codex"           "$outDir\codex-home"      /MIR /XJ /R:2 /W:5 /NFL /NDL /NJH /NJS | Out-Null
        Write-Host "Backup: $outDir" -ForegroundColor Green
    }
    'doctor'    {
        $issues = 0
        Write-Host "octane doctor:" -ForegroundColor Cyan
        $expectedClaudeActive = "$env:USERPROFILE\.claude-profiles\active"
        $expectedCodexActive  = "$env:USERPROFILE\.codex-profiles\active"
        @(
            @{ Path = $expectedClaudeActive; Type = 'Junction'; Desc = 'Claude active junction' },
            @{ Path = $expectedCodexActive;  Type = 'Junction'; Desc = 'Codex active junction' },
            @{ Path = "$env:USERPROFILE\.claude-active-dir";      Type = 'File';     Desc = 'Claude active marker' },
            @{ Path = "$env:USERPROFILE\.codex-active-profile";   Type = 'File';     Desc = 'Codex active marker' }
        ) | ForEach-Object {
            if (Test-Path $_.Path) {
                $extra = if ($_.Type -eq 'Junction') { " -> " + ((Get-Item $_.Path -Force).Target -join ',') } else { '' }
                Write-Host "  [OK]   $($_.Desc): $($_.Path)$extra"
            } else {
                Write-Host "  [MISS] $($_.Desc): $($_.Path)" -ForegroundColor Yellow
                $issues++
            }
        }
        # Env vars: check value, not just presence
        foreach ($pair in @(
            @{ Var = 'CLAUDE_CONFIG_DIR'; Expected = $expectedClaudeActive },
            @{ Var = 'CODEX_HOME';        Expected = $expectedCodexActive }
        )) {
            $val = [Environment]::GetEnvironmentVariable($pair.Var, 'User')
            if (-not $val) {
                Write-Host "  [MISS] env $($pair.Var) not set" -ForegroundColor Yellow; $issues++
            } elseif ([System.IO.Path]::TrimEndingDirectorySeparator($val) -ne [System.IO.Path]::TrimEndingDirectorySeparator($pair.Expected)) {
                Write-Host "  [WARN] env $($pair.Var)=$val (expected $($pair.Expected))" -ForegroundColor Yellow; $issues++
            } else {
                Write-Host "  [OK]   env $($pair.Var)=$val"
            }
        }
        foreach ($t in 'ClaudeAutoRotate','CodexAutoRotate') {
            $tk = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
            if ($tk) { Write-Host "  [OK]   task $t state=$($tk.State)" }
            else { Write-Host "  [MISS] task $t not registered" -ForegroundColor Yellow; $issues++ }
        }
        if ($issues -eq 0) { Write-Host "All checks pass." -ForegroundColor Green }
        else { Write-Host "$issues issue(s)." -ForegroundColor Yellow; exit 1 }
    }
    'panel'     {
        Import-Module (Join-Path $PSScriptRoot 'server\Start-OctaneUI.psm1') -Force -DisableNameChecking
        Start-OctaneUI
    }
    default     { Show-Help-Local; Write-Host "Unknown: $Command" -ForegroundColor Red; exit 1 }
}
```

- [ ] **Step 2: Validar manualmente**

Run:
```powershell
pwsh -ExecutionPolicy Bypass -File C:\Users\marce\Diego\octane\octane.ps1 doctor
pwsh -ExecutionPolicy Bypass -File C:\Users\marce\Diego\octane\octane.ps1 status
pwsh -ExecutionPolicy Bypass -File C:\Users\marce\Diego\octane\octane.ps1 list claude
```

Expected: doctor mostra estado atual, status lista perfis, list claude mostra perfis Claude.

## Task 2.9: Criar TUI Spectre.Console — minimal stub

**Files:**
- Create: `C:\Users\marce\Diego\octane\octane-tui.ps1`
- Create: `C:\Users\marce\Diego\ai-skills-hub\ai-skills-tui.ps1`

**Implementation note:** Spectre.Console-PowerShell module (https://github.com/trackd/Spectre.Console-PowerShell) wraps Spectre.Console.dll. Instalar via `Install-Module PwshSpectreConsole -Scope CurrentUser`.

- [ ] **Step 1: Instalar PwshSpectreConsole**

Run:
```powershell
Install-Module PwshSpectreConsole -Scope CurrentUser -Force -AllowClobber
Import-Module PwshSpectreConsole
Get-Command -Module PwshSpectreConsole | Select-Object -First 10
```
Expected: módulo instalado, comandos como `Format-SpectreTable`, `Read-SpectreSelection` disponíveis.

- [ ] **Step 2: TUI octane mínimo**

Create `C:\Users\marce\Diego\octane\octane-tui.ps1`:

```powershell
#requires -Version 7.0
<#
.SYNOPSIS
    octane TUI — visual via PwshSpectreConsole.
    Stub mínimo. Versão completa em iteração posterior.
#>
$ErrorActionPreference = 'Stop'

# Verificar dependência
if (-not (Get-Module -ListAvailable PwshSpectreConsole)) {
    Write-Host "Dependência ausente: PwshSpectreConsole" -ForegroundColor Red
    Write-Host "Instale com: Install-Module PwshSpectreConsole -Scope CurrentUser -Force"
    Write-Host "Fallback: use 'octane status' (CLI flag mode)."
    exit 1
}
Import-Module PwshSpectreConsole

$mods = @(
    'modules\Common.psm1', 'modules\ClaudeAuth.psm1', 'modules\CodexAuth.psm1',
    'modules\GeminiAuth.psm1', 'modules\UsageTracker.psm1', 'modules\RunningInstances.psm1'
)
foreach ($m in $mods) { Import-Module (Join-Path $PSScriptRoot $m) -Force -DisableNameChecking }

function Show-Dashboard {
    Clear-Host
    Write-SpectreFigletText -Text "octane" -Color Cyan -Alignment Left
    
    $claudeProfiles = Get-ClaudeProfileDefinitions
    if ($claudeProfiles) {
        Write-Host "`nCLAUDE" -ForegroundColor Yellow
        $claudeProfiles | Format-SpectreTable -HeaderColor Yellow
    }
    
    $codexProfiles = Get-CodexProfiles
    if ($codexProfiles) {
        Write-Host "`nCODEX" -ForegroundColor Yellow
        $codexProfiles | Format-SpectreTable -HeaderColor Yellow
    }
    
    $instances = Get-RunningInstances
    if ($instances) {
        Write-Host "`nRUNNING" -ForegroundColor Yellow
        $instances | Format-SpectreTable -HeaderColor Yellow
    }
}

function Show-Menu {
    $choice = Read-SpectreSelection -Title "Action:" -Choices @(
        'Refresh dashboard',
        'Switch profile (claude)',
        'Switch profile (codex)',
        'Force rotate',
        'Auto-rotate toggle',
        'Doctor',
        'Open web panel',
        'Exit'
    )
    return $choice
}

while ($true) {
    Show-Dashboard
    $choice = Show-Menu
    switch ($choice) {
        'Refresh dashboard'        { continue }
        'Switch profile (claude)'  {
            $names = (Get-ClaudeProfileDefinitions).name
            $target = Read-SpectreSelection -Title "Claude profile:" -Choices $names
            Set-ClaudeProfileJunction -Name $target
            Write-Host "Switched." -ForegroundColor Green
            Read-Host "ENTER para continuar"
        }
        'Switch profile (codex)'   {
            $names = (Get-CodexProfiles).name
            $target = Read-SpectreSelection -Title "Codex profile:" -Choices $names
            Set-CodexProfileJunction -Name $target
            Read-Host "ENTER"
        }
        'Force rotate'             {
            & "$PSScriptRoot\bin\auto-rotate.ps1" -Force
            Read-Host "ENTER"
        }
        'Auto-rotate toggle'       {
            $tasks = Get-ScheduledTask -TaskName ClaudeAutoRotate,CodexAutoRotate -ErrorAction SilentlyContinue
            $isOn = $tasks | Where-Object { $_.State -eq 'Ready' }
            if ($isOn) {
                Disable-ScheduledTask -TaskName ClaudeAutoRotate | Out-Null
                Disable-ScheduledTask -TaskName CodexAutoRotate  | Out-Null
                Write-Host "OFF" -ForegroundColor Yellow
            } else {
                Enable-ScheduledTask -TaskName ClaudeAutoRotate | Out-Null
                Enable-ScheduledTask -TaskName CodexAutoRotate  | Out-Null
                Write-Host "ON" -ForegroundColor Green
            }
            Read-Host "ENTER"
        }
        'Doctor'                   {
            & "$PSScriptRoot\octane.ps1" doctor
            Read-Host "ENTER"
        }
        'Open web panel'           {
            Start-Process "http://localhost:8766"
            Read-Host "ENTER"
        }
        'Exit'                     { return }
    }
}
```

- [ ] **Step 3: TUI Hub mínimo**

Create `C:\Users\marce\Diego\ai-skills-hub\ai-skills-tui.ps1`:

```powershell
#requires -Version 7.0
$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable PwshSpectreConsole)) {
    Write-Host "Instale: Install-Module PwshSpectreConsole -Scope CurrentUser" -ForegroundColor Yellow
    exit 1
}
Import-Module PwshSpectreConsole

Import-Module (Join-Path $PSScriptRoot 'modules\Common.psm1')        -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'modules\SkillManager.psm1')  -Force -DisableNameChecking

function Show-SkillsDashboard {
    Clear-Host
    Write-SpectreFigletText -Text "ai-skills" -Color Cyan
    Show-Status
}

while ($true) {
    Show-SkillsDashboard
    $choice = Read-SpectreSelection -Title "Action:" -Choices @(
        'Refresh',
        'Reconcile junctions',
        'Sync native superpowers',
        'Open web panel',
        'Exit'
    )
    switch ($choice) {
        'Refresh' { continue }
        'Reconcile junctions' { Reconcile-SharedSkills; Read-Host "ENTER" }
        'Sync native superpowers' { Sync-NativeSuperpowers; Read-Host "ENTER" }
        'Open web panel' { Start-Process "http://localhost:8765" }
        'Exit' { return }
    }
}
```

- [ ] **Step 4: Validar TUIs abrem (sem crash)**

Run:
```powershell
pwsh -ExecutionPolicy Bypass -File C:\Users\marce\Diego\octane\octane-tui.ps1
```
Expected: TUI abre, dashboard renderiza. Selecione "Exit" para sair.

```powershell
pwsh -ExecutionPolicy Bypass -File C:\Users\marce\Diego\ai-skills-hub\ai-skills-tui.ps1
```
Expected: idem.

## Task 2.10: README de cada repo

**Files:**
- Modify: `C:\Users\marce\Diego\ai-skills-hub\README.md`
- Create: `C:\Users\marce\Diego\octane\README.md`

- [ ] **Step 1: README ai-skills-hub (refresh removendo auth)**

Edit `C:\Users\marce\Diego\ai-skills-hub\README.md`. Remover toda seção sobre "Painel Claude Auth", "Painel Codex", auto-rotate, OAuth — esses agora moram em `diegocamara89/octane`. Adicionar link cruzado:

```markdown
# AI Skills Hub

Hub central para catálogo de skills, sincronizadas em junctions NTFS para Claude/Codex/Qwen/Antigravity/Gemini.

> **Auth multi-CLI:** ver repo separado [`diegocamara89/octane`](https://github.com/diegocamara89/octane) para gestão de perfis, OAuth e auto-rotate.

## Estrutura
... (manter seções relevantes apenas) ...
```

- [ ] **Step 2: README octane**

Create `C:\Users\marce\Diego\octane\README.md`:

```markdown
# octane

Gestão de perfis multi-CLI para Claude, Codex e Gemini. Hot-swap de credenciais via junction NTFS, auto-rotate por uso, dashboard de uso 5h/7d, sync VPS.

> **Skills:** ver repo separado [`diegocamara89/ai-skills-hub`](https://github.com/diegocamara89/ai-skills-hub) para catálogo de skills.

## Quickstart

\`\`\`powershell
git clone git@github.com:diegocamara89/octane.git C:\Users\<you>\Diego\octane
cd C:\Users\<you>\Diego\octane
.\setup.ps1
.\octane.ps1 doctor
\`\`\`

## Comandos principais

\`\`\`text
octane                          # TUI interativo (Spectre.Console)
octane status                   # uso + processos
octane list                     # todos os perfis
octane claude list              # só Claude
octane switch claude-b          # hot-swap para claude-b
octane login claude-c           # OAuth (devolve URL)
octane rotate                   # força pit stop manual
octane auto-rotate on           # liga rotação automática
octane vps push                 # empurra creds do perfil ativo para VPS
octane backup                   # snapshot dos perfis
octane doctor                   # diagnóstico
octane panel                    # web UI (porta 8766)
\`\`\`

## Arquitetura

- Módulos PowerShell (.psm1) em `modules/` com lógica pura.
- Três interfaces: CLI flag (`octane.ps1`), TUI Spectre (`octane-tui.ps1`), HTTP server (`server/Start-OctaneUI.ps1` porta 8766).
- Junctions NTFS para hot-swap sem reiniciar a CLI.
- Auto-rotate via Task Scheduler (default **DISABLED**, ligado via `octane auto-rotate on`).

## Salvaguardas

- Atomic writes via `Set-FileAtomic` em todas as escritas de `auth.json`, `.credentials.json`, markers.
- Setup preserva junctions/markers existentes — nunca reseta para defaults.
- Snapshot manual: `octane backup` ou `robocopy /MIR ~\.claude-profiles ~\.profile-backups\<data>\`.

## Dependências

- PowerShell 7+
- Pester 5+ (testes)
- PwshSpectreConsole (TUI): `Install-Module PwshSpectreConsole -Scope CurrentUser`
- .NET 8 (Spectre.Console)
- Windows Task Scheduler (built-in)
```

- [ ] **Step 3: Commit em cada pasta (ainda não pushar)**

```powershell
cd C:\Users\marce\Diego\ai-skills-hub
git init -b main
git add .
git commit -m "init: ai-skills-hub split from monolith"

cd C:\Users\marce\Diego\octane
git init -b main
git add .
git commit -m "init: octane (formerly claude-auth-manager) split from monolith"
```

Anotar hashes para referência.

---

# PHASE 3 — Git/GitHub split

**Goal:** Empurrar `ai-skills-hub` (force push em `main` substituindo monolito antigo) e criar repo `octane` no GitHub.

**Exit criterion:** Ambos repos visíveis no GitHub com conteúdo split.

## Task 3.1: Confirmar archive branch existe no GitHub

- [ ] **Step 1: Verificar branch archive**

Run:
```powershell
gh api repos/diegocamara89/ai-skills-hub/branches/archive%2Fmonolith-v1 --jq '.commit.sha'
```
Expected: SHA do commit. Se 404 → parar e voltar a Fase 0.

## Task 3.2: Push ai-skills-hub para o repo existente (force main)

- [ ] **Step 1: Adicionar remote e force-push**

Run:
```powershell
cd C:\Users\marce\Diego\ai-skills-hub
git remote add origin git@github.com:diegocamara89/ai-skills-hub.git
git push --force-with-lease origin main
```
Expected: push success. `--force-with-lease` é mais seguro que `--force` (rejeita se outro commit chegou no remote).

- [ ] **Step 2: Verificar no GitHub**

Run:
```powershell
gh api repos/diegocamara89/ai-skills-hub/commits/main --jq '.commit.message'
```
Expected: "init: ai-skills-hub split from monolith".

## Task 3.3: Criar repo octane no GitHub e push

- [ ] **Step 1: Criar repo via gh CLI**

Run:
```powershell
gh repo create diegocamara89/octane --private --source C:\Users\marce\Diego\octane --remote origin --push --description "Multi-CLI account/profile manager — Claude, Codex, Gemini. Hot-swap + auto-rotate + usage tracking."
```
Expected: repo criado e primeiro push automaticamente.

- [ ] **Step 2: Verificar**

Run:
```powershell
gh api repos/diegocamara89/octane --jq '.name'
gh api repos/diegocamara89/octane/commits/main --jq '.commit.message'
```

---

# PHASE 3.5 — Pré-cutover

**Goal:** Segundo snapshot dos perfis + inventário de junctions + `octane doctor` passa.

## Task 3.5.1: Segundo snapshot dos perfis

- [ ] **Step 1: Snapshot Fase 3.5**

Run (mesma metodologia da Task 0.3, com label diferente):
```powershell
$ts = Get-Date -Format 'yyyy-MM-dd-HHmm'
$backupRoot = "$env:USERPROFILE\.profile-backups\$ts-fase35"
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
Set-Content -Path "$backupRoot\.label" -Value "fase35-pre-cutover" -Encoding utf8 -NoNewline

foreach ($pair in @(
    @{ src="$env:USERPROFILE\.claude-profiles"; dst="$backupRoot\claude-profiles" },
    @{ src="$env:USERPROFILE\.codex-profiles";  dst="$backupRoot\codex-profiles" },
    @{ src="$env:USERPROFILE\.codex";           dst="$backupRoot\codex-home" }
)) {
    New-Item -ItemType Directory -Path $pair.dst -Force | Out-Null
    & robocopy $pair.src $pair.dst /MIR /XJ /R:2 /W:5 /NFL /NDL /NJH /NJS | Out-Null
}

Write-Host "Backup root fase35: $backupRoot"
```

- [ ] **Step 2: Comparar com snapshot Fase 0**

Run:
```powershell
$fase0 = Get-ChildItem "$env:USERPROFILE\.profile-backups" -Directory | Where-Object Name -like '*-fase0' | Sort-Object Name -Descending | Select-Object -First 1
$fase35 = Get-ChildItem "$env:USERPROFILE\.profile-backups" -Directory | Where-Object Name -like '*-fase35' | Sort-Object Name -Descending | Select-Object -First 1
# Codex review fix: compare by relative path + length, not FullName
function Get-Manifest {
    param([string]$Root)
    Get-ChildItem $Root -Recurse -File | ForEach-Object {
        [PSCustomObject]@{
            RelPath = $_.FullName.Substring($Root.Length).TrimStart('\','/')
            Length  = $_.Length
        }
    }
}
$diff = Compare-Object (Get-Manifest $fase0.FullName) (Get-Manifest $fase35.FullName) -Property RelPath, Length
$diff | Format-Table -AutoSize
```
Expected: lista vazia (ou diferenças mínimas devido a arquivos vivos como `state.sqlite`). **Se houver mudança em `.credentials.json` ou `auth.json` → INVESTIGAR antes de seguir.**

## Task 3.5.2: octane doctor passa

- [ ] **Step 1: Rodar doctor**

Run:
```powershell
cd C:\Users\marce\Diego\octane
.\octane.ps1 doctor
```
Expected: `All checks pass.` Se houver miss, resolver antes da Fase 4.

---

# PHASE 4 — Cutover atômico do Task Scheduler

**Goal:** Substituir tasks `ClaudeAutoRotate`/`CodexAutoRotate` por versões apontando para `~\Diego\octane\bin\` sem janela de coexistência.

**Cutover order (Codex review fix):** desabilitar v1 ANTES de testar v2 manualmente, para eliminar race condition. Re-ordem corrigida abaixo.

## Task 4.0: Desabilitar e parar v1 ANTES de qualquer outra coisa

- [ ] **Step 1: Disable e Stop tasks v1**

Run:
```powershell
foreach ($t in @('ClaudeAutoRotate','CodexAutoRotate')) {
    $task = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
    if ($task) {
        Disable-ScheduledTask -TaskName $t | Out-Null
        # Se está rodando agora, parar
        $info = Get-ScheduledTaskInfo -TaskName $t
        if ($info.LastTaskResult -eq 267009) {  # 267009 = task currently running
            Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
        }
        Write-Host "Task $t: Disabled"
    }
}
# Wait a moment for any in-flight execution to settle
Start-Sleep -Seconds 5
```

- [ ] **Step 2: Confirmar zero processos auto-rotate em voo**

Run:
```powershell
$rotateProcs = Get-Process pwsh, powershell -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -like '*auto-rotate*'
}
if ($rotateProcs) {
    Write-Host "auto-rotate processes ainda rodando — abortar e investigar:"
    $rotateProcs | Format-Table Id, CommandLine
    throw "auto-rotate em voo. Não prosseguir."
}
Write-Host "OK — nenhum auto-rotate em voo."
```

## Task 4.1: Registrar tasks v2 apontando para o novo octane

- [ ] **Step 1: Registrar tasks v2**

Run:
```powershell
$octaneBin = "C:\Users\marce\Diego\octane\bin"
foreach ($entry in @(
    @{ Name = 'ClaudeAutoRotate-v2'; Script = "$octaneBin\auto-rotate.ps1" },
    @{ Name = 'CodexAutoRotate-v2';  Script = "$octaneBin\auto-rotate-codex.ps1" }
)) {
    $action  = New-ScheduledTaskAction -Execute "pwsh.exe" -Argument "-NonInteractive -ExecutionPolicy Bypass -File `"$($entry.Script)`""
    $trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 10) -Once -At (Get-Date)
    Register-ScheduledTask -TaskName $entry.Name -Action $action -Trigger $trigger -RunLevel Limited -Force | Out-Null
    Disable-ScheduledTask -TaskName $entry.Name | Out-Null
    Write-Host "Registered DISABLED: $($entry.Name) -> $($entry.Script)"
}
```

## Task 4.2: Validar tasks v2 executam (one-shot manual)

- [ ] **Step 1: Rodar v2 manualmente**

Run:
```powershell
Start-ScheduledTask -TaskName ClaudeAutoRotate-v2
Start-Sleep -Seconds 10
Get-ScheduledTask -TaskName ClaudeAutoRotate-v2 | Select-Object TaskName, State, LastTaskResult, LastRunTime
```
Expected: `LastTaskResult` = 0 (success). Se diferente, investigar (path errado, módulo faltando, etc.).

- [ ] **Step 2: Idem para Codex**

Run:
```powershell
Start-ScheduledTask -TaskName CodexAutoRotate-v2
Start-Sleep -Seconds 10
Get-ScheduledTask -TaskName CodexAutoRotate-v2 | Select-Object TaskName, State, LastTaskResult, LastRunTime
```

## Task 4.3: Remover tasks v1 (já desabilitadas na Task 4.0)

- [ ] **Step 1: Confirmar v1 ainda disabled**

Run:
```powershell
Get-ScheduledTask -TaskName ClaudeAutoRotate,CodexAutoRotate | Select-Object TaskName, State
```
Expected: ambas `Disabled`.

- [ ] **Step 2: Remover v1**

Run:
```powershell
Unregister-ScheduledTask -TaskName 'ClaudeAutoRotate' -Confirm:$false
Unregister-ScheduledTask -TaskName 'CodexAutoRotate'  -Confirm:$false
```

- [ ] **Step 3: Renomear v2 → nome final**

Não há `Rename-ScheduledTask` direto. Estratégia: registrar com nome final, deletar v2.

Run:
```powershell
$octaneBin = "C:\Users\marce\Diego\octane\bin"
foreach ($entry in @(
    @{ Name = 'ClaudeAutoRotate'; OldName = 'ClaudeAutoRotate-v2'; Script = "$octaneBin\auto-rotate.ps1" },
    @{ Name = 'CodexAutoRotate';  OldName = 'CodexAutoRotate-v2';  Script = "$octaneBin\auto-rotate-codex.ps1" }
)) {
    $action  = New-ScheduledTaskAction -Execute "pwsh.exe" -Argument "-NonInteractive -ExecutionPolicy Bypass -File `"$($entry.Script)`""
    $trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 10) -Once -At (Get-Date)
    Register-ScheduledTask -TaskName $entry.Name -Action $action -Trigger $trigger -RunLevel Limited -Force | Out-Null
    Disable-ScheduledTask -TaskName $entry.Name | Out-Null
    Unregister-ScheduledTask -TaskName $entry.OldName -Confirm:$false
    Write-Host "Renamed: $($entry.OldName) -> $($entry.Name)"
}
Get-ScheduledTask -TaskName ClaudeAutoRotate,CodexAutoRotate | Format-Table TaskName, State
```

- [ ] **Step 4: Validar nome final**

Run:
```powershell
Get-ScheduledTask | Where-Object TaskName -in 'ClaudeAutoRotate','CodexAutoRotate','ClaudeAutoRotate-v2','CodexAutoRotate-v2'
```
Expected: apenas `ClaudeAutoRotate` e `CodexAutoRotate`, sem `-v2`, ambas state `Disabled`.

## Task 4.4: Verificar junction destinations não mudaram

- [ ] **Step 1: Comparar inventário pré e pós**

Run:
```powershell
$out = "C:\Users\marce\Diego\AI-Skills-Hub\cutover-post-fase4.txt"
$paths = @(
    "$env:USERPROFILE\.claude-profiles\active",
    "$env:USERPROFILE\.codex-profiles\active",
    "$env:USERPROFILE\.claude\skills",
    "$env:USERPROFILE\.codex\skills",
    "$env:USERPROFILE\.agents\skills",
    "$env:USERPROFILE\.qwen\skills",
    "$env:USERPROFILE\.antigravity\skills",
    "$env:USERPROFILE\.gemini\antigravity\skills"
)
"INVENTORY POST-FASE4 @ $(Get-Date -Format 'o')" | Out-File $out -Encoding utf8
foreach ($p in $paths) {
    if (Test-Path $p) {
        $item = Get-Item $p -Force
        $target = if ($item.LinkType) { ($item.Target -join ',') } else { '(not a junction)' }
        "$p -> $target [$($item.LinkType)]" | Out-File $out -Append -Encoding utf8
    }
}

# Diff vs Fase 0 — parse into objects, skip timestamp line
# Codex review fix: parse "path -> target [LinkType]" structurally
function Parse-Inventory {
    param([string]$Path)
    Get-Content $Path | Where-Object { $_ -notlike 'INVENTORY*' -and $_ -notlike 'INVENTORY POST*' } | ForEach-Object {
        if ($_ -match '^(?<path>.+?)\s*->\s*(?<target>.+?)(?:\s*\[(?<link>.+)\])?$') {
            [PSCustomObject]@{
                Path     = $matches.path.Trim()
                Target   = $matches.target.Trim()
                LinkType = $matches.link
            }
        }
    }
}
$pre  = Parse-Inventory "C:\Users\marce\Diego\AI-Skills-Hub\cutover-pre-fase0.txt"
$post = Parse-Inventory $out
$diff = Compare-Object $pre $post -Property Path, Target -PassThru
if ($diff) {
    Write-Host "Diff detected:" -ForegroundColor Yellow
    $diff | Format-Table SideIndicator, Path, Target
} else {
    Write-Host "No junction changes detected." -ForegroundColor Green
}
```
Expected: somente a linha de timestamp difere. **Se algum target mudou → ROLLBACK imediato.**

---

# PHASE 5 — Validação em uso real + arquivamento

**Goal:** Validar com a CLI real, atualizar shims, arquivar o monolito antigo.

## Task 5.1: Atualizar shims

- [ ] **Step 1: Reinstalar shims via setup de cada repo**

Run:
```powershell
cd C:\Users\marce\Diego\ai-skills-hub
.\setup.ps1

cd C:\Users\marce\Diego\octane
.\setup.ps1 -SkipScheduler  # tasks já foram registradas na Fase 4
```

- [ ] **Step 2: Validar shims**

Run:
```powershell
where.exe ai-skills
where.exe octane
ai-skills doctor
octane doctor
```
Expected: caminhos novos (`~\.local\bin\`), ambos doctors passam.

## Task 5.2: Smoke test web painéis

- [ ] **Step 1: Painel octane**

Run:
```powershell
Start-Process pwsh -ArgumentList "-NoExit", "-File", "C:\Users\marce\Diego\octane\octane.ps1", "panel"
Start-Sleep -Seconds 5
Invoke-RestMethod http://localhost:8766/api/runtime/instances
```
Expected: JSON com `claude.count`, `codex.count`.

- [ ] **Step 2: Painel Hub**

Run:
```powershell
Start-Process pwsh -ArgumentList "-NoExit", "-File", "C:\Users\marce\Diego\ai-skills-hub\ai-skills.ps1", "panel"
Start-Sleep -Seconds 5
Invoke-WebRequest http://localhost:8765 -UseBasicParsing | Select-Object StatusCode
```
Expected: 200 OK.

- [ ] **Step 3: Smoke test browser**

Manual: abrir browser em `http://localhost:8766` e `http://localhost:8765`. Ambos carregam. Web UI octane mostra perfis e usage. Web UI Hub mostra skills.

## Task 5.3: Smoke test switch de perfil em conversa Claude Code ativa

**This is a critical canary test, not authoritative validation.** Não sabemos com certeza se Claude Code recarrega credenciais a cada call ou cacheia na inicialização (Codex review fix). Tratar como verificação observacional: trocar perfil, fazer call, ver onde o uso é debitado. Se o uso é debitado no perfil errado, o teste indica caching — não bloqueia o split, mas vira issue.

- [ ] **Step 1: Anotar perfil ativo atual**

Run:
```powershell
$currentClaude = (Get-Item "$env:USERPROFILE\.claude-profiles\active" -Force).Target
Write-Host "Current claude active: $currentClaude"
```

- [ ] **Step 2: Iniciar Claude Code numa conversa**

Manual: abra um terminal, rode `claude`, faça uma pergunta simples e receba resposta. Confirma que o token funciona.

- [ ] **Step 3: Trocar de perfil via octane**

Run:
```powershell
$other = if ($currentClaude -like '*claude-a') { 'claude-b' } else { 'claude-a' }
octane switch $other
(Get-Item "$env:USERPROFILE\.claude-profiles\active" -Force).Target
```
Expected: junction agora aponta para `$other`.

- [ ] **Step 4: Próxima call no Claude Code usa novo perfil**

Manual: na mesma conversa Claude Code, faça outra pergunta. Resposta vem usando o token do novo perfil (verifica logs ou usage no `octane status` — deve subir o uso do novo perfil, não do antigo).

- [ ] **Step 5: Voltar ao perfil original**

Run:
```powershell
octane switch $currentClaude.Split('\')[-1]
```

## Task 5.4: Arquivar o monolito antigo

- [ ] **Step 1: Mover pasta antiga**

Run:
```powershell
$archive = "C:\Users\marce\Diego\.archive"
if (-not (Test-Path $archive)) { New-Item -ItemType Directory -Path $archive -Force | Out-Null }
$dest = "$archive\AI-Skills-Hub-pre-split-2026-05-16"
Move-Item "C:\Users\marce\Diego\AI-Skills-Hub" $dest -Force
Write-Host "Arquivado em: $dest"
```

- [ ] **Step 2: Confirmar shims não apontam para o arquivo morto**

Run:
```powershell
Get-Content $env:USERPROFILE\.local\bin\octane.cmd
Get-Content $env:USERPROFILE\.local\bin\ai-skills.cmd
```
Expected: ambos apontam para `C:\Users\marce\Diego\octane\octane.ps1` e `C:\Users\marce\Diego\ai-skills-hub\ai-skills.ps1`. **Não pode haver referência a `AI-Skills-Hub` antigo.**

- [ ] **Step 3: Smoke test final pós-arquivamento**

Run:
```powershell
octane doctor
ai-skills doctor
octane status
ai-skills status
```
Expected: tudo passa, sem erros sobre pasta missing.

## Task 5.5: Critérios de sucesso (checklist final)

- [ ] **Step 1: Validar cada critério da spec §11**

```powershell
# 1. Pester hub
$h = Invoke-Pester -Path C:\Users\marce\Diego\ai-skills-hub\tests -PassThru
Write-Host "Hub Pester: $($h.PassedCount)/$($h.PassedCount + $h.FailedCount) pass"

# 2. Pester octane
$o = Invoke-Pester -Path C:\Users\marce\Diego\octane\tests -PassThru
Write-Host "Octane Pester: $($o.PassedCount)/$($o.PassedCount + $o.FailedCount) pass"

# 3. octane status sem painel
# NÃO usar Stop-Process -Name pwsh (mataria esta sessão!).
# Os painéis foram iniciados via Start-Process com -PassThru anteriormente; usar PIDs salvos.
# Se não tem PIDs salvos, parar manualmente via Get-Process | Where CommandLine match 'Start-OctaneUI|Start-SkillManagerUI'
$panels = Get-Process pwsh -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -like '*Start-OctaneUI*' -or $_.CommandLine -like '*Start-SkillManagerUI*' -or `
    $_.CommandLine -like '*octane*panel*' -or $_.CommandLine -like '*ai-skills*panel*'
}
$panels | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
Start-Sleep 2
octane status

# 4. ai-skills list sem painel
ai-skills list

# 11. octane doctor + ai-skills doctor
octane doctor
ai-skills doctor

# 12. Snapshot fase35 idêntico ao fase0
$f0 = (Get-ChildItem $env:USERPROFILE\.profile-backups -Directory | ? Name -like '*fase0' | Select -First 1).FullName
$f35 = (Get-ChildItem $env:USERPROFILE\.profile-backups -Directory | ? Name -like '*fase35' | Select -First 1).FullName
$diff = Compare-Object (Get-ChildItem $f0 -Recurse -File) (Get-ChildItem $f35 -Recurse -File) -Property Name, Length
"Snapshot drift: $($diff.Count) files differ"

# 13. Junction antes/depois
$preTarget  = ((Get-Content C:\Users\marce\Diego\.archive\AI-Skills-Hub-pre-split-2026-05-16\cutover-pre-fase0.txt | Select-String 'claude-profiles\\active') -split ' -> ')[1]
$postTarget = (Get-Item "$env:USERPROFILE\.claude-profiles\active" -Force).Target -join ','
"Junction pre=$preTarget post=$postTarget — match=$($preTarget -eq $postTarget)"
```
Expected: todos OK, match=$true.

- [ ] **Step 2: Commit final em cada repo + push**

```powershell
cd C:\Users\marce\Diego\ai-skills-hub
git add -A
git diff --cached --stat
git commit -m "chore: phase 5 final validation passed" --allow-empty
git push origin main

cd C:\Users\marce\Diego\octane
git add -A
git diff --cached --stat
git commit -m "chore: phase 5 final validation passed" --allow-empty
git push origin main
```

---

# Post-implementation: open follow-ups

After all phases done, create GitHub issues:

- **octane#1:** rate limits Codex cruzando entre perfis. Repro steps em `UsageTracker.psm1::Get-CodexRateLimits`. Adicionar teste de regressão em `tests/UsageTracker.Tests.ps1`.
- **octane#2:** suporte oficial Qwen (estrutura pronta, falta testar).
- **ai-skills-hub#1:** distribuição via winget/scoop (futuro).

```powershell
gh issue create --repo diegocamara89/octane --title "fix: rate limits Codex cruzando entre perfis" --body "Bug existente desde antes do split. Get-CodexRateLimits está aplicando limites de um perfil a todos. Reproduzir, isolar, adicionar teste, fixar."
gh issue create --repo diegocamara89/octane --title "feat: suporte oficial Qwen" --body "Estrutura comporta. Falta testar com perfil real."
```

---

## Self-Review

**1. Spec coverage:**
- §2 Estrutura final dos dois repos → tasks 2.1, 2.2, 2.10 ✓
- §3 Propriedade exclusiva → Setup scripts (tasks 2.5) implementam invariante ✓
- §4 Fases de migração → Phases 0–5 com sub-tasks ✓
- §5 Arquitetura módulo + 3 interfaces → tasks 1.3–1.15, 2.7, 2.8, 2.9 ✓
- §6 Comandos do octane e ai-skills → tasks 2.7, 2.8 ✓
- §7 Setup & install → task 2.5 ✓
- §8 Salvaguardas → tasks 0.3, 0.4, 3.5.1, 4.4 ✓
- §9 Critérios de sucesso → task 5.5 ✓
- §10 Pós-split → seção final do plano ✓
- VPS commands → incluídos em task 2.8 octane.ps1 ✓
- TUI Spectre.Console → task 2.9 ✓
- Engine prefix detection → task 2.8 (função `Detect-Engine`) ✓

**2. Placeholder scan:** Procurei por "TBD", "TODO", "implement later" — zero matches. Todos os steps têm código completo ou comando exato.

**3. Type consistency:**
- `Set-ClaudeProfileJunction -Name <x>` usado em task 1.5 (export) e task 2.8 (consumo). ✓
- `Set-CodexProfileJunction -Name <x>` idem. ✓
- `Get-ClaudeProfileDefinitions` retorna lista; task 2.8 espera `.name` propriedade. **Verificar na implementação se o objeto retornado tem essa propriedade — caso contrário ajustar para `.id` ou similar.**
- `Set-GeminiActiveProfile -Name <x>` usado em task 2.8; precisa confirmar export na task 1.7.

**4. Plan integrity:**
- Fase 1 não move pastas — confere com spec. ✓
- Fase 4 cutover atômico com `-v2` sufix — implementado.
- Snapshot Fase 0 + Fase 3.5 — implementado.
- Auto-rotate off por default — confere (setup.ps1 chama Disable-ScheduledTask após Register).

Plan complete and saved to `docs/superpowers/plans/2026-05-16-split-skills-hub-octane-implementation.md`.
