#!/usr/bin/env bash
# Test suite for the helper scripts in scripts/.
#
# Run from the repository root:  bash tests/run.sh
# Requires: bash 3.2, git, jq. No network: a fake gh is forced onto PATH and
# into $GH, and every repository the tests touch is built under a temp dir that
# is deleted on exit.
#
# Each test runs in a subshell. It prints why it failed and exits non-zero; the
# runner turns that into one "FAIL <name>: <reason>" line. VERBOSE=1 dumps the
# whole log of a failing test.

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
SCRIPTS="$ROOT/scripts"
FAKE_GH="$ROOT/tests/fake-gh"

[ -x "$FAKE_GH" ] || { echo "tests/fake-gh is missing or not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/acr-tests.XXXXXX") || exit 2
# A TMPDIR that ends in a slash leaves a doubled one here, and git prints its
# own normalised spelling. Collapsing it keeps path assertions comparable.
TMP=$(printf '%s' "$TMP" | sed 's#//*#/#g')

teardown() {
  # Every clone, worktree and review dir lives inside TMP, so one removal is
  # enough; worktree admin dirs go with the clone they belong to.
  [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"
}
trap teardown EXIT INT TERM

# ---------------------------------------------------------------- environment

# HOME is redirected so the user's git and gh configuration cannot leak in.
export HOME="$TMP/home"
export GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME="Review Tests"
export GIT_AUTHOR_EMAIL="tests@example.invalid"
export GIT_COMMITTER_NAME="Review Tests"
export GIT_COMMITTER_EMAIL="tests@example.invalid"
export GIT_AUTHOR_DATE="2020-01-01T00:00:00Z"
export GIT_COMMITTER_DATE="2020-01-01T00:00:00Z"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE REVIEW_DIR
mkdir -p "$HOME" "$TMP/bin" "$TMP/rd" "$TMP/gh" "$TMP/logs" "$TMP/neutral"

ln -s "$FAKE_GH" "$TMP/bin/gh"
PATH="$TMP/bin:$PATH"
export PATH
export GH="$FAKE_GH"

# The scripts default --repo to the current directory's repository. Running
# from a directory that is not a repository turns a missing --repo into a loud
# failure instead of a silent hit on the user's own checkout.
cd "$TMP/neutral" || exit 2

ROOT_IS_REPO=0
ROOT_STATUS_BEFORE=""
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  ROOT_IS_REPO=1
  ROOT_STATUS_BEFORE=$(git -C "$ROOT" status --porcelain 2>/dev/null)
fi

TAB=$(printf '\t')
TMP_REAL=$(cd "$TMP" && pwd -P)

# ------------------------------------------------------------ assertion tools

fail() { echo "$*"; exit 1; }

assert_eq() { # <expected> <actual> <label>
  [ "$1" = "$2" ] || fail "$3: expected [$1] got [$2]"
}

assert_ne() { # <unexpected> <actual> <label>
  [ "$1" != "$2" ] || fail "$3: value should not be [$1]"
}

assert_contains() { # <needle> <haystack> <label>
  case "$2" in
    *"$1"*) : ;;
    *) fail "$3: [$1] not found" ;;
  esac
}

assert_not_contains() { # <needle> <haystack> <label>
  case "$2" in
    *"$1"*) fail "$3: [$1] should not be present" ;;
    *) : ;;
  esac
}

assert_file() { [ -f "$1" ] || fail "$2: file missing: $1"; }
assert_no_file() { [ ! -e "$1" ] || fail "$2: file should not exist: $1"; }
assert_dir() { [ -d "$1" ] || fail "$2: directory missing: $1"; }
assert_no_dir() { [ ! -d "$1" ] || fail "$2: directory should not exist: $1"; }

need() { # a missing script is a failure, never a silent pass for a negative test
  [ -f "$SCRIPTS/$1" ] || fail "scripts/$1 does not exist"
  [ -r "$SCRIPTS/$1" ] || fail "scripts/$1 is not readable"
}

# Runs a helper script, capturing stdout+stderr in CAP_OUT and the code in CAP_RC.
sh_run() {
  local s="$1"; shift
  CAP_OUT=$(bash "$SCRIPTS/$s" "$@" 2>&1)
  CAP_RC=$?
}

assert_ok() { # <label> - the last sh_run must have succeeded
  [ "$CAP_RC" = "0" ] || { echo "$CAP_OUT"; fail "$1: exit $CAP_RC"; }
}

assert_refused() { # <label> - non-zero exit with a reason on the output
  if [ "$CAP_RC" = "0" ]; then echo "$CAP_OUT"; fail "$1: exited 0, expected a refusal"; fi
  [ -n "$CAP_OUT" ] || fail "$1: refused without printing a reason"
}

# A git that kills whoever called it the moment a `git worktree add` has
# succeeded. It leaves exactly the state a script killed in that window leaves:
# the worktree is on disk and registered, and nothing has recorded it.
REAL_GIT=$(command -v git)
KILLER_BIN="$TMP/killer-git"
mkdir -p "$KILLER_BIN"
cat > "$KILLER_BIN/git" <<KILLER
#!/usr/bin/env bash
saw_worktree=0
is_add=0
for a in "\$@"; do
  [ "\$a" = "worktree" ] && saw_worktree=1
  [ "\$a" = "add" ] && [ "\$saw_worktree" = "1" ] && is_add=1
done
"$REAL_GIT" "\$@"
rc=\$?
if [ "\$is_add" = "1" ] && [ "\$rc" = "0" ]; then
  kill -KILL "\$PPID" 2>/dev/null
  sleep 1
fi
exit \$rc
KILLER
chmod +x "$KILLER_BIN/git"

# sh_run, but with the killing git in front on PATH.
killer_run() {
  local s="$1"; shift
  CAP_OUT=$(PATH="$KILLER_BIN:$PATH" bash "$SCRIPTS/$s" "$@" 2>&1)
  CAP_RC=$?
}

# Runs <script> in the background against REVIEW_DIR <dir>, recording its
# output and exit code under <tag>.
bg_run() { # <tag> <review dir> <script> [args...]
  local tag="$1" dir="$2" s="$3"; shift 3
  ( REVIEW_DIR="$dir" bash "$SCRIPTS/$s" "$@" > "$TMP/logs/$tag.out" 2>&1
    echo $? > "$TMP/logs/$tag.rc" ) &
}

bg_rc() { cat "$TMP/logs/$1.rc" 2>/dev/null; }
bg_out() { cat "$TMP/logs/$1.out" 2>/dev/null; }

jqf() { jq -r "$2" "$1" 2>/dev/null; }

# Counts the pipes that act as column separators, ignoring escaped ones.
unescaped_pipes() {
  printf '%s' "$1" | sed 's/\\|/@@ESCAPED_PIPE@@/g' | tr -cd '|' | wc -c | tr -d ' '
}

# Pulls the first JSON object out of mixed output.
extract_json() {
  if printf '%s' "$1" | jq -e . >/dev/null 2>&1; then
    printf '%s' "$1"
  else
    printf '%s\n' "$1" | sed -n '/^[[:space:]]*{/,$p'
  fi
}

# ------------------------------------------------------------- patch analysis

