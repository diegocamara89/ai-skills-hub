# Quirks e Limites das IAs neste Ambiente

> Apenas comportamentos nao-obvios, bugs locais e restricoes de producao.
> Ultima atualizacao: 2026-04-05

---

## Claude Code

| Comando | Modelo default | Modelo top |
|---------|---------------|-----------|
| `echo "prompt" \| claude --print` | `claude-sonnet-4-6` | `claude-opus-4-6` |

**Stdin pipe obrigatorio** — nao usar `-p "inline"`, cmd.exe corrompe `{|}%`.

---

## Gemini

| Comando | Modelo rapido | Modelo serio |
|---------|--------------|-------------|
| `gemini -m MODELO -p "@arquivo.txt"` | `gemini-3-flash-preview` | `gemini-3-pro-preview` |

**Quirks criticos (observados em producao):**
- Rate limit 429 com 2+ chamadas simultaneas — serializar ou trocar para Codex/Qwen
- `rc=130` ("Operation cancelled") intermitente — retry ou fallback
- Stderr poluido com `[IDEClient] Failed to connect...` — nao e erro real, filtrar
- **EVITAR como worker de lote** (>20 itens) — Codex processou 63 itens com 100% sucesso; Gemini falhou

---

## Codex CLI

| Comando | Variavel obrigatoria |
|---------|---------------------|
| `echo "prompt" \| codex exec --skip-git-repo-check -` | Limpar `OPENAI_BASE_URL` e `OPENAI_API_KEY` antes |

**Quirks criticos:**
- Se chamado pelo Claude (que usa OpenRouter), as vars acima contaminam a auth do Codex
- Usar flag `-` para stdin — nao passar prompt como argumento
- Estavel em lotes: 63 chamadas consecutivas sem falha (pipeline URGA, 397s)

---

## Qwen CLI

| Comando | Modo autonomo |
|---------|--------------|
| `echo "prompt" \| qwen` | `echo "prompt" \| qwen --yolo` |

- Le stdin nativamente, sem flags
- Limite: 2.000 req/dia via OpenRouter; sem limite via Ollama local

---

## Matriz de decisao rapida

| Necessidade | 1a opcao | 2a opcao |
|-------------|----------|---------|
| Analise arquitetural pontual | Gemini Pro | Claude |
| Bugs especificos / implementacao | Codex | Claude |
| Lote grande (>20 itens) | Codex | Qwen |
| Lote pequeno ou triagem | Qwen | Gemini Flash |
| Dados sensiveis (local) | Qwen via Ollama | Claude |
| Visao executiva / plano | Claude | Gemini Pro |
