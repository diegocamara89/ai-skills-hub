---
name: analise-bancaria
description: >
  Esta skill deve ser usada quando o usuário enviar extratos bancários,
  planilhas de movimentação financeira, dados de PIX/TED/DOC, relatórios
  do BACEN, ou solicitar "analisar extrato", "verificar movimentação bancária",
  "incompatibilidade patrimonial", "análise financeira forense", "rastrear
  dinheiro", "identificar fracionamento", "quem recebeu o dinheiro",
  ou quando o comando /analise-bancaria for invocado. Contém metodologia
  completa para análise forense de dados bancários com identificação de
  padrões suspeitos, cálculo de incompatibilidade patrimonial e produção
  de laudo de análise financeira.
---

# Análise Bancária Forense — Conhecimento Especializado

Skill de referência para análise de dados bancários em contexto de investigações policiais.

## Princípio Fundamental

Dados bancários são a "memória financeira" do investigado. Eles não mentem — registram com precisão milissegundos onde cada real entrou e saiu. A análise forense destes dados transforma números em narrativa probatória.

## Estrutura do Sistema Bancário Brasileiro

### Tipos de Operações e seus Registros

| Operação | Registro | Dados disponíveis | Limiar de comunicação COAF |
|----------|---------|------------------|--------------------------|
| **Depósito em espécie** | Banco (extrato) | Data, valor, agência, operador | R$ 50.000,00 |
| **Saque em espécie** | Banco (extrato) | Data, valor, agência | R$ 50.000,00 |
| **PIX** | BCB (SPB) | Data/hora, valor, CPF/CNPJ remetente/destinatário, banco, chave PIX | R$ 50.000,00 |
| **TED** | COMPE/STR | Data, valor, dados das contas de origem/destino | R$ 50.000,00 |
| **DOC** | COMPE | Data, valor, dados das contas | R$ 50.000,00 |
| **Boleto** | FEBRABAN | Data, valor, beneficiário | Varia por segmento |
| **Cartão crédito** | Bandeira + banco | Data, valor, estabelecimento, categoria | Varia |
| **Investimentos** | Banco/Corretora | Aportes e resgates | Varia |
| **Câmbio** | PTAX (BCB) | Data, valor, moeda, contraparte | U$ 10.000 |

### Tipos de Dados por Fonte

**Extrato bancário convencional (conta corrente/poupança):**
- Lançamentos com data e descrição
- Pode ou não conter CPF/CNPJ da contraparte (depende do banco e formato)
- Saldo progressivo

**Relatório de PIX (exportação BCB/BACENJUD):**
- Contém SEMPRE CPF/CNPJ do remetente e destinatário
- Data e hora exatas (UTC ou horário de Brasília)
- Chave PIX utilizada
- Banco de origem e destino
- Tipo de transação (DICT, QR code, etc.)

**Dados de quebra de sigilo bancário (BACENJUD):**
- Dados completos de todas as contas e movimentações
- Pode incluir dados de múltiplos bancos
- Geralmente mais completo que o extrato voluntariamente fornecido

## Padrões Suspeitos — Referência Técnica

### 1. Fracionamento (Structuring / Smurfing)

**Definição**: Divisão de grandes valores em múltiplas operações menores para evitar comunicação obrigatória ao COAF.

**Como identificar:**
- Múltiplas operações em espécie abaixo de R$ 50.000,00 em curto período
- Valores recorrentes de R$ 49.XXX ou R$ 48.XXX (ligeiramente abaixo do limiar)
- Mesma agência, mesmos tipos de operação
- Somas que, consolidadas, configurariam comunicação obrigatória

**Fundamento**: Art. 11, §2º, Lei 9.613/98; Carta Circular BACEN 4.001/2020, inciso I

**Cálculo de fracionamento:**
- Somar operações no período suspeito
- Comparar com limiar de comunicação
- Calcular número mínimo de transações que configurariam comunicação se unificadas

### 2. Transferências Circulares (Layering)

**Definição**: Recursos percorrem múltiplas contas antes de retornar ao ponto de origem ou ao beneficiário final, obscurecendo a origem.

**Como identificar:**
- Débito da conta A → crédito na conta B no mesmo dia
- Débito da conta B → crédito na conta C próximo dia
- Conta C tem relação com conta A ou com o investigado
- Valores sem lógica econômica (sem prestação de serviço que justifique)

**Ferramenta de rastreamento**: Construir grafo de transferências com setas direcionais e datas.

### 3. Conta de Passagem (Relay Account)

**Definição**: Conta que recebe e retransfer os valores em prazo muito curto, funcionando apenas como "retransmissor".