# Prints one row per diff body line: <file> <add|del|ctx> <old line> <new line>.
# "-" means the line does not exist on that side.
patch_map() {
  awk '
    /^diff --git / { file=""; inhunk=0; next }
    /^--- /        { next }
    /^\+\+\+ /     { p=$2; sub(/^b\//, "", p); file=p; inhunk=0; next }
    /^@@/ {
      o=$2; sub(/^-/, "", o); split(o, oa, ","); ol=oa[1]+0
      n=$3; sub(/^\+/, "", n); split(n, na, ","); nl=na[1]+0
      inhunk=1; next
    }
    inhunk && file != "" {
      c=substr($0, 1, 1)
      if (c == "+")       { print file "\tadd\t-\t" nl; nl++ }
      else if (c == "-")  { print file "\tdel\t" ol "\t-"; ol++ }
      else if (c == " ")  { print file "\tctx\t" ol "\t" nl; ol++; nl++ }
      else if (c == "\\") { }
      else                { inhunk=0 }
    }
  ' "$1"
}

map_first() { # <map> <file> <add|del|ctx> <col 3=old 4=new>
  awk -F'\t' -v f="$2" -v t="$3" -v c="$4" '$1==f && $2==t { print $c; exit }' "$1"
}

map_max_new() { # <map> <file>
  awk -F'\t' -v f="$2" '$1==f && $4!="-" { if ($4+0 > m) m=$4+0 } END { print m+0 }' "$1"
}

# ------------------------------------------------------------------- fixtures

filler() { # <count> <tag> <start index>
  local i=$3
  local end=$(( $3 + $1 - 1 ))
  while [ "$i" -le "$end" ]; do
    echo "// $2 filler line $i"
    i=$(( i + 1 ))
  done
}

# src/a.ts keeps the edited block near line 15 so that lines well below it are
# inside the file but outside every hunk.
a_ts_base() {
  filler 14 alpha 1
  echo 'export function alpha(x: number): number {'
  echo '  const a = x + 1;'
  echo '  const b = a * 2;'
  echo '  const doomedOne = "remove me one";'
  echo '  const doomedTwo = "remove me two";'
  echo '  return b + a;'
  echo '}'
  filler 19 alpha 22
}

a_ts_feature() {
  filler 14 alpha 1
  echo 'export function alpha(x: number): number {'
  echo '  const a = x + 1;'
  echo '  const b = a * 2;'
  echo '  const addedOne = a - 1;'
  echo '  const addedTwo = b + addedOne;'
  echo '  const addedThree = addedTwo * 3;'
  echo '  return b + a;'
  echo '}'
  filler 19 alpha 22
}

# src/a.ts.bak exists to catch a path match that treats "src/a.ts" as a prefix.
# Its only hunk sits far below every hunk of src/a.ts.
bak_base() {
  filler 69 bak 1
  echo 'const bakValue = 1;'
  filler 20 bak 71
}

bak_feature() {
  filler 69 bak 1
  echo 'const bakValue = 2;'
  filler 20 bak 71
}

b_ts_base() { filler 20 beta 1; }

b_ts_feature() {
  filler 20 beta 1
  echo 'export const betaExtra = 1;'
  echo 'export const betaExtraTwo = 2;'
}

keep_base() { filler 10 keep 1; }

keep_main_second() {
  filler 4 keep 1
  echo '// keep: changed on main after feature branched'
  filler 5 keep 6
}

generated_lines() { # <count> <tag>
  local i=1
  while [ "$i" -le "$1" ]; do
    echo "export const $2$i = $i;"
    i=$(( i + 1 ))
  done
}

build_target_repo() {
  ORIGIN="$TMP/target-origin.git"
  SEED="$TMP/seed"
  git init --bare -q -b main "$ORIGIN"
  git init -q -b main "$SEED"
  git -C "$SEED" remote add origin "file://$ORIGIN"
  mkdir -p "$SEED/src"

  a_ts_base   > "$SEED/src/a.ts"
  bak_base    > "$SEED/src/a.ts.bak"
  b_ts_base   > "$SEED/src/b.ts"
  keep_base   > "$SEED/src/keep.ts"
  git -C "$SEED" add -A
  git -C "$SEED" commit -q -m "base"
  MB_SHA=$(git -C "$SEED" rev-parse HEAD)
  git -C "$SEED" push -q origin main

  git -C "$SEED" checkout -q -b feature
  a_ts_feature > "$SEED/src/a.ts"
  git -C "$SEED" commit -q -am "alpha: replace doomed constants with derived values"
  bak_feature  > "$SEED/src/a.ts.bak"
  git -C "$SEED" commit -q -am "bak: bump value"
  b_ts_feature > "$SEED/src/b.ts"
  git -C "$SEED" commit -q -am "beta: two more exports"
  FEATURE_SHA=$(git -C "$SEED" rev-parse HEAD)
  git -C "$SEED" push -q origin feature

  # main moves on AFTER feature branched: a two-dot diff would show this as a
  # reversion, a three-dot diff will not mention keep.ts at all.
  git -C "$SEED" checkout -q main
  keep_main_second > "$SEED/src/keep.ts"
  git -C "$SEED" commit -q -am "keep: change after feature branched"
  MAIN_SHA=$(git -C "$SEED" rev-parse HEAD)
  git -C "$SEED" push -q origin main

  git -C "$SEED" checkout -q -b medfeature main
  generated_lines 400 med > "$SEED/src/med.ts"
  git -C "$SEED" add -A && git -C "$SEED" commit -q -m "med change"
  MED_SHA=$(git -C "$SEED" rev-parse HEAD)
  git -C "$SEED" push -q origin medfeature

  git -C "$SEED" checkout -q -b bigfeature main
  generated_lines 3000 big > "$SEED/src/big.ts"
  git -C "$SEED" add -A && git -C "$SEED" commit -q -m "big change"
  BIG_SHA=$(git -C "$SEED" rev-parse HEAD)
  git -C "$SEED" push -q origin bigfeature

  # A fork head: reachable only through refs/pull/7/head on the origin, which a
  # plain `git fetch origin` does not bring down.
  git -C "$SEED" checkout -q -b forkwork main
  echo 'export const forked = true;' > "$SEED/src/fork.ts"
  git -C "$SEED" add -A && git -C "$SEED" commit -q -m "fork head"
  FORK_SHA=$(git -C "$SEED" rev-parse HEAD)
  git -C "$SEED" push -q origin HEAD:refs/pull/7/head
  git -C "$SEED" checkout -q main
  git -C "$SEED" branch -q -D forkwork

  # The same-repository PR 11 also has a pull ref on the origin, which is the
  # only way a clone that tracks one branch can reach the PR head.
  git -C "$SEED" push -q origin "$FEATURE_SHA:refs/pull/11/head"

  # file:// avoids the local-clone object hardlink, so the fork commit really is
  # absent from the clones until something fetches refs/pull/7/head.
  CLONE="$TMP/clone"
  git clone -q "file://$ORIGIN" "$CLONE"
  git -C "$CLONE" checkout -q feature
  # The clone stays dirty for the whole run: staged, unstaged and untracked.
  # Nothing the scripts do may depend on it or disturb it.
  echo '// staged edit' >> "$CLONE/src/keep.ts"
  git -C "$CLONE" add src/keep.ts
  echo '// unstaged edit' >> "$CLONE/src/b.ts"
  echo 'scratch' > "$CLONE/scratch.local"

  CLONE_NOHEAD="$TMP/clone-nohead"
  git clone -q "file://$ORIGIN" "$CLONE_NOHEAD"
  git -C "$CLONE_NOHEAD" checkout -q feature
  git -C "$CLONE_NOHEAD" symbolic-ref -d refs/remotes/origin/HEAD 2>/dev/null \
    || git -C "$CLONE_NOHEAD" update-ref -d refs/remotes/origin/HEAD

  CLONE_WIP="$TMP/clone-wip"
  git clone -q "file://$ORIGIN" "$CLONE_WIP"
  git -C "$CLONE_WIP" checkout -q feature
  echo 'export const WIP_UNCOMMITTED_MARKER = 1;' >> "$CLONE_WIP/src/b.ts"
  echo 'scratch notes' > "$CLONE_WIP/wip-untracked.txt"
}

# A clone whose fetch refspec covers main alone: `git fetch origin` brings down
# no other branch and no pull ref, so anything else has to be asked for by name.
single_branch_clone() { # <path>
  rm -rf "$1"
  git clone -q --single-branch --branch main "file://$ORIGIN" "$1" \
    || fail "fixture: single-branch clone failed"
}

build_consumer_repo() {
  # The default branch is deliberately not "main" or "master": a script that
  # hardcodes either name fails here.
  CONSUMER_ORIGIN="$TMP/consumer-origin.git"
  CSEED="$TMP/consumer-seed"
  git init --bare -q -b trunk "$CONSUMER_ORIGIN"
  git init -q -b trunk "$CSEED"
  git -C "$CSEED" remote add origin "file://$CONSUMER_ORIGIN"
  echo 'module.exports = 1;' > "$CSEED/index.js"
  git -C "$CSEED" add -A && git -C "$CSEED" commit -q -m "consumer v1"
  CONSUMER_RELEASE_SHA=$(git -C "$CSEED" rev-parse HEAD)
  git -C "$CSEED" branch release-1
  echo 'module.exports = 2;' > "$CSEED/index.js"
  git -C "$CSEED" commit -q -am "consumer v2"
  CONSUMER_TRUNK_SHA=$(git -C "$CSEED" rev-parse HEAD)
  git -C "$CSEED" push -q origin trunk release-1

  CONSUMER="$TMP/consumer"
  git clone -q "file://$CONSUMER_ORIGIN" "$CONSUMER"
  git -C "$CONSUMER" checkout -q -b wip-random-123
  echo 'module.exports = 3;' > "$CONSUMER/index.js"
  git -C "$CONSUMER" commit -q -am "local only work"
  CONSUMER_LOCAL_SHA=$(git -C "$CONSUMER" rev-parse HEAD)
  echo '// dirty' >> "$CONSUMER/index.js"
  echo 'junk' > "$CONSUMER/junk.local"
}

PR_TITLE='Fix "off by one" | edge case'
PR_BODY='First line of the body.
Second line has `backticks`, a | pipe and $(echo pwned) left as text.'

write_pr_fixture() { # <gh dir> <number> <base> <head ref> <head oid> <cross true|false>
  jq -n \
    --arg base "$3" --arg head "$4" --arg oid "$5" \
    --arg title "$PR_TITLE" --arg body "$PR_BODY" \
    --argjson cross "$6" --argjson num "$2" \
    '{ number: $num, baseRefName: $base, headRefName: $head, headRefOid: $oid,
       isCrossRepository: $cross, title: $title, body: $body, state: "OPEN",
       url: ("https://example.invalid/fake/fake/pull/" + ($num|tostring)) }' \
    > "$1/pr-$2.json"
}

write_repo_fixture() { # <gh dir> <default branch>
  jq -n --arg b "$2" \
    '{ defaultBranchRef: { name: $b }, name: "target", owner: { login: "fake" } }' \
    > "$1/repo.json"
}

# A REVIEW_DIR as scope.sh is documented to leave it, built by hand so that the
# ledger, anchor, post-review and cleanup tests do not depend on scope.sh.
write_meta() { # <review dir> <head sha> <pr number>
  jq -n \
    --arg repo "$CLONE" --arg head "$2" --arg base "$MB_SHA" \
    --arg title "$PR_TITLE" --arg body "$PR_BODY" --argjson num "$3" \
    '{ target: ($num|tostring), repo: $repo, repoName: "target",
       ownerRepo: "acme/widgets", baseRef: "main",
       headSha: $head, baseSha: $base, prNumber: $num, isCrossRepository: false,
       title: $title, body: $body, wip: false, untracked: [],
       diffLines: 9, diffFiles: 3, fanout: 4 }' \
    > "$1/meta.json"
}

review_dir_with_diff() { # <review dir> - three-dot diff plus meta.json and a line map
  mkdir -p "$1"
  git -C "$CLONE" diff "origin/main...origin/feature" > "$1/diff.patch" \
    || fail "fixture: could not build the three-dot diff"
  write_meta "$1" "$FEATURE_SHA" 11
  patch_map "$1/diff.patch" > "$1/map.tsv"
  [ -s "$1/map.tsv" ] || fail "fixture: the diff produced no line map"
}

new_rd() { # per-test REVIEW_DIR, named after the test
  RD="$TMP/rd/$CUR"
  rm -rf "$RD"
  mkdir -p "$RD"
  export REVIEW_DIR="$RD"
}

new_gh() { # per-test fake gh state, named after the test
  GHD="$TMP/gh/$CUR"
  rm -rf "$GHD"
  mkdir -p "$GHD"
  export FAKE_GH_DIR="$GHD"
  write_repo_fixture "$GHD" main
}

clone_state() { # <clone> - branch, head, worktree and index content in one string
  printf '%s|%s|%s|%s' \
    "$(git -C "$1" rev-parse --abbrev-ref HEAD)" \
    "$(git -C "$1" rev-parse HEAD)" \
    "$(git -C "$1" status --porcelain)" \
    "$(git -C "$1" diff --cached)"
}

# =============================================================== scope.sh ====

