---
name: adversarial-code-review
description: Deep code review for a PR, branch, or diff. Fans out parallel "finder" agents across up to 8 angles (line-by-line bugs, removed behavior, cross-service impact, reuse, simplification, efficiency, altitude, conventions), then adversarially verifies every candidate with real evidence (running code, probing endpoints read-only, checking infra/deployment repos) before reporting at most 10 ranked findings. Use this whenever the user asks to review a PR, diff, branch, or code change, pastes a GitHub PR link, asks "any bugs?", "is this safe to ship/merge/deploy?", "anything blocking the push?", or wants review findings posted as PR comments — even if they never say the word "review".
---

# Adversarial Code Review

The core idea, in one line:
**many cheap guesses first, then hard evidence for every guess, then a short honest report.**

Finder agents are allowed to be wrong — they hunt for *candidates* and err on the side
of surfacing. Verifier agents are not allowed to guess — every candidate is either
proven, kept as plausible, or killed with evidence. The user only ever sees what
survived. This split matters: a single agent doing both jobs either misses bugs
(too cautious) or reports noise (too eager).

**You orchestrate directly.** Never delegate the pipeline to a sub-orchestrator
agent — it stalls waiting on its own children's notifications. You launch the
finders, you dedup, you launch the verifiers, you write the report.

## Hard rules (read before anything else)

1. **No finding reaches the user without a verifier pass.** A finder's candidate
   is never a finding. If you skip Phase 2 for a candidate, it appears under
   "Not verified" or not at all — never in the ranked list, never with the word
   "confirmed". Past reviews that skipped this step shipped noise as their top
   three items.
2. **Worktrees, never local clones.** Every repo the review reads — target,
   consumers, infra — gets its own detached worktree in the scratch directory
   at the ref that matters (PR head for the target, deployed ref for the
   rest). Agents read and probe only in those worktrees. Local clones sit on
   random branches with local edits; nothing is read from them and nothing is
   done to them: no checkout, stash, install, or commit there. Worktrees are
   throwaway, so installing dependencies or running tests inside one is fine.
3. **External systems need the user's go, per review.** Read-only probes are
   free only against local checkouts, the review worktree, and dependency
   source. Anything else — a third-party or vendor API, a cloud CLI (aws,
   kubectl, gcloud), a production database, a live service — needs an explicit
   yes from the user in this review. Do not probe first and confess later.
4. **The aim is one repo.** Other repos may be read for tracing. A defect found
   in another repo is a one-line note, never an action item, never a fix.
5. **Report the question's answer first.** No merge, hold, ordering, or
   rollout-sequencing advice unless asked. The review ends at the findings.
6. **Settled facts are not questions.** Two kinds of fact settle most of what
   agents otherwise dig for: invariants of the system (which service creates
   a resource, who holds a key), which the repo's own code and docs prove;
   and the state of the target environment (what is deployed there, whether
   the touched feature is live there), which differs per environment and is
   established fresh for every review. Agents get both up front and never
   re-derive them. An agent that cannot settle a question inside its budget
   names the fact it needs and returns; you settle it from the repos or the
   user in one line. Nobody chases it.
7. **Time is a cost.** Every agent has a tool-call budget. Verifiers start as
   soon as their candidates exist, not when the slowest finder ends. A small
   diff gets a small review.

## Phase 0 — Scope (do this yourself, no agents)

