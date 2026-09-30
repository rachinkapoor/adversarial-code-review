# adversarial-code-review

A Claude Code skill for deep code review: parallel finder agents across up to 8
angles (sized to the diff), then one adversarial verifier per candidate, then a
short ranked report (max 10 findings). Optionally posts findings as PR comments
with GitHub suggested changes.

## Install

```bash
git clone git@github.com:rachinkapoor/adversarial-code-review.git ~/.claude/skills/adversarial-code-review
```

Then in any session: `/adversarial-code-review <PR link | branch | nothing for working tree>`
— or just ask for a review; the skill triggers on review requests.

## Layout

```
SKILL.md                       — the pipeline (scope → find → verify → report → comment → fix → cleanup)
references/finder-prompts.md   — the 8 finder angle templates, plus substitutions for config-only diffs
references/verifier-prompt.md  — the verifier template + verdict rules
references/posting-comments.md — PR comment mechanics + suggestion blocks
scripts/                       — scope, add-repo, ledger, anchor, post-review, cleanup (contract in scripts/README.md)
tests/run.sh                   — test suite for the scripts, throwaway git fixtures, fake gh
```

Dependencies for the scripts: bash, git, jq, and gh for PR targets and posting.

## Design

- Finders are recall-biased: they surface every candidate with a nameable
  failure scenario.
- Verifiers are evidence-biased: CONFIRMED / PLAUSIBLE / REFUTED, where refuting
  requires proof (quote the line, run the probe, cite the guard). A real
  mechanism whose failure needs production state that does not exist yet is
  tagged latent and reported separately, never as a top finding.
- Nothing reaches the report without a verifier pass or a quoted self-check.
- Review phases are read-only; fixes (Phase 5) are made only when asked, on the PR branch. External systems (vendor APIs, cloud CLIs,
  production databases) are probed only with the user's go for that review.
- The report leads with the answer to the question the user actually asked,
  says what was ruled out and what could not be checked, and gives no
  merge/hold/sequencing advice.
- A candidate ledger in the scratch directory carries verdicts across long
  sessions, so the report is written from evidence, not memory.