test_scope_pr_meta_fields() {
  need scope.sh
  new_rd; new_gh
  write_pr_fixture "$GHD" 11 main feature "$FEATURE_SHA" false
  sh_run scope.sh --repo "$CLONE" 11
  assert_ok "scope.sh on PR 11"
  assert_file "$RD/meta.json" "meta.json"
  jq -e . "$RD/meta.json" >/dev/null 2>&1 || fail "meta.json is not valid JSON"

  assert_contains "11" "$(jqf "$RD/meta.json" .target)" "meta.target names the PR"
  metarepo=$(jqf "$RD/meta.json" .repo)
  [ -n "$metarepo" ] && [ -d "$metarepo" ] || fail "meta.repo is not a directory: [$metarepo]"
  assert_eq "$(cd "$CLONE" && pwd -P)" "$(cd "$metarepo" && pwd -P)" "meta.repo"
  [ -n "$(jqf "$RD/meta.json" .repoName)" ] || fail "meta.repoName is empty"
  assert_eq "main" "$(jqf "$RD/meta.json" .baseRef)" "meta.baseRef"
  assert_eq "$FEATURE_SHA" "$(jqf "$RD/meta.json" .headSha)" "meta.headSha"
  assert_eq "$MB_SHA" "$(jqf "$RD/meta.json" .baseSha)" "meta.baseSha is the merge base"
  assert_eq "11" "$(jqf "$RD/meta.json" .prNumber)" "meta.prNumber"
  assert_eq "false" "$(jqf "$RD/meta.json" .isCrossRepository)" "meta.isCrossRepository"
  assert_eq "$PR_TITLE" "$(jqf "$RD/meta.json" .title)" "meta.title kept verbatim"
  assert_contains 'echo pwned' "$(jqf "$RD/meta.json" .body)" "meta.body kept verbatim"
  assert_eq "false" "$(jqf "$RD/meta.json" .wip)" "meta.wip"
  assert_eq "0" "$(jqf "$RD/meta.json" '.untracked | length')" "meta.untracked is empty"
  assert_eq "3" "$(jqf "$RD/meta.json" .diffFiles)" "meta.diffFiles"
  dl=$(jqf "$RD/meta.json" .diffLines)
  [ "$dl" -gt 0 ] 2>/dev/null || fail "meta.diffLines is not a positive number: [$dl]"
}

test_scope_pr_diff_is_three_dot() {
  need scope.sh
  new_rd; new_gh
  write_pr_fixture "$GHD" 11 main feature "$FEATURE_SHA" false
  sh_run scope.sh --repo "$CLONE" 11
  assert_ok "scope.sh on PR 11"
  assert_file "$RD/diff.patch" "diff.patch"
  patch=$(cat "$RD/diff.patch")
  two_dot=$(git -C "$CLONE" diff origin/main origin/feature)
  assert_contains "keep.ts" "$two_dot" "fixture check: a two-dot diff must show keep.ts"
  assert_not_contains "keep.ts" "$patch" "three-dot diff must not show the base branch commit"
  assert_contains "src/a.ts" "$patch" "diff.patch covers the changed files"
  assert_contains "addedOne" "$patch" "diff.patch contains the added lines"
  assert_contains "doomedOne" "$patch" "diff.patch contains the deleted lines"
}

test_scope_pr_worktree_detached_at_head() {
  need scope.sh
  new_rd; new_gh
  write_pr_fixture "$GHD" 11 main feature "$FEATURE_SHA" false
  sh_run scope.sh --repo "$CLONE" 11
  assert_ok "scope.sh on PR 11"
  name=$(jqf "$RD/meta.json" .repoName)
  [ -n "$name" ] || fail "meta.repoName is empty, cannot locate the worktree"
  wt="$RD/wt/$name"
  assert_dir "$wt" "worktree directory"
  assert_eq "$FEATURE_SHA" "$(git -C "$wt" rev-parse HEAD)" "worktree head"
  if git -C "$wt" symbolic-ref -q HEAD >/dev/null 2>&1; then
    fail "worktree is on a branch, it must be detached"
  fi
  assert_contains "addedOne" "$(cat "$wt/src/a.ts")" "worktree holds the head content"
}

test_scope_pr_worktrees_tsv_line() {
  need scope.sh
  new_rd; new_gh
  write_pr_fixture "$GHD" 11 main feature "$FEATURE_SHA" false
  sh_run scope.sh --repo "$CLONE" 11
  assert_ok "scope.sh on PR 11"
  assert_file "$RD/worktrees.tsv" "worktrees.tsv"
  lines=$(grep -c . "$RD/worktrees.tsv")
  assert_eq "1" "$lines" "worktrees.tsv line count"
  fields=$(awk -F'\t' '{ print NF; exit }' "$RD/worktrees.tsv")
  assert_eq "3" "$fields" "worktrees.tsv tab-separated field count"
  c=$(awk -F'\t' '{ print $1; exit }' "$RD/worktrees.tsv")
  w=$(awk -F'\t' '{ print $2; exit }' "$RD/worktrees.tsv")
  r=$(awk -F'\t' '{ print $3; exit }' "$RD/worktrees.tsv")
  assert_eq "$(cd "$CLONE" && pwd -P)" "$(cd "$c" && pwd -P)" "worktrees.tsv clone path"
  assert_dir "$w" "worktrees.tsv worktree path"
  [ -n "$r" ] || fail "worktrees.tsv ref field is empty"
}

test_scope_fanout_small_diff_is_4() {
  need scope.sh
  new_rd; new_gh
  write_pr_fixture "$GHD" 11 main feature "$FEATURE_SHA" false
  sh_run scope.sh --repo "$CLONE" 11
  assert_ok "scope.sh on PR 11"
  assert_eq "4" "$(jqf "$RD/meta.json" .fanout)" "fanout for a 9-line diff"
}

test_scope_prints_a_summary() {
  need scope.sh
  new_rd; new_gh
  write_pr_fixture "$GHD" 11 main feature "$FEATURE_SHA" false
  sh_run scope.sh --repo "$CLONE" 11
  assert_ok "scope.sh on PR 11"
  assert_contains "$FEATURE_SHA" "$CAP_OUT" "the summary prints the head SHA"
  name=$(jqf "$RD/meta.json" .repoName)
  [ -n "$name" ] || fail "meta.repoName is empty"
  assert_contains "$RD/wt/$name" "$CAP_OUT" "the summary prints the worktree path"
  assert_contains "main" "$CAP_OUT" "the summary prints the base"
}

test_scope_fanout_medium_diff_is_6() {
  need scope.sh
  new_rd; new_gh
  sh_run scope.sh --repo "$CLONE" --base main medfeature
  assert_ok "scope.sh on medfeature"
  assert_eq "6" "$(jqf "$RD/meta.json" .fanout)" "fanout for a 400-line diff"
}

test_scope_fanout_large_diff_is_8() {
  need scope.sh
  new_rd; new_gh
  sh_run scope.sh --repo "$CLONE" --base main bigfeature
  assert_ok "scope.sh on bigfeature"
  assert_eq "8" "$(jqf "$RD/meta.json" .fanout)" "fanout for a 3000-line diff"
}

test_scope_cross_repository_pr_fetches_pull_head() {
  need scope.sh
  new_rd; new_gh
  write_pr_fixture "$GHD" 7 main "contributor:fork-branch" "$FORK_SHA" true
  if git -C "$CLONE" cat-file -e "$FORK_SHA^{commit}" 2>/dev/null; then
    fail "fixture check: the fork head must be absent from the clone before scope.sh runs"
  fi
  sh_run scope.sh --repo "$CLONE" 7
  assert_ok "scope.sh on cross-repository PR 7"
  assert_eq "true" "$(jqf "$RD/meta.json" .isCrossRepository)" "meta.isCrossRepository"
  assert_eq "$FORK_SHA" "$(jqf "$RD/meta.json" .headSha)" "meta.headSha is the fork head"
  name=$(jqf "$RD/meta.json" .repoName)
  [ -n "$name" ] || fail "meta.repoName is empty"
  assert_eq "$FORK_SHA" "$(git -C "$RD/wt/$name" rev-parse HEAD)" "worktree sits at the fork head"
  assert_file "$RD/wt/$name/src/fork.ts" "the fork-only file is in the worktree"
}

test_scope_branch_target_with_base() {
  need scope.sh
  new_rd; new_gh
  sh_run scope.sh --repo "$CLONE" --base main feature
  assert_ok "scope.sh on branch feature with --base main"
  assert_eq "$FEATURE_SHA" "$(jqf "$RD/meta.json" .headSha)" "head is origin/feature"
  assert_eq "$MB_SHA" "$(jqf "$RD/meta.json" .baseSha)" "base sha is the merge base"
  assert_contains "main" "$(jqf "$RD/meta.json" .baseRef)" "meta.baseRef"
  assert_not_contains "keep.ts" "$(cat "$RD/diff.patch")" "branch diff is three-dot"
}

test_scope_branch_target_without_base_uses_origin_head() {
  need scope.sh
  new_rd; new_gh
  sh_run scope.sh --repo "$CLONE" feature
  assert_ok "scope.sh on branch feature without --base"
  assert_contains "main" "$(jqf "$RD/meta.json" .baseRef)" "base falls back to the default branch"
  assert_eq "$MB_SHA" "$(jqf "$RD/meta.json" .baseSha)" "base sha is the merge base"
}

test_scope_branch_default_falls_back_to_gh() {
  need scope.sh
  new_rd; new_gh
  # This clone has no refs/remotes/origin/HEAD, so the default branch can only
  # come from `gh repo view`.
  if git -C "$CLONE_NOHEAD" symbolic-ref -q refs/remotes/origin/HEAD >/dev/null 2>&1; then
    fail "fixture check: clone-nohead still has refs/remotes/origin/HEAD"
  fi
  sh_run scope.sh --repo "$CLONE_NOHEAD" feature
  assert_ok "scope.sh without origin/HEAD"
  assert_contains "main" "$(jqf "$RD/meta.json" .baseRef)" "base came from gh repo view"
  assert_file "$GHD/calls.log" "fake gh call log"
  assert_contains "repo view" "$(cat "$GHD/calls.log")" "gh repo view was used for the default branch"
}

test_scope_wip_applies_uncommitted_and_lists_untracked() {
  need scope.sh
  new_rd; new_gh
  before=$(clone_state "$CLONE_WIP")
  sh_run scope.sh --repo "$CLONE_WIP" --wip
  assert_ok "scope.sh --wip"
  assert_eq "true" "$(jqf "$RD/meta.json" .wip)" "meta.wip"
  untracked=$(jqf "$RD/meta.json" '.untracked | join(",")')
  assert_contains "wip-untracked.txt" "$untracked" "meta.untracked lists the untracked file"
  patch=$(cat "$RD/diff.patch")
  assert_contains "WIP_UNCOMMITTED_MARKER" "$patch" "the uncommitted change is in the diff"
  assert_not_contains "wip-untracked.txt" "$patch" "the untracked file is not in the diff"
  name=$(jqf "$RD/meta.json" .repoName)
  [ -n "$name" ] || fail "meta.repoName is empty"
  assert_file "$RD/wt/$name/src/b.ts" "worktree copy of the changed file"
  assert_contains "WIP_UNCOMMITTED_MARKER" "$(cat "$RD/wt/$name/src/b.ts")" \
    "the uncommitted change is applied inside the worktree"
  assert_eq "$before" "$(clone_state "$CLONE_WIP")" "the clone is unchanged by --wip"
}

