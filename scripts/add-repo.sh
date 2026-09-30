#!/usr/bin/env bash
# Adds a second repository to the review: fetches it and puts a detached
# worktree under $REVIEW_DIR/wt/. Usage: add-repo.sh <clone> [ref]
set -euo pipefail

. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"

usage() { acr_die "usage: add-repo.sh <clone> [ref]"; }

[ $# -ge 1 ] && [ $# -le 2 ] || usage
CLONE_ARG="$1"
REF_ARG="${2:-}"

acr_review_dir create

REPO=$(acr_repo_root "$CLONE_ARG")
REPO_NAME=$(basename "$REPO")

EXISTING=$(acr_wt_for_clone "$REPO")
if [ -n "$EXISTING" ] && [ -d "$EXISTING" ]; then
  printf '%s\n' "$EXISTING"
  exit 0
fi

acr_fetch "$REPO" || acr_die "git fetch origin failed in $REPO"

if [ -n "$REF_ARG" ]; then REF="$REF_ARG"; else REF=$(acr_default_branch "$REPO"); fi

SHA=$(acr_resolve_ref_fetch "$REPO" "$REF") || acr_die "cannot resolve the ref in $REPO: $REF"

WT=$(acr_claim_worktree "$REPO" "$REPO_NAME" "$SHA")

printf '%s\n' "$WT"
