---
name: deep-research
description: Multi-source deep research using web search MCPs. Searches the web, synthesizes findings, and delivers cited reports with source attribution. Use when the user wants thorough research on any topic with evidence and citations.
origin: ECC
---

# Deep Research

Workflow estruturado para produção de relatórios completos e citados a partir de múltiplas fontes web.

## When to Activate

Ativar quando o usuário pedir:
- "research", "deep dive", "investigate", "current state of"
- Análise competitiva ou benchmarking
- Due diligence sobre tecnologia, mercado ou pessoa
- Pesquisa com evidências e fontes citadas

## MCP Requirements

Pelo menos uma ferramenta de busca deve estar configurada:
- `firecrawl` — busca e scraping de páginas completas
- `exa` — busca semântica avançada
- `WebSearch` + `WebFetch` — alternativa nativa do Claude Code

Ambas (`firecrawl` + `exa`) em conjunto oferecem cobertura máxima.

## Workflow

### Step 1: Clarify Objectives
Faça 1-2 perguntas clarificadoras para entender:
- Qual o objetivo da pesquisa?
- Qual o nível de profundidade esperado?
- Há fontes preferenciais ou restrições?

### Step 2: Decompose the Topic
Quebre o tópico em 3-5 sub-questões focadas:

```
Topic: "State of AI coding assistants in 2025"

Sub-questions:
1. What are the top tools and their market share?
2. What are the benchmark performance comparisons?
3. What are the pricing models?
4. What do developers say in forums/reviews?
5. What are the recent major releases/changes?
```

### Step 3: Multi-Source Search
Use buscas variadas com keywords diferentes. Alvo: 15-30 fontes.

```
# Vary your search terms
"AI coding assistants 2025 comparison"
"Claude Code vs Copilot benchmark"
"developer survey AI tools 2025"
"best coding AI tools reddit"
```

### Step 4: Deep-Read Key Sources
Selecione 3-5 fontes mais relevantes e leia o conteúdo completo (não só o snippet).

Priorize:
- Publicações técnicas e papers
- Dados primários (benchmarks, surveys)
- Fontes recentes (últimos 6 meses)

### Step 5: Synthesize into Report

Estrutura padrão do relatório:

```markdown
# [Topic] — Research Report

**Date:** YYYY-MM-DD
**Sources:** N sources reviewed

## Executive Summary
2-3 parágrafos com as principais conclusões.

## Key Findings

### Finding 1: [Título]
Análise com citações inline [Source 1].

### Finding 2: [Título]
...

## Data & Evidence
Tabelas, números, comparativos.

## Gaps & Limitations
O que não foi possível confirmar. O que pode ter mudado.

## Sources
1. [Title](URL) — descrição
2. ...
```

### Step 6: Deliver
- Relatório completo no chat, ou
- Salvar em arquivo `.md` se o usuário preferir

## Parallel Research with Subagents

Para tópicos amplos, paralelize usando o Agent tool:

```
Agent 1: Buscar dados quantitativos e benchmarks
Agent 2: Buscar opiniões e reviews de usuários
Agent 3: Buscar notícias e lançamentos recentes
```

Depois sintetize os resultados dos 3 agentes em um único relatório.

## Quality Rules

1. **Toda afirmação precisa de fonte** — sem dados sem citação
2. **Cross-reference** — confirme fatos importantes em 2+ fontes
3. **Recência** — prefira fontes dos últimos 12 meses; sinalize quando antigas
4. **Acknowledge gaps** — seja explícito sobre o que não foi encontrado
5. **Sem alucinação** — se não encontrou dado, diga que não encontrou
6. **Fato vs inferência** — separe claramente dados verificados de análise própria

## Examples

```
# Tópicos adequados para esta skill:
"What are the best practices for RAG systems in 2025?"
"Compare pricing of top cloud providers for ML workloads"
"What is the current state of WebAssembly adoption?"
"Research competitors to [product] in the Brazilian market"
"Due diligence on [technology/library] before adopting"
```
