# VPS Sync Regression Fix + CLI Updates + Cleanup

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]`. NÃO IMPLEMENTAR sem autorização do user — este plano está em revisão.

**Goal:** Resolver bug de regressão de credenciais (sync empurra provider stale por cima de remote válido), atualizar Codex/Claude/Gemini CLI na VPS, desinstalar Qwen e limpar profiles legados em `auth-profiles.json`.

**Architecture:** Mudança cirúrgica em `vps_ai_auth_sync.py` (validação anti-regressão + flag `--only`) + 2 funções PowerShell em `manage-skills.ps1` (`Invoke-VpsAuthSyncForProfile`, `Invoke-VpsAuthSyncForCodex` passam `--only`). Update CLIs via script SSH idempotente. Cleanup com backup automático.

**Tech Stack:** Python 3 (sync script), PowerShell 7 (wrappers), Pester 5, SSH/systemctl (VPS ops).

---

## Contexto crítico

**Timeline do bug (confirmado pelos logs):**

| Hora (BRT) | Evento | Estado Codex VPS |
|---|---|---|
| ~23:00 | User loga Codex local | VÁLIDO |
| 23:01-23:13 | Sync VPS, openclaw restart | VÁLIDO |
| 23:13 | User loga Claude local | Claude OK |
| 23:22:55 | Painel chama `Invoke-VpsAuthSync*` → empurra `--claude-source` E default `~/.codex/auth.json` | Codex local 2-dias-velho sobe |
| 23:22:58 | openclaw-auth-sync.sh propaga para auth-profiles.json | **REGREDIU** |
| AGORA | Claude funciona, Codex retorna 401 | EXPIRED |

**Profiles atuais na VPS** (de `auth-profiles.json`):

| Profile | Status | Ação |
|---|---|---|
| `anthropic:claude-code` | VALID 7h | manter |
| `openai-codex:default` | EXPIRED 2d | re-logar local Codex + push |
| `qwen-portal:qwen-cli` | EXPIRED 0d | remover (Qwen descontinuado) |
| `qwen-portal:default` | EXPIRED 34d | remover |
| `google-gemini-cli:marcelodiego@gmail.com` | EXPIRED 8d | re-logar (Fase 2 separada) |
| `google-gemini-cli:cctech084@gmail.com` | EXPIRED 29d | re-logar OU remover (se não usa) |
| `anthropic:manual` | EXPIRED 20584d (1969!) | LIXO — remover |
| `anthropic:claude-cli` | EXPIRED 11d | LIXO ou re-logar (decidir) |

**Versões CLIs a atualizar (a verificar via `npm view`):**
- `@openai/codex` — atual na VPS desconhecido
- `@anthropic-ai/claude-code` — idem
- `@google/gemini-cli` — idem
- `@qwen-code/qwen-code` — **desinstalar** globalmente

---

## File Structure

```
C:\Users\marce\Diego\
├── AI-Skills-Hub\
│   ├── manage-skills.ps1                 (Modify ~3300, ~3700: passar --only para Python)
│   ├── tests\VpsAuthSyncSelective.Tests.ps1  (NEW — Pester anti-regression)
│   └── docs\superpowers\plans\
│       └── 2026-05-11-vps-sync-fix-and-update.md  (este arquivo)
│
└── VPS\Oracle\ClowdBot\scripts\
    ├── vps_ai_auth_sync.py               (Modify — add --only flag + remote-newer-wins check)
    └── vps-cli-update.sh                 (NEW — script idempotente SSH para update CLIs)
