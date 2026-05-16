# orchestrate — Agent Skill para Orquestração Multi-IA via CLI

> Compatível com **Claude Code**, **Codex CLI**, **Qwen**, **Gemini** e qualquer agente que suporte SKILL.md ou AGENTS.md.

## O que faz

Ensina o agente a coordenar múltiplas IAs via CLI no Windows usando o fluxo canônico:

```
Claude planeja → Codex executa → Claude valida (quando o risco justifica)
```

Inclui: detecção de capacidade por ferramentas disponíveis, contrato de handoff JSON, quirks de produção das CLIs, kill de árvore de processo no Windows e wrapper scripts.

## Instalação

```bash
# Claude Code (projeto local)
cp -r orchestrate/ .claude/skills/

# Claude Code (global)
cp -r orchestrate/ ~/.claude/skills/
```

## Como usar

```
/orchestrate analise arquitetural do arquivo X.py com Gemini e Codex
```

## Estrutura

```
orchestrate/
├── SKILL.md                 # Para Claude Code: plano, fluxo, contrato de handoff
├── AGENTS.md                # Para Codex/Qwen/Gemini: cheatsheet de invocação
├── ai-catalog.md            # Quirks de produção por IA (rate limits, bugs, stdin)
├── calling-conventions.md   # Comandos CLI exatos, Windows kill tree, JSON parser
├── examples.md              # Exemplos práticos
├── team-patterns.md         # → redirect para run_ai_cli.py
├── agents/openai.yaml       # Agente OpenAI com instruções de orquestração
├── references/              # Docs auxiliares (windows-orchestrator, codex multiagent...)
├── scripts/                 # run_ai_cli.py, claude_codex_orchestrator.py/.ps1
└── tests/                   # Testes dos scripts
```

## Avaliação (skill-judge, 120 pts)

| Avaliador | Nota | Letra | Data |
|-----------|------|-------|------|
| Gemini Pro (qualidade) | 107/120 | A (89%) | 2026-04-05 |
| Gemini Pro (redundância) | — | Aprovado | 2026-04-05 |

## IAs suportadas

| IA | Comando seguro | Observação |
|----|---------------|------------|
| Claude | `echo "prompt" \| claude --print` | stdin obrigatório no Windows |
| Codex | `echo "prompt" \| unset OPENAI_BASE_URL && ... codex exec -` | Limpar vars OpenRouter |
| Qwen | `echo "prompt" \| qwen` | stdin nativo |
| Gemini | `gemini -m gemini-3-flash-preview -p "@/tmp/prompt.txt"` | Não suporta stdin |

## Autor

**Diego Câmara** — [@diegocamara89](https://github.com/diegocamara89)

Criado com Claude Code + Gemini CLI + Codex CLI (fev/2026). Refatorado abr/2026.

## Licença

MIT
