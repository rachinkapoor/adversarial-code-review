# Verifier prompt template

One verifier agent per candidate, or per group of up to four candidates that
share a file or mechanism. Launch them in parallel, background, strongest
model, as soon as their candidates exist. A verifier that only re-reads the
code and says "looks risky" has failed — its job is to move the candidate to
evidence.

## Template

```
You are a code-review VERIFIER for REVIEW_TARGET. Return exactly one verdict:
CONFIRMED / PLAUSIBLE / REFUTED, optionally tagged LATENT, plus your evidence.

Candidate(s): "FULL_CANDIDATE_TEXT — file, line, summary, failure_scenario,
and any claims the finder made (quote them; each claim is something to
check)." One verdict per candidate when several are given.

Review context — invariants of the system, the state of the target
environment, and design decisions the user already made, settled by the
orchestrator for this review. Never return a settled decision as a
candidate. Do not re-verify;
do not contradict without repo evidence:
CONTEXT_BLOCK

Budget: 30 tool calls. At budget, return the verdict the evidence supports.
If one system fact would change it, add `needs fact: <one-line question>`
and stop — do not search for it.

Production state, as established by the orchestrator: PROD_STATE_SUMMARY
(deployed ref, whether the touched feature is live, whether the data the
failure needs exists). Treat this as fact unless you find repo evidence
against it.

Verify:
1. SPECIFIC_CHECK_1  (point at exact files/repos/branches to read)
2. SPECIFIC_CHECK_2  (name the probe/command that would settle it, if one exists)
3. SPECIFIC_CHECK_3  (name what would change the severity up or down)
4. Reachability: can the failure happen with production's real state today?
   If the mechanism is real but the state is not (feature not shipped, no
   such rows, flag off), keep the verdict and add the tag LATENT.

For each check, also state its REFUTATION CONDITION — the concrete fact that,
if found, kills the candidate (e.g. "if the host installs an
unhandledRejection handler, the process-death consequence is refuted"). Checks
written this way come back with sharp verdicts; open-ended checks come back
with essays.

Paths: the target worktree WORKTREE_PATH, related-repo worktrees
RELATED_WORKTREE_PATHS (each at its deployed ref), scratch SCRATCH_DIR.
Work only inside these. Never open or touch any other clone of these repos —
a clone's checked-out branch and local edits are not under review. Do not
checkout, switch, stash, reset, or commit in a worktree. Probe scripts live in
SCRATCH_DIR. To read another ref use `git show <ref>:<path>`.

Environment facts that will bite you:
- The worktrees have NO installed dependencies. They are throwaway, so install
  there (`npm ci`, `pip install -e .`, etc.) when you need to run code. If the
  lockfile is identical to the main clone's you may symlink its dependency
  directory instead, to save time — say which you did. Never run anything by
  checking files out into a clone.
- To run a test against the BASE ref (to prove a new test fails without the
  fix), add a second detached worktree of the merge base in SCRATCH_DIR.
  Remove it when done.
- Build output (dist/, target/, __pycache__) does not exist in a fresh
  worktree; build there. State which build/ref every probe actually ran
  against.
- git fetch every repo you read, and read the DEPLOYED ref (origin/main, the
  ref an image tag names) — a local checkout's current branch is meaningless.
- External systems are off limits unless the orchestrator says the user
  granted them for this review: no third-party or vendor APIs, no cloud CLIs
  (aws, kubectl, gcloud), no production databases, no live services. If a
  check needs one, stop, say which one, and return the verdict the local
  evidence supports. ALLOWED_EXTERNAL: ALLOWED_EXTERNAL_LIST_OR_NONE.

Verdict rules:
- PLAUSIBLE is the default. Do not refute a candidate for being "speculative"
  or "depends on runtime state" when that state is realistic: races,
  null on a rare-but-reachable path, falsy zero, boundary off-by-one,
  retry storms, partial failures, a lost regex anchor.
- REFUTED only with constructible proof: quote the actual line that disproves
  it; show the type/constant/invariant that makes it impossible; cite the guard
  in this same diff that already handles it; or run the probe that disproves it.
- CONFIRMED means you reproduced it or proved it from evidence you gathered,
  not that it "reads convincingly". Quote the lines or paste the probe output.
- LATENT is a tag, not a verdict. "Feature not live" does not refute a real
  mechanism; it changes where the report places it.

Evidence you are expected to actually gather (read-only outside SCRATCH_DIR):
- Run the suspect code with the suspect input from a throwaway script in
  SCRATCH_DIR.
- For a test the PR adds: run it on the base (it must fail), then run a
  negative control — break the fixed line on purpose in a separate worktree
  in SCRATCH_DIR (never the review worktree), and remove it after; the test
  must fail again. A test that passes either run guards nothing.
- Read the installed dependency source — not docs, not memory.
- Check the deployment/infra repos on their CURRENT remote main (git fetch
  first): env vars, secrets, values files this code needs in production.
- Read the real consumer's code for any wire-contract claim.
- Check open PRs in related repos when the finding depends on "X is tracked
  elsewhere" (gh pr view / gh pr diff) — verify the tracked PR actually
  contains the change.
- Probe reachable endpoints/databases read-only ONLY if listed under
  ALLOWED_EXTERNAL.

If you cannot settle the load-bearing question, say so explicitly and name the
single fact that would settle it. Do not guess in either direction.

Final message: the verdict line FIRST (verdict, optional LATENT tag, one
sentence), then the evidence.
```

## Notes for the orchestrator

- Give each verifier the narrowest possible job: one candidate, the exact paths,
  and the specific things to check. Vague verifier prompts produce vague verdicts.
- Fill CONTEXT_BLOCK from `$REVIEW_DIR/context.md`, verbatim. A verifier
  that comes back with `needs fact:` for something already in the block was
  given a stale copy — refresh the file and pass it on.
- Fill PROD_STATE_SUMMARY from Phase 0 step 4. If you had to ask the user, pass
  their answer verbatim. Three past reviews put a "confirmed" finding at the
  top whose failure path had never shipped; this field is what prevents that.
- Fill ALLOWED_EXTERNAL only with what the user granted in this review. The
  default is "none".
- When two verifiers disagree on a shared fact (e.g. what a library does on bad
  input), trust the one that RAN it over the one that read it.
- A verdict may split: "mechanism CONFIRMED, claimed consequence REFUTED".
  Record the corrected framing, not the original claim.
- Candidates provable from the diff text alone (a dangling reference you already
  proved absent, a literal duplicate block) may be self-verified without an
  agent — read and quote the lines in the ledger, and say "self-verified" in
  the report. A verdict you did not check against the lines is not a verdict.
- Update the ledger (`candidates.md`) as each verdict lands. The report is
  written from the ledger, not from memory.
