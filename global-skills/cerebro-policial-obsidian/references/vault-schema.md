# Vault Schema

Use esta skill sobre um vault unico.

## Camadas

- `DRCC Cerebro/BOs/`: acervo global frio por BO.
- `DRCC Cerebro/Entidades/`: acervo global frio por entidade.
- `DRCC Cerebro/Casos Ativos/<caso_id>/`: dossie quente do caso ativo.
- `DRCC Cerebro/Casos Arquivados/<caso_id>/`: dossie frio de caso materializado e encerrado.
- `DRCC Cerebro/Operacional/`: paineis operacionais e inbox.
- `DRCC Cerebro/Indices/`: bases e navegacao.

## Arquivos controlados pela skill

- `Casos Ativos/<caso_id>/Caso <caso_id>.md`
- `Casos Ativos/<caso_id>/Pecas/Peca <caso_id> - <peca_tipo> - <source_key>.md`
- `Casos Arquivados/<caso_id>/...`
- `Operacional/00_Casos_Ativos.md`
- `Operacional/00_Inbox_Atualizacoes_Pendentes.md`
- `Indices/Casos Ativos.base`
- `Indices/Pecas Ativas.base`

## Nota de caso

Frontmatter minimo:

```yaml
type: caso
caso_id: "00011329_2025"
status: "ativo"
titulo_curto: "Caso 00011329_2025"
bo_principal: "00011329/2025"
bo_relacionados:
  - "00011329/2025"
entidades_chave:
  - "187.38.209.15"
ultima_atualizacao: "2026-03-26"
prioridade: "normal"
```

Secoes obrigatorias:

- `Síntese`
- `BOs relacionados`
- `Peças produzidas`
- `Achados principais`
- `Pedidos e diligências`
- `Vínculos relevantes`
- `Log de atualizações`

## Nota de peca

Frontmatter minimo:

```yaml
type: peca
caso_id: "00011329_2025"
peca_tipo: "relatorio-missao"
source_key: "8ab0..."
source_path: "C:\\caminho\\arquivo.md"
data_peca: "2026-03-26"
bo_relacionados:
  - "00011329/2025"
entidades_chave:
  - "187.38.209.15"
confianca_vinculacao: "high"
```

Secoes obrigatorias:

- `Resumo curto`
- `Principais achados`
- `Pedidos e diligências`
- `Entidades-chave`
- `BOs relacionados`

## Regras

- Nao crie dossie para todos os procedimentos.
- Nao altere o conteudo de `BOs/` ou `Entidades/`.
- Mova o dossie inteiro para `Casos Arquivados/` quando o status mudar para `arquivado`.
