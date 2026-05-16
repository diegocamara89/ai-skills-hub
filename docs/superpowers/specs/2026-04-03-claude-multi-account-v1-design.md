# Claude Multi-Account V1 Design

Date: 2026-04-03
Status: Draft for review

## Tese

O produto precisa resolver dois problemas diferentes:

1. operar varias contas do Claude Code no mesmo Windows sem troca manual de autenticacao
2. usar Claude como planejador e Codex como executor, com failover automatico de conta quando houver exaustao de quota ou falha relevante

O plugin oficial `openai/codex-plugin-cc` e util na camada de execucao do Codex, mas nao cobre o plano de autenticacao, a rotacao de contas do Claude nem a orquestracao completa.

## Objetivo da V1

Entregar uma base funcional e controlada para:

- autenticar varios perfis Claude em diretorios isolados
- selecionar automaticamente o proximo perfil disponivel
- trocar de conta de forma reativa quando a conta ativa falhar por quota, rate limit relevante ou erro de autenticacao
- reidratar o contexto canonico da tarefa apos a troca
- executar Codex via adaptador unico, preferindo plugin oficial e caindo para CLI quando necessario

## Fora de escopo da V1

- pool de sessoes Claude pre-aquecidas
- rotacao proativa por previsao de quota
- paralelismo amplo entre varias contas Claude
- broker remoto ou multi-host
- isolamento garantido por usuario Windows separado
- auditoria corporativa completa

## Principios

- `CLAUDE_CONFIG_DIR` e a base validada agora para separar perfis; isso nao deve ser tratado como isolamento forte por si so.
- o contexto canonico da tarefa vive fora da sessao Claude.
- o broker nao pode tratar toda falha como "troque de conta".
- plugin oficial e CLI fallback sao backends diferentes do mesmo adaptador, nao equivalentes transparentes.
- a troca automatica precisa preservar rastreabilidade: qual conta planejou, qual executou, qual validou.

## Componentes da V1

### 1. Auth Control Plane

Responsabilidades:

- iniciar `auth login` no perfil correto
- mostrar estado por perfil
- permitir adicionar perfil e acionar relogin

Entradas:

- pedido humano no painel

Saidas:

- comando de login por perfil
- estado visual de autenticacao

### 2. Account State Store

Responsabilidades:

- persistir estado por perfil
- guardar metadados operacionais de selecao
- manter leases e locks minimos para evitar disputa entre tarefas

Regras de seguranca da V1:

- o store nao guarda tokens nem credenciais brutas
- credenciais continuam no diretorio do perfil autenticado pelo proprio Claude
- o store deve ser persistido com ACL restritiva ao usuario atual
- qualquer segredo adicional local deve usar protecao nativa do Windows, preferencialmente DPAPI
- `config_dir` e metadado operacional; nao deve ser tratado como segredo, mas o conteudo do diretorio sim

Campos minimos por perfil:

- `profile_id`
- `config_dir`
- `logged_in`
- `state`
- `lease_owner`
- `lease_expires_at`
- `cooldown_until`
- `last_success_at`
- `last_failure_at`
- `last_failure_kind`
- `last_known_model`
- `quota_note`

Regra de precedencia:

- `state` e a fonte de verdade
- `logged_in` e um campo derivado de conveniencia
- se `state = auth_required`, entao `logged_in` deve ser tratado como `false` para decisao operacional

### 3. Session Broker

Responsabilidades:

- escolher perfil ativo
- classificar falhas
- trocar de conta quando a politica mandar
- acionar reidratacao

Regras da V1:

- usar um perfil ativo por tarefa
- fazer failover reativo
- nao assumir sessoes pre-aquecidas

### 4. Task Context Store

Responsabilidades:

- manter o estado canonico da tarefa fora da sessao Claude
- reduzir replay integral de historico

Campos minimos:

- `task_id`
- `task_brief`
- `current_goal`
- `constraints`
- `relevant_files`
- `last_plan_summary`
- `last_executor_handoff`
- `validation_needed`
- `token_budget_hint`

Definicao de `token_budget_hint`:

- unidade: tokens aproximados
- origem: calculado pelo broker a partir da configuracao da tarefa
- valor padrao da V1: `4000`
- uso: limitar a reidratacao total, nao o prompt completo da tarefa

Estrutura minima de `relevant_files`:

- lista de objetos
- cada objeto contem:
  - `path`
  - `reason`
  - `content_mode`

Valores validos de `content_mode`:

- `path_only`
- `diff_only`
- `summary_only`

Regras:

- a V1 nao reidrata arquivo inteiro por padrao
- o modo padrao e `path_only`
- `diff_only` so deve ser usado para arquivos alterados e pequenos
- `summary_only` deve conter no maximo 300 caracteres por item

### 5. Policy Engine

Responsabilidades:

- decidir quando executar
- decidir quando validar
- decidir quando trocar de conta

Contrato da V1:

Entrada:

- `task_context`
- `account_snapshot`
- `last_failure_kind`
- `switch_count`
- `executor_backend_status`

Saida:

- `should_execute`
- `should_validate`
- `should_switch_account`
- `next_account_strategy`
- `selected_executor_backend`
- `rehydration_mode`
- `blocking_reason`

Regras minimas:

- se `last_failure_kind = quota_exhausted`, trocar de conta
- se `last_failure_kind = rate_limited_transient`, trocar de conta apenas se existir outra `available`; caso contrario aguardar cooldown
- se `last_failure_kind = auth_required`, bloquear a conta e exigir relogin; nao tratar como quota
- se `last_failure_kind = backend_unavailable`, manter a conta atual em `cooling` e trocar de conta apenas se existir outra `available`; caso contrario retornar `blocking_reason = backend_temporarily_unavailable`
- se `last_failure_kind = plugin_backend_failure`, tentar CLI fallback sem trocar conta Claude
- se `last_failure_kind = cli_backend_failure` e o plugin ja falhou para a mesma tarefa, bloquear a execucao do adaptador; nao trocar conta automaticamente
- se `last_failure_kind = local_host_failure`, marcar o perfil como `unhealthy` e retornar `blocking_reason = local_host_failure`; nao propagar troca automatica em cadeia sem confirmacao adicional
- se `switch_count >= 3`, interromper a cascata e retornar estado bloqueado
- `should_validate` e `true` quando houver arquivos alterados, risco alto ou pedido explicito

### 6. Codex Adapter

Responsabilidades:

- expor um contrato unico de execucao para o orquestrador
- decidir backend: plugin oficial ou CLI fallback

Contrato minimo:

- `execute(task_context, cwd, mode) -> handoff`
- `mode` aceita: `implement`, `review`, `rescue`
- `handoff.status`
- `handoff.changed_files`
- `handoff.tests_run`
- `handoff.risks`
- `handoff.analyst_summary`
- `handoff.next_action`
- `handoff.backend_used`
- `handoff.failure_kind`
- `handoff.account_switch_recommended`

## Fronteiras de confianca

### Confiar menos no host Windows

Assumir risco em:

- caches compartilhados
- arquivos temporarios
- logs
- variaveis herdadas
- locks de arquivo
- AV/politicas locais

Conclusao:

- diretorio isolado por perfil e necessario
- diretorio isolado por perfil nao e prova suficiente de isolamento forte

### Confiar menos no erro textual

Nao inferir exaustao de quota apenas por texto generico.

Sempre que possivel, classificar:

- erro estruturado
- codigo de saida
- padrao conhecido do CLI
- backend usado
- contexto da chamada

## Maquina de estados da conta

Estados da V1:

- `available`
- `active`
- `exhausted`
- `cooling`
- `auth_required`
- `unhealthy`

Transicoes:

1. `available -> active`
   Quando o broker seleciona o perfil para uma tarefa.

2. `active -> available`
   Quando a chamada termina com sucesso e a conta continua saudavel.

2a. `active -> available`
    Quando o lease expira, o watchdog verifica que nao ha processo vivo associado e libera a conta com alerta operacional.

3. `active -> exhausted`
   Quando houver evidencia suficiente de quota esgotada.

4. `active -> cooling`
   Quando houver rate limit transitorio ou degradacao temporaria.

5. `active -> auth_required`
   Quando a sessao estiver expirada, nao autenticada ou exigir novo login.

6. `active -> unhealthy`
   Quando houver falha local persistente do perfil ou erro repetido nao classificado como quota.

7. `exhausted -> cooling`
   Quando houver horario de revisitacao definido.

8. `exhausted -> available`
   Quando houver confirmacao explicita de renovacao de quota ou expiracao do prazo estimado de revisitacao.

9. `cooling -> available`
   Quando o cooldown expirar e o health check minimo passar.

10. `auth_required -> available`
   Apos relogin confirmado no perfil correto.

11. `unhealthy -> available`
    Apos recuperacao manual ou health check confirmando volta.

Watchdog da V1:

- toda conta em `active` recebe `lease_owner` e `lease_expires_at`
- o lease deve ser renovado enquanto a tarefa estiver viva
- se o lease expirar sem heartbeat, a conta nao pode ficar presa em `active`

## Taxonomia de falhas da V1

### `quota_exhausted`

Exemplos:

- janela de quota esgotada
- limite semanal ou 5h esgotado

Acao:

- marcar `exhausted`
- registrar horario e causa
- preencher `cooldown_until` ou `quota_note` com prazo estimado quando houver
- trocar para proxima conta `available`

### `rate_limited_transient`

Exemplos:

- 429 temporario
- sobrecarga momentanea

Acao:

- marcar `cooling`
- aplicar backoff curto
- tentar outra conta se houver

### `auth_required`

Exemplos:

- `Not logged in`
- sessao expirada
- fluxo pedindo `/login`

Acao:

- marcar `auth_required`
- nao insistir no failover cego como se fosse quota
- pedir relogin no painel

### `backend_unavailable`

Exemplos:

- indisponibilidade remota
- timeout do provedor

Acao:

- tratar como `cooling` ou `unhealthy` conforme recorrencia
- nao confundir com quota

### `plugin_backend_failure`

Exemplos:

- plugin do Codex indisponivel
- comando `/codex:*` falhando

Acao:

- degradar para backend CLI se permitido
- registrar backend usado no handoff
- retornar falha do adaptador com `account_switch_recommended = false`

### `cli_backend_failure`

Exemplos:

- `codex exec` falhando localmente
- binario ausente

Acao:

- registrar incapacidade do adaptador
- nao tratar como falha de conta Claude automaticamente
- retornar falha do adaptador com `account_switch_recommended = false`

### `local_host_failure`

Exemplos:

- lock de arquivo
- politica local
- AV interferindo

Acao:

- marcar perfil ou host como `unhealthy`
- interromper trocas cegas em cadeia

## Politica de selecao de conta

Ordem de tentativa da V1:

1. perfil ativo anterior, se estiver `available`
2. proximo perfil `available` por round-robin
3. nenhum perfil disponivel -> retornar estado bloqueado

Regras:

- nunca usar perfil em `auth_required`
- nunca usar perfil em `cooling` antes do prazo
- limitar tentativas em cascata por tarefa a `3`
- usar lease antes de promover `available -> active`
- se duas tarefas concorrerem pela mesma conta, a primeira que gravar lease valido vence

## Contrato de reidratacao

A troca de conta nao deve replayar o transcript integral.

Payload alvo:

- `task_summary`
- `current_goal`
- `constraints`
- `relevant_files`
- `last_plan_summary`
- `executor_or_validator_checkpoint`
- `pending_decision`

Regras:

- resumir antes de trocar
- registrar tamanho do resumo
- rejeitar reidratacao que exceda o orcamento definido

Se a reidratacao exceder o orcamento:

- primeiro tentar modo reduzido, removendo `relevant_files` nao essenciais
- se ainda exceder, interromper a troca automatica e retornar `blocking_reason = rehydration_budget_exceeded`
- nao executar a tarefa com contexto truncado silenciosamente

## Plugin oficial vs CLI fallback

### Plugin oficial

Uso:

- backend preferencial quando o ambiente Claude suportar bem a integracao

Vantagens:

- UX melhor dentro do Claude
- comandos nativos `/codex:*`

Riscos:

- contrato operacional diferente do CLI
- falhas especificas do plugin

### CLI fallback

Uso:

- backend secundario

Vantagens:

- independencia do plugin
- previsibilidade maior em automacao local

Riscos:

- menor integracao com UX do Claude
- possivel divergencia de capacidade

Conclusao:

- o adaptador deve expor `backend_used`
- o broker deve saber qual backend falhou
- plugin oficial e CLI fallback sao backends distintos e devem ser testados separadamente

## Observabilidade minima da V1

Registrar por tarefa:

- `task_id`
- `planner_profile`
- `executor_backend`
- `validator_profile`
- `account_switch_count`
- `failure_kinds_seen`
- `rehydration_count`
- `rehydration_token_estimate`

`analyst_summary` no handoff:

- deve ser produzido sem chamada adicional de modelo sempre que possivel
- na V1, priorizar resumo derivado do proprio resultado do executor
- nao exigir round-trip extra ao Claude apenas para preencher esse campo

## Health check minimo da V1

Objetivo:

- verificar se a conta pode voltar para `available` sem gastar tokens desnecessariamente

Regras:

- nao usar prompt real ao Claude como health check padrao
- validar primeiro sinais locais:
  - existencia do diretorio do perfil
  - presenca dos arquivos minimos esperados
  - ausencia de estado `auth_required`
  - expiracao do cooldown
- so promover para `available` apos esses checks locais
- qualquer verificacao que consuma tokens deve ser opcional e explicita

## Decisoes abertas para a proxima etapa

- como medir quota com mais precisao sem depender apenas de heuristica textual
- quais artefatos locais realmente permanecem compartilhados entre perfis
- quais diferencas concretas entre plugin e CLI precisam entrar no contrato do adaptador

## Recomendacao

A implementacao deve comecar pelo nucleo brokered stateful:

1. perfis autenticados corretamente no diretorio isolado
2. store de estado por conta
3. taxonomia de falhas
4. failover reativo
5. contexto reidratavel compacto

Sem esse nucleo, o painel e a integracao com o Codex so escondem a fragilidade operacional em vez de resolve-la.
