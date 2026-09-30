#!/usr/bin/env bash
# Shared helpers for the review pipeline scripts. Sourced, never run directly.
# Bash 3.2 compatible: no associative arrays, no mapfile, no ${var,,}.

# ------------------------------------------------------------------ basics --

acr_die() { printf '%s\n' "$*" >&2; exit 1; }

acr_warn() { printf '%s\n' "$*" >&2; }

# Fetch without letting git invent refs/remotes/<remote>/HEAD, which would be a
# write to the clone's ref store that the caller did not ask for.
acr_fetch() { # <clone> [extra fetch args...]
  local clone="$1"; shift
  git -C "$clone" -c remote.origin.followRemoteHEAD=never fetch --quiet origin "$@"
}

# ----------------------------------------------------------------- locking --

# Finders run in parallel, so any read-then-write of a shared file needs a lock.
# A directory is the portable one: mkdir is atomic on every filesystem here and
# flock is not installed on macOS.
ACR_LOCK_DIR=""

acr_lock() { # <name>
  local d="$REVIEW_DIR/.lock-$1" waited=0 missing=0 pid="" seen="" dead=0
  while ! mkdir "$d" 2>/dev/null; do
    # A single miss proves nothing: the holder can release the lock between the
    # mkdir and this test. Only a run of them means the path is unwritable.
    if [ -d "$d" ]; then
      missing=0
      # A process killed with SIGKILL runs no trap, so its lock outlives it and
      # would block every later run for the whole timeout. The holder's pid is
      # in the directory: when it names no live process for two seconds on the
      # trot, the lock is stale and this run takes it over. The counter resets
      # on any other reading, so a lock that has since been handed to a live
      # process, or one whose pid file is not written yet, is never stolen.
      pid=$(cat "$d/pid" 2>/dev/null || true)
      case "$pid" in
        ''|*[!0-9]*) dead=0; seen="" ;;
        *)
          if kill -0 "$pid" 2>/dev/null; then
            dead=0; seen=""
          else
            [ "$seen" = "$pid" ] || dead=0
            seen="$pid"
            dead=$(( dead + 1 ))
            if [ "$dead" -ge 20 ]; then
              acr_warn "taking over the $1 lock from process $pid, which is gone: $d"
              # One mover wins: the loser's rename finds nothing to move and it
              # goes back to waiting for whoever created the lock next.
              if mv "$d" "$d.stale.$$" 2>/dev/null; then rm -rf "$d.stale.$$"; fi
              dead=0; seen=""
              continue
            fi
          fi
          ;;
      esac
    else
      missing=$(( missing + 1 ))
      [ "$missing" -lt 20 ] || acr_die "cannot create the lock directory: $d"
    fi
    waited=$(( waited + 1 ))
    [ "$waited" -le 600 ] || acr_die "timed out after 60s waiting for the $1 lock, remove it by hand: $d"
    sleep 0.1
  done
  printf '%s\n' "$$" > "$d/pid" 2>/dev/null || true
  ACR_LOCK_DIR="$d"
  # A signal that only released the lock would leave this process running its
  # read-modify-write while the next one holds the lock, so the handlers stop
  # the script as well, with the conventional 128 + signal number.
  trap acr_unlock EXIT
  trap 'acr_unlock; exit 130' INT
  trap 'acr_unlock; exit 143' TERM
}

acr_unlock() {
  [ -n "$ACR_LOCK_DIR" ] || return 0
  rmdir "$ACR_LOCK_DIR" 2>/dev/null || rm -rf "$ACR_LOCK_DIR" 2>/dev/null || true
  ACR_LOCK_DIR=""
}

# ------------------------------------------------------------- REVIEW_DIR ---

# Requires REVIEW_DIR to be set. `create` also makes the directory.
acr_review_dir() { # [create]
  [ -n "${REVIEW_DIR:-}" ] || acr_die "REVIEW_DIR is not set"
  if [ "${1:-}" = "create" ]; then
    mkdir -p "$REVIEW_DIR" || acr_die "REVIEW_DIR cannot be created: $REVIEW_DIR"
  else
    [ -d "$REVIEW_DIR" ] || acr_die "REVIEW_DIR is not a directory: $REVIEW_DIR"
  fi
}

# Reads one field out of meta.json.
acr_meta() { # <jq expression>
  local f="$REVIEW_DIR/meta.json"
  [ -f "$f" ] || acr_die "meta.json is missing, run scope.sh first: $f"
  jq -r "$1" "$f" 2>/dev/null || acr_die "meta.json is not readable JSON: $f"
}

