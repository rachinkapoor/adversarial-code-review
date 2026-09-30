# Helper scripts

Deterministic steps of the review pipeline. Bash only. Dependencies: git, jq,
and gh. `gh` is needed for PR targets, for posting, and for the remote default
branch of a clone that has no `refs/remotes/origin/HEAD`. Every script exits
non-zero with a one-line reason on failure and never touches a clone's
checked-out branch, index, or working tree.

## Shared state: `REVIEW_DIR`

Every script reads the environment variable `REVIEW_DIR` (required; no
default). `scope.sh` creates it. Contents:

| Path | Written by | Holds |
|---|---|---|
| `meta.json` | scope.sh | `target`, `repo` (clone path), `repoName`, `ownerRepo`, `baseRef`, `headSha`, `baseSha` (merge base), `prNumber` (null unless a PR), `isCrossRepository`, `title`, `body`, `wip` (bool), `untracked` (array), `diffLines`, `diffFiles`, `fanout` |
| `diff.patch` | scope.sh | unified diff, merge base → head (plus uncommitted changes for `--wip`) |
| `wt/<repoName>` | scope.sh, add-repo.sh | detached worktrees |
| `worktrees.tsv` | scope.sh, add-repo.sh | one line per worktree: `<clone path>\t<worktree path>\t<sha>` (always the resolved SHA) |
| `wip-uncommitted.patch` | scope.sh | `--wip` only: the uncommitted changes, as applied into the worktree |
| `candidates.md` | ledger.sh | the candidate ledger, a markdown table |
| `review.json`, `posted.json` | post-review.sh | copy of the validated payload that was posted, and the API response |
| `.lock-<name>` | every script | held while a shared file is rewritten, removed again afterwards |

Field rules:
- `target` is canonical: `pr:<N>`, `branch:<name>@<base>`, or `wip:<headSha>`.
  Two invocations are "the same target" when these strings are equal, so a PR
  given by URL and by number is the same target.
- `repoName` is the basename of the clone path. If `wt/<repoName>` already
  belongs to a different clone, or holds a directory that is not a worktree of
  this clone, the new worktree is `wt/<repoName>-2`, `-3`, … A directory that
  no line claims but that is a worktree of this clone is adopted and recorded:
  that is what a run killed between `git worktree add` and the record leaves.
- `ownerRepo` is `owner/name` parsed from `git remote get-url origin`
  (ssh or https GitHub URLs). Empty string when it cannot be parsed.
- `diffLines` is the number of added plus deleted lines in `diff.patch`.
  `fanout` is 4 when `diffLines < 150`, 6 when `150 <= diffLines < 1500`,
  8 when `diffLines >= 1500`.

`gh` is invoked as `${GH:-gh}` so tests can substitute a fake.

## Locking

`worktrees.tsv` and `candidates.md` are read and rewritten by parallel agents,
so each is guarded by a lock directory in `REVIEW_DIR` that holds the pid of
its holder. A holder that is interrupted releases the lock and stops. A lock
whose pid names no living process for two seconds is taken over, with a line on
stderr. Any other lock is waited for, and a script that is still waiting after
60 seconds exits with the path to remove by hand.

## `scope.sh [--repo <clone>] [--base <ref>] <PR number | PR URL | branch | --wip>`

- Target parsing: an all-digit argument or `pr:<N>` is a PR number; a GitHub
  PR URL is a PR number; `--wip` is the working tree; anything else is a
  branch name. A branch whose name is all digits must be given as
  `branch:<name>`.
- `--repo` defaults to the current directory's repository root.
- Runs `git fetch origin` in the clone, without creating `origin/HEAD`. A ref
  that is still missing afterwards (single-branch clone) is fetched by name
  into `FETCH_HEAD`; no remote-tracking ref is created. For a PR, reads
  `gh pr view <N> --json baseRefName,headRefName,headRefOid,isCrossRepository,title,body,state`;
  for a cross-repository PR also runs `git fetch origin pull/<N>/head`. Any PR
  whose head is still missing after that is tried once more from
  `pull/<N>/head`, which a single-branch clone needs even for a
  same-repository PR.
- Branch target: head is `origin/<branch>`, else the ref as given, else the
  tip fetched by name; base is `--base`, else the remote default branch
  (`refs/remotes/origin/HEAD`, else `gh repo view --json defaultBranchRef`).
- `--wip`: head is the clone's `HEAD`; base is `--base`, else the remote
  default branch; diff is merge base → working tree (committed plus
  uncommitted changes). Untracked files are listed in
  `meta.untracked` and not included in the diff. Uncommitted changes are
  applied into the worktree with `git apply`.
