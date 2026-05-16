---
name: skill-judge
description: Evaluate Agent Skill design quality against official specifications and best practices. Use when reviewing, auditing, or improving SKILL.md files and skill packages. Provides multi-dimensional scoring (8 dimensions, 120 points) and actionable improvement suggestions.
---

# Skill Judge

Evaluate Agent Skills against official specifications and patterns derived from 17+ official examples.

## Core Philosophy

A Skill is a **knowledge externalization mechanism** — a hot-swappable LoRA adapter that requires no training.

> **Good Skill = Expert-only Knowledge - What Claude Already Knows**

A Skill's value is measured by its **knowledge delta**.

### Three Types of Knowledge

| Type | Definition | Treatment |
|------|------------|-----------|
| **Expert** | Claude genuinely doesn't know this | Must keep |
| **Activation** | Claude knows but may not think of | Keep if brief |
| **Redundant** | Claude definitely knows this | Should delete |

## Evaluation Dimensions (120 points total)

### D1: Knowledge Delta (20 pts)
Does the Skill add genuine expert knowledge? Red flags: "What is X" sections, standard tutorials, generic best practices. Green flags: decision trees, expert trade-offs, edge cases, NEVER lists with non-obvious reasons.

### D2: Mindset + Procedures (15 pts)
Does it transfer thinking patterns AND domain-specific procedures? "Before doing X, ask yourself..." frameworks are high value. Generic procedures (open, read, save) are low value.

### D3: Anti-Pattern Quality (15 pts)
Does it have effective NEVER lists? Specific + reason = expert. Vague warnings = weak.

### D4: Specification Compliance (15 pts)
Valid frontmatter? Description answers WHAT, WHEN, and includes trigger KEYWORDS? Description is THE MOST IMPORTANT field - determines if skill ever gets activated.

### D5: Progressive Disclosure (15 pts)
SKILL.md < 500 lines? Heavy content in references/? Loading triggers embedded in workflow? "Do NOT Load" guidance?

### D6: Freedom Calibration (15 pts)
Creative tasks = high freedom. Fragile operations = low freedom. Match freedom to consequence of mistakes.

### D7: Pattern Recognition (10 pts)
Follows one of: Mindset (~50 lines), Navigation (~30), Philosophy (~150), Process (~200), Tool (~300)?

### D8: Practical Usability (15 pts)
Decision trees? Working code examples? Error handling? Edge cases? Immediately actionable?

## NEVER Do When Evaluating

- NEVER give high scores just because it looks professional
- NEVER ignore token waste
- NEVER let length impress you
- NEVER skip testing decision trees mentally
- NEVER forgive explaining basics with "helpful context"
- NEVER overlook missing anti-patterns
- NEVER undervalue the description field

## Evaluation Protocol

1. **First Pass**: Knowledge Delta Scan - mark each section [E]xpert, [A]ctivation, [R]edundant
2. **Structure Analysis**: frontmatter, line count, references, pattern identification
3. **Score Each Dimension**: with specific evidence
4. **Calculate Total**: Grade A (90%+), B (80-89%), C (70-79%), D (60-69%), F (<60%)
5. **Generate Report** with template below

## Report Template

```
# Skill Evaluation Report: [Name]
## Summary
- **Total Score**: X/120 (X%)
- **Grade**: [A/B/C/D/F]
- **Pattern**: [Mindset/Navigation/Philosophy/Process/Tool]
- **Knowledge Ratio**: E:A:R = X:Y:Z
- **Verdict**: [One sentence]

## Dimension Scores
| Dimension | Score | Max | Notes |
|-----------|-------|-----|-------|
| D1: Knowledge Delta | X | 20 | |
| D2: Mindset + Procedures | X | 15 | |
| D3: Anti-Pattern Quality | X | 15 | |
| D4: Specification Compliance | X | 15 | |
| D5: Progressive Disclosure | X | 15 | |
| D6: Freedom Calibration | X | 15 | |
| D7: Pattern Recognition | X | 10 | |
| D8: Practical Usability | X | 15 | |

## Critical Issues
## Top 3 Improvements
## Detailed Analysis
```

## Common Failure Patterns

1. **The Tutorial**: Explains basics Claude knows. Fix: focus on expert decisions.
2. **The Dump**: 800+ lines with everything. Fix: progressive disclosure.
3. **The Orphan References**: References never loaded. Fix: MANDATORY loading triggers.
4. **The Checkbox Procedure**: Mechanical steps. Fix: thinking frameworks.
5. **The Vague Warning**: "Be careful". Fix: specific NEVER list with reasons.
6. **The Invisible Skill**: Great content, bad description. Fix: WHAT + WHEN + KEYWORDS.
7. **The Wrong Location**: "When to use" in body not description. Fix: move to description.
8. **The Over-Engineered**: README, CHANGELOG, etc. Fix: only what Agent needs.

## The Meta-Question

> "Would an expert in this domain say: 'Yes, this captures knowledge that took me years to learn'?"
