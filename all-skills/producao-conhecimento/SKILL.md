---
name: producao-conhecimento
description: >
  Esta skill deve ser usada quando o usuário pedir "produzir inteligência",
  "criar relatório de inteligência", "fazer ficha do alvo", "mapa de vínculos",
  "análise de organização", "produto de inteligência", "cronograma de fatos",
  "NIR", "nota de inteligência", "análise de vínculos", ou quando o
  comando /producao-conhecimento for invocado. Contém os padrões,
  estruturas e metodologias de inteligência policial para transformar
  dados investigativos em conhecimento estruturado e acionável.
---

# Produção de Conhecimento de Inteligência Policial — Conhecimento Especializado

Skill de referência para produção de todos os tipos de conhecimento de inteligência no contexto de investigações policiais.

## Ciclo de Inteligência Policial

O ciclo de inteligência tem 5 fases que orientam a produção de conhecimento:

```
1. PLANEJAMENTO → O que preciso saber?
2. COLETA → Reunir dados de todas as fontes
3. PROCESSAMENTO → Organizar, validar e tratar os dados
4. ANÁLISE → Transformar dados em conhecimento
5. DIFUSÃO → Entregar o produto ao usuário final
```

Cada produto de inteligência deve percorrer este ciclo. A qualidade do produto é diretamente proporcional à completude das fases anteriores.

## Classificação de Informações (Lei 12.527/2011 — LAI)

Ao produzir qualquer produto de inteligência, aplicar a classificação adequada:

| Grau | Prazo máximo | Quando usar |
|------|-------------|------------|
| **RESERVADO** | 5 anos | Informações de uso interno que não expõem métodos ou fontes |
| **CONFIDENCIAL** | 15 anos | Informações que podem comprometer investigação em andamento |
| **SECRETO** | 25 anos | Informações que expõem fontes humanas ou métodos especiais |
| **ULTRASSECRETO** | 25 anos + renovável | Raramente aplicável à atividade policial estadual |

**Regra prática**: Inquéritos em andamento com quebras de sigilo → SIGILOSO (conforme CPP). Produtos de inteligência sobre organizações criminosas → no mínimo CONFIDENCIAL.

## Fontes de Informação por Tipo

### Fontes Abertas (OSINT)
- Registros públicos: Receita Federal, Junta Comercial, cartórios
- Redes sociais e internet (com cautela para admissibilidade)
- Diário Oficial (nomeações, licitações, sanções)
- Portais de transparência
- Bases de precatórios, protestos, ações judiciais

### Fontes Restritas (acesso por requisição/autorização)
- Bases policiais: SISP, IIRGD, AFIS, INFOCRIM, SIGMA
- Bases de trânsito: DETRAN, SENATRAN, RENAJUD
- Bases tributárias: Receita Federal (com representação judicial)
- Dados bancários: BACENJUD (com autorização judicial)
- Dados do COAF (art. 15, Lei 9.613/98)

### Fontes Humanas
- Vítimas, testemunhas, informantes
- Colaboradores premiados (art. 4º, Lei 12.850/2013)
- Infiltrados (art. 10-A, Lei 12.850/2013)

## Técnicas de Análise de Vínculos

### Análise de Redes Sociais (ARS) Aplicada à Investigação

Conceitos-chave:
- **Nódulo**: pessoa, empresa, conta bancária, endereço ou fato
- **Aresta**: relação entre nódulos (tipo + força + direção)
- **Centralidade**: grau de conexão de um nódulo (quem é mais central é mais importante)
- **Cluster**: grupo de nódulos fortemente interconectados

### Tipos de Vínculos na Investigação Criminal

| Tipo | Exemplos | Força Investigativa |
|------|---------|-------------------|
| **Familiar** | Cônjuge, filho, irmão | Alta (pode ser laranja) |
| **Societário** | Sócio, procurador, representante | Alta (pode encobrir beneficiário real) |
| **Financeiro** | Transferência bancária, PIX, TED | Muito Alta (documentado) |
| **Telefônico** | Ligações, mensagens frequentes | Alta (demonstra comunicação) |
| **Operacional** | Co-autor, executor, suporte | Máxima (vínculo com o crime) |
| **Profissional** | Empregador, cliente, fornecedor | Média (pode ser legítimo) |
| **Endereço** | Mesmo endereço, vizinhos | Média (indica proximidade) |
| **Criminal** | Co-réus em outros casos | Alta (padrão de conduta) |

### Método de Construção do Mapa de Vínculos

1. Listar todos os nódulos identificados na investigação
2. Para cada par de nódulos, verificar se existe vínculo documentado
3. Classificar cada vínculo por tipo, força e evidência
4. Identificar os nódulos de maior centralidade (alvos prioritários)
5. Identificar clusters (organizações, grupos)
6. Identificar "pontes" — nódulos que conectam dois grupos

## Análise Temporal e Espacial

### Construção de Linha do Tempo Investigativa

Princípios:
- Todo evento deve ter fonte (folhas dos autos, número do documento)
- Lacunas temporais são tão importantes quanto os eventos documentados
- Cruzar eventos com a posição geográfica dos investigados
- Identificar "janelas de oportunidade" para o crime

### Análise de Padrões Temporais

Perguntas a responder:
- O crime ocorreu em horários/dias que seguem padrão?
- Os contatos entre investigados seguem padrão temporal?
- Há coincidência entre movimentações financeiras e datas dos fatos?
- Os deslocamentos dos investigados coincidem com os eventos criminosos?

## Padrões de Redação por Produto

### Princípios Gerais de Redação de Inteligência

1. **Objetividade**: cada frase deve conter uma única ideia
2. **Rastreabilidade**: toda afirmação deve ter fonte identificada
3. **Distinção entre fato e análise**: separar claramente o que é dado e o que é interpretação
4. **Linguagem de hedging**: usar "indica", "sugere", "é consistente com" para análises; usar "documenta", "demonstra" apenas para fatos objetivos
5. **Orientação para ação**: o produto de inteligência deve sempre culminar em recomendações concretas

### Linguagem Adequada para Cada Tipo de Afirmação

**Para fatos documentados:**
- "O extrato bancário demonstra transferência de R$ X em [data]"
- "O depoimento de [testemunha] afirma que..."
- "O laudo pericial conclui que..."

**Para análises e inferências:**
- "A movimentação financeira *indica* possível incompatibilidade patrimonial"
- "O padrão de comunicações *sugere* coordenação entre investigados"
- "Os dados disponíveis são *consistentes com* a hipótese de..."

**Para recomendações:**
- "Recomenda-se aprofundar a investigação de [elemento] mediante [diligência]"
- "Sugere-se representação por [medida cautelar] com fundamento em..."

## Referência: Bases de Dados e Sistemas Policiais

| Sistema | Acesso | Conteúdo |
|---------|--------|---------|
| SISP/IIRGD | Delegacias | Identificação criminal, antecedentes |
| AFIS | Delegacias | Identificação datiloscópica |
| BACENJUD | Representação judicial | Contas bancárias, bloqueios |
| RENAJUD | Representação judicial | Veículos, bloqueios de transferência |
| DETRAN | Delegacias (via ofício) | Veículos, CNH, infrações |
| Receita Federal | Delegacias (via ofício) | Dados cadastrais, IRPF, CNPJ |
| COAF/UIF | Delegacias (via ofício) | RIF, comunicações de atividades suspeitas |
| ANATEL | Delegacias (via ofício) | Titular de número telefônico |
| TSE | Acesso público | Dados de candidatos e financiadores |
| CNJ | Acesso público | Processos judiciais em todo Brasil |