The mechanical steps are scripts in `scripts/` (contract in
[scripts/README.md](scripts/README.md)). They share one state directory:
`export REVIEW_DIR=<scratch>/review-<repo>-<target>`. Use the scripts; do not
retype their git commands by hand — past reviews got exactly these steps wrong
(worktree by branch name, two-dot diffs, reading a clone's random branch).

1. `scripts/scope.sh [--repo <clone>] [--base <ref>] <PR number | PR URL | branch | --wip>`.
   It fetches, resolves head and base, writes the three-dot diff to
   `$REVIEW_DIR/diff.patch` and the facts to `meta.json`, and creates a
   detached worktree of the head at `$REVIEW_DIR/wt/<repo>`. For `--wip` it
   applies the uncommitted changes into the worktree and lists untracked
   files in `meta.untracked` — mention those in the report; they are not in
   the diff. It prints diff size and the fan-out to use.
2. Read `diff.patch` yourself, top to bottom, before launching anything. You need
   your own picture of the change to judge agent output later.
3. Read the deployed state, never a clone's checked-out branch: local clones sit
   on random feature branches with local edits and will hand you wrong file
   states and wrong deployed versions. For any related repo (consumer, infra,
   bridge) run `scripts/add-repo.sh <clone> [ref]`; it fetches and creates a
   detached worktree at the deployed ref (`origin/HEAD` by default, or the ref
   an image tag names). Read only inside `$REVIEW_DIR/wt/`.
4. Establish what production actually runs, while you still have the picture:
   - Deployed ref of this service, and whether the touched feature is live
     (flag on, route wired, data present) or only merged. If this cannot be
     settled from repos and docs, ask the user now, in one line. A finding
     whose failure needs production state that does not exist yet is "latent",
     not a defect of this PR (see Phase 3).
   - Which other repos/services consume this code? (grep the workspace for the
     changed symbols / endpoint names). Only repos the user's workspace
     actively uses count — an archived or stale clone is not a consumer.
   - Is there an infra/deployment repo that must change for this code to work in
     production? (env vars, values files, migrations)
   Add a worktree for each with `add-repo.sh`. Finders and verifiers get the
   worktree paths, not the clone paths.
5. Read the task folder the user keeps for this work, if one exists: its
   decisions file, progress file and spec. A behavior the user already
   decided is not a finding; past reviews raised two such decisions as
   defects. Carry each settled decision into `context.md`.
6. Read the PR description (`meta.body`). If it makes claims ("tests pass",
   "no conflicts", "byte-identical"), treat them as candidates to verify, not
   facts.
7. Write `$REVIEW_DIR/context.md`, the block every agent prompt embeds. Three
   sections, ten to thirty lines in all:
   - **Invariants** — true in every environment, each with the file that
     proves it: which service creates or owns a resource, which service is
     the only caller, which key lives where. Source: the repo's code and
     docs, the consumer repos' code.
   - **Target environment** — the environment this PR's base branch deploys
     to, its deployed ref, whether the touched feature is live there, and
     whether the data a failure would need exists there. Source: the
     deployment repo for that environment, established now, for this
     review. Never copy this from an earlier review or a static file: a
     feature can be live in one environment and absent in the next.
   - **Settled decisions** — product and design calls the user already made
     for this work, from step 5. Agents do not raise them as findings.
   Anything an agent will need that neither source settles: ask the user
   now, one line, before launching agents, and write the answer into the
   block.
8. The ledger is `$REVIEW_DIR/candidates.md`, managed by `scripts/ledger.sh`
   (`add`, `set`, `list`). Long reviews get context-summarized mid-way; the
   ledger is what survives. Every candidate goes in as it arrives; every
   verdict is recorded as it lands; the report is written from `ledger.sh list`.

## Phase 1 — Finders (parallel agents, sized to the diff)

Launch all finders **in one message** so they run concurrently, in the background.
Use the strongest model available for every agent (never a small or fast tier).
Each agent gets: the diff file path, the worktree paths from Phase 0 (target
and related repos), and ONE angle from
[references/finder-prompts.md](references/finder-prompts.md). Read that file and
copy the templates — do not improvise the prompts. For a non-application repo
(Helm values, Terraform, CI, SQL) use the same angles with the substitutions
listed in that file, not invented ones.

The 8 angles:

| # | Angle | Hunts for |
|---|-------|-----------|
| 1 | Line-by-line | A wrong line: inverted condition, off-by-one, null deref, missing await, falsy-zero, swallowed error, injection, missing authz |
| 2 | Removed behavior | A deleted line whose guarantee is not re-established anywhere |
| 3 | Cross-file / cross-service | A caller, consumer, or wire contract the change breaks |
| 4 | Reuse | New code that re-implements an existing helper |
| 5 | Simplification | Redundant state, dead guards, copy-paste, derivable values |
| 6 | Efficiency | Serial work that could be parallel, defeated indexes, hot-path waste |
| 7 | Altitude | A fix at the wrong depth: special case where the mechanism should change |
| 8 | Conventions | Clear violations of a governing CLAUDE.md rule (quote the rule) |

Size the fan-out to the diff. Angles 1–3 are always separate agents; the
cleanup angles merge when the diff is small:

| Diff size | Finders | How |
|---|---|---|
| Under ~150 changed lines | 4 | Angles 1, 2, 3 separately; angles 4–8 as ONE "cleanup + conventions" finder |
| ~150–1500 lines | 6–8 | Angles 1–3 separately; 4+5, 6+7, 8, or all eight |
| Over ~1500 lines, or many files | 8+ | All eight; split Angle 1 (and 3 if needed) by file group so each agent reads every hunk it owns |

Every finder returns up to 6 candidates, each with exactly these fields:
`file`, `line` (`NEW:<n>` for added or kept lines, `OLD:<n>` for deleted
lines), `summary` (one sentence), `failure_scenario` (concrete input/state →
concrete wrong outcome). A candidate with no nameable failure scenario is not
a candidate.

Tell every finder: **pass through every candidate you can name a failure for.
Do not silently drop half-believed candidates.** Finders that self-censor bypass
the verify step and are the main cause of missed bugs.

Every finder has a budget: 20 tool calls for a small diff, 40 for a large
one. A finder whose candidate hinges on a system fact it cannot see in the
worktrees does not dig for it — it returns the candidate with
`needs fact: <question>`. You settle that from `context.md`, the repos, or
one line to the user, and add the answer to `context.md` for the verifiers.
A finder still running after the others have returned, chasing a question
`context.md` already answers, is stopped, not awaited.

Do not wait for all finders before starting Phase 2. As each finder returns,
ledger its candidates and dispatch their verifiers. The slowest finder must
never gate the fastest verifier.

While the finders run, do NOT idle. Spend the window on Phase-0 work only you
can do: verify the PR description's own claims, check the deployment/infra
repos for what production actually runs, and map the rollout order (what
auto-deploys, what needs a human). Deployment-gap findings usually come from
this window, not from the finders.

## Phase 2 — Dedup, then verify (one agent per candidate)

1. `ledger.sh add` every candidate. Dedup: same defect + same location +
   same reason → keep one (`ledger.sh set <id> merged`). Overlapping candidates from different angles usually
   mean the finding is real — merge them, keep the strongest failure scenario.
2. CUT before verifying — 8 finders × 6 candidates can be ~40+, and the report
   caps at 10. Correctness candidates first, then the one or two cleanup
   candidates that could change the verdict. Batch: candidates that share a
   file or a mechanism go to ONE verifier (up to 4 per agent) — it reads the
   code once. Verifier agents: at most 4 for a small diff, 8 for a medium
   one, 12 for a large one. Each has a budget of 30 tool calls; at budget it
   returns the verdict the evidence supports plus `needs fact:` if a fact
   would change it. A candidate whose load-bearing question `context.md`
   already answers gets its verdict from you, with the fact quoted as the
   evidence — no agent.
   Self-verify the trivial ones where the diff text alone is proof (a comment
   citing a file you already proved absent, a literal duplicate block) — read
   the lines yourself, quote them in the ledger, and say "self-verified" in
   the report. Everything else that is cut gets `ledger.sh set <id> cut` and
   goes to the report's "Not verified" line, never to the ranked list.
3. Launch the verifiers, parallel, background, strongest model, as their
   candidates land, using the template in [references/verifier-prompt.md](references/verifier-prompt.md).
   Each returns exactly one verdict:
   - **CONFIRMED** — reproduced or proven from evidence.
   - **PLAUSIBLE** — realistic and not disprovable. This is the default.
   - **REFUTED** — killed with constructible proof only: quote the actual line,
     show the type/constant/invariant, cite the guard in this same diff, or run
     the probe that disproves it. "Seems unlikely" is not a refutation.
   - Any verdict may carry the tag **latent**: the mechanism is real but the
     failure needs production state that does not exist today (feature not
     shipped, no such rows, flag off). Latent items are reported, but never as
     a defect of this PR.
4. Verifiers must chase **real evidence**, not read code and speculate:
   - Run the suspect code with the suspect input, inside the worktree or the
     scratch directory.
   - Read the installed dependency source, not its docs.
   - Check the deployment/infra repos: does production actually have the env
     vars, secrets, and config this code needs? A PR that cannot work in prod
     is a finding even when every line of code is correct.
   - Check production reachability: is the path live, is the data there? A
     verifier that proves "this code can fail" has not proved "this PR breaks
     production".
   - For a test the PR adds: run it against the base ref (worktree of the
     merge base). A test that passes without the fix guards nothing. Then
     run a negative control: break the fixed line on purpose in a scratch
     copy; the test must fail. Watch for a test that only checks its own
     stub (a mock returning `[]` asserted to give `[]`), or one that
     computes its expected value with the same formula as the code.
   - Trace the real consumer's code for wire-contract claims. Never assert
     behavior from a flag or field name — grep the code that consumes it.
   - Probe endpoints and databases **read-only**, and only within hard rule 3.
5. If a verifier cannot settle the load-bearing question, it must say so and
   name the one fact that would settle it. Record it in the ledger as
   unsettled. Do not round "unverified" up to confirmed or down to refuted.

## Phase 3 — Report

1. Keep CONFIRMED and PLAUSIBLE. Drop REFUTED. Move latent items to their own
   short section.
2. Rank by severity, at most 10. Correctness beats cleanup when the cap forces a cut.
3. **Lead with the answer to the question the user actually asked.** "Any
   blockers?" gets a yes/no with the blocker named in the first sentence —
   before the findings list. With no question given, the first line is what
   needs fixing in this PR, or that nothing does.
4. Write in simple language. Short sentences. One finding = what breaks, when,
   the verdict (CONFIRMED / PLAUSIBLE / self-verified) with its evidence in a
   few words, and the fix direction. If the user said "review only", describe
   the defect and stop — no fix direction.
5. A finding that is a design or product choice (behavior, cadence, contract)
   is not a defect. Frame it as a question: "Is this intended?" — the user
   decides.
6. Say what was ruled out, in one or two lines. "No money-wrong bug survived —
   X, Y, Z were refuted with evidence" is information the user needs; a bare
   findings list hides how hard the diff was pushed.
7. Say what could not be checked, in one line: probes that needed access you
   did not have, environments you could not reach. Name the fact, not a task.
8. Distinguish "safe but pointless" from "dangerous": a change that fails loudly
   without paying/breaking anything is a different verdict than one that
   silently corrupts.
9. Nothing verified is silently dropped. Verified items that missed the cap
   appear as one line each under "Also seen". A human reviewer who later files
   an item you saw and dropped is a review failure.
10. A verified bug that is OUTSIDE the diff but inside the target repo
    (pre-existing, found on the way) is reported in its own short section
    after the findings, outside the 10-cap — never ranked against the PR's
    own defects, never silently dropped.
11. Anything found in ANOTHER repo is one line under "Other repos", labeled
    as a note. No action items there. If the user did not name that repo as
    part of the aim, they may not want it mentioned at all — keep it to the
    fact.
12. Unsettled candidates go under "Not verified", one line each, only when the
    user can settle it with a fact they know ("is feature X live?"). Never
    attach an action that needs access the user has not granted.
13. No merge, hold, ordering, or rollout-sequencing advice. Not even framed as
    "what still blocks". The review ends at the findings.

Report skeleton:

```
<First line: the answer to the user's question.>

Findings (ranked)
1. <file:line> — <what breaks, when>. <Verdict: CONFIRMED — ran X / PLAUSIBLE — Y not disprovable>. Fix: <direction>.
...
Also seen (verified, below the cap): <one line each>
Latent (mechanism real, not reachable in prod today): <one line each, why not reachable>
Outside the diff (this repo): <one line each>
Other repos (notes only): <one line each>
Ruled out: <what was refuted, with the evidence in a few words>
Not verified: <what could not be checked and the fact that would settle it>
```

## Phase 4 — PR comments (only when asked)

If the user asks to post the findings on the PR, read
[references/posting-comments.md](references/posting-comments.md) first. Key rules:
comments in very simple language, bullet points, one idea per line; use GitHub
`suggestion` blocks for every fix that fits the diff, anchored to the exact lines
the fix replaces; findings whose fix lives outside the diff (infra repo, another
file) go as prose comments or in the review body. Check every anchor with
`scripts/anchor.sh <file> <NEW:n|OLD:n>` and post with
`scripts/post-review.sh review.json` — it validates all anchors against the
diff, pins `commit_id` to the reviewed head, refuses to post if the PR moved,
and prints what landed. Do this before cleanup.

## Phase 5 — Fixes and reviewer comments (only when asked)

- **Review the fix too.** A fix is new code. Before pushing it, run a short
  pass on the fix diff: angles 1 and 2, one verifier per candidate. A first
  fix for a lifecycle gap once carried two new bugs; this pass caught them.
- **Check a reviewer comment against the code before accepting it.**
  - A rule the reviewer cites may not exist. Check the file. The ask behind
    it may still be sound; judge the ask on its own.
  - "Add a guard for X": first trace every producer of X. If an upstream
    component would already break on X, a guard downstream hides that bug.
  - "Use a scoped read" or "match on key K": check which casing and format
    the storage keys use, and which the caller holds.

## Cleanup (last)

`scripts/cleanup.sh` removes every worktree the review created, in every repo,
and prints `git status --short` for each clone so you can confirm it is
exactly as you found it. It never runs `git worktree prune` — that silently
deletes other sessions' stale worktrees. Delete any throwaway probe scripts
from the scratch directory; `cleanup.sh --all` removes the whole `REVIEW_DIR`
once the report is delivered and no comments remain to post. If any removal
failed it keeps `REVIEW_DIR` and exits non-zero: read its output, fix the
cause, run it again.

## Rules that make this work

- **Recall first, precision second, honesty last-and-most.** Finders over-report,
  verifiers cut, and the final report never claims more certainty than the
  evidence bought.
- **The PR's purpose is in scope.** If the change exists to make something work
  in production, verify production can actually run it (config, env, migrations,
  the consumer being deployed). "The code is correct" is not the same claim as
  "the PR achieves its goal".
- **Probe lifecycle windows hard.** Most real bugs in stateful services come
  from reading a component while it is being torn down and replaced (for
  example a `rebuildComponents` that sets `handle.dsl` to `null`, then
  commits a new one). The finder prompts carry the checklist.
- **Reachable beats possible.** A failure that needs state production does not
  have is latent. Report it as such; never let it take a top slot.
- **Evidence beats reading.** A 5-minute local probe (run the snippet, diff the
  DDL, run the test against base) settles what an hour of code-reading
  leaves plausible. Prefer the probe — within hard rule 3.
- **A settled fact beats an agent's search.** A finder once spent its whole
  run on a question the orchestrator could have answered from one line of
  the consumer's code. Establish the invariants and the target environment
  first, hand them to the agents, and let agents return questions instead
  of chasing them.
- **Never let an agent's "needs verification" reach the user as fact.** Blocked
  claims stay blocked until verified. Never repeat an agent's "confirmed" you
  did not check against the lines yourself.