test_scope_missing_review_dir_errors() {
  need scope.sh
  new_gh
  write_pr_fixture "$GHD" 11 main feature "$FEATURE_SHA" false
  unset REVIEW_DIR
  sh_run scope.sh --repo "$CLONE" 11
  assert_refused "scope.sh without REVIEW_DIR"
  assert_contains "REVIEW_DIR" "$CAP_OUT" "the error names REVIEW_DIR"
}

test_scope_refuses_a_second_different_target() {
  need scope.sh
  new_rd; new_gh
  sh_run scope.sh --repo "$CLONE" --base main feature
  assert_ok "first scope.sh run"
  first=$(cat "$RD/meta.json")
  sh_run scope.sh --repo "$CLONE" --base main bigfeature
  assert_refused "scope.sh on a second, different target in the same REVIEW_DIR"
  assert_eq "$first" "$(cat "$RD/meta.json")" "the first meta.json must survive"
}

test_scope_repo_flag_pointing_at_non_repo_errors() {
  need scope.sh
  new_rd; new_gh
  mkdir -p "$TMP/not-a-repo"
  sh_run scope.sh --repo "$TMP/not-a-repo" --base main feature
  assert_refused "scope.sh with --repo on a directory that is not a repository"
  assert_no_file "$RD/meta.json" "nothing is written for a bad --repo"
}

test_scope_leaves_the_clone_untouched() {
  need scope.sh
  new_rd; new_gh
  write_pr_fixture "$GHD" 11 main feature "$FEATURE_SHA" false
  before=$(clone_state "$CLONE")
  assert_contains "scratch.local" "$before" "fixture check: the clone is dirty before the run"
  sh_run scope.sh --repo "$CLONE" 11
  assert_ok "scope.sh on PR 11"
  assert_eq "$before" "$(clone_state "$CLONE")" \
    "branch, head, working tree and index must all be unchanged"
}

test_scope_target_and_wip_together_are_refused() {
  need scope.sh
  new_rd; new_gh
  sh_run scope.sh --repo "$CLONE" feature --wip
  assert_refused "scope.sh given a branch and --wip in the same call"
  assert_no_file "$RD/meta.json" "nothing is scoped when two targets were named"
}

test_scope_single_branch_clone_reaches_the_branch() {
  need scope.sh
  new_rd; new_gh
  sbc="$TMP/sbc-$CUR"
  single_branch_clone "$sbc"
  if git -C "$sbc" rev-parse --verify --quiet refs/remotes/origin/feature >/dev/null 2>&1; then
    fail "fixture check: the single-branch clone already tracks feature"
  fi
  sh_run scope.sh --repo "$sbc" --base main feature
  assert_ok "scope.sh on a branch a single-branch clone does not track"
  assert_eq "$FEATURE_SHA" "$(jqf "$RD/meta.json" .headSha)" "head is the branch tip"
  assert_eq "$MB_SHA" "$(jqf "$RD/meta.json" .baseSha)" "base sha is the merge base"
  assert_contains "addedOne" "$(cat "$RD/diff.patch")" "the diff holds the branch's added lines"
  if git -C "$sbc" rev-parse --verify --quiet refs/remotes/origin/feature >/dev/null 2>&1; then
    fail "the fetch must not invent a remote-tracking branch in the clone"
  fi
}

test_scope_single_branch_clone_reaches_the_pr_head() {
  need scope.sh
  new_rd; new_gh
  write_pr_fixture "$GHD" 11 main feature "$FEATURE_SHA" false
  sbc="$TMP/sbc-$CUR"
  single_branch_clone "$sbc"
  if git -C "$sbc" cat-file -e "$FEATURE_SHA^{commit}" 2>/dev/null; then
    fail "fixture check: the single-branch clone must not already hold the PR head"
  fi
  sh_run scope.sh --repo "$sbc" 11
  assert_ok "scope.sh on a same-repository PR in a single-branch clone"
  assert_eq "$FEATURE_SHA" "$(jqf "$RD/meta.json" .headSha)" "meta.headSha is the PR head"
  name=$(jqf "$RD/meta.json" .repoName)
  [ -n "$name" ] || fail "meta.repoName is empty"
  assert_eq "$FEATURE_SHA" "$(git -C "$RD/wt/$name" rev-parse HEAD)" "the worktree sits at the PR head"
}

test_scope_wip_applies_a_binary_change() {
  need scope.sh
  new_rd; new_gh
  c="$TMP/wip-binary-$CUR"
  rm -rf "$c"
  git clone -q "file://$ORIGIN" "$c" || fail "fixture: clone failed"
  git -C "$c" checkout -q feature
  printf 'AAAA\000\001\002BBBB\n' > "$c/src/blob.bin"
  git -C "$c" add src/blob.bin || fail "fixture: could not stage the binary file"
  git -C "$c" commit -q -m "add a binary fixture" || fail "fixture: could not commit the binary file"
  printf 'CCCC\000\377\376DDDD\n' > "$c/src/blob.bin"
  sh_run scope.sh --repo "$c" --wip
  assert_ok "scope.sh --wip with an uncommitted binary change"
  name=$(jqf "$RD/meta.json" .repoName)
  [ -n "$name" ] || fail "meta.repoName is empty"
  assert_file "$RD/wt/$name/src/blob.bin" "the binary file reached the worktree"
  cmp -s "$c/src/blob.bin" "$RD/wt/$name/src/blob.bin" \
    || fail "the worktree copy of the binary file does not match the working tree"
}

test_scope_paths_with_spaces_are_handled() {
  need scope.sh
  need ledger.sh
  new_gh
  RD="$TMP/rd/$CUR with space"
  rm -rf "$RD"
  mkdir -p "$RD"
  export REVIEW_DIR="$RD"
  c="$TMP/clone with space $CUR"
  rm -rf "$c"
  git clone -q "file://$ORIGIN" "$c" || fail "fixture: clone failed"
  git -C "$c" checkout -q feature
  sh_run scope.sh --repo "$c" --base main feature
  assert_ok "scope.sh with a space in REVIEW_DIR and in the clone path"
  name=$(jqf "$RD/meta.json" .repoName)
  assert_eq "clone with space $CUR" "$name" "repoName keeps the spaces"
  assert_dir "$RD/wt/$name" "the worktree directory"
  assert_contains "$TAB" "$(cat "$RD/worktrees.tsv")" "worktrees.tsv stays tab separated"
  sh_run ledger.sh add line-by-line src/a.ts NEW:18 "a candidate"
  assert_ok "ledger.sh add with a spaced REVIEW_DIR"
  assert_file "$RD/candidates.md" "candidates.md"
}

test_scope_killed_after_worktree_add_recovers() {
  need scope.sh
  new_rd; new_gh
  name=$(basename "$CLONE")
  killer_run scope.sh --repo "$CLONE" --base main feature
  [ "$CAP_RC" = "0" ] && fail "the killed run reported success"
  assert_dir "$RD/wt/$name" "the killed run left its worktree on disk"
  assert_no_file "$RD/worktrees.tsv" "fixture check: the kill landed before the record"
  assert_no_file "$RD/meta.json" "fixture check: the kill landed before meta.json"

  sh_run scope.sh --repo "$CLONE" --base main feature
  assert_ok "the next scope.sh run after a killed one"
  assert_no_dir "$RD/wt/$name-2" "the stranded worktree must be adopted, not passed over"
  assert_eq "1" "$(grep -c . "$RD/worktrees.tsv")" "worktrees.tsv line count"
  assert_eq "$RD/wt/$name" "$(awk -F'\t' '{ print $2; exit }' "$RD/worktrees.tsv")" \
    "the recorded worktree is the one the killed run created"
}

test_add_repo_killed_after_worktree_add_recovers() {
  need add-repo.sh
  new_rd; new_gh
  write_meta "$RD" "$FEATURE_SHA" 11
  name=$(basename "$CONSUMER")
  killer_run add-repo.sh "$CONSUMER"
  [ "$CAP_RC" = "0" ] && fail "the killed run reported success"
  assert_dir "$RD/wt/$name" "the killed run left its worktree on disk"
  assert_no_file "$RD/worktrees.tsv" "fixture check: the kill landed before the record"

  sh_run add-repo.sh "$CONSUMER"
  assert_ok "the next add-repo.sh run after a killed one"
  assert_no_dir "$RD/wt/$name-2" "the stranded worktree must be adopted, not passed over"
  assert_eq "1" "$(grep -c . "$RD/worktrees.tsv")" "worktrees.tsv line count"
  assert_eq "$RD/wt/$name" "$(awk -F'\t' '{ print $2; exit }' "$RD/worktrees.tsv")" \
    "the recorded worktree is the one the killed run created"
}

test_scope_two_runs_on_one_review_dir_both_succeed() {
  need scope.sh
  new_rd; new_gh
  name=$(basename "$CLONE")
  bg_run "$CUR-a" "$RD" scope.sh --repo "$CLONE" --base main feature
  bg_run "$CUR-b" "$RD" scope.sh --repo "$CLONE" --base main feature
  wait
  assert_eq "0" "$(bg_rc "$CUR-a")" "first run: $(bg_out "$CUR-a")"
  assert_eq "0" "$(bg_rc "$CUR-b")" "second run: $(bg_out "$CUR-b")"
  jq -e . "$RD/meta.json" >/dev/null 2>&1 || fail "meta.json is not valid JSON after the race"
  assert_eq "1" "$(grep -c . "$RD/worktrees.tsv")" "worktrees.tsv line count"
  assert_no_dir "$RD/wt/$name-2" "the two runs must share one worktree"
  assert_eq "$FEATURE_SHA" "$(git -C "$RD/wt/$name" rev-parse HEAD)" "the worktree head"
}

test_scope_two_review_dirs_on_one_clone_both_succeed() {
  need scope.sh
  new_rd; new_gh
  name=$(basename "$CLONE")
  RD2="$TMP/rd/$CUR-second"
  rm -rf "$RD2"; mkdir -p "$RD2"
  bg_run "$CUR-a" "$RD" scope.sh --repo "$CLONE" --base main feature
  bg_run "$CUR-b" "$RD2" scope.sh --repo "$CLONE" --base main feature
  wait
  assert_eq "0" "$(bg_rc "$CUR-a")" "first review: $(bg_out "$CUR-a")"
  assert_eq "0" "$(bg_rc "$CUR-b")" "second review: $(bg_out "$CUR-b")"
  assert_eq "$FEATURE_SHA" "$(git -C "$RD/wt/$name" rev-parse HEAD)" "first review's worktree"
  assert_eq "$FEATURE_SHA" "$(git -C "$RD2/wt/$name" rev-parse HEAD)" "second review's worktree"
  REVIEW_DIR="$RD2" bash "$SCRIPTS/cleanup.sh" >/dev/null 2>&1 \
    || fail "cleanup.sh could not clear the second review"
  export REVIEW_DIR="$RD"
}

