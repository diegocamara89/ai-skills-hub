---
name: cerebro-policial-obsidian
description: Atualize a camada quente de casos ativos em vaults Obsidian policiais autorizados sem poluir o acervo global de BOs e entidades. Use quando o trabalho envolver caso ativo, inquerito, BO, relatorio de missao, relatorio de diligencias, oficio, representacao, analise tecnica, achado probatorio, vinculacao de peca ao caso, ou manutencao do painel operacional de casos ativos em vaults como DRCC_Obsidian_Vault. Tambem use para ativar, arquivar e sincronizar dossies de casos ativos com rastreabilidade de fonte e escrita idempotente.
---

# Cerebro Policial Obsidian

Mantenha a camada quente do vault policial sem duplicar o cerebro inteiro.

## Regra central

- Trate `BOs/` e `Entidades/` como acervo frio e global.
- Materialize dossie apenas para caso ativo, prioritario ou com peca final relevante.
- Escreva no vault apenas com evidencia concreta e vinculacao confiavel.
- Se a vinculacao estiver fraca, registre no inbox operacional e pare.

## Nunca faca

- Nunca grave fatos de caso na `napkin`. Ela guarda regras recorrentes, nao inteligencia operacional.
- Nunca crie dossie de caso para todo procedimento so porque ele existe no acervo.
- Nunca escreva em vault fora da lista autorizada.
- Nunca vincule peca a caso so por semelhanca narrativa quando faltar identificador, BO ativo ou contexto operacional.
- Nunca sobrescreva `BOs/` ou `Entidades/` existentes para "encaixar" a camada quente.

## Fluxo

1. Confirme que o workspace e policial e que o vault-alvo esta autorizado.
2. Identifique se a entrada e uma peca final principal ou um comando operacional de ativacao/arquivamento.
3. Resolva `caso_id` nesta ordem:
   - identificador explicito `NNNNNNNN_YYYY` ou `NNNNNNNN/YYYY` em caminho, nome ou conteudo;
   - BO citado que ja esteja ligado a um caso ativo;
   - contexto operacional ativo em `DRCC Cerebro/Operacional/00_Casos_Ativos.md`;
   - inbox pendente, sem escrita no caso.
4. Se a confianca cair abaixo do limiar seguro, registre no inbox e nao escreva no dossie.
5. Se a confianca for suficiente, use `scripts/sync_case_to_obsidian.py` para:
   - criar ou atualizar o dossie em `Casos Ativos/<caso_id>/`;
   - criar ou atualizar a nota da peca;
   - reconstruir a nota do caso, o painel operacional e o inbox.
6. Preserve a base global existente. O dossie ativo referencia `BOs` e `Entidades`; ele nao substitui essas notas.

## O que sincronizar no v1

Sincronize apenas:

- `relatorio-missao`
- `relatorio-diligencia`
- `oficio`
- `representacao`
- `analise-tecnica`
- `achado-probatorio`

Ignore rascunhos, brainstorms, conversas e texto sem fonte identificavel.

## Comandos operacionais

Ativar um caso sem peca:

```bash
python scripts/sync_case_to_obsidian.py activate-case \
  --vault-path "C:\Users\marce\Diego\PCRN\DRCC\DRCC_Obsidian_Vault" \
  --case-id "00011329_2025" \
  --bo "00011329/2025" \
  --focus
```

Sincronizar uma peca:

```bash
python scripts/sync_case_to_obsidian.py sync \
  --vault-path "C:\Users\marce\Diego\PCRN\DRCC\DRCC_Obsidian_Vault" \
  --source-path "C:\caminho\relatorio_missao_00011329_2025.md" \
  --piece-type "relatorio-missao"
```

Arquivar um caso:

```bash
python scripts/sync_case_to_obsidian.py archive-case \
  --vault-path "C:\Users\marce\Diego\PCRN\DRCC\DRCC_Obsidian_Vault" \
  --case-id "00011329_2025"
```

## Ler sob demanda

- Leia `references/vault-schema.md` antes de mexer na estrutura de notas ou bases.
- Leia `references/artifact-triggers.md` quando houver duvida se uma peca deve ou nao gerar atualizacao.
- Leia `references/case-resolution.md` quando a vinculacao do caso estiver ambigua.

## Resultado esperado

- O vault continua unico.
- A operacao diaria olha para `Casos Ativos`.
- O historico continua pesquisavel por `BOs` e `Entidades`.
- Casos arquivados saem da camada quente sem perder backlinks e contexto.
