---
name: orchestrate
description: Orquestrador Windows-first para Claude Code como planejador principal, Codex como executor e Claude como validador condicional, com failover reativo entre perfis Claude e handoff estruturado de baixo contexto.
---

# Orchestrate

Use esta skill quando o trabalho pedir coordenacao entre modelos, troca automatica de perfis Claude por cota, ou quando o usuario quiser explicitar o fluxo `Claude planeja -> Codex executa -> Claude valida quando vale a pena`.

## Objetivo canonico

- `Claude` decide o plano, o risco e se vale chamar outro modelo.
- `Codex` executa implementacao, automacao e alteracoes de codigo.
- `Claude` valida apenas quando o risco justificar custo e latencia.

Nao trate esta skill como um "roteador multi-IA generico". O caminho padrao aqui e:

1. classificar a tarefa
2. planejar no Claude
3. executar no Codex quando houver trabalho de implementacao
4. devolver ao Claude um handoff curto
5. validar no Claude apenas se os gatilhos de risco forem atingidos

## Como identificar qual IA voce e

Nao tente adivinhar seu nome. Observe as ferramentas que voce tem disponíveis:

| Voce tem esta ferramenta | Voce provavelmente e | Como chamar Claude |
|--------------------------|---------------------|--------------------|
| `Agent tool` | Claude Code | Agent tool nativo (nao use subprocess) |
| `exec`/shell sem `Agent tool` | Codex, Gemini ou Qwen | `echo "prompt" \| claude --print` |

### Chamando cada IA via stdin pipe (sem Agent tool)

```bash
# Claude
echo "prompt" | claude --print

# Codex (obrigatorio limpar variaveis OpenRouter)
echo "prompt" | unset OPENAI_BASE_URL && unset OPENAI_API_KEY && codex exec --skip-git-repo-check -

# Qwen
echo "prompt" | qwen

# Gemini (nao suporta stdin direto — usar arquivo temporario)
cat > /tmp/prompt.txt << 'EOF'
prompt aqui
EOF
gemini -m gemini-3-flash-preview -p "@/tmp/prompt.txt"
```

Nunca use `-p "prompt inline"` para prompts com codigo, JSON ou dados — o `cmd.exe` no Windows
corrompe `{`, `}`, `|` e `%` silenciosamente.

## Regra de decisao

Classifique o pedido em um destes modos antes de executar:

- `claude_only`
  - quando o proprio Claude resolve sem implementacao real, sem automacao e sem risco relevante
- `codex`
  - quando ha execucao tecnica, mudanca em arquivo, shell, refactor, teste, script ou investigacao operacional

Valide no Claude somente quando houver um ou mais destes sinais:

- alteracao multiarquivo
- `security`, `auth`, `privacy`, `pii`, `migration`, `schema`, `billing`, `infra`, `refactor`
- mudanca com testes ausentes ou fracos
- pedido explicito do usuario para revisar ou validar
- erro do executor que precise de arbitragem do planejador

Para decidir programaticamente: `grep -iE 'security|auth|password|token|pii|migration|billing|schema' <arquivos>` — se der match, acione validacao.

## Contrato de handoff

Quando o Codex devolver contexto para o Claude, responda **apenas este JSON**:

```json
{
  "status": "OK|ERRO|PARCIAL",
  "task_summary": "o que foi feito em 1-2 frases",
  "changed_files": ["lista/de/arquivos.py"],
  "tests_run": true,
  "risks": ["lista de riscos ou array vazio"],
  "analyst_summary": "observacoes tecnicas relevantes",
  "next_action": "DONE|NEEDS_VALIDATION|NEEDS_RETRY|ESCALATE"
}
```

**NEVER** envolva a resposta em blocos markdown (\`\`\`json). Stdout deve comecar com `{` e terminar com `}` para permitir parse direto via `jq` ou Python.

## Wrapper Windows

Sempre que o usuario quiser o fluxo automatizado, prefira os scripts desta skill:

- `scripts/claude_codex_orchestrator.py bootstrap-profiles`
- `scripts/claude_codex_orchestrator.py call-claude`
- `scripts/claude_codex_orchestrator.py call-codex`
- `scripts/claude_codex_orchestrator.py route`
- `scripts/claude_codex_orchestrator.ps1 ...`

Esses comandos existem para:

- isolar `CLAUDE_CONFIG_DIR` por perfil
- preservar autenticacao de mais de uma conta Claude no mesmo usuario do Windows
- detectar erro explicito de cota
- alternar para o proximo perfil Claude
- chamar o Codex pelo `.cmd` correto no Windows
- devolver um handoff curto e previsivel

## Perfis Claude

Perfis vivem fora do repositorio, por padrao em:

- `%USERPROFILE%\.claude-profiles\claude-a`
- `%USERPROFILE%\.claude-profiles\claude-b`

Credenciais e estado ficam fora do hub. So compartilhe no bootstrap os assets nao sensiveis, como:

- `skills`
- `plugins`
- `commands`
- `settings.json`
- `trustedFolders.json`

Nao copie credenciais entre perfis manualmente.

## Sequencia recomendada

1. Se os perfis ainda nao existem, rode `bootstrap-profiles`.
2. Se a tarefa exigir execucao, use `route`.
3. Se a tarefa for simples e totalmente analitica, responda no proprio Claude.
4. Para escalar entre IAs, use `scripts/run_ai_cli.py --provider X --prompt-file /tmp/prompt.txt`.

## Quando consultar arquivos auxiliares

- **Falha silenciosa ou timeout inesperado**: leia `calling-conventions.md` (kill de arvore de processo no Windows)
- **Rate limit, rc=130 ou resposta vazia do Gemini**: leia `ai-catalog.md` (quirks e fallback de IA)
- **Handoff JSON chegando corrompido ou com preambulo**: use o extrator de 3 niveis documentado em `calling-conventions.md`
- **Orquestracao nativa Codex-Codex (sem CLI externa)**: leia `references/codex-native-multiagent.md`

## Integracoes nativas

Para pacotes como `superpowers`, nao importe a raiz do repositorio como se fosse uma unica skill.

Use o hub para:

- documentar a instalacao nativa por agente
- sincronizar skill packs multi-skill apenas pelos mecanismos suportados
- rejeitar importacoes GitHub sem `SKILL.md` raiz

Consulte:

- `references/windows-orchestrator.md`
- `references/windows-orchestrator.config.example.json`
- `references/calling-conventions-powershell.md`

## Sincronizacao

Este arquivo e uma copia gerenciada. A fonte original esta em:
`all-skills/orchestrate/SKILL.md`

Para sincronizar apos atualizacoes:
```powershell
.\manage-skills.ps1 sync-global
```