test_lock_stale_from_a_dead_process_is_taken_over() {
  need ledger.sh
  new_rd
  sh_run ledger.sh add line-by-line src/a.ts NEW:18 "first candidate"
  assert_ok "first ledger add"
  # A lock whose holder is gone: the pid belonged to a shell that has exited.
  dead=$(sh -c 'echo $$')
  mkdir "$RD/.lock-ledger" || fail "could not plant a stale lock"
  printf '%s\n' "$dead" > "$RD/.lock-ledger/pid"
  start=$(date +%s)
  sh_run ledger.sh add line-by-line src/a.ts NEW:19 "second candidate"
  waited=$(( $(date +%s) - start ))
  assert_ok "the add that found a stale lock"
  [ "$waited" -lt 30 ] || fail "waited ${waited}s on a lock whose holder is gone"
  assert_eq "C2" "$(printf '%s' "$CAP_OUT" | tr -d ' ' | tail -1)" "the id after the takeover"
  assert_no_dir "$RD/.lock-ledger" "the lock is released again afterwards"
}

test_lock_held_by_a_live_process_is_waited_for() {
  need ledger.sh
  new_rd
  sh_run ledger.sh add line-by-line src/a.ts NEW:18 "first candidate"
  assert_ok "first ledger add"
  cat > "$RD/holder.sh" <<'HOLDER'
. "$1/lib.sh"
acr_lock ledger
: > "$REVIEW_DIR/holding"
sleep 4
: > "$REVIEW_DIR/holder-finished"
HOLDER
  bash "$RD/holder.sh" "$SCRIPTS" &
  holder=$!
  waited=0
  while [ ! -f "$RD/holding" ]; do
    sleep 0.1
    waited=$(( waited + 1 ))
    [ "$waited" -lt 100 ] || fail "the holder never took the lock"
  done
  start=$(date +%s)
  sh_run ledger.sh add line-by-line src/a.ts NEW:19 "second candidate"
  elapsed=$(( $(date +%s) - start ))
  wait "$holder" 2>/dev/null
  assert_ok "the add that waited for a live holder"
  assert_not_contains "taking over" "$CAP_OUT" "a lock with a live holder must not be taken over"
  [ "$elapsed" -ge 3 ] || fail "the add went through after ${elapsed}s, while the lock was still held"
  assert_file "$RD/holder-finished" "the holder finished its own work"
}

test_lock_signal_releases_it_and_stops_the_script() {
  need ledger.sh
  new_rd
  cat > "$RD/probe.sh" <<'PROBE'
. "$1/lib.sh"
acr_lock ledger
: > "$REVIEW_DIR/holding"
sleep 3
: > "$REVIEW_DIR/ran-on-without-the-lock"
PROBE
  bash "$RD/probe.sh" "$SCRIPTS" &
  probe=$!
  waited=0
  while [ ! -f "$RD/holding" ]; do
    sleep 0.1
    waited=$(( waited + 1 ))
    [ "$waited" -lt 100 ] || fail "the probe never took the lock"
  done
  kill -TERM "$probe" 2>/dev/null || fail "could not signal the probe"
  wait "$probe" 2>/dev/null
  rc=$?
  [ "$rc" != "0" ] || fail "a script stopped by SIGTERM exited 0"
  assert_no_dir "$RD/.lock-ledger" "the lock is released when the holder is signalled"
  sleep 3.5
  assert_no_file "$RD/ran-on-without-the-lock" \
    "a signalled holder must stop, not carry on with the lock released"
}

# ================================================================== lib.sh ===

test_owner_repo_parses_github_remote_urls() {
  need lib.sh
  new_rd
  r="$TMP/rd/$CUR-repo"
  rm -rf "$r"
  git init -q -b main "$r" || fail "fixture: git init failed"
  git -C "$r" remote add origin "https://github.com/acme/widgets.git" \
    || fail "fixture: remote add failed"
  check_owner_repo() { # <origin url> <expected owner/name>
    git -C "$r" remote set-url origin "$1" || fail "fixture: remote set-url failed"
    got=$( . "$SCRIPTS/lib.sh"; acr_owner_repo "$r" )
    assert_eq "$2" "$got" "owner/name from $1"
  }
  check_owner_repo "git@github.com:acme/widgets.git" "acme/widgets"
  check_owner_repo "https://github.com/acme/widgets" "acme/widgets"
  check_owner_repo "https://github.com/acme/widgets/" "acme/widgets"
  check_owner_repo "https://github.com/acme/widgets.git/" "acme/widgets"
  check_owner_repo "ssh://git@github.com/acme/widgets.git" "acme/widgets"
  check_owner_repo "file:///tmp/not-github.git" ""
}

# ============================================================= add-repo.sh ===

test_add_repo_default_ref_is_origin_default_branch() {
  need add-repo.sh
  new_rd; new_gh
  write_meta "$RD" "$FEATURE_SHA" 11
  assert_ne "$CONSUMER_TRUNK_SHA" "$CONSUMER_LOCAL_SHA" "fixture check: local branch differs from trunk"
  sh_run add-repo.sh "$CONSUMER"
  assert_ok "add-repo.sh with no ref"
  wt=$(printf '%s' "$CAP_OUT" | tr -d ' ' | tail -1)
  [ -n "$wt" ] && [ -d "$wt" ] || fail "add-repo.sh did not print an existing worktree path: [$wt]"
  assert_eq "$CONSUMER_TRUNK_SHA" "$(git -C "$wt" rev-parse HEAD)" \
    "the worktree must sit at origin's default branch, not the local branch"
  assert_ne "$CONSUMER_LOCAL_SHA" "$(git -C "$wt" rev-parse HEAD)" "not the dirty local branch"
  assert_file "$RD/worktrees.tsv" "worktrees.tsv"
  assert_contains "$CONSUMER" "$(cat "$RD/worktrees.tsv")" "worktrees.tsv records the clone"
}

test_add_repo_explicit_ref() {
  need add-repo.sh
  new_rd; new_gh
  write_meta "$RD" "$FEATURE_SHA" 11
  sh_run add-repo.sh "$CONSUMER" origin/release-1
  assert_ok "add-repo.sh with an explicit ref"
  wt=$(printf '%s' "$CAP_OUT" | tr -d ' ' | tail -1)
  [ -n "$wt" ] && [ -d "$wt" ] || fail "add-repo.sh did not print an existing worktree path: [$wt]"
  assert_eq "$CONSUMER_RELEASE_SHA" "$(git -C "$wt" rev-parse HEAD)" "worktree sits at the named ref"
}

test_add_repo_is_idempotent() {
  need add-repo.sh
  new_rd; new_gh
  write_meta "$RD" "$FEATURE_SHA" 11
  sh_run add-repo.sh "$CONSUMER"
  assert_ok "first add-repo.sh"
  first="$CAP_OUT"
  sh_run add-repo.sh "$CONSUMER"
  assert_ok "second add-repo.sh for the same clone"
  assert_contains "$(printf '%s' "$first" | tr -d ' ' | tail -1)" "$CAP_OUT" \
    "the second call prints the same worktree path"
  count=$(grep -c "$CONSUMER$TAB" "$RD/worktrees.tsv" 2>/dev/null)
  [ -n "$count" ] || count=0
  assert_eq "1" "$count" "worktrees.tsv keeps exactly one line for the clone"
}

test_add_repo_missing_clone_errors() {
  need add-repo.sh
  new_rd; new_gh
  write_meta "$RD" "$FEATURE_SHA" 11
  sh_run add-repo.sh "$TMP/no-such-clone"
  assert_refused "add-repo.sh on a path that does not exist"
  assert_no_dir "$RD/wt/no-such-clone" "no worktree is created for a missing clone"
}

# =============================================================== ledger.sh ===

test_ledger_add_returns_ids_in_order() {
  need ledger.sh
  new_rd
  sh_run ledger.sh add line-by-line src/a.ts NEW:18 "off by one in the loop bound"
  assert_ok "first ledger add"
  assert_eq "C1" "$(printf '%s' "$CAP_OUT" | tr -d ' ' | tail -1)" "first id"
  sh_run ledger.sh add removed-behavior src/a.ts OLD:18 "dropped guard is not restored"
  assert_ok "second ledger add"
  assert_eq "C2" "$(printf '%s' "$CAP_OUT" | tr -d ' ' | tail -1)" "second id"
  assert_file "$RD/candidates.md" "candidates.md"
  body=$(cat "$RD/candidates.md")
  assert_contains "C1" "$body" "candidates.md holds C1"
  assert_contains "C2" "$body" "candidates.md holds C2"
  assert_contains "off by one in the loop bound" "$body" "candidates.md holds the summary"
}

test_ledger_summary_with_pipe_round_trips() {
  need ledger.sh
  new_rd
  sum='matches a|b|c and then | stops'
  sh_run ledger.sh add line-by-line src/a.ts NEW:18 "$sum"
  assert_ok "ledger add with pipes in the summary"
  head1=$(head -1 "$RD/candidates.md")
  printf '%s' "$head1" | grep -qi 'summary' \
    || fail "candidates.md has no header row naming the columns"
  row=$(grep 'C1' "$RD/candidates.md" | head -1)
  [ -n "$row" ] || fail "no row for C1 in candidates.md"
  # Unescaped pipes are the column separators, so a summary pipe must be escaped
  # or the row gains a column the header does not have.
  assert_eq "$(unescaped_pipes "$head1")" "$(unescaped_pipes "$row")" \
    "the candidate row has the same column count as the header"
  restored=$(printf '%s' "$row" | sed 's/\\|/|/g')
  assert_contains "$sum" "$restored" "the summary survives unescaping"
  sh_run ledger.sh list
  assert_ok "ledger list"
  assert_contains "$sum" "$(printf '%s' "$CAP_OUT" | sed 's/\\|/|/g')" "list prints the summary back"
}

test_ledger_set_bad_status_is_refused() {
  need ledger.sh
  new_rd
  sh_run ledger.sh add line-by-line src/a.ts NEW:18 "a candidate"
  assert_ok "ledger add"
  sh_run ledger.sh set C1 probably-fine "some evidence"
  assert_refused "ledger set with a status that is not in the list"
  assert_not_contains "probably-fine" "$(cat "$RD/candidates.md")" "the bad status is not written"
  assert_contains "new" "$(cat "$RD/candidates.md")" "the original status survives"
}

