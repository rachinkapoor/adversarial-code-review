#!/usr/bin/env bash
# Pins the review target: writes $REVIEW_DIR/meta.json and diff.patch and adds
# a detached worktree of the head under $REVIEW_DIR/wt/.
#
#   scope.sh [--repo <clone>] [--base <ref>] <PR number | PR URL | branch | --wip>
set -euo pipefail

. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"

usage() { acr_die "usage: scope.sh [--repo <clone>] [--base <ref>] <PR number | PR URL | branch | --wip>"; }

REPO_ARG=""
BASE_ARG=""
TARGET_ARG=""
WIP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || usage; REPO_ARG="$2"; shift 2 ;;
    --base) [ $# -ge 2 ] || usage; BASE_ARG="$2"; shift 2 ;;
    --wip)  [ -z "$TARGET_ARG" ] || acr_die "more than one target given: $TARGET_ARG and --wip"
            WIP=1; TARGET_ARG="--wip"; shift ;;
    --)     shift ;;
    -*)     acr_die "unknown option: $1" ;;
    *)      [ -z "$TARGET_ARG" ] || acr_die "more than one target given: $TARGET_ARG and $1"
            TARGET_ARG="$1"; shift ;;
  esac
done

[ -n "$TARGET_ARG" ] || usage

acr_review_dir create

# ------------------------------------------------------------- the clone ----

if [ -n "$REPO_ARG" ]; then
  REPO=$(acr_repo_root "$REPO_ARG")
else
  REPO=$(acr_repo_root ".")
fi
REPO_NAME=$(basename "$REPO")

# ------------------------------------------------------ what was asked for --

PR_NUMBER=""
BRANCH=""
if [ "$WIP" = "1" ]; then
  :
else
  case "$TARGET_ARG" in
    pr:*)            PR_NUMBER="${TARGET_ARG#pr:}" ;;
    branch:*)        BRANCH="${TARGET_ARG#branch:}" ;;
    http://*|https://*)
      case "$TARGET_ARG" in
        */pull/*) PR_NUMBER=$(printf '%s' "$TARGET_ARG" | sed -e 's#[?#].*$##' -e 's#/*$##' -e 's#^.*/pull/##' -e 's#/.*$##') ;;
        *) acr_die "not a pull request URL: $TARGET_ARG" ;;
      esac
      ;;
    *)
      case "$TARGET_ARG" in
        ''|*[!0-9]*) BRANCH="$TARGET_ARG" ;;
        *)           PR_NUMBER="$TARGET_ARG" ;;
      esac
      ;;
  esac
  if [ -n "$PR_NUMBER" ]; then
    case "$PR_NUMBER" in
      ''|*[!0-9]*) acr_die "not a pull request number: $TARGET_ARG" ;;
    esac
  fi
fi

# -------------------------------------------------------------- the facts ---

acr_fetch "$REPO" || acr_die "git fetch origin failed in $REPO"

OWNER_REPO=$(acr_owner_repo "$REPO")
PR_TITLE=""
PR_BODY=""
CROSS="false"
UNTRACKED_JSON="[]"

gh_pr_view() { # <fields>
  ( cd "$REPO" && "${GH:-gh}" pr view "$PR_NUMBER" --json "$1" ) \
    || acr_die "gh pr view $PR_NUMBER failed"
}

if [ -n "$PR_NUMBER" ]; then
  PR_JSON=$(gh_pr_view "baseRefName,headRefName,headRefOid,isCrossRepository,title,body,state")
  printf '%s' "$PR_JSON" | jq -e . >/dev/null 2>&1 || acr_die "gh pr view $PR_NUMBER returned no usable JSON"
  BASE_REF=$(printf '%s' "$PR_JSON" | jq -r '.baseRefName // ""')
  HEAD_SHA=$(printf '%s' "$PR_JSON" | jq -r '.headRefOid // ""')
  CROSS=$(printf '%s' "$PR_JSON" | jq -r 'if .isCrossRepository then "true" else "false" end')
  PR_TITLE=$(printf '%s' "$PR_JSON" | jq -r '.title // ""')
  PR_BODY=$(printf '%s' "$PR_JSON" | jq -r '.body // ""')
  [ -n "$HEAD_SHA" ] || acr_die "PR $PR_NUMBER has no head commit"
  [ -n "$BASE_REF" ] || acr_die "PR $PR_NUMBER has no base branch"
  if [ -n "$BASE_ARG" ]; then BASE_REF="$BASE_ARG"; fi
  if [ "$CROSS" = "true" ]; then
    acr_fetch "$REPO" "pull/$PR_NUMBER/head" \
      || acr_die "cannot fetch pull/$PR_NUMBER/head in $REPO"
  fi
  # A clone whose fetch refspec covers a single branch does not get the head of
  # a same-repository PR from a plain fetch of origin either; the pull ref
  # carries it for every PR, so fall back to it before giving up.
  if ! git -C "$REPO" cat-file -e "$HEAD_SHA^{commit}" 2>/dev/null; then
    acr_fetch "$REPO" "pull/$PR_NUMBER/head" >/dev/null 2>&1 || true
  fi
  git -C "$REPO" cat-file -e "$HEAD_SHA^{commit}" 2>/dev/null \
    || acr_die "the PR head $HEAD_SHA is not in $REPO after fetching"
  TARGET="pr:$PR_NUMBER"

