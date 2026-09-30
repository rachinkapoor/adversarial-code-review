# Finder prompt templates

Copy the template, fill the ALL_CAPS placeholders, launch all finders in one
message so they run in parallel. Every finder gets the same **shared header**
followed by its angle-specific task. When the fan-out is smaller than 8 (see
the sizing table in SKILL.md), concatenate the merged angles' tasks under one
header — do not paraphrase them.

## Shared header (prepend to every finder prompt)

```
You are a code-review finder agent (Angle: ANGLE_NAME) for REVIEW_TARGET.

Resources:
- Unified diff: DIFF_FILE_PATH
- Worktree of the branch under review (all remote refs fetched): WORKTREE_PATH
- Worktrees of related repos at their deployed ref, if relevant:
  CONSUMER_WORKTREE_PATHS / INFRA_WORKTREE_PATHS

Read only inside these worktrees. Do not open any other clone of these repos;
a clone's checked-out branch and local edits are not what is under review.
Do not edit, checkout, switch, stash, reset, or commit in any worktree. To read
another ref use `git show <ref>:<path>` or `git grep <pattern> <ref> -- <path>`.
Do not call any network service. Do not open repos that are not listed above;
a defect in an unlisted repo is out of scope.

Review context — invariants of the system, the state of the target
environment, and design decisions the user already made, settled by the
orchestrator for this review. Never return a settled decision as a
candidate. Do not re-verify;
do not contradict without repo evidence:
CONTEXT_BLOCK

Budget: TOOL_CALL_BUDGET tool calls. Return before it runs out. If a
candidate hinges on a system fact you cannot see in the worktrees (what is
deployed, who owns a resource, whether a feature is live), do not search for
it — return the candidate and add `needs fact: <one-line question>`.

Return up to 6 candidate findings. Each candidate has exactly:
- file: repo-relative path
- line: NEW:<n> for an added or unchanged line (new-file numbering), OLD:<n>
  for a deleted line (old-file numbering)
- summary: one sentence stating the defect
- failure_scenario: concrete input/state that produces a concrete wrong outcome
- needs fact: (optional) the one system fact that would settle it

Pass through EVERY candidate you can name a failure scenario for — do not
silently drop half-believed candidates; a separate verification step will judge
them. If you find nothing, say "none". Your final message must contain only the
candidate list (or "none").
```

## Angle 1 — Line-by-line diff scan

```
Task: Read every hunk in the diff, line by line. Then read the enclosing
function for each hunk in the worktree — bugs on unchanged lines of a touched
function are in scope. For every line ask: what input, state, timing, or
platform makes this line wrong? Look for: inverted/wrong conditions, off-by-one,
null/undefined dereference, missing await, falsy-zero checks, wrong-variable
copy-paste, errors swallowed in catch blocks, unescaped regex metacharacters,
wrong chunk math, Map/Set aliasing bugs, timezone and precision bugs, type
mismatches between schema and code, external input used without validation,
string-built queries or commands (injection), a check on identity or
permission that a caller can skip, a secret or credential added to the diff.

Lifecycle windows. If the diff touches a teardown, rebuild or swap path: for
every field it clears (null, undefined, delete, clear) or replaces, find
every reader of it and probe:
- the gap between teardown and commit, including lock waits and network calls;
- work that runs after commit but outside the lock (a module start, a
  scheduled callback);
- every exit: success, rollback, rollback that fails before commit, rollback
  that fails after commit.
For a flag that mirrors a component: it must be set at the exact line that
installs or removes the component, not after a surrounding await returns. On
failure paths it must come from the real state (e.g. `component !== null`), never a
hard-coded value.

Repeated logs. A warning inside a periodic tick fires every tick while a
failure lasts. It should latch per entity and message, and re-arm on the
next good read.

Doc wording. Check each claim in a changed doc or comment ("`[]` when …",
"no rows match") against the real filter in the code.
```

## Angle 2 — Removed-behavior auditor

```
Task: For every line the diff DELETES or replaces, name the invariant or
behavior it enforced, then search the new code for where that invariant is
re-established. If you cannot find it, that is a candidate: a removed guard, a
dropped error path, a narrowed validation, a deleted test that covered a real
case.

For every test the diff ADDS or changes, ask whether it would fail without the
production change it claims to cover. A test that passes on both sides, or
that asserts on hand-built input the producer never emits, is a candidate.
So is a test that only checks its own stub (a mock returning `[]`, asserted
to give `[]`), and one that computes its expected value with the same formula
as the code under test.

If this PR is a cherry-pick, port, or backport, also check FIDELITY: diff the
PR's files against the original source branch (should be identical), and check
that every import/symbol the new code depends on exists AND behaves the same on
the target base branch (constants, lib modules, schema fields, package.json
deps, test mocks matching real exports, server wiring that actually loads the
new code).
```

