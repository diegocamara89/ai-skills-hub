---
name: persona-bridge
description: Curated AIOX bridge for low-context Codex subagents. Use this skill whenever the user asks to use AIOX or Xquads-style personas, wants you to choose which AIOX roles should inform spawned subagents, or wants orchestration with small context instead of loading the full upstream framework. Prefer this skill when the task mentions "use those agents", "AIOX", "Xquads", "subagentes com persona", or "spawn com papel".
---

# Persona Bridge

Use this skill as a router for a curated AIOX subset, not as a large prompt pack.

The job here is simple:

- decide whether the task really needs multiagent help
- read only a tiny selector first
- load full cards only for the personas you actually choose
- consult upstream only if the chosen card is still not enough

## Default loading order

1. Read `references/persona-selector.yaml` only.
2. If the choice is still unclear, read `references/selection-rubric.md`.
3. Load only the selected files from `references/role-cards/`.
4. Read project override or upstream material only on demand.

Do not skip straight to all cards or to the upstream repository.

## Hard rules

- Default to `single`, not `team`.
- Default to 1-3 personas. More than 3 needs a real justification.
- Treat the bundled set as a curated subset of AIOX upstream roles, not a full mirror.
- Do not import upstream memory, handoff, session continuity, or workflow state.
- Do not dump full role cards into spawned subagents when a short briefing will do.
- If the task does not need multiagent help, stop after classification and answer inline.

## Classification

Classify the task before loading cards:

- `single`: one specialist is enough
- `paired`: a second perspective materially improves quality
- `team`: planning, execution, and verification are all distinct enough to justify 3 personas

## Briefing contract

When briefing a native subagent from a selected role card, keep the prompt short and structured:

- `role`
- `objective`
- `focus`
- `constraints`
- `deliverables`

The `Recommended spawn` field in a role card indicates the suggested native subagent type:

- `explorer`: read-only discovery, review, or analysis work
- `worker`: implementation or edit-capable execution work

## Upstream policy

Use this priority order:

1. Bundled selector and role cards in this skill
2. Project-local override at `<project>/.persona-bridge.yaml`
3. Explicit upstream source for the chosen persona only

Read upstream material only when:

- the chosen role card is insufficiently specific
- the user explicitly asks for the original upstream persona
- the task depends on a framework-specific workflow rather than just a role

If you read upstream, compress it back down before briefing any subagent.

## Files

- `references/persona-selector.yaml`
  - minimal selector used for the first pass
- `references/selection-rubric.md`
  - quick team-shape guide when selector alone is not enough
- `references/role-cards/`
  - detailed cards loaded only for selected personas
- `references/source-registry.example.yaml`
  - project-local upstream override template
