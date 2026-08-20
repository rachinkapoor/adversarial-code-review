# adversarial-code-review

A Claude Code skill for deep code review: parallel finder agents across 8
angles, then one adversarial verifier per candidate, then a short ranked report
(max 10 findings). Optionally posts findings as PR comments with GitHub
suggested changes.

## Install

```bash
git clone git@github.com:rachinkapoor/adversarial-code-review.git ~/.claude/skills/adversarial-code-review
```

Then in any session: `/adversarial-code-review <PR link | branch | nothing for working tree>`
— or just ask for a review; the skill triggers on review requests.

## Layout

```
SKILL.md                       — the pipeline (scope → find → verify → report → comment)
references/finder-prompts.md   — the 8 finder agent prompt templates
references/verifier-prompt.md  — the verifier template + verdict rules
references/posting-comments.md — PR comment mechanics + suggestion blocks
```

## Design

- Finders are recall-biased: they surface every candidate with a nameable
  failure scenario.
- Verifiers are evidence-biased: CONFIRMED / PLAUSIBLE / REFUTED, where refuting
  requires proof (quote the line, run the probe, cite the guard).
- The report leads with the answer to the question the user actually asked,
  and says what was ruled out — not just what was found.