```

---

## Fase 1 — Fix sync regressivo (anti-regression)

### Task 1.1: Modificar `vps_ai_auth_sync.py` com `--only=<claude|codex|both>`

**Files:**
- Modify: `C:\Users\marce\Diego\VPS\Oracle\ClowdBot\scripts\vps_ai_auth_sync.py`

- [ ] **Step 1: Escrever teste Pester (smoke do behaviour)**

Como o Python script é o que muda, criamos teste PowerShell que invoca o Python com flag nova e valida output:

```powershell
# tests/VpsAuthSyncSelective.Tests.ps1
Describe "vps_ai_auth_sync --only flag" {
    It "Skip codex push when --only=claude even if codex auth exists" {
        # ... cria estado mock + roda Python local + valida JSON output
    }

    It "Skip claude push when --only=codex" {
        # ...
    }

    It "Default (no --only) preserves current behaviour" {
        # ...
    }
}
```

- [ ] **Step 2: Adicionar param `--only=` no Python**

```python
# vps_ai_auth_sync.py — adicionar em argparse
parser.add_argument(
    "--only",
    choices=["claude", "codex", "both"],
    default="both",
    help="Restringe sync a um provider so. Default 'both' preserva comportamento legado.",
)
```

- [ ] **Step 3: Aplicar filtro no compute_plan**

```python
def compute_plan(
    local_codex, remote_codex,
    local_claude, remote_claude,
    remote_openclaw_codex_ok,
    only: str = "both",  # NOVO
) -> SyncPlan:
    push_codex = needs_sync(local_codex, remote_codex) and only in ("codex", "both")
    push_claude = needs_sync(local_claude, remote_claude) and only in ("claude", "both")
    ...
```

- [ ] **Step 4: Anti-regression check — abortar se remote.expires > local.expires + margin**

```python
def needs_sync(local: ProviderState, remote: ProviderState) -> bool:
    if not local.present:
        return False
    if not remote.present:
        return True
    # NOVO: se remote tem token mais novo (expires maior por > 60s), nao regredir
    if remote.expires_ms and local.expires_ms and remote.expires_ms > local.expires_ms + 60_000:
        return False
    # fingerprint check (existente)
    return local.refresh_fingerprint != remote.refresh_fingerprint or local.account_id != remote.account_id
```

- [ ] **Step 5: Rodar smoke local — não tocar VPS**

```powershell
python .\scripts\vps_ai_auth_sync.py --dry-run --only=claude --json
# Esperado: pushCodex=false, pushClaude=true_or_false_based_on_state
```

- [ ] **Step 6: Commit (apos validacao do user)**

```bash
# manual: git add scripts/vps_ai_auth_sync.py
# manual: git commit -m "fix(vps-sync): add --only flag + remote-newer-wins anti-regression"
```

### Task 1.2: Modificar wrappers PowerShell

**Files:**
- Modify: `C:\Users\marce\Diego\AI-Skills-Hub\manage-skills.ps1` — linhas ~3300 (Claude) e ~3706 (Codex)

- [ ] **Step 1: Em `Invoke-VpsAuthSyncForProfile` (Claude), passar `--only=claude`**

```powershell
# Linha ~3300 atual:
$psi.Arguments = ('"{0}" --apply --json --claude-source "{1}"' -f $Script:VpsAuthSyncScriptPath, $profileDir)
# Trocar para:
$psi.Arguments = ('"{0}" --apply --json --only=claude --claude-source "{1}"' -f $Script:VpsAuthSyncScriptPath, $profileDir)
```

- [ ] **Step 2: Em `Invoke-VpsAuthSyncForCodex`, passar `--only=codex`**

```powershell
# Linha ~3706 atual:
$arguments = ('"{0}" --apply --json --codex-source "{1}"' -f $Script:VpsAuthSyncScriptPath, $authJsonPath)
# Trocar:
$arguments = ('"{0}" --apply --json --only=codex --codex-source "{1}"' -f $Script:VpsAuthSyncScriptPath, $authJsonPath)
```

- [ ] **Step 3: Rodar suite Pester completa — esperado ainda 117+ PASS (não regredir)**

```powershell
Invoke-Pester C:\Users\marce\Diego\AI-Skills-Hub\tests, C:\Users\marce\Diego\AI-Skills-Hub\aiox-shared\tests
```

- [ ] **Step 4: Commit**

### Task 1.3: Validação ponta-a-ponta manual

- [ ] User faz login Claude no painel
- [ ] Verifica `vps-sync-status.json`: deve mostrar `pushClaude=true, pushCodex=false`
- [ ] SSH VPS: confirma `~/.claude/.credentials.json` mtime recente, `~/.codex/auth.json` mtime INALTERADO
- [ ] Profile openclaw `openai-codex:default` continua com expires válido

---

## Fase 2 — Update CLIs na VPS

### Task 2.1: Verificar versões instaladas + disponíveis

- [ ] **Step 1: Coletar versões atuais via SSH**

```powershell
ssh -i ~/.ssh/id_ed25519 marce@79.72.71.20 'npm list -g --depth=0 2>&1 | grep -iE "codex|claude-code|gemini-cli|qwen"; echo; for pkg in "@openai/codex" "@anthropic-ai/claude-code" "@google/gemini-cli"; do echo "=== $pkg ==="; npm view "$pkg" version 2>&1 | head -1; done'
```

- [ ] **Step 2: Decidir se cada CLI precisa update**
  - Comparar atual vs latest
  - Considerar release notes (especialmente breaking changes Gemini que tem flag `--skip-trust` removido)

### Task 2.2: Criar script idempotente `vps-cli-update.sh`

**Files:**
- Create: `C:\Users\marce\Diego\VPS\Oracle\ClowdBot\scripts\vps-cli-update.sh`

```bash
#!/usr/bin/env bash
# vps-cli-update.sh — Atualiza Codex/Claude/Gemini CLIs na VPS de forma idempotente
# Para o gateway, atualiza, reinicia.
set -euo pipefail

