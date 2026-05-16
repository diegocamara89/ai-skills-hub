# Case Resolution

Resolva o caso de forma conservadora.

## Ordem

1. `case_id` explicito passado ao script
2. identificador `NNNNNNNN_YYYY` ou `NNNNNNNN/YYYY` em caminho, nome ou conteudo
3. BO citado que ja esteja em um caso ativo
4. `caso_em_foco` em `DRCC Cerebro/Operacional/00_Casos_Ativos.md`
5. inbox pendente, sem escrita no caso

## Sinais fortes

- pasta do procedimento no caminho do arquivo
- nome do arquivo contendo o numero do caso
- conteudo com um unico identificador compativel
- BO citado que ja esta no frontmatter de um caso ativo

## Sinais fracos

- varias referencias numericas concorrentes
- narrativa semelhante sem identificador
- mencao a BO historico nao ligado a caso ativo

## Politica

- Um unico sinal forte: pode escrever.
- Dois sinais medios convergentes: pode escrever.
- Qualquer ambiguidade relevante: inbox.