**Como identificar:**
- Calcular o tempo médio de retenção de recursos
- Contas de passagem têm saldo médio próximo de zero
- Créditos são seguidos de débitos no mesmo valor (±10%) em até 48 horas
- Titular geralmente não tem atividade econômica que justifique o volume

**Cálculo de tempo de retenção:**
```python
# Para cada par crédito-débito:
tempo_retencao = data_debito - data_credito
# Conta de passagem: tempo_retencao < 48 horas para grande parte das operações
```

### 4. Incompatibilidade Patrimonial

**Definição**: Movimentação financeira incompatível com a renda declarada ou presumida do investigado.

**Como calcular:**
1. Obter renda declarada anual (IRPF) ou estimada (RAIS/CAGED/ocupação)
2. Somar créditos totais no período dos extratos
3. Calcular índice de incompatibilidade: `créditos / renda_proporcional_ao_período`
4. Índice > 3x → altamente atípico (documentar como indício)

**Fontes de renda declarada:**
- IRPF (Receita Federal — via representação judicial)
- RAIS (MTE — retrato da renda do emprego formal)
- CAGED (variações de emprego formal)
- Declaração em oitiva (com cautela)

**Importante**: A incompatibilidade patrimonial não é um crime em si — é um **indício** que fundamenta a investigação por enriquecimento ilícito (art. 9º, Lei 8.429/92) ou lavagem de dinheiro (Lei 9.613/98).

### 5. Operações com PEPs (Pessoas Expostas Politicamente)

**Definição**: Agentes públicos e seus familiares próximos com mandato ou cargo relevante nos últimos 5 anos.

**Por que importa**: PEPs têm dever reforçado de transparência patrimonial e são alvo preferencial de corrupção. Operações atípicas envolvendo PEPs têm presunção de suspeita reforçada.

**Bases para identificação de PEPs:**
- Lista do COAF/BACEN
- Diário Oficial (nomeações e exonerações)
- TSE (candidatos eleitos)

### 6. Operações em Paraísos Fiscais e Evasão de Divisas

**Indicadores:**
- Transferências internacionais acima de U$ 10.000 sem justificativa econômica
- Contas em jurisdições com sigilo bancário reforçado
- Valores incompatíveis com atividade declarada
- Uso de câmbio físico ou turismo de fronteira

**Fundamentos**: Art. 22, Lei 7.492/86 (evasão de divisas); Lei 9.613/98 (lavagem)

## Análise de Compatibilidade Patrimonial — Metodologia Completa

### Passo 1: Identificar a renda declarada ou presumida

- IRPF declarado
- Salário registrado (RAIS/CAGED)
- Declaração de bens em posse pública (se servidor/candidato)
- Renda presumida pela atividade econômica declarada

### Passo 2: Calcular a movimentação total no período

- Somar CRÉDITOS por tipo (evitar dupla contagem de estornos)
- Separar créditos de origem identificada vs. origem desconhecida
- Destacar operações em espécie

### Passo 3: Calcular o Índice de Incompatibilidade

```
Índice = Total de Créditos no Período / Renda Esperada no Período

Interpretação:
< 1x  → Compatível (movimentação abaixo da renda)
1-2x  → Normal (movimentação próxima à renda)
2-3x  → Atenção (pode haver explicação legítima — herança, venda de bem, etc.)
3-5x  → Atípico (exige explicação)
> 5x  → Altamente suspeito (forte indício de renda não declarada)
```

### Passo 4: Verificar se há explicação legítima

Créditos que podem justificar movimentação acima da renda:
- Herança documentada
- Venda de bem imóvel ou veículo
- Rescisão trabalhista
- Indenização judicial
- Empréstimo documentado

**Instrução**: Perguntar ao investigado sobre cada crédito relevante. A incapacidade de explicar a origem é relevante juridicamente (art. 9º, §3º, Lei 8.429/92 para servidores).

## Referência: Legislação Financeira Relevante

| Norma | Conteúdo |
|-------|---------|
| LC 105/2001 | Sigilo das operações de instituições financeiras |
| Lei 9.613/98 | Lavagem de dinheiro — crimes e obrigações |
| CC BACEN 4.001/2020 | 17 categorias de operações suspeitas |
| Res. CMN 4.753/2019 | Cadastro de clientes (KYC) |
| Res. BCB 1/2020 | Regulação do PIX |
| Lei 7.492/86 | Crimes contra o Sistema Financeiro Nacional |
| Art. 9º, Lei 8.429/92 | Enriquecimento ilícito de servidor público |

Para modelos de scripts de análise Python completos, ver: `references/scripts_analise.md`
Para interpretação das ocorrências do COAF (CC 4.001/2020), ver: `references/carta_circular_4001.md`