elif [ "$WIP" = "1" ]; then
  HEAD_SHA=$(git -C "$REPO" rev-parse --verify HEAD 2>/dev/null) \
    || acr_die "$REPO has no HEAD commit"
  if [ -n "$BASE_ARG" ]; then BASE_REF="$BASE_ARG"; else BASE_REF=$(acr_default_branch "$REPO"); fi
  TARGET="wip:$HEAD_SHA"

else
  HEAD_SHA=$(acr_resolve_ref_fetch "$REPO" "$BRANCH") \
    || acr_die "no such branch in $REPO: $BRANCH"
  if [ -n "$BASE_ARG" ]; then BASE_REF="$BASE_ARG"; else BASE_REF=$(acr_default_branch "$REPO"); fi
  TARGET="branch:$BRANCH@$BASE_REF"
fi

BASE_SHA_REF=$(acr_resolve_ref_fetch "$REPO" "$BASE_REF") \
  || acr_die "cannot resolve the base ref in $REPO: $BASE_REF"
BASE_SHA=$(git -C "$REPO" merge-base "$BASE_SHA_REF" "$HEAD_SHA" 2>/dev/null) \
  || acr_die "no merge base between $BASE_REF and the head in $REPO"

# ------------------------------------------ one REVIEW_DIR, one target ------

if [ -f "$REVIEW_DIR/meta.json" ]; then
  EXISTING=$(jq -r '.target // ""' "$REVIEW_DIR/meta.json" 2>/dev/null || true)
  if [ -n "$EXISTING" ] && [ "$EXISTING" != "$TARGET" ]; then
    acr_die "REVIEW_DIR already holds the target $EXISTING, refusing to scope $TARGET: $REVIEW_DIR"
  fi
fi

# ------------------------------------------------------------- the diff -----

PATCH="$REVIEW_DIR/diff.patch"
if [ "$WIP" = "1" ]; then
  git -C "$REPO" diff "$BASE_SHA" > "$PATCH" \
    || acr_die "cannot build the working-tree diff in $REPO"
  UNTRACKED_JSON=$(git -C "$REPO" ls-files --others --exclude-standard \
    | jq -R -s 'split("\n") | map(select(length > 0))')
else
  git -C "$REPO" diff "$BASE_SHA" "$HEAD_SHA" > "$PATCH" \
    || acr_die "cannot build the diff in $REPO"
fi

acr_diff_stats "$PATCH"
FANOUT=$(acr_fanout "$ACR_DIFF_LINES")

# --------------------------------------------------------- the worktree -----

WT=$(acr_claim_worktree "$REPO" "$REPO_NAME" "$HEAD_SHA")

# The uncommitted work is what the review is about, so it goes into the
# worktree; the clone itself is left exactly as it was found.
if [ "$WIP" = "1" ]; then
  WIP_PATCH="$REVIEW_DIR/wip-uncommitted.patch"
  # --binary so that a changed image, fixture or other non-text file reaches the
  # worktree: a textual "Binary files differ" stanza cannot be applied at all.
  git -C "$REPO" diff --binary HEAD > "$WIP_PATCH" \
    || acr_die "cannot read the uncommitted changes in $REPO"
  if [ -s "$WIP_PATCH" ]; then
    git -C "$WT" apply --whitespace=nowarn "$WIP_PATCH" \
      || acr_die "cannot apply the uncommitted changes into $WT"
  fi
fi

# ------------------------------------------------------------- meta.json ----

if [ "$WIP" = "1" ]; then WIP_JSON=true; else WIP_JSON=false; fi

jq -n \
  --arg target "$TARGET" --arg repo "$REPO" --arg repoName "$REPO_NAME" \
  --arg ownerRepo "$OWNER_REPO" --arg baseRef "$BASE_REF" \
  --arg headSha "$HEAD_SHA" --arg baseSha "$BASE_SHA" \
  --arg prNumber "$PR_NUMBER" --argjson cross "$CROSS" \
  --arg title "$PR_TITLE" --arg body "$PR_BODY" \
  --argjson wip "$WIP_JSON" \
  --argjson untracked "$UNTRACKED_JSON" \
  --argjson diffLines "$ACR_DIFF_LINES" --argjson diffFiles "$ACR_DIFF_FILES" \
  --argjson fanout "$FANOUT" \
  '{ target: $target, repo: $repo, repoName: $repoName, ownerRepo: $ownerRepo,
     baseRef: $baseRef, headSha: $headSha, baseSha: $baseSha,
     prNumber: (if $prNumber == "" then null else ($prNumber | tonumber) end),
     isCrossRepository: $cross, title: $title, body: $body, wip: $wip,
     untracked: $untracked, diffLines: $diffLines, diffFiles: $diffFiles,
     fanout: $fanout }' \
  > "$REVIEW_DIR/meta.json"

# --------------------------------------------------------------- summary ----

printf 'target:    %s\n' "$TARGET"
printf 'repo:      %s\n' "$REPO"
printf 'head:      %s\n' "$HEAD_SHA"
printf 'base:      %s (%s)\n' "$BASE_REF" "$BASE_SHA"
printf 'diff:      %s changed lines in %s files\n' "$ACR_DIFF_LINES" "$ACR_DIFF_FILES"
printf 'fan-out:   %s finders\n' "$FANOUT"
printf 'worktree:  %s\n' "$WT"