test_ledger_set_unknown_id_is_refused() {
  need ledger.sh
  new_rd
  sh_run ledger.sh add line-by-line src/a.ts NEW:18 "a candidate"
  assert_ok "ledger add"
  sh_run ledger.sh set C99 CONFIRMED "evidence"
  assert_refused "ledger set on an id that does not exist"
  assert_not_contains "C99" "$(cat "$RD/candidates.md")" "no row is invented for the unknown id"
}

test_ledger_list_filters_by_status() {
  need ledger.sh
  new_rd
  sh_run ledger.sh add line-by-line src/a.ts NEW:18 "first candidate"
  assert_ok "add C1"
  sh_run ledger.sh add reuse src/b.ts NEW:21 "second candidate"
  assert_ok "add C2"
  sh_run ledger.sh add efficiency src/b.ts NEW:22 "third candidate"
  assert_ok "add C3"
  sh_run ledger.sh set C1 CONFIRMED "ran the snippet"
  assert_ok "set C1 CONFIRMED"
  sh_run ledger.sh set C2 cut "duplicate"
  assert_ok "set C2 cut"
  sh_run ledger.sh list CONFIRMED
  assert_ok "list CONFIRMED"
  assert_contains "first candidate" "$CAP_OUT" "the confirmed row is listed"
  assert_not_contains "second candidate" "$CAP_OUT" "the cut row is not listed"
  assert_not_contains "third candidate" "$CAP_OUT" "the new row is not listed"
}

test_ledger_summary_with_leading_dash_and_quotes() {
  need ledger.sh
  new_rd
  sum='-n "quoted" $(echo pwned) and '"'"'single'"'"' text'
  sh_run ledger.sh add conventions src/a.ts NEW:18 "$sum"
  assert_ok "ledger add with a summary that starts with a dash"
  body=$(cat "$RD/candidates.md")
  assert_contains '-n ' "$body" "the leading dash is kept, not eaten as a flag"
  assert_contains 'echo pwned' "$body" "the summary is stored as text, not evaluated"
  assert_contains '"quoted"' "$body" "double quotes survive"
  assert_contains "'single'" "$body" "single quotes survive"
}