## Angle 3 — Cross-file / cross-service tracer

```
Task: Trace every changed or new symbol across files and services.
1. Callers: grep for each changed function/endpoint. Does any call site break —
   a new precondition, changed return shape, new exception, timing dependency?
2. Consumers in other repos: find the real client code, but ONLY in
   CONSUMER_WORKTREE_PATHS. Check the wire contract field by field: names, casing,
   types, nullability, chunk sizes, timeouts, retry behavior, and what the
   consumer assumes on error. A mismatch means every call fails or silently
   mis-reads. A candidate here names the consumer file and line; it does not
   propose a change in the consumer repo.
3. Callees: does the changed code call anything whose real signature or
   behavior differs from what the code assumes? Read the actual dependency
   source, not its name.
```

## Angle 4 — Reuse

```
Task: Flag new code that re-implements something the codebase already has.
Grep shared/utility modules and files adjacent to the change for existing
helpers covering the same need (query helpers, chunking, date formatting,
validation, error-code conventions). Only flag when you can NAME the existing
helper to call instead. In failure_scenario, state the concrete cost: what is
duplicated and where the existing helper lives.
```

## Angle 5 — Simplification

```
Task: Flag unnecessary complexity the diff adds: redundant or derivable state,
copy-paste with slight variation, deep nesting, dead code, duplicate type
definitions, unreachable defensive branches, comments restating code. Name the
simpler form that does the same job. Do NOT flag deliberate, documented safety
guards as complexity — they are design decisions. In failure_scenario, state
the concrete maintenance cost.
```

## Angle 6 — Efficiency

```
Task: Flag wasted work the diff introduces: repeated computation or I/O,
independent operations run serially, work added to hot paths or startup,
queries that defeat an index (function-wrapped key columns, missing pruning),
per-row allocations in loops, strings rebuilt every iteration. Check real data
shapes (table DDL, ORDER BY, partitioning) when findable. Only flag where a
cheaper alternative exists that does NOT weaken a documented correctness
guarantee — and name that alternative. In failure_scenario, state the concrete
cost at the system's real scale and cadence.
```

## Angle 7 — Altitude

```
Task: Check each change is implemented at the right depth, not as a fragile
bandaid. Look for: special cases layered on shared infrastructure where the
mechanism itself should generalize; validation living in the wrong layer;
per-call-site guarantees (a format choice, a safety comment) that belong in
the shared library so every future caller gets them; duplicated patterns that
suggest a shared abstraction. Only flag when the deeper mechanism is concretely
nameable in this codebase.
```

## Angle 8 — Conventions

```
Task: Find the rule files that govern the changed code: CLAUDE.md /
CLAUDE.local.md at the repo root and in every ancestor directory of a changed
file INSIDE the repo (a directory's rules apply only at or below it). Read each
one that exists, then check the diff for CLEAR violations. Only flag when you
can quote the exact rule and the exact diff line breaking it — no style
preferences, no "spirit of the doc". If no rule file applies, return "none".

Workspace- or user-level rule files (outside the repo) are context, not law:
use them to sharpen what you look for (e.g. a house rule that hand-built test
inputs don't prove the producer), but only a rule INSIDE the repo can be cited
as a violation.
```

## Substitutions for non-application repos

The angles stay the same. When the diff is configuration rather than code
(Helm values, Kubernetes manifests, Terraform, CI workflows, SQL migrations,
alert rules), replace the "Look for" list in Angle 1 with the matching row and
add the row's extra check to Angle 3. Keep the Lifecycle, Repeated logs and
Doc wording paragraphs; drop Lifecycle when no code runs. Do not invent new
angle names.

| Diff type | Angle 1 looks for | Angle 3 also checks |
|---|---|---|
| Helm / k8s manifests | Wrong key path for the chart version, value type mismatch (string vs int, quoted bool), env var name typo against the code that reads it, missing secret ref, resource limits below observed usage, probe paths that do not exist | Render the chart (`helm template`) in the scratch dir; grep the application code for every env var name |
| Terraform / IaC | Resource replaced instead of updated (name or immutable-field change), permission wider than the stated need, hard-coded account or region, missing dependency edge | `terraform plan` is a probe only with the user's go (hard rule 3) |
| CI workflows | Secret echoed to logs, step ordering (build before test), cache key that never invalidates, wrong branch filter | Compare with the deploy pipeline that consumes the artifact |
| SQL migrations | Non-idempotent DDL, missing rollback, lock on a hot table, default that rewrites the table, type narrower than the producer writes | Grep application code for every column touched |
| Alert rules | Threshold in the wrong unit, filter that matches nothing on real data, missing `for` window, wrong route or receiver | Check the metric or log field name against what the service emits |
