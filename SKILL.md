---
name: adversarial-code-review
description: Deep code review for a PR, branch, or diff. Fans out parallel "finder" agents across 8 angles (line-by-line bugs, removed behavior, cross-service impact, reuse, simplification, efficiency, altitude, conventions), then adversarially verifies every candidate with real evidence (running code, probing endpoints read-only, checking infra/deployment repos) before reporting at most 10 ranked findings. Use this whenever the user asks to review a PR, diff, branch, or code change, pastes a GitHub PR link, asks "any bugs?", "is this safe to ship/merge/deploy?", "anything blocking the push?", or wants review findings posted as PR comments — even if they never say the word "review".
---

# Adversarial Code Review

The core idea, in one line:
**many cheap guesses first, then hard evidence for every guess, then a short honest report.**

Finder agents are allowed to be wrong — they hunt for *candidates* and err on the side
of surfacing. Verifier agents are not allowed to guess — every candidate is either
proven, kept as plausible, or killed with evidence. The user only ever sees what
survived. This split matters: a single agent doing both jobs either misses bugs
(too cautious) or reports noise (too eager).

## Phase 0 — Scope (do this yourself, no agents)

1. Resolve the target:
   - PR link or number → `gh pr view <N> --json title,baseRefName,headRefName,body,state`.
   - Branch → diff it against its base.
   - Nothing given → `git diff @{upstream}...HEAD`, plus `git diff HEAD` if there are
     uncommitted changes.
2. `git fetch origin` first. Never review a stale local clone.
3. Save the full diff to a scratch file. Read it yourself, top to bottom, before
   launching anything. You need your own picture of the change to judge agent output later.
4. Create a worktree of the head commit so agents can read whole files, not just hunks:
   `git worktree add <scratch>/review-wt origin/<head-branch>`
5. Note the blast radius while reading:
   - Which other repos/services consume this code? (grep the workspace for the
     changed symbols / endpoint names)
   - Is there an infra/deployment repo that must change for this code to work in
     production? (env vars, values files, migrations)
   Write these paths down — finders and verifiers will need them.
6. Read the PR description. If it makes claims ("tests pass", "no conflicts",
   "byte-identical"), treat them as candidates to verify, not facts.

## Phase 1 — Finders (8 parallel agents)

Launch 8 agents **in one message** so they run concurrently, in the background.
Use a strong model for every agent. Each agent gets: the diff file path, the
worktree path, the repo paths from Phase 0, and ONE angle from
[references/finder-prompts.md](references/finder-prompts.md). Read that file and
copy the templates — do not improvise the prompts.

The 8 angles:

| # | Angle | Hunts for |
|---|-------|-----------|
| 1 | Line-by-line | A wrong line: inverted condition, off-by-one, null deref, missing await, falsy-zero, swallowed error |
| 2 | Removed behavior | A deleted line whose guarantee is not re-established anywhere |
| 3 | Cross-file / cross-service | A caller, consumer, or wire contract the change breaks |
| 4 | Reuse | New code that re-implements an existing helper |
| 5 | Simplification | Redundant state, dead guards, copy-paste, derivable values |
| 6 | Efficiency | Serial work that could be parallel, defeated indexes, hot-path waste |
| 7 | Altitude | A fix at the wrong depth: special case where the mechanism should change |
| 8 | Conventions | Clear violations of a governing CLAUDE.md rule (quote the rule) |

Every finder returns up to 6 candidates, each with exactly these fields:
`file`, `line`, `summary` (one sentence), `failure_scenario` (concrete input/state
→ concrete wrong outcome). A candidate with no nameable failure scenario is not
a candidate.

Tell every finder: **pass through every candidate you can name a failure for.
Do not silently drop half-believed candidates.** Finders that self-censor bypass
the verify step and are the main cause of missed bugs.

## Phase 2 — Dedup, then verify (one agent per candidate)

1. Dedup: same defect + same location + same reason → keep one. Overlapping
   candidates from different angles usually mean the finding is real — merge
   them, keep the strongest failure scenario.
2. Self-verify only trivial candidates where the diff text alone is proof
   (e.g. a comment citing a file you already proved absent). Everything else
   gets its own verifier agent.
3. Launch one verifier per candidate, parallel, background, strong model, using
   the template in [references/verifier-prompt.md](references/verifier-prompt.md).
   Each returns exactly one verdict:
   - **CONFIRMED** — reproduced or proven from evidence.
   - **PLAUSIBLE** — realistic and not disprovable. This is the default.
   - **REFUTED** — killed with constructible proof only: quote the actual line,
     show the type/constant/invariant, cite the guard in this same diff, or run
     the probe that disproves it. "Seems unlikely" is not a refutation.
4. Verifiers must chase **real evidence**, not read code and speculate:
   - Run the suspect code with the suspect input (`node -e`, a throwaway script).
   - Read the installed dependency source in `node_modules`, not its docs.
   - Check the deployment/infra repos: does production actually have the env
     vars, secrets, and config this code needs? A PR that cannot work in prod
     is a finding even when every line of code is correct.
   - Probe endpoints and databases **read-only** when reachable. Never mutate.
   - Trace the real consumer's code for wire-contract claims. Never assert
     behavior from a flag or field name — grep the code that consumes it.
5. If a verifier cannot settle the load-bearing question, it must say so and
   name the one query/check that would settle it. Report that honestly —
   do not round "unverified" up to confirmed or down to refuted.

## Phase 3 — Report

1. Keep CONFIRMED and PLAUSIBLE. Drop REFUTED.
2. Rank by severity, at most 10. Correctness beats cleanup when the cap forces a cut.
3. **Lead with the answer to the question the user actually asked.** "Any
   blockers?" gets a yes/no with the blocker named in the first sentence —
   before the findings list.
4. Write in simple language. Short sentences. One finding = what breaks, when,
   and the fix direction.
5. Say what was ruled out, in one or two lines. "No money-wrong bug survived —
   X, Y, Z were refuted with evidence" is information the user needs; a bare
   findings list hides how hard the diff was pushed.
6. Distinguish "safe but pointless" from "dangerous": a change that fails loudly
   without paying/breaking anything is a different verdict than one that
   silently corrupts.
7. Do not volunteer merge/hold advice unless asked. The review ends at the findings.

## Phase 4 — PR comments (only when asked)

If the user asks to post the findings on the PR, read
[references/posting-comments.md](references/posting-comments.md) first. Key rules:
comments in very simple language, bullet points, one idea per line; use GitHub
`suggestion` blocks for every fix that fits the diff, anchored to the exact lines
the fix replaces; findings whose fix lives outside the diff (infra repo, another
file) go as prose comments or in the review body.

## Rules that make this work

- **Recall first, precision second, honesty last-and-most.** Finders over-report,
  verifiers cut, and the final report never claims more certainty than the
  evidence bought.
- **The PR's purpose is in scope.** If the change exists to make something work
  in production, verify production can actually run it (config, env, migrations,
  the consumer being deployed). "The code is correct" is not the same claim as
  "the PR achieves its goal".
- **Evidence beats reading.** A 5-minute live probe (run the snippet, hit the
  endpoint read-only, query the DDL) settles what an hour of code-reading
  leaves plausible. Prefer the probe.
- **Never let an agent's "needs verification" reach the user as fact.** Blocked
  claims stay blocked until verified.
