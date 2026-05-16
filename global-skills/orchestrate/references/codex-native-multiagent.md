# Orquestração nativa do Codex (spawn_agent)

Use esta referência quando quiser equipes **sem CLI externa**.

## Contrato de saída (por agente)

Peça para cada sub-agente responder **apenas JSON**:

```json
{
  "status": "OK|ERRO",
  "papel": "arquiteto|executor|revisor|auditor|debugger",
  "achados": ["..."],
  "riscos": ["..."],
  "recomendacao": "...",
  "next_steps": ["..."]
}
```

## Padrões práticos

### Paralelo (independente)

- Arquiteto: checa design/anti-patterns
- Revisor: checa clareza/alternativas
- Auditor: checa segurança/privacidade

Depois: consolidação única com consenso/divergências.

### Sequencial (dependente)

- Arquiteto propõe plano
- Executor implementa
- Revisor valida e pede ajustes

## Boas práticas

- 2–4 agentes costuma ser o “sweet spot”.
- Prompts curtos + contrato JSON reduzem ruído.
- Sempre explicitar “o que é aceitável mudar” (escopo) e “o que não pode” (restrições).