test_ledger_parallel_adds_get_distinct_ids() {
  need ledger.sh
  new_rd
  out="$TMP/rd/$CUR-out"
  rm -rf "$out"
  mkdir -p "$out"
  i=1
  while [ "$i" -le 20 ]; do
    bash "$SCRIPTS/ledger.sh" add line-by-line "src/f$i.ts" "NEW:$i" "candidate $i" \
      > "$out/$i" 2>&1 &
    i=$(( i + 1 ))
  done
  wait
  distinct=$(cat "$out"/* | tr -d ' ' | grep '^C[0-9][0-9]*$' | sort -u | wc -l | tr -d ' ')
  assert_eq "20" "$distinct" "20 parallel adds must hand out 20 distinct ids"
  rows=$(grep -c '^| C' "$RD/candidates.md")
  assert_eq "20" "$rows" "the table holds one row per add"
  assert_no_dir "$RD/.lock-ledger" "the lock is released when the last add finishes"
}

# =============================================================== anchor.sh ===

test_anchor_added_line_is_right() {
  need anchor.sh
  new_rd
  review_dir_with_diff "$RD"
  n=$(map_first "$RD/map.tsv" src/a.ts add 4)
  [ -n "$n" ] || fail "fixture: no added line found for src/a.ts"
  sh_run anchor.sh src/a.ts "NEW:$n"
  assert_ok "anchor on an added line"
  assert_contains "side=RIGHT" "$CAP_OUT" "added line anchors on RIGHT"
  assert_contains "line=$n" "$CAP_OUT" "the reported line number"
}

test_anchor_deleted_line_is_left() {
  need anchor.sh
  new_rd
  review_dir_with_diff "$RD"
  n=$(map_first "$RD/map.tsv" src/a.ts del 3)
  [ -n "$n" ] || fail "fixture: no deleted line found for src/a.ts"
  sh_run anchor.sh src/a.ts "OLD:$n"
  assert_ok "anchor on a deleted line"
  assert_contains "side=LEFT" "$CAP_OUT" "deleted line anchors on LEFT"
  assert_contains "line=$n" "$CAP_OUT" "the reported line number"
}

test_anchor_context_line_new_is_right() {
  need anchor.sh
  new_rd
  review_dir_with_diff "$RD"
  n=$(map_first "$RD/map.tsv" src/a.ts ctx 4)
  [ -n "$n" ] || fail "fixture: no context line found for src/a.ts"
  sh_run anchor.sh src/a.ts "NEW:$n"
  assert_ok "anchor on a context line, new side"
  assert_contains "side=RIGHT" "$CAP_OUT" "context lines are valid on RIGHT"
}

test_anchor_context_line_old_is_refused() {
  need anchor.sh
  new_rd
  review_dir_with_diff "$RD"
  n=$(map_first "$RD/map.tsv" src/a.ts ctx 3)
  [ -n "$n" ] || fail "fixture: no context line found for src/a.ts"
  sh_run anchor.sh src/a.ts "OLD:$n"
  assert_refused "anchor on a context line, old side"
}

test_anchor_line_outside_a_hunk_is_refused() {
  need anchor.sh
  new_rd
  review_dir_with_diff "$RD"
  maxn=$(map_max_new "$RD/map.tsv" src/a.ts)
  [ "$maxn" -gt 0 ] 2>/dev/null || fail "fixture: no new lines mapped for src/a.ts"
  outside=$(( maxn + 5 ))
  total=$(git -C "$CLONE" show "origin/feature:src/a.ts" | wc -l | tr -d ' ')
  [ "$outside" -lt "$total" ] || fail "fixture: line $outside is past the end of the file ($total lines)"
  sh_run anchor.sh src/a.ts "NEW:$outside"
  assert_refused "anchor on a line that is in the file but outside every hunk"
}

test_anchor_file_not_in_diff_is_refused() {
  need anchor.sh
  new_rd
  review_dir_with_diff "$RD"
  assert_not_contains "keep.ts" "$(cat "$RD/diff.patch")" "fixture check: keep.ts is not in the diff"
  sh_run anchor.sh src/keep.ts NEW:5
  assert_refused "anchor on a file that is not in the diff"
}

test_anchor_prefix_path_does_not_match() {
  need anchor.sh
  new_rd
  review_dir_with_diff "$RD"
  bakline=$(map_first "$RD/map.tsv" src/a.ts.bak add 4)
  [ -n "$bakline" ] || fail "fixture: no added line found for src/a.ts.bak"
  maxa=$(map_max_new "$RD/map.tsv" src/a.ts)
  [ "$bakline" -gt "$maxa" ] 2>/dev/null \
    || fail "fixture: the two files' hunks overlap ($bakline vs $maxa)"
  sh_run anchor.sh src/a.ts.bak "NEW:$bakline"
  assert_ok "anchor on the longer path"
  assert_contains "side=RIGHT" "$CAP_OUT" "the longer path anchors normally"
  sh_run anchor.sh src/a.ts "NEW:$bakline"
  assert_refused "a path that is a prefix of another must not borrow its hunks"
}

# ========================================================== post-review.sh ===

post_input() { # <file> <comments json array>
  jq -n --argjson c "$2" \
    '{ event: "COMMENT", body: "Review summary.", comments: $c }' > "$1"
}

post_setup() { # builds REVIEW_DIR, gh fixtures and the line numbers used below
  new_rd; new_gh
  review_dir_with_diff "$RD"
  ADD_NEW=$(map_first "$RD/map.tsv" src/a.ts add 4)
  DEL_OLD=$(map_first "$RD/map.tsv" src/a.ts del 3)
  CTX_NEW=$(map_first "$RD/map.tsv" src/a.ts ctx 4)
  [ -n "$ADD_NEW" ] && [ -n "$DEL_OLD" ] && [ -n "$CTX_NEW" ] || fail "fixture: line map is incomplete"
  write_pr_fixture "$GHD" 11 main feature "$FEATURE_SHA" false
}

good_comments() {
  jq -n --argjson add "$ADD_NEW" --argjson del "$DEL_OLD" \
    '[ { path: "src/a.ts", line: $add, side: "RIGHT",
         body: "Use the helper here.\n```suggestion\n  const addedOne = a + 1;\n```" },
       { path: "src/a.ts", line: $del, side: "LEFT",
         body: "This guard was dropped." } ]'
}

test_post_dry_run_injects_commit_id() {
  need post-review.sh
  post_setup
  post_input "$RD/input-review.json" "$(good_comments)"
  sh_run post-review.sh "$RD/input-review.json" --dry-run
  assert_ok "post-review.sh --dry-run"
  json=$(extract_json "$CAP_OUT")
  printf '%s' "$json" | jq -e . >/dev/null 2>&1 || fail "--dry-run did not print valid JSON"
  assert_eq "$FEATURE_SHA" "$(printf '%s' "$json" | jq -r '.commit_id')" \
    "commit_id comes from meta.headSha"
  assert_eq "2" "$(printf '%s' "$json" | jq -r '.comments | length')" "both comments survive"
  assert_no_file "$GHD/posted.json" "--dry-run must not post"
  if [ -f "$GHD/calls.log" ]; then
    assert_not_contains "gh api" "$(cat "$GHD/calls.log")" "--dry-run must not call the API"
  fi
}

test_post_one_bad_anchor_aborts_and_posts_nothing() {
  need post-review.sh
  post_setup
  comments=$(jq -n --argjson add "$ADD_NEW" \
    '[ { path: "src/a.ts", line: $add, side: "RIGHT", body: "fine" },
       { path: "src/keep.ts", line: 5, side: "RIGHT", body: "this file is not in the diff" } ]')
  post_input "$RD/input-review.json" "$comments"
  sh_run post-review.sh "$RD/input-review.json"
  assert_refused "post-review.sh with one unanchorable comment"
  assert_contains "keep.ts" "$CAP_OUT" "the bad anchor is named"
  assert_no_file "$GHD/posted.json" "nothing is posted when an anchor fails"
}

test_post_head_moved_aborts() {
  need post-review.sh
  post_setup
  # The PR head moved after the diff was taken.
  write_pr_fixture "$GHD" 11 main feature "$MAIN_SHA" false
  post_input "$RD/input-review.json" "$(good_comments)"
  sh_run post-review.sh "$RD/input-review.json"
  assert_refused "post-review.sh when the PR head moved"
  assert_no_file "$GHD/posted.json" "nothing is posted against a stale head"
}

test_post_head_moved_with_force_posts() {
  need post-review.sh
  post_setup
  write_pr_fixture "$GHD" 11 main feature "$MAIN_SHA" false
  post_input "$RD/input-review.json" "$(good_comments)"
  sh_run post-review.sh "$RD/input-review.json" --force
  assert_ok "post-review.sh --force with a moved head"
  assert_file "$GHD/posted.json" "--force posts anyway"
  assert_eq "$FEATURE_SHA" "$(jqf "$GHD/posted.json" .commit_id)" \
    "the posted commit_id is still the diffed head"
}

test_post_start_line_not_before_line_is_refused() {
  need post-review.sh
  post_setup
  comments=$(jq -n --argjson add "$ADD_NEW" \
    '[ { path: "src/a.ts", start_line: $add, start_side: "RIGHT",
         line: $add, side: "RIGHT", body: "range that does not move forward" } ]')
  post_input "$RD/input-review.json" "$comments"
  sh_run post-review.sh "$RD/input-review.json"
  assert_refused "post-review.sh with start_line equal to line"
  assert_no_file "$GHD/posted.json" "nothing is posted for a bad range"
}

test_post_records_body_and_lists_comments() {
  need post-review.sh
  post_setup
  post_input "$RD/input-review.json" "$(good_comments)"
  sh_run post-review.sh "$RD/input-review.json"
  assert_ok "post-review.sh against a matching head"
  assert_file "$GHD/posted.json" "the review body reached the API"
  assert_eq "2" "$(jqf "$GHD/posted.json" '.comments | length')" "both comments were posted"
  assert_eq "$FEATURE_SHA" "$(jqf "$GHD/posted.json" .commit_id)" "commit_id was injected"
  assert_eq "COMMENT" "$(jqf "$GHD/posted.json" .event)" "the review event"
  assert_contains "src/a.ts" "$CAP_OUT" "the after-post listing names the file"
  assert_contains "side=RIGHT" "$CAP_OUT" "the after-post listing names the side"
  assert_contains "suggestion=yes" "$CAP_OUT" "the after-post listing flags the suggestion block"
}

test_post_body_only_review_is_posted() {
  need post-review.sh
  post_setup
  jq -n '{ event: "COMMENT", body: "Nothing to anchor.", comments: [] }' \
    > "$RD/input-review.json"
  sh_run post-review.sh "$RD/input-review.json"
  assert_ok "post-review.sh with an empty comments array"
  assert_file "$GHD/posted.json" "the body-only review reached the API"
  assert_eq "0" "$(jqf "$GHD/posted.json" '.comments | length')" "no comments were posted"
  assert_eq "$FEATURE_SHA" "$(jqf "$GHD/posted.json" .commit_id)" "commit_id was injected"
}

test_post_comments_must_be_a_list_of_objects() {
  need post-review.sh
  post_setup
  jq -n '{ event: "COMMENT", body: "Review summary.", comments: "oops" }' \
    > "$RD/input-review.json"
  sh_run post-review.sh "$RD/input-review.json"
  assert_refused "post-review.sh with comments that are not an array"
  assert_contains "comments" "$CAP_OUT" "the reason names the field"
  assert_not_contains "jq: error" "$CAP_OUT" "the reason is a sentence, not a raw jq error"
  assert_no_file "$GHD/posted.json" "nothing is posted"
}

test_post_empty_owner_repo_is_refused() {
  need post-review.sh
  post_setup
  # meta.ownerRepo gone, and meta.repo's origin is not a GitHub remote, so
  # owner/name cannot be re-derived either.
  jq 'del(.ownerRepo)' "$RD/meta.json" > "$RD/meta-no-owner.json" \
    || fail "fixture: could not rewrite meta.json"
  mv "$RD/meta-no-owner.json" "$RD/meta.json"
  assert_not_contains "github.com" "$(git -C "$CLONE" remote get-url origin)" \
    "fixture check: the clone's origin must not be a GitHub remote"
  post_input "$RD/input-review.json" "$(good_comments)"
  sh_run post-review.sh "$RD/input-review.json"
  assert_refused "post-review.sh without an owner/name to post to"
  assert_contains "ownerRepo" "$CAP_OUT" "the reason names the missing field"
  assert_no_file "$GHD/posted.json" "nothing is posted"
  if [ -f "$GHD/calls.log" ]; then
    assert_not_contains "gh api" "$(cat "$GHD/calls.log")" "the API is never called"
  fi
}

test_post_dry_run_needs_no_owner_repo() {
  need post-review.sh
  post_setup
  jq 'del(.ownerRepo)' "$RD/meta.json" > "$RD/meta-no-owner.json" \
    || fail "fixture: could not rewrite meta.json"
  mv "$RD/meta-no-owner.json" "$RD/meta.json"
  post_input "$RD/input-review.json" "$(good_comments)"
  sh_run post-review.sh "$RD/input-review.json" --dry-run
  assert_ok "post-review.sh --dry-run validates without a repository to post to"
  assert_no_file "$GHD/posted.json" "--dry-run must not post"
}

# ============================================================== cleanup.sh ===

cleanup_setup() { # two worktrees in two clones, recorded in worktrees.tsv
  new_rd; new_gh
  mkdir -p "$RD/wt"
  write_meta "$RD" "$FEATURE_SHA" 11
  git -C "$CLONE" worktree add --detach -q "$RD/wt/target" "$FEATURE_SHA" \
    || fail "fixture: could not add the target worktree"
  git -C "$CONSUMER" worktree add --detach -q "$RD/wt/consumer" "$CONSUMER_TRUNK_SHA" \
    || fail "fixture: could not add the consumer worktree"
  {
    printf '%s\t%s\t%s\n' "$CLONE" "$RD/wt/target" "$FEATURE_SHA"
    printf '%s\t%s\t%s\n' "$CONSUMER" "$RD/wt/consumer" "origin/trunk"
  } > "$RD/worktrees.tsv"
}

test_cleanup_removes_every_worktree() {
  need cleanup.sh
  cleanup_setup
  sh_run cleanup.sh
  assert_ok "cleanup.sh"
  assert_no_dir "$RD/wt/target" "the target worktree directory is gone"
  assert_no_dir "$RD/wt/consumer" "the consumer worktree directory is gone"
  assert_not_contains "$RD/wt/target" "$(git -C "$CLONE" worktree list)" \
    "the target worktree is deregistered"
  assert_not_contains "$RD/wt/consumer" "$(git -C "$CONSUMER" worktree list)" \
    "the consumer worktree is deregistered"
  assert_no_dir "$RD/wt" "wt/ is removed"
  assert_file "$RD/meta.json" "meta.json survives without --all"
}

test_cleanup_tolerates_an_already_removed_worktree() {
  need cleanup.sh
  cleanup_setup
  git -C "$CONSUMER" worktree remove --force "$RD/wt/consumer" \
    || fail "fixture: could not pre-remove the consumer worktree"
  assert_no_dir "$RD/wt/consumer" "fixture check: the consumer worktree is already gone"
  sh_run cleanup.sh
  assert_ok "cleanup.sh with one worktree already removed"
  assert_no_dir "$RD/wt/target" "the remaining worktree is still removed"
}

test_cleanup_never_prunes_other_sessions() {
  need cleanup.sh
  cleanup_setup
  # A stale worktree left behind by something else: the directory is gone but
  # the admin entry remains. `git worktree prune` would delete it.
  other="$TMP/other-session-xyz"
  git -C "$CLONE" worktree add --detach -q "$other" "$FEATURE_SHA" \
    || fail "fixture: could not add the other session's worktree"
  rm -rf "$other"
  admin="$CLONE/.git/worktrees/other-session-xyz"
  assert_dir "$admin" "fixture check: the stale admin entry exists before cleanup"
  sh_run cleanup.sh
  assert_ok "cleanup.sh"
  assert_dir "$admin" "another session's stale worktree entry must survive"
}

test_cleanup_prints_status_per_clone() {
  need cleanup.sh
  cleanup_setup
  sh_run cleanup.sh
  assert_ok "cleanup.sh"
  assert_contains "$CLONE" "$CAP_OUT" "the target clone is reported"
  assert_contains "$CONSUMER" "$CAP_OUT" "the consumer clone is reported"
  assert_contains "scratch.local" "$CAP_OUT" "the target clone's dirty state is visible"
  assert_contains "junk.local" "$CAP_OUT" "the consumer clone's dirty state is visible"
}

test_cleanup_all_removes_the_review_dir() {
  need cleanup.sh
  cleanup_setup
  sh_run cleanup.sh --all
  assert_ok "cleanup.sh --all"
  assert_no_dir "$RD/wt/target" "the target worktree directory is gone"
  assert_not_contains "$RD/wt/target" "$(git -C "$CLONE" worktree list)" \
    "the target worktree is deregistered before the directory goes"
  assert_no_dir "$RD" "--all removes REVIEW_DIR"
}

test_cleanup_reads_a_tsv_with_crlf_and_no_final_newline() {
  need cleanup.sh
  cleanup_setup
  # The last line's worktree sits outside wt/, so that removing wt/ wholesale
  # cannot stand in for having read the line.
  outside="$TMP/outside-$CUR"
  rm -rf "$outside"
  git -C "$CONSUMER" worktree add --detach -q "$outside" "$CONSUMER_TRUNK_SHA" \
    || fail "fixture: could not add the outside worktree"
  admin="$CONSUMER/.git/worktrees/outside-$CUR"
  assert_dir "$admin" "fixture check: the outside worktree is registered"
  # The record is about to be replaced by one that does not mention the
  # consumer worktree, so that worktree is deregistered first: this test is
  # about reading the file, not about leaving an entry behind.
  git -C "$CONSUMER" worktree remove --force "$RD/wt/consumer" \
    || fail "fixture: could not drop the consumer worktree"
  printf '%s\t%s\t%s\r\n%s\t%s\t%s' \
    "$CLONE" "$RD/wt/target" "$FEATURE_SHA" \
    "$CONSUMER" "$outside" "$CONSUMER_TRUNK_SHA" > "$RD/worktrees.tsv"
  sh_run cleanup.sh
  assert_ok "cleanup.sh on a tsv with a CRLF line and no newline on the last one"
  assert_no_dir "$RD/wt/target" "the CRLF-terminated line's worktree is gone"
  assert_no_dir "$outside" "the unterminated last line's worktree is gone"
  assert_no_dir "$admin" "the unterminated last line's worktree is deregistered"
}

test_cleanup_reports_a_clone_it_cannot_read() {
  need cleanup.sh
  new_rd; new_gh
  mkdir -p "$RD/wt"
  write_meta "$RD" "$FEATURE_SHA" 11
  notrepo="$TMP/rd/$CUR-notrepo"
  rm -rf "$notrepo"
  mkdir -p "$notrepo"
  printf '%s\t%s\t%s\n' "$notrepo" "$RD/wt/ghost" "$FEATURE_SHA" > "$RD/worktrees.tsv"
  sh_run cleanup.sh
  assert_refused "cleanup.sh when a recorded clone cannot report its status"
  assert_contains "$notrepo" "$CAP_OUT" "the clone that could not be read is named"
}

test_cleanup_run_twice_is_a_no_op() {
  need cleanup.sh
  cleanup_setup
  sh_run cleanup.sh
  assert_ok "first cleanup.sh"
  sh_run cleanup.sh
  assert_ok "second cleanup.sh over the same record"
  assert_no_dir "$RD/wt" "wt/ is still gone"
}

test_cleanup_without_a_review_dir_is_refused() {
  need cleanup.sh
  new_gh
  RD="$TMP/rd/$CUR"
  rm -rf "$RD"
  export REVIEW_DIR="$RD"
  sh_run cleanup.sh
  assert_refused "cleanup.sh on a REVIEW_DIR that is not there"
  assert_contains "REVIEW_DIR" "$CAP_OUT" "the reason names REVIEW_DIR"
}

test_cleanup_all_keeps_the_review_dir_when_a_removal_fails() {
  need cleanup.sh
  cleanup_setup
  # A recorded path git does not know as a worktree: its removal fails and the
  # directory is still there, which is the case cleanup.sh reports.
  mkdir -p "$RD/wt/not-a-worktree"
  printf '%s\t%s\t%s\n' "$CLONE" "$RD/wt/not-a-worktree" "$FEATURE_SHA" \
    >> "$RD/worktrees.tsv"
  sh_run cleanup.sh --all
  assert_refused "cleanup.sh --all with a worktree it cannot remove"
  assert_dir "$RD" "REVIEW_DIR is kept when something could not be removed"
  assert_file "$RD/worktrees.tsv" "the record of what to remove by hand survives"
  assert_dir "$RD/wt/not-a-worktree" "what could not be removed is left where it is"
}

test_post_many_comments_on_a_large_diff_stay_quick() {
  need post-review.sh
  need anchor.sh
  new_rd; new_gh
  write_meta "$RD" "$FEATURE_SHA" 11
  # 300 files of 200 added lines each: 60,000 changed lines. Validating one
  # comment at a time re-reads all of it per comment, which is the shape this
  # test exists to catch; the bound is loose enough for a slow machine and far
  # under what a re-read per comment costs.
  awk 'BEGIN {
    for (f = 1; f <= 300; f++) {
      printf "diff --git a/src/f%d.ts b/src/f%d.ts\n", f, f
      printf "new file mode 100644\n--- /dev/null\n+++ b/src/f%d.ts\n", f
      printf "@@ -0,0 +1,200 @@\n"
      for (i = 1; i <= 200; i++) printf "+export const v%d = %d;\n", i, i
    }
  }' > "$RD/diff.patch"
  # Every comment lands in the last file, so nothing can be answered early.
  jq -n '{ event: "COMMENT", body: "Review summary.",
           comments: [ range(1; 61) as $i
                       | { path: "src/f300.ts", start_line: $i, start_side: "RIGHT",
                           line: ($i + 100), side: "RIGHT", body: "c" } ] }' \
    > "$RD/input-review.json"
  start=$(date +%s)
  sh_run post-review.sh "$RD/input-review.json" --dry-run
  assert_ok "post-review.sh --dry-run over 60 comments on a 60,000 line diff"
  sh_run anchor.sh src/f300.ts NEW:200
  assert_ok "anchor.sh on the last line of the last file"
  elapsed=$(( $(date +%s) - start ))
  # Under a second when the diff is read once, about twenty when it is read
  # once per anchor.
  [ "$elapsed" -le 8 ] || fail "validating 60 comments took ${elapsed}s, the diff is read once per comment"
}

# ================================================================== runner ===

TESTS="
scope_pr_meta_fields
scope_pr_diff_is_three_dot
scope_pr_worktree_detached_at_head
scope_pr_worktrees_tsv_line
scope_prints_a_summary
scope_fanout_small_diff_is_4
scope_fanout_medium_diff_is_6
scope_fanout_large_diff_is_8
scope_cross_repository_pr_fetches_pull_head
scope_branch_target_with_base
scope_branch_target_without_base_uses_origin_head
scope_branch_default_falls_back_to_gh
scope_wip_applies_uncommitted_and_lists_untracked
scope_missing_review_dir_errors
scope_refuses_a_second_different_target
scope_repo_flag_pointing_at_non_repo_errors
scope_leaves_the_clone_untouched
scope_target_and_wip_together_are_refused
scope_single_branch_clone_reaches_the_branch
scope_single_branch_clone_reaches_the_pr_head
scope_wip_applies_a_binary_change
scope_paths_with_spaces_are_handled
scope_killed_after_worktree_add_recovers
scope_two_runs_on_one_review_dir_both_succeed
scope_two_review_dirs_on_one_clone_both_succeed
lock_stale_from_a_dead_process_is_taken_over
lock_held_by_a_live_process_is_waited_for
lock_signal_releases_it_and_stops_the_script
owner_repo_parses_github_remote_urls
add_repo_default_ref_is_origin_default_branch
add_repo_explicit_ref
add_repo_is_idempotent
add_repo_missing_clone_errors
add_repo_killed_after_worktree_add_recovers
ledger_add_returns_ids_in_order
ledger_summary_with_pipe_round_trips
ledger_set_bad_status_is_refused
ledger_set_unknown_id_is_refused
ledger_list_filters_by_status
ledger_summary_with_leading_dash_and_quotes
ledger_parallel_adds_get_distinct_ids
anchor_added_line_is_right
anchor_deleted_line_is_left
anchor_context_line_new_is_right
anchor_context_line_old_is_refused
anchor_line_outside_a_hunk_is_refused
anchor_file_not_in_diff_is_refused
anchor_prefix_path_does_not_match
post_dry_run_injects_commit_id
post_one_bad_anchor_aborts_and_posts_nothing
post_head_moved_aborts
post_head_moved_with_force_posts
post_start_line_not_before_line_is_refused
post_records_body_and_lists_comments
post_body_only_review_is_posted
post_comments_must_be_a_list_of_objects
post_empty_owner_repo_is_refused
post_dry_run_needs_no_owner_repo
cleanup_removes_every_worktree
cleanup_tolerates_an_already_removed_worktree
cleanup_never_prunes_other_sessions
cleanup_prints_status_per_clone
cleanup_all_removes_the_review_dir
cleanup_reads_a_tsv_with_crlf_and_no_final_newline
cleanup_reports_a_clone_it_cannot_read
cleanup_run_twice_is_a_no_op
cleanup_without_a_review_dir_is_refused
cleanup_all_keeps_the_review_dir_when_a_removal_fails
post_many_comments_on_a_large_diff_stay_quick
"

# Drops whatever worktrees a test left behind, using the record the scripts
# keep. Tests that exercise cleanup.sh are covered by the same record.
post_test_cleanup() {
  local rd
  for rd in "$TMP/rd/$1"*; do
    [ -f "$rd/worktrees.tsv" ] || continue
    local clone wt ref
    while IFS="$TAB" read -r clone wt ref; do
      [ -n "$clone" ] || continue
      [ -n "$wt" ] || continue
      if [ -d "$clone" ]; then
        git -C "$clone" worktree remove --force "$wt" >/dev/null 2>&1
      fi
      [ -d "$wt" ] && rm -rf "$wt"
    done < "$rd/worktrees.tsv"
  done
  return 0
}

# What a finished test may never leave behind: a worktree still registered in a
# clone, a lock directory, or one of the temporary files the scripts write next
# to their output. Every review directory a test uses starts with its name, so
# a registration is this test's leak when its path starts there.
leak_check() { # <test name>
  local prefix="$TMP/rd/$1" real="$TMP_REAL/rd/$1" gitdirs g target leaked=0 stray
  gitdirs=$(find "$TMP" -path '*/.git/worktrees/*/gitdir' -type f 2>/dev/null)
  for g in $gitdirs; do
    # git records the path with every symlink resolved, which on this platform
    # is not how the temporary directory is spelled.
    target=$(cat "$g" 2>/dev/null)
    case "$target" in
      "$prefix"*|"$real"*)
        echo "leak: $(dirname "$g") still registers a worktree under $prefix"
        leaked=1
        ;;
    esac
  done
  for stray in $(find "$TMP/rd" -maxdepth 2 \
                   \( -name '.lock-*' -o -name '.cleanup-*' -o -name '*.stale.*' \
                      -o -name 'worktrees.tsv.[0-9]*' -o -name 'candidates.md.[0-9]*' \) \
                   2>/dev/null); do
    case "$stray" in
      "$prefix"*) echo "leak: temporary file left behind: $stray"; leaked=1 ;;
    esac
  done
  [ "$leaked" = "0" ]
}

PASSED=0
FAILED=0
FAILED_NAMES=""

run_test() {
  CUR="$1"
  local log="$TMP/logs/$CUR.log"
  ( "test_$CUR" ) > "$log" 2>&1
  local rc=$?
  post_test_cleanup "$CUR"
  if [ "$rc" -eq 0 ]; then
    leak_check "$CUR" >> "$log" 2>&1 || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    echo "PASS $CUR"
    PASSED=$(( PASSED + 1 ))
  else
    local reason
    reason=$(grep -v '^[[:space:]]*$' "$log" | tail -1)
    [ -n "$reason" ] || reason="exited $rc with no output"
    echo "FAIL $CUR: $reason"
    FAILED=$(( FAILED + 1 ))
    FAILED_NAMES="$FAILED_NAMES $CUR"
    if [ "${VERBOSE:-0}" = "1" ]; then
      sed 's/^/    | /' "$log"
    fi
  fi
}

build_target_repo   || { echo "fixture setup failed (target repo)" >&2; exit 2; }
build_consumer_repo || { echo "fixture setup failed (consumer repo)" >&2; exit 2; }

if [ "${FIXTURES_ONLY:-0}" = "1" ]; then
  echo "fixtures built under $TMP"
  git -C "$CLONE" log --oneline --all | sed 's/^/  /'
  exit 0
fi

for t in $TESTS; do
  run_test "$t"
done

echo "TOTAL $(( PASSED + FAILED ))  PASS $PASSED  FAIL $FAILED"

# The scripts default --repo to the current directory. Catch the case where one
# of them walked out of the fixtures and into this repository.
if [ "$ROOT_IS_REPO" = "1" ]; then
  if [ "$ROOT_STATUS_BEFORE" != "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
    echo "ERROR: the suite changed the working tree of $ROOT" >&2
    exit 3
  fi
fi

[ "$FAILED" -eq 0 ]
