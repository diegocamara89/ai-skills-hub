# Claude Multi-Account V1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implementar a V1 mínima de múltiplas contas Claude com failover reativo por quota/erro, contexto reidratável e adaptador de execução Codex com backend preferencial por plugin e fallback por CLI.

**Architecture:** A implementação permanece Windows-first e centrada nos artefatos já existentes do projeto: `manage-skills.ps1` continua como backend principal do painel e do estado operacional, `ui/claude-auth.html` continua como superfície local, e o fluxo Claude -> Codex -> Claude permanece nos scripts do orquestrador. O recorte da V1 adiciona estado de contas, classificação de falhas, leases/watchdog e contexto reidratável sem introduzir ainda pool de sessões pre-aquecidas.

**Tech Stack:** PowerShell 7, HTML/CSS/JS local, Python 3 para o orquestrador existente, Claude Code CLI, Codex CLI/plugin.

---

## File Structure

### Existing files to modify

- `C:\Users\marce\Diego\AI-Skills-Hub\manage-skills.ps1`
  - Persistência do estado das contas Claude
  - Leases/watchdog
  - Classificação de falhas
  - Seleção automática da próxima conta
  - Endpoints do painel
- `C:\Users\marce\Diego\AI-Skills-Hub\ui\claude-auth.html`
  - Exibição do estado por perfil
  - Ações de relogin
  - Visualização de cooldown, auth_required e unhealthy
- `C:\Users\marce\Diego\AI-Skills-Hub\all-skills\orchestrate\scripts\claude_codex_orchestrator.py`
  - Handoff reidratável
  - Contrato explícito do backend executor
  - Classificação de `plugin_backend_failure` e `cli_backend_failure`
- `C:\Users\marce\Diego\AI-Skills-Hub\all-skills\orchestrate\tests\test_claude_codex_orchestrator.py`
  - Cobertura do adaptador e política mínima de backend

### New files to create

- `C:\Users\marce\Diego\AI-Skills-Hub\all-skills\orchestrate\tests\test_claude_account_failover.py`
  - Testes de classificação de falhas, leases e failover reativo

### Runtime/state files produced by the app

- `%USERPROFILE%\.claude-orchestrator\state.json`
- `%USERPROFILE%\.claude-orchestrator\profiles\*.json` ou estrutura equivalente persistida pelo backend

---

### Task 1: Persistir estado canônico das contas Claude

**Files:**
- Modify: `C:\Users\marce\Diego\AI-Skills-Hub\manage-skills.ps1`
- Test: smoke test via PowerShell no comando `status` e endpoint `/api/claude-auth/status`

- [ ] **Step 1: Escrever o teste/manual reproduction note para o estado por perfil**

```text
Cenário alvo:
1. Existe ao menos um perfil `claude-a`
2. O backend retorna para cada perfil:
   - name
   - configDir
   - loggedIn
   - state
   - cooldownUntil
   - lastFailureKind
   - leaseOwner
   - leaseExpiresAt
3. `state` governa a decisão operacional
```