- Diff is always three-dot (from the merge base of base and head).
- Creates `wt/<repoName>` with `git worktree add --detach` at `headSha`, or
  reuses the worktree already there when it sits at `headSha` and refuses when
  it sits elsewhere. Picking the path, creating the worktree and recording it
  happen under one lock, so two scopes on one `REVIEW_DIR` both succeed.
  Refuses if `REVIEW_DIR` already holds a `meta.json` for a different target.
- `fanout` follows the sizing table in SKILL.md: 4 under 150 changed lines,
  6 up to 1500, 8 above.
- Prints a summary: target, clone, head SHA, base, diff lines and files,
  fan-out, worktree path.

## `add-repo.sh <clone> [ref]`

- Fetches, resolves `ref` (default: the remote default branch) to a SHA,
  creates `wt/<repoName>` detached at that SHA, appends to `worktrees.tsv`.
- `ref` is tried as `origin/<ref>` first, then as given (`git rev-parse`).
- Idempotent: an existing entry for the same clone whose worktree is still on
  disk prints its path and exits 0.
- Prints the worktree path.

## `ledger.sh add <angle> <file> <NEW:n|OLD:n> <summary>` → prints the new id (`C1`, `C2`, …)
## `ledger.sh set <id> <status> [evidence]`
## `ledger.sh list [status]`

- Statuses: `new`, `merged`, `cut`, `verifying`, `CONFIRMED`, `PLAUSIBLE`,
  `REFUTED`, `latent`. `add` starts a row at `new`. `set` refuses any other
  value and unknown ids.
- `candidates.md` is a markdown table. Line 1 is the header
  `| id | angle | file:line | summary | status | evidence |`, line 2 the
  separator, then one row per candidate. Pipe characters inside fields are
  escaped as `\|`, and newlines, carriage returns and tabs inside a field
  become spaces so that one candidate is one row. `list` prints the header, the
  separator and the matching rows.

## `anchor.sh <file> <NEW:n|OLD:n>`

- Reads `diff.patch`. Exit 0 and print `side=RIGHT|LEFT line=<n> hunk=<header>`
  when the line is inside a hunk of that file on that side. Exit 1 with a reason
  (file not in diff, line not in any hunk, or line is a context line that
  cannot take `LEFT`) otherwise. Context lines are valid on `RIGHT` only.

## `post-review.sh <review.json> [--dry-run] [--force]`

- Validates every entry in `comments`: `path` + `line` (+ `start_line`) must
  pass `anchor.sh` on the given `side`; `start_line` < `line`, same hunk.
  Any failure aborts before posting and lists every bad anchor.
- Refuses when `.comments` is present but is not a list of objects.
- Refuses when `meta.prNumber` is null (branch or `--wip` target).
- Every anchor a payload needs is resolved in one pass, so validation reads
  `diff.patch` once however many comments there are.
- Sets `commit_id` to `meta.headSha` when absent.
- `--dry-run`: prints the validated JSON and stops. No network, no head check.
- Otherwise, unless `--force`, re-reads the PR head from `gh pr view` and
  aborts if it differs from `meta.headSha`.
- Posts to `meta.ownerRepo`; when that is empty it is re-derived from origin in
  `meta.repo`, and anything that is not `owner/name` is refused.
- Posts with `gh api repos/<ownerRepo>/pulls/<N>/reviews --input`, saves the
  payload to `$REVIEW_DIR/review.json` and the response to `posted.json`, then
  lists the posted comments as
  `path:[<start_line>-]<line> side=<RIGHT|LEFT> suggestion=<yes|no>`.

## `cleanup.sh [--all]`

- For every line in `worktrees.tsv`: `git -C <clone> worktree remove --force <wt>`.
  Missing worktrees are skipped, not errors. A recorded clone that is no longer
  there is reported and skipped.
- Never runs `git worktree prune`.
- Prints `git -C <clone> status --short` for each clone so a dirty clone is visible.
  Exits non-zero if a clone's status cannot be read or a worktree is still on
  disk after removal. A worktree git refused to remove is left where it is,
  because git finds a worktree by its path and a later run could not remove it
  at all once the directory is gone.
- Removes `wt/`, and `--all` also removes the rest of `REVIEW_DIR` — both only
  when everything above worked. After a failure `REVIEW_DIR` is kept, because
  `worktrees.tsv` is the only record of what is still registered.

## Tests

`tests/run.sh` builds throwaway repositories with a bare `origin` under a
temporary directory and exercises every script, including a fake `gh`
(`tests/fake-gh`) for PR paths. Run it from the repository root; it prints one
line per test and a final pass/fail count.
