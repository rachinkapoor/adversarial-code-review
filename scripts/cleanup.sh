#!/usr/bin/env bash
# Removes every worktree this review created and shows each clone's status, so
# a clone that was left dirty is visible. Usage: cleanup.sh [--all]
set -euo pipefail

. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"

usage() { acr_die "usage: cleanup.sh [--all]"; }

ALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --all) ALL=1; shift ;;
    --)    shift ;;
    *)     usage ;;
  esac
done

acr_review_dir

TSV="$REVIEW_DIR/worktrees.tsv"
CLONE_LIST="$REVIEW_DIR/.cleanup-clones.$$"
CLONE_UNIQ="$REVIEW_DIR/.cleanup-uniq.$$"
NORM_TSV="$REVIEW_DIR/.cleanup-tsv.$$"
: > "$CLONE_LIST"
TAB=$(printf '\t')
TROUBLE=0

if [ -f "$TSV" ]; then
  # `read` drops a last line that has no newline, and the CR of a CRLF file
  # rides on the last field it reads. awk ends every record with a newline, so
  # normalising first makes a hand-edited file behave like a written one.
  awk '{ sub(/\r$/, ""); print }' "$TSV" > "$NORM_TSV"
  while IFS="$TAB" read -r clone wt sha; do
    [ -n "${clone:-}" ] || continue
    [ -n "${wt:-}" ] || continue
    printf '%s\n' "$clone" >> "$CLONE_LIST"
    if [ ! -d "$clone" ]; then
      printf 'clone is gone, nothing to remove: %s\n' "$clone"
      continue
    fi
    # A worktree an earlier run already removed is not an error here. One that
    # is still on disk after a failed removal is. Its directory stays exactly
    # where it is: git identifies a worktree by its path, so deleting it would
    # leave the clone with an entry that only `git worktree prune` could clear,
    # and this never prunes.
    if git -C "$clone" worktree remove --force "$wt" >/dev/null 2>&1; then
      printf 'removed worktree: %s\n' "$wt"
    elif [ ! -d "$wt" ]; then
      printf 'worktree already gone: %s\n' "$wt"
    else
      acr_warn "cannot remove the worktree $wt from $clone"
      TROUBLE=1
    fi
  done < "$NORM_TSV"
  rm -f "$NORM_TSV"
fi

# Never `git worktree prune`: it also deletes other sessions' stale entries.

# A plain redirect, not a pipe: a pipeline's loop runs in a subshell, where a
# clone whose status could not be read would be forgotten by the exit code.
awk '!seen[$0]++' "$CLONE_LIST" > "$CLONE_UNIQ"
while IFS= read -r clone; do
  [ -n "$clone" ] || continue
  [ -d "$clone" ] || continue
  printf '\n%s\n' "$clone"
  git -C "$clone" status --short \
    || { acr_warn "cannot read the status of $clone"; TROUBLE=1; }
done < "$CLONE_UNIQ"

rm -f "$CLONE_LIST" "$CLONE_UNIQ"
if [ "$TROUBLE" = "0" ]; then
  rm -rf "$REVIEW_DIR/wt"
else
  acr_warn "keeping $REVIEW_DIR/wt: the worktrees above are still registered in their clones"
fi

if [ "$ALL" = "1" ]; then
  # worktrees.tsv is the only record of what this review created. Deleting it
  # after a failed removal would leave entries registered in a clone with
  # nothing left to say which ones, so a failed run keeps REVIEW_DIR.
  if [ "$TROUBLE" = "0" ]; then
    rm -rf "$REVIEW_DIR"
    printf '\nremoved REVIEW_DIR: %s\n' "$REVIEW_DIR"
  else
    acr_warn "keeping REVIEW_DIR, it still records the worktrees above: $REVIEW_DIR"
  fi
fi

[ "$TROUBLE" = "0" ] || acr_die "cleanup did not finish cleanly, see the lines above"