PACKAGES=(
  "@openai/codex"
  "@anthropic-ai/claude-code"
  "@google/gemini-cli"
)

echo "=== Parando openclaw-gateway ==="
systemctl --user stop openclaw-gateway

echo "=== Update CLIs ==="
for pkg in "${PACKAGES[@]}"; do
  echo "--- $pkg ---"
  npm install -g "$pkg@latest" 2>&1 | tail -5
done

echo "=== Desinstalando Qwen (descontinuado) ==="
npm uninstall -g @qwen-code/qwen-code 2>&1 || echo "qwen ja desinstalado"

echo "=== Reiniciando gateway ==="
systemctl --user start openclaw-gateway
sleep 3
systemctl --user is-active openclaw-gateway

echo "=== Versoes pos-update ==="
for pkg in "${PACKAGES[@]}"; do
  npm list -g "$pkg" --depth=0 2>&1 | grep -E "$pkg"
done
```

- [ ] **Step 1: Criar script local + scp para VPS**

```powershell
scp -i ~/.ssh/id_ed25519 C:\Users\marce\Diego\VPS\Oracle\ClowdBot\scripts\vps-cli-update.sh marce@79.72.71.20:~/.local/bin/
ssh -i ~/.ssh/id_ed25519 marce@79.72.71.20 'chmod +x ~/.local/bin/vps-cli-update.sh'
```

- [ ] **Step 2: Executar (com confirmação user)**

```powershell
ssh -i ~/.ssh/id_ed25519 marce@79.72.71.20 '~/.local/bin/vps-cli-update.sh'
```

- [ ] **Step 3: Validar logs gateway post-restart sem erros novos**

---

## Fase 3 — Cleanup profiles legados

### Task 3.1: Remover profiles lixo de `auth-profiles.json`

Profiles para remover:
- `anthropic:manual` (expired 20584d — lixo histórico, provavelmente epoch zero)
- `qwen-portal:default`, `qwen-portal:qwen-cli` (Qwen descontinuado)
- `google-gemini-cli:cctech084@gmail.com` (se user não usa)

- [ ] **Step 1: Backup do `auth-profiles.json` antes**

```bash
cp ~/.openclaw/agents/main/agent/auth-profiles.json{,.bak.20260511-$(date +%H%M)}
```

- [ ] **Step 2: Script Python remove + valida**

```python
# ssh com here-doc:
python3 <<'EOF'
import json, shutil, pathlib, datetime
p = pathlib.Path('/home/marce/.openclaw/agents/main/agent/auth-profiles.json')
shutil.copy(p, str(p) + '.bak.' + datetime.datetime.now().strftime('%Y%m%d-%H%M'))
d = json.loads(p.read_text())
to_remove = ['anthropic:manual', 'qwen-portal:default', 'qwen-portal:qwen-cli']
removed = []
for k in to_remove:
    if k in d.get('profiles', {}):
        del d['profiles'][k]
        removed.append(k)
# Limpar lastGood se aponta para removidos
for prov, prof_key in list(d.get('lastGood', {}).items()):
    if prof_key in to_remove:
        del d['lastGood'][prov]
