---
name: orchestrate
description: Orquestrador multi-IA para Codex, Gemini e Qwen. Cheatsheet de invocacao sem API key, gatilhos de escalada e contrato de handoff.
---

# Orchestrate — Cheatsheet para Codex e outras IAs

> Para identificacao de qual IA voce e e o fluxo canonico, consulte `SKILL.md`.
> Este arquivo contem apenas o que e exclusivo para IAs nao-Claude.

## Invocacao rapida (sem API key)

| IA | Comando seguro | Observacao critica |
|----|---------------|-------------------|
| Claude | `echo "prompt" \| claude --print` | Nao usar `-p inline` — cmd.exe corrompe `{|}%` |
| Codex | `echo "prompt" \| unset OPENAI_BASE_URL && unset OPENAI_API_KEY && codex exec --skip-git-repo-check -` | Limpar vars OpenRouter e obrigatorio |
| Qwen | `echo "prompt" \| qwen` | Le stdin nativamente |
| Gemini | `gemini -m gemini-3-flash-preview -p "@/tmp/prompt.txt"` | Nao suporta stdin — exige arquivo |

Para prompts longos ou com `{}|%`, use sempre o script centralizado:

```bash
python scripts/run_ai_cli.py --provider claude  --prompt-file /tmp/prompt.txt
python scripts/run_ai_cli.py --provider codex   --prompt-file /tmp/prompt.txt
python scripts/run_ai_cli.py --provider gemini  --model gemini-3-flash-preview --prompt-file /tmp/prompt.txt
python scripts/run_ai_cli.py --provider qwen    --prompt-file /tmp/prompt.txt
```

## Quando escalar e contrato de handoff

Consulte `SKILL.md` para: regras completas de escalada, contrato de handoff JSON e gatilho grep de risco.

Resumo: escale via `echo "..." | claude --print` quando houver alteracao multiarquivo, temas sensiveis (security/auth/pii/migration/billing), testes ausentes, ou erro apos 2 tentativas.

## Orquestracao nativa Codex (sem CLI externa)

Se voce e o Codex e quer distribuir entre sub-agentes Codex, instrua cada um com:

```json
{ "role": "executor|revisor|auditor", "task": "descricao precisa", "output_format": "json" }
```

Cada sub-agente deve responder no formato de handoff acima.
Para detalhes: `references/codex-native-multiagent.md`.
