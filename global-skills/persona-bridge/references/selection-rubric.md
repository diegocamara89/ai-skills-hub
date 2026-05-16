# Selection Rubric

Use this file after reading `persona-selector.yaml` when you need a fast mapping from task shape to a minimal team.

## Default rule

- Prefer `single`
- Escalate to `paired` only when a second perspective clearly improves quality
- Escalate to `team` only when planning, execution, and verification are all materially distinct

## Quick mappings

### Study a repository

- `single`: `aiox-analyst`
- `paired`: `aiox-analyst` + `aiox-architect`

### Large refactor or architecture decision

- `paired`: `aiox-architect` + `aiox-dev`
- `team`: add `aiox-qa` if regression risk matters

### Build or patch a feature

- `single`: `aiox-dev`
- `paired`: `aiox-dev` + `aiox-qa`
- add `aiox-architect` only if the change crosses boundaries or changes interfaces

### CI, deploy, or environment problem

- `single`: `aiox-devops`
- `paired`: `aiox-devops` + `aiox-dev`
- add `aiox-qa` if you need a release-risk pass

### Product planning or execution plan

- `single`: `aiox-pm`
- `paired`: `aiox-pm` + `aiox-po`
- add `aiox-analyst` if discovery is still incomplete

### Requirement or story quality

- `single`: `aiox-po`
- `paired`: `aiox-po` + `aiox-pm`

### Orchestration of a broader workflow

- `single`: `aiox-master` if the main task is decomposition
- `team`: `aiox-master` + the smallest set of specialists needed

Routine task breakdown does not justify `aiox-master`. Simple decomposition inside a normal bugfix, feature, or review should stay with the primary specialist.

### Context contamination or memory hygiene

- `paired`: `aiox-architect` + `aiox-qa`

## Hard limits

- Do not select `aiox-master` just to make a simple answer sound fancy
- Do not select both `aiox-pm` and `aiox-po` for pure coding work
- Do not select `aiox-devops` unless there is a real operational angle
- Do not select more than three personas unless the user explicitly asked for a larger team

## Decision language

When you explain the choice to the user, keep it short:

- "Vou usar `aiox-dev` para execução e `aiox-qa` para verificação."
- "Vou usar `aiox-architect` para tradeoffs e `aiox-dev` para viabilidade prática."
- "Aqui basta uma persona: `aiox-analyst`."