# ------------------------------------------------------------- worktrees ----

# The worktree already recorded for a clone, empty when there is none.
acr_wt_for_clone() { # <clone>
  local tsv; tsv="$REVIEW_DIR/worktrees.tsv"
  [ -f "$tsv" ] || return 0
  awk -F'\t' -v c="$1" '$1 == c { print $2; exit }' "$tsv"
}

# The clone that owns a worktree path, empty when the path is unclaimed.
acr_clone_for_wt() { # <worktree path>
  local tsv; tsv="$REVIEW_DIR/worktrees.tsv"
  [ -f "$tsv" ] || return 0
  awk -F'\t' -v w="$1" '$2 == w { print $1; exit }' "$tsv"
}

# True when <dir> is itself a worktree of <clone>: both name the same shared
# git directory. A plain directory under a REVIEW_DIR that happens to sit
# inside some other repository answers with that repository's root, which is
# why the toplevel has to be the directory itself.
acr_wt_of_clone() { # <dir> <clone>
  local dir="$1" clone="$2" top mine theirs
  [ -d "$dir" ] || return 1
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$top" ] || return 1
  [ "$(cd "$top" 2>/dev/null && pwd -P)" = "$(cd "$dir" 2>/dev/null && pwd -P)" ] || return 1
  mine=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  theirs=$(git -C "$clone" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$mine" in /*) : ;; *) mine="$dir/$mine" ;; esac
  case "$theirs" in /*) : ;; *) theirs="$clone/$theirs" ;; esac
  [ -d "$mine" ] && [ -d "$theirs" ] || return 1
  [ "$(cd "$mine" && pwd -P)" = "$(cd "$theirs" && pwd -P)" ]
}

# Picks wt/<name>, or wt/<name>-2, -3, ... when the plain name is taken by a
# different clone or by a directory that is already there. A directory that no
# line claims but that is a worktree of this clone is adopted: it is what a run
# killed between `git worktree add` and the record leaves behind, and passing
# it over would strand it where cleanup.sh can never find it.
acr_wt_path() { # <clone> <repoName>
  local clone="$1" name="$2" i=1 cand owner
  while :; do
    if [ "$i" = "1" ]; then cand="$REVIEW_DIR/wt/$name"; else cand="$REVIEW_DIR/wt/$name-$i"; fi
    owner=$(acr_clone_for_wt "$cand")
    if [ -n "$owner" ]; then
      [ "$owner" = "$clone" ] && { printf '%s\n' "$cand"; return 0; }
    elif [ ! -e "$cand" ] || acr_wt_of_clone "$cand" "$clone"; then
      printf '%s\n' "$cand"; return 0
    fi
    i=$(( i + 1 ))
    [ "$i" -gt 99 ] && acr_die "no free worktree slot for $name under $REVIEW_DIR/wt"
  done
}

# Appends a worktree line, replacing any earlier line for the same clone.
# The caller holds the worktrees lock.
acr_write_worktree_line() { # <clone> <worktree> <sha>
  local tsv="$REVIEW_DIR/worktrees.tsv" tmp="$REVIEW_DIR/worktrees.tsv.$$"
  if [ -f "$tsv" ]; then
    awk -F'\t' -v c="$1" '$1 != c' "$tsv" > "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$tmp"
  mv "$tmp" "$tsv"
}

# Picks the path, creates the detached worktree and records it, as one step
# under one lock: two scopes on the same REVIEW_DIR would otherwise pick the
# same path and collide inside git, and both would fail. Prints the path.
acr_claim_worktree() { # <clone> <worktree name> <sha>
  local clone="$1" name="$2" sha="$3" wt current
  mkdir -p "$REVIEW_DIR/wt" || acr_die "cannot create the worktree directory: $REVIEW_DIR/wt"
  acr_lock worktrees
  wt=$(acr_wt_path "$clone" "$name")
  if [ -d "$wt" ]; then
    current=$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)
    [ "$current" = "$sha" ] \
      || acr_die "a worktree is already there at another commit, remove it with cleanup.sh or use a fresh REVIEW_DIR: $wt"
  else
    git -C "$clone" worktree add --detach --quiet "$wt" "$sha" \
      || acr_die "cannot create the worktree $wt at $sha"
  fi
  acr_write_worktree_line "$clone" "$wt" "$sha"
  acr_unlock
  printf '%s\n' "$wt"
}

# ------------------------------------------------------------ repo facts ----

# The repository root of a path, or a failure naming the path. An absolute
# argument that already names the root is echoed back as the caller spelled it,
# so paths recorded here stay comparable with the ones the caller passes later.
acr_repo_root() { # <path>
  local p="$1" root
  [ -d "$p" ] || acr_die "not a directory: $p"
  root=$(git -C "$p" rev-parse --show-toplevel 2>/dev/null) \
    || acr_die "not a git repository: $p"
  [ -n "$root" ] || acr_die "not a git repository: $p"
  case "$p" in
    /*)
      p=${p%/}
      [ -n "$p" ] || p=/
      if [ "$(cd "$p" && pwd -P)" = "$(cd "$root" && pwd -P)" ]; then
        printf '%s\n' "$p"
        return 0
      fi
      ;;
  esac
  printf '%s\n' "$root"
}

# owner/name out of origin's URL. Empty when the URL is not a GitHub remote.
acr_owner_repo() { # <clone>
  local url
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 0
  case "$url" in
    *github.com[:/]*) : ;;
    *) return 0 ;;
  esac
  printf '%s\n' "$url" | sed -e 's#/*$##' -e 's#\.git$##' -e 's#/*$##' \
    -e 's#^.*github\.com[:/]##' -e 's#^/*##' \
    | awk -F/ 'NF >= 2 { print $(NF-1) "/" $NF }'
}

# The remote default branch: refs/remotes/origin/HEAD, else `gh repo view`.
acr_default_branch() { # <clone>
  local clone="$1" ref name
  ref=$(git -C "$clone" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#refs/remotes/origin/}"
    return 0
  fi
  name=$( cd "$clone" && "${GH:-gh}" repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null ) || true
  [ -n "$name" ] && [ "$name" != "null" ] || acr_die "cannot determine the remote default branch of $clone"
  printf '%s\n' "$name"
}

# Resolves a ref, preferring the remote-tracking copy over a local branch.
acr_resolve_ref() { # <clone> <ref>
  local clone="$1" ref="$2" sha
  sha=$(git -C "$clone" rev-parse --verify --quiet "refs/remotes/origin/$ref^{commit}" 2>/dev/null || true)
  [ -n "$sha" ] || sha=$(git -C "$clone" rev-parse --verify --quiet "${ref}^{commit}" 2>/dev/null || true)
  [ -n "$sha" ] || return 1
  printf '%s\n' "$sha"
}

# The same, but asks origin for the ref when the clone does not already have it.
# A single-branch clone's refspec covers one branch, so a plain fetch of origin
# leaves every other branch out of the ref store; fetching the ref by name puts
# its objects in the clone and its tip in FETCH_HEAD without creating a
# remote-tracking ref the caller did not ask for.
acr_resolve_ref_fetch() { # <clone> <ref>
  local clone="$1" ref="$2" sha
  sha=$(acr_resolve_ref "$clone" "$ref") && { printf '%s\n' "$sha"; return 0; }
  acr_fetch "$clone" "$ref" >/dev/null 2>&1 || return 1
  sha=$(acr_resolve_ref "$clone" "$ref") && { printf '%s\n' "$sha"; return 0; }
  sha=$(git -C "$clone" rev-parse --verify --quiet 'FETCH_HEAD^{commit}' 2>/dev/null || true)
  [ -n "$sha" ] || return 1
  printf '%s\n' "$sha"
}

# ---------------------------------------------------------- diff parsing ----

# One awk program parses the patch for every consumer. It tracks the line
# budget of each hunk header instead of trusting line prefixes, so a removed
# line that itself starts with "---" cannot be mistaken for a file header.
ACR_PATCH_AWK='
function unquote(p,   s, out, i, n, c, oct, k, v) {
  if (substr(p, 1, 1) != "\"") return p
  s = substr(p, 2, length(p) - 2)
  out = ""; i = 1; n = length(s)
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "\\") {
      i++
      c = substr(s, i, 1)
      if (c == "n") out = out "\n"
      else if (c == "t") out = out "\t"
      else if (c == "r") out = out "\r"
      else if (c >= "0" && c <= "7") {
        oct = substr(s, i, 3); v = 0
        for (k = 1; k <= 3; k++) v = v * 8 + (substr(oct, k, 1) + 0)
        out = out sprintf("%c", v)
        i += 2
      } else out = out c
    } else out = out c
    i++
  }
  return out
}
function pathof(raw, side,   p, t) {
  t = index(raw, "\t")
  if (t > 0) raw = substr(raw, 1, t - 1)
  p = unquote(raw)
  if (p == "/dev/null") return ""
  if (substr(p, 1, 2) == side "/") p = substr(p, 3)
  return p
}
function hunkstart(f,   v, parts) {
  v = f
  sub(/^[-+]/, "", v)
  if (index(v, ",") > 0) { split(v, parts, ","); return parts[1] + 0 }
  return v + 0
}
function hunkcount(f,   v, parts) {
  v = f
  sub(/^[-+]/, "", v)
  if (index(v, ",") > 0) { split(v, parts, ","); return parts[2] + 0 }
  return 1
}
{
  if (inhunk) {
    c = substr($0, 1, 1)
    if (c == "+") {
      body("add", 0, nl)
      nl++; nrem--
    } else if (c == "-") {
      body("del", ol, 0)
      ol++; orem--
    } else if (c == " " || $0 == "") {
      body("ctx", ol, nl)
      ol++; nl++; orem--; nrem--
    } else if (c == "\\") {
      # "\ No newline at end of file" belongs to the line before it.
    } else {
      inhunk = 0
    }
    if (orem <= 0 && nrem <= 0) inhunk = 0
    if (inhunk || c == "+" || c == "-" || c == " " || $0 == "" || c == "\\") next
  }
  if (substr($0, 1, 11) == "diff --git ") { oldf = ""; newf = ""; nfiles++; header(); next }
  if (substr($0, 1, 4) == "--- ") { oldf = pathof(substr($0, 5), "a"); next }
  if (substr($0, 1, 4) == "+++ ") { newf = pathof(substr($0, 5), "b"); next }
  if (substr($0, 1, 3) == "@@ ") {
    ol = hunkstart($2); orem = hunkcount($2)
    nl = hunkstart($3); nrem = hunkcount($3)
    hdr = $0
    inhunk = 1
    hunk()
    next
  }
}
'

# Answers a whole list of "where does <file> <NEW:n|OLD:n> land" questions in
# one pass over diff.patch, because one pass per question turns a review with
# many comments on a large diff into minutes of re-parsing.
#
# Requests, one per line:  <tag>\t<NEW|OLD>\t<line>\t<path>
# Answers, in the same order, one per line:
#   <tag>\tOK\t<RIGHT|LEFT>\t<line>\t<hunk header>
#   <tag>\tERR\t<reason>
# The path and the hunk header come last because either may contain a tab.
acr_anchor_batch() { # <requests file> <answers file>
  local requests="$1" answers="$2" patch="$REVIEW_DIR/diff.patch"
  [ -s "$requests" ] || { : > "$answers"; return 0; }
  if [ ! -f "$patch" ]; then
    awk -F'\t' -v p="$patch" \
      '{ print $1 "\tERR\tdiff.patch is missing, run scope.sh first: " p }' \
      "$requests" > "$answers"
    return 0
  fi
  awk '
    function record(tag, text) { if (!(tag in res)) res[tag] = text }
    function answer(key, text,   n, list, i) {
      if (!(key in tags)) return
      n = split(tags[key], list, " ")
      for (i = 1; i <= n; i++) record(list[i], text)
    }
    FNR == NR {
      # The patch is parsed with the default field separator, which the hunk
      # headers need, so a request line is split on its tabs by hand.
      split($0, q, "\t")
      tag = q[1]; want = q[2]; num = q[3]
      rest = $0
      sub(/^[^\t]*\t[^\t]*\t[^\t]*\t/, "", rest)
      order[++nreq] = tag
      qwant[tag] = want; qnum[tag] = num; qpath[tag] = rest
      if (num !~ /^[0-9]+$/) {
        res[tag] = "ERR\tlocation line must be a number, got: " want ":" num
        next
      }
      # + 0 so that a line number written with leading zeros keys the same as
      # the plain one, which is how the line numbers out of the patch key.
      key = rest SUBSEP want SUBSEP (num + 0)
      tags[key] = (key in tags) ? tags[key] " " tag : tag
      next
    }
    function header() { }
    function hunk() { }
    function body(kind, oline, nline) {
      if (newf != "") seen["NEW" SUBSEP newf] = 1
      if (oldf != "") seen["OLD" SUBSEP oldf] = 1
      if (kind != "del" && newf != "")
        answer(newf SUBSEP "NEW" SUBSEP nline, "OK\tRIGHT\t" nline "\t" hdr)
      if (oldf == "") return
      if (kind == "del")
        answer(oldf SUBSEP "OLD" SUBSEP oline, "OK\tLEFT\t" oline "\t" hdr)
      else if (kind == "ctx")
        answer(oldf SUBSEP "OLD" SUBSEP oline,
               "ERR\tline " oline " of " oldf " is a context line: context lines are valid on RIGHT only")
    }
    '"$ACR_PATCH_AWK"'
    END {
      for (i = 1; i <= nreq; i++) {
        tag = order[i]
        if (tag in res) { print tag "\t" res[tag]; continue }
        if (!((qwant[tag] SUBSEP qpath[tag]) in seen))
          print tag "\tERR\tfile is not in the diff: " qpath[tag]
        else
          print tag "\tERR\tline " qnum[tag] " is not inside any hunk of " qpath[tag]
      }
    }
  ' "$requests" "$patch" > "$answers" \
    || { awk -F'\t' -v p="$patch" '{ print $1 "\tERR\tcannot read the diff: " p }' "$requests" > "$answers"; }
  return 0
}

# Answers one such question, through the same pass, so that anchor.sh and
# post-review.sh can never disagree about what anchors where.
# On success sets ACR_SIDE, ACR_LINE and ACR_HUNK; on failure sets ACR_ERR.
acr_anchor() { # <file> <NEW:n|OLD:n>
  ACR_SIDE=""; ACR_LINE=""; ACR_HUNK=""; ACR_ERR=""
  local file="$1" loc="$2" want num dir out rest tab
  tab=$(printf '\t')
  case "$loc" in
    NEW:*) want=NEW; num=${loc#NEW:} ;;
    OLD:*) want=OLD; num=${loc#OLD:} ;;
    *) ACR_ERR="location must be NEW:<n> or OLD:<n>, got: $loc"; return 1 ;;
  esac
  case "$num" in
    ''|*[!0-9]*) ACR_ERR="location line must be a number, got: $loc"; return 1 ;;
  esac
  # Under the temporary directory, never under REVIEW_DIR: a review directory
  # is read by the finders and must hold nothing but the recorded files.
  dir=$(mktemp -d "${TMPDIR:-/tmp}/acr-anchor.XXXXXX") || {
    ACR_ERR="cannot create a temporary directory for the anchor lookup"
    return 1
  }
  printf '1\t%s\t%s\t%s\n' "$want" "$num" "$file" > "$dir/req"
  acr_anchor_batch "$dir/req" "$dir/ans"
  out=$(cat "$dir/ans" 2>/dev/null || true)
  rm -rf "$dir"

  rest="${out#*"$tab"}"
  case "$rest" in
    "OK$tab"*)
      rest="${rest#*"$tab"}"
      ACR_SIDE="${rest%%"$tab"*}"
      rest="${rest#*"$tab"}"
      ACR_LINE="${rest%%"$tab"*}"
      ACR_HUNK="${rest#*"$tab"}"
      return 0
      ;;
    "ERR$tab"*)
      ACR_ERR="${rest#*"$tab"}"
      ;;
  esac
  [ -n "$ACR_ERR" ] || ACR_ERR="no anchor for $file $loc"
  return 1
}

# Added plus deleted body lines, and the number of files, in a patch.
# Sets ACR_DIFF_LINES and ACR_DIFF_FILES.
acr_diff_stats() { # <patch file>
  local out
  out=$(awk '
    function header() { }
    function hunk() { }
    function body(kind, oline, nline) { if (kind != "ctx") changed++ }
    '"$ACR_PATCH_AWK"'
    END { print changed + 0 "\t" nfiles + 0 }
  ' "$1")
  ACR_DIFF_LINES=$(printf '%s' "$out" | awk -F'\t' '{ print $1 }')
  ACR_DIFF_FILES=$(printf '%s' "$out" | awk -F'\t' '{ print $2 }')
}

# The fan-out the skill prescribes for a diff of this size.
acr_fanout() { # <changed lines>
  if [ "$1" -lt 150 ]; then printf '4\n'
  elif [ "$1" -lt 1500 ]; then printf '6\n'
  else printf '8\n'
  fi
}