p.write_text(json.dumps(d, indent=2))
print(f"Removed: {removed}")
EOF
```

- [ ] **Step 3: Replicar para todos os agents (main, analyst, builder, reviewer, assistant, nutri-diego, nutri-anne, trainer)**

O `openclaw-auth-sync.sh` propaga, mas precisa rodar:
```bash
~/.local/bin/openclaw-auth-sync.sh
```

- [ ] **Step 4: Restart gateway para carregar profiles limpos**

```bash
systemctl --user restart openclaw-gateway
```

---

## Fase 4 — Re-logar Gemini/Codex para reativar

(Após updates + cleanup, vai precisar re-logar os providers expirados)

- [ ] **Step 1: User faz login Codex no painel local** → sync com `--only=codex` empurra
- [ ] **Step 2: User faz login Gemini no painel local** → sync (precisa adicionar `--only=gemini`?)
- [ ] **Step 3: Validar profiles válidos no openclaw**

```bash
ssh marce@79.72.71.20 'python3 <<EOF
import json, time
now = int(time.time() * 1000)
d = json.load(open("/home/marce/.openclaw/agents/main/agent/auth-profiles.json"))
for k, p in d.get("profiles", {}).items():
    exp = p.get("expires", 0)
    print(f"{k:50} {'VALID' if exp > now else 'EXPIRED'}")
EOF'
```

---

## Riscos e mitigações

| Risco | Mitigação |
|---|---|
| Quebrar sync existente que funciona para casos default | `--only=both` é default; comportamento legado preservado |
| Update CLI quebrar gateway por API change | Backup `auth-profiles.json` ANTES; teste em horário low-traffic; tem rollback (revert `npm install -g <pkg>@<old_ver>`) |
| Anti-regression check falhar falso-positivo (clock drift VPS↔local) | Margem de 60s + log estruturado de cada skip |
| Remover profile que openclaw ainda referencia | Restart gateway forçado + alerta se erro |
| Sync `--only=gemini` ainda não existe no Python | Adicionar choice em argparse mas pode adiar implementação completa pra próxima iteração |
| User logar 2 providers em janela curta (race) | Sync `--only=X` é independente; sem race |
| Suite Pester regredir | Roda full suite após cada task; bloqueia commit se falhar |

---

## Verificação ponta-a-ponta (depois de TODAS as fases)

```powershell
# 1) Pester verde
Invoke-Pester C:\Users\marce\Diego\AI-Skills-Hub\tests, C:\Users\marce\Diego\AI-Skills-Hub\aiox-shared\tests

# 2) Smoke sync seletivo: login Claude no painel → confirma só Claude empurrado
$status = Get-Content C:\Users\marce\.claude-orchestrator\vps-sync-status.json -Raw | ConvertFrom-Json
$status."claude-a" | Should: pushClaude=$true, pushCodex=$false

# 3) Login Codex no painel → confirma só Codex empurrado
$status."codex:codex-b" | Should: pushClaude=$false, pushCodex=$true

# 4) SSH VPS: profiles na auth-profiles.json — só providers ativos
ssh marce@79.72.71.20 'python3 -c "import json; d=json.load(open(\"/home/marce/.openclaw/agents/main/agent/auth-profiles.json\")); print(sorted(d[\"profiles\"].keys()))"'
# Esperado: ["anthropic:claude-code", "google-gemini-cli:marcelodiego@gmail.com", "openai-codex:default"]
# NÃO esperado: nenhum qwen, nenhum anthropic:manual

# 5) Gateway responde sem 401 loop
ssh marce@79.72.71.20 'journalctl --user --since "5 minutes ago" --no-pager | grep -iE "Token refresh failed|401|fallback" | wc -l'
# Esperado: 0
```

---

## Decisão pendente do user

Antes de implementar, confirme:

1. **`anthropic:claude-cli`** (expired 11d) — remover ou re-logar?
2. **`google-gemini-cli:cctech084@gmail.com`** (segunda conta Gemini) — manter ou remover?
3. **Fase 2 (update CLIs)** — agora ou depois? Update pode quebrar coisa se alguma CLI tem breaking change. Recomendo: fazer em momento de menor uso.
4. **Hardening 3 (`aiohealth`)** ainda está rodando background — esperar ele terminar antes de começar Fase 1, ou paralelizar?