- [ ] **Step 2: Rodar o estado atual para confirmar a lacuna**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\manage-skills.ps1 status
```

Expected: saída atual sem a estrutura completa de `state`, `leaseOwner` e `leaseExpiresAt`.

- [ ] **Step 3: Adicionar a estrutura mínima do estado no backend**

```powershell
function New-ClaudeProfileRuntimeState {
    param(
        [string]$ProfileName,
        [string]$ConfigDir
    )

    return [ordered]@{
        profileId = $ProfileName
        configDir = $ConfigDir
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
```

- [ ] **Step 4: Adicionar normalização de precedência entre `state` e `loggedIn`**

```powershell
function Normalize-ClaudeProfileRuntimeState {
    param([hashtable]$State)

    if (-not $State.state) {
        $State.state = if ($State.loggedIn) { "available" } else { "auth_required" }
    }

    if ($State.state -eq "auth_required") {
        $State.loggedIn = $false
    }

    return $State
}
```

- [ ] **Step 5: Rodar a verificação após a mudança**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\manage-skills.ps1 status
```

Expected: o estado do perfil passa a incluir os campos novos e `state` aparece de forma explícita.

- [ ] **Step 6: Commit**

```bash
git add manage-skills.ps1
git commit -m "feat: persist claude profile runtime state"
```

---

### Task 2: Implementar classificação de falhas e transições de conta

**Files:**
- Modify: `C:\Users\marce\Diego\AI-Skills-Hub\manage-skills.ps1`
- Create: `C:\Users\marce\Diego\AI-Skills-Hub\all-skills\orchestrate\tests\test_claude_account_failover.py`

- [ ] **Step 1: Escrever o teste de classificação de falhas**

```python
def test_classify_not_logged_in_as_auth_required():
    assert classify_failure("Not logged in · Please run /login", "", 1) == "auth_required"

def test_classify_rate_limit_as_rate_limited_transient():
    assert classify_failure("rate limit exceeded", "", 1) == "rate_limited_transient"

def test_classify_quota_as_quota_exhausted():
    assert classify_failure("usage limit reached", "", 1) == "quota_exhausted"
```

- [ ] **Step 2: Rodar o teste para confirmar que falha**

Run:

```powershell
python -m pytest .\all-skills\orchestrate\tests\test_claude_account_failover.py -q
```

Expected: FAIL porque `classify_failure` ainda não existe.

- [ ] **Step 3: Implementar a função mínima de classificação no backend/orquestrador**

```powershell
function Get-ClaudeFailureKind {
    param(
        [string]$Stdout,
        [string]$Stderr,
        [int]$ReturnCode
    )

    $haystack = "$Stdout`n$Stderr".ToLowerInvariant()

    if ($haystack -match "not logged in|/login") { return "auth_required" }
    if ($haystack -match "usage limit reached|quota exceeded|5h") { return "quota_exhausted" }
    if ($haystack -match "rate limit|too many requests") { return "rate_limited_transient" }
    if ($haystack -match "plugin|/codex:") { return "plugin_backend_failure" }
    if ($haystack -match "codex exec|executable|not recognized") { return "cli_backend_failure" }
    if ($haystack -match "timeout|temporarily unavailable|backend") { return "backend_unavailable" }
    if ($ReturnCode -ne 0) { return "local_host_failure" }
    return ""
}
```

- [ ] **Step 4: Implementar a aplicação mínima da transição**

```powershell
function Set-ClaudeProfileStateFromFailure {
    param(
        [hashtable]$State,
        [string]$FailureKind,
        [datetime]$Now
    )

    $State.lastFailureAt = $Now.ToString("o")
    $State.lastFailureKind = $FailureKind

    switch ($FailureKind) {
        "quota_exhausted" { $State.state = "exhausted" }
        "rate_limited_transient" { $State.state = "cooling" }
        "auth_required" { $State.state = "auth_required"; $State.loggedIn = $false }
        "backend_unavailable" { $State.state = "cooling" }
        "local_host_failure" { $State.state = "unhealthy" }
        default { }
    }

    return $State
}
```

- [ ] **Step 5: Rodar o teste para verificar aprovação**

Run:

```powershell
python -m pytest .\all-skills\orchestrate\tests\test_claude_account_failover.py -q
```

Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add manage-skills.ps1 all-skills/orchestrate/tests/test_claude_account_failover.py
git commit -m "feat: classify claude account failures"
```

---

### Task 3: Adicionar lease/watchdog e seleção segura de conta

**Files:**
- Modify: `C:\Users\marce\Diego\AI-Skills-Hub\manage-skills.ps1`
- Test: `C:\Users\marce\Diego\AI-Skills-Hub\all-skills\orchestrate\tests\test_claude_account_failover.py`

- [ ] **Step 1: Escrever o teste do lease**

```python
def test_active_profile_returns_to_available_when_lease_expires():
    state = {
        "state": "active",
        "leaseOwner": "task-123",
        "leaseExpiresAt": "2000-01-01T00:00:00Z",
        "loggedIn": True,
    }
    new_state = expire_lease_if_stale(state, now="2000-01-01T00:05:00Z")
    assert new_state["state"] == "available"
```

- [ ] **Step 2: Rodar o teste para confirmar a falha**

Run:

```powershell
python -m pytest .\all-skills\orchestrate\tests\test_claude_account_failover.py -q
```

Expected: FAIL porque a expiração de lease ainda não existe.

- [ ] **Step 3: Implementar lease e watchdog mínimos**

```powershell
function Set-ClaudeProfileLease {
    param(
        [hashtable]$State,
        [string]$LeaseOwner,
        [datetime]$Now
    )

    $State.leaseOwner = $LeaseOwner
    $State.leaseExpiresAt = $Now.AddMinutes(5).ToString("o")
    $State.state = "active"
    return $State
}

function Clear-StaleClaudeLease {
    param(
        [hashtable]$State,
        [datetime]$Now
    )

    if ($State.state -eq "active" -and $State.leaseExpiresAt) {
        $leaseTime = [datetime]::Parse($State.leaseExpiresAt)
        if ($leaseTime -lt $Now) {
            $State.state = if ($State.loggedIn) { "available" } else { "auth_required" }
            $State.leaseOwner = ""
            $State.leaseExpiresAt = $null
        }
    }

    return $State
}
```

- [ ] **Step 4: Implementar a seleção segura do próximo perfil**

```powershell
function Get-NextAvailableClaudeProfile {
    param(
        [object[]]$Profiles,
        [datetime]$Now
    )

    foreach ($profile in $Profiles) {
        $state = Clear-StaleClaudeLease -State $profile.runtimeState -Now $Now
        if ($state.state -eq "available") {
            return $profile
        }
    }

    return $null
}
```

- [ ] **Step 5: Rodar os testes**

Run:

```powershell
python -m pytest .\all-skills\orchestrate\tests\test_claude_account_failover.py -q
```

Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add manage-skills.ps1 all-skills/orchestrate/tests/test_claude_account_failover.py
git commit -m "feat: add claude profile lease watchdog"
```

---

### Task 4: Implementar contexto reidratável compacto

**Files:**
- Modify: `C:\Users\marce\Diego\AI-Skills-Hub\all-skills\orchestrate\scripts\claude_codex_orchestrator.py`
- Modify: `C:\Users\marce\Diego\AI-Skills-Hub\all-skills\orchestrate\tests\test_claude_codex_orchestrator.py`

- [ ] **Step 1: Escrever o teste da reidratação com orçamento**

```python
def test_rehydration_blocks_when_budget_exceeded():
    context = {
        "task_summary": "Implementar fluxo de failover",
        "current_goal": "Trocar de conta sem perder contexto",
        "constraints": ["Nao replayar transcript inteiro"],
        "relevant_files": [{"path": "big.txt", "reason": "debug", "content_mode": "summary_only"}],
        "token_budget_hint": 10,
    }
    result = build_rehydration_payload(context)
    assert result["status"] == "blocked"
    assert result["blocking_reason"] == "rehydration_budget_exceeded"
```

- [ ] **Step 2: Rodar o teste para confirmar falha**

Run:

```powershell
python -m pytest .\all-skills\orchestrate\tests\test_claude_codex_orchestrator.py -q
```

Expected: FAIL porque `build_rehydration_payload` ainda não aplica esse contrato.

- [ ] **Step 3: Implementar o payload mínimo de reidratação**

```python
def build_rehydration_payload(task_context: dict[str, Any]) -> dict[str, Any]:
    payload = {
        "task_summary": task_context.get("task_summary", ""),
        "current_goal": task_context.get("current_goal", ""),
        "constraints": task_context.get("constraints", []),
        "relevant_files": task_context.get("relevant_files", []),
        "last_plan_summary": task_context.get("last_plan_summary", ""),
        "executor_or_validator_checkpoint": task_context.get("executor_or_validator_checkpoint", ""),
        "pending_decision": task_context.get("pending_decision", ""),
    }
    budget = int(task_context.get("token_budget_hint", 4000))
    estimate = len(json.dumps(payload, ensure_ascii=False)) // 4
    if estimate > budget:
        payload["relevant_files"] = []
        estimate = len(json.dumps(payload, ensure_ascii=False)) // 4
        if estimate > budget:
            return {
                "status": "blocked",
                "blocking_reason": "rehydration_budget_exceeded",
                "estimated_tokens": estimate,
            }
    return {
        "status": "ok",
        "payload": payload,
        "estimated_tokens": estimate,
    }
```

- [ ] **Step 4: Rodar o teste para verificar aprovação**

Run:

```powershell
python -m pytest .\all-skills\orchestrate\tests\test_claude_codex_orchestrator.py -q
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add all-skills/orchestrate/scripts/claude_codex_orchestrator.py all-skills/orchestrate/tests/test_claude_codex_orchestrator.py
git commit -m "feat: add compact rehydration payload"
```

---

### Task 5: Tornar o Codex Adapter explícito entre plugin e CLI

**Files:**
- Modify: `C:\Users\marce\Diego\AI-Skills-Hub\all-skills\orchestrate\scripts\claude_codex_orchestrator.py`
- Modify: `C:\Users\marce\Diego\AI-Skills-Hub\all-skills\orchestrate\tests\test_claude_codex_orchestrator.py`

- [ ] **Step 1: Escrever o teste de fallback controlado**

```python
def test_plugin_failure_falls_back_to_cli_without_switching_account():
    result = normalize_executor_failure(
        backend_used="plugin",
        failure_kind="plugin_backend_failure",
        plugin_failed=True,
        cli_failed=False,
    )
    assert result["account_switch_recommended"] is False
    assert result["next_backend"] == "cli"
```

- [ ] **Step 2: Rodar o teste para verificar a falha**

Run:

```powershell
python -m pytest .\all-skills\orchestrate\tests\test_claude_codex_orchestrator.py -q
```

Expected: FAIL porque o contrato atual ainda não diferencia bem plugin e CLI.

- [ ] **Step 3: Implementar o contrato mínimo do adaptador**

```python
def normalize_executor_failure(
    *,
    backend_used: str,
    failure_kind: str,
    plugin_failed: bool,
    cli_failed: bool,
) -> dict[str, Any]:
    if failure_kind == "plugin_backend_failure" and not cli_failed:
        return {
            "account_switch_recommended": False,
            "next_backend": "cli",
        }
    if failure_kind == "cli_backend_failure" and plugin_failed:
        return {
            "account_switch_recommended": False,
            "next_backend": "",
        }
    return {
        "account_switch_recommended": failure_kind in {"quota_exhausted", "rate_limited_transient"},
        "next_backend": "",
    }
```

- [ ] **Step 4: Rodar o teste**

Run:

```powershell
python -m pytest .\all-skills\orchestrate\tests\test_claude_codex_orchestrator.py -q
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add all-skills/orchestrate/scripts/claude_codex_orchestrator.py all-skills/orchestrate/tests/test_claude_codex_orchestrator.py
git commit -m "feat: separate codex plugin and cli backends"
```

---

### Task 6: Expor o estado no painel local

**Files:**
- Modify: `C:\Users\marce\Diego\AI-Skills-Hub\ui\claude-auth.html`
- Modify: `C:\Users\marce\Diego\AI-Skills-Hub\manage-skills.ps1`

- [ ] **Step 1: Escrever o comportamento esperado da UI**

```text
Cada card de perfil deve mostrar:
- state
- logged_in
- cooldown_until
- last_failure_kind
- lease_owner
- ação de relogin quando state = auth_required
```

- [ ] **Step 2: Rodar a UI atual para confirmar lacuna**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\manage-skills.ps1 ui
```

Expected: painel atual sem a visualização completa desses campos.

- [ ] **Step 3: Adicionar o render mínimo do estado**

```javascript
function renderProfileRuntime(profile) {
  const state = profile.runtimeState || {};
  return `
    <div class="collector-box">
      <div><strong>state:</strong> ${state.state || "-"}</div>
      <div><strong>loggedIn:</strong> ${String(state.loggedIn)}</div>
      <div><strong>cooldownUntil:</strong> ${state.cooldownUntil || "-"}</div>
      <div><strong>lastFailureKind:</strong> ${state.lastFailureKind || "-"}</div>
      <div><strong>leaseOwner:</strong> ${state.leaseOwner || "-"}</div>
    </div>
  `;
}
```

- [ ] **Step 4: Rodar a UI para validar**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\manage-skills.ps1 ui
```

Expected: painel mostra o estado operacional por conta.

- [ ] **Step 5: Commit**

```bash
git add ui/claude-auth.html manage-skills.ps1
git commit -m "feat: show claude runtime state in auth panel"
```

---

### Task 7: Verificação integrada da V1

**Files:**
- Test: `C:\Users\marce\Diego\AI-Skills-Hub\all-skills\orchestrate\tests\test_claude_account_failover.py`
- Test: `C:\Users\marce\Diego\AI-Skills-Hub\all-skills\orchestrate\tests\test_claude_codex_orchestrator.py`
- Test: `C:\Users\marce\Diego\AI-Skills-Hub\manage-skills.ps1`

- [ ] **Step 1: Rodar os testes Python relevantes**

Run:

```powershell
python -m pytest .\all-skills\orchestrate\tests\test_claude_account_failover.py .\all-skills\orchestrate\tests\test_claude_codex_orchestrator.py -q
```

Expected: PASS

- [ ] **Step 2: Rodar smoke test do backend**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\manage-skills.ps1 status
```

Expected: PASS sem erro e com estado das contas exposto.

- [ ] **Step 3: Rodar smoke test da UI**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\manage-skills.ps1 ui
```

Expected: servidor local sobe e o painel renderiza o estado do perfil.

- [ ] **Step 4: Rodar smoke test de reidratação/fallback com um perfil não autenticado**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\all-skills\orchestrate\scripts\claude_codex_orchestrator.ps1 call-claude --prompt "oi" --timeout-s 30
```

Expected: se o perfil estiver `auth_required`, o erro é classificado corretamente; não deve ser tratado como quota.

- [ ] **Step 5: Commit**

```bash
git add manage-skills.ps1 ui/claude-auth.html all-skills/orchestrate/scripts/claude_codex_orchestrator.py all-skills/orchestrate/tests/test_claude_account_failover.py all-skills/orchestrate/tests/test_claude_codex_orchestrator.py
git commit -m "test: verify claude multi-account v1 flow"
```

---

## Self-Review

### Spec coverage

- Estado por conta: coberto nas Tasks 1 e 3
- Taxonomia de falhas: coberta na Task 2
- Policy Engine mínimo: coberto na Task 2 e no fluxo de backend
- Reidratação compacta: coberta na Task 4
- Plugin vs CLI fallback: coberto na Task 5
- Painel local: coberto na Task 6
- Verificação integrada: coberta na Task 7

### Placeholder scan

- Sem `TODO`, `TBD` ou referências circulares
- Cada tarefa contém arquivos, passos, comandos e resultado esperado

### Type consistency

- `state`, `leaseOwner`, `leaseExpiresAt`, `lastFailureKind`, `token_budget_hint`, `backend_used`, `account_switch_recommended` foram mantidos com o mesmo nome ao longo do plano

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-03-claude-multi-account-v1-implementation.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
