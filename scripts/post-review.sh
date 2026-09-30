#!/usr/bin/env bash
# Validates a GitHub review payload against the reviewed diff and posts it.
#
#   post-review.sh <review.json> [--dry-run] [--force]
set -euo pipefail

. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"

usage() { acr_die "usage: post-review.sh <review.json> [--dry-run] [--force]"; }

INPUT=""
DRY_RUN=0
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --force)   FORCE=1; shift ;;
    --)        shift ;;
    -*)        acr_die "unknown option: $1" ;;
    *)         [ -z "$INPUT" ] || acr_die "more than one input file given: $INPUT and $1"
               INPUT="$1"; shift ;;
  esac
done

[ -n "$INPUT" ] || usage
[ -f "$INPUT" ] || acr_die "review payload not found: $INPUT"

acr_review_dir
jq -e . "$INPUT" >/dev/null 2>&1 || acr_die "review payload is not valid JSON: $INPUT"
# An absent or empty `comments` is a body-only review and valid; anything that
# is not a list of objects would make every later jq read fail with its own
# error instead of one reason from here.
jq -e '((.comments // []) | type) == "array" and ((.comments // []) | all(type == "object"))' \
  "$INPUT" >/dev/null 2>&1 \
  || acr_die "review payload .comments must be an array of objects: $INPUT"

PR_NUMBER=$(acr_meta '.prNumber // ""')
[ -n "$PR_NUMBER" ] && [ "$PR_NUMBER" != "null" ] \
  || acr_die "this review has no pull request (meta.prNumber is null), nothing to post to"
HEAD_SHA=$(acr_meta '.headSha // ""')
[ -n "$HEAD_SHA" ] || acr_die "meta.headSha is empty, cannot pin the review to a commit"
OWNER_REPO=$(acr_meta '.ownerRepo // ""')
[ "$OWNER_REPO" != "null" ] || OWNER_REPO=""
REPO_PATH=$(acr_meta '.repo // ""')
# origin is only asked when meta names a clone that is still there. The current
# directory is whatever the caller happened to be in, and its origin would name
# a different repository to post the review to.
if [ -z "$OWNER_REPO" ] && [ -n "$REPO_PATH" ] && [ -d "$REPO_PATH" ]; then
  OWNER_REPO=$(acr_owner_repo "$REPO_PATH")
fi
[ -n "$REPO_PATH" ] && [ -d "$REPO_PATH" ] || REPO_PATH="."

# ------------------------------------------------------------ validation ----

COUNT=$(jq -r '(.comments // []) | length' "$INPUT")
BAD=""
TAB=$(printf '\t')
WORK=$(mktemp -d "${TMPDIR:-/tmp}/acr-post.XXXXXX") \
  || acr_die "cannot create a temporary directory for the anchor lookup"
trap 'rm -rf "$WORK"' EXIT

add_bad() { BAD="$BAD$1
"; }

# Every comment's fields in one pass, as tab separated columns with the path
# last because a path may itself contain a tab.
jq -r '(.comments // []) | to_entries[]
       | [ (.key | tostring),
           ((.value.side // "RIGHT") | tostring),
           ((.value.line // "") | tostring),
           ((.value.start_line // "") | tostring),
           ((.value.start_side // "") | tostring),
           ((.value.path // "") | tostring) ]
       | join("\t")' "$INPUT" > "$WORK/comments.tsv" \
  || acr_die "cannot read the comments out of $INPUT"
ROWS=$(grep -c . "$WORK/comments.tsv" || true)
[ "$ROWS" = "$COUNT" ] \
  || acr_die "$INPUT: $COUNT comments but $ROWS readable rows, a path with a newline in it cannot be checked"

# One request per anchor the comments need, answered in a single pass over the
# diff: one pass per comment re-reads the whole patch for every one of them.
awk -F"$TAB" -v count="$COUNT" '
  function want(side) { return side == "RIGHT" ? "NEW" : (side == "LEFT" ? "OLD" : "") }
  {
    i = $1; side = $2; line = $3; sl = $4; ss = $5
    path = $0
    sub(/^([^\t]*\t){5}/, "", path)
    if (path == "" || line == "" || want(side) == "") next
    printf "%s\t%s\t%s\t%s\n", i, want(side), line, path
    if (sl == "" || sl == "null") next
    if (ss == "" || ss == "null") ss = side
    if (want(ss) == "") next
    printf "%s\t%s\t%s\t%s\n", i + count, want(ss), sl, path
  }
' "$WORK/comments.tsv" > "$WORK/requests.tsv"

acr_anchor_batch "$WORK/requests.tsv" "$WORK/answers.tsv"

# One shell variable per answer, keyed by the request tag. The tag is checked
# to be digits before it names a variable, so nothing in the payload can ever
# reach eval as a name.
while IFS= read -r answer; do
  tag="${answer%%"$TAB"*}"
  case "$tag" in
    ''|*[!0-9]*) continue ;;
  esac
  eval "ANS_$tag=\$answer"
done < "$WORK/answers.tsv"

# Splits one answer into ACR_SIDE / ACR_LINE / ACR_HUNK, or ACR_ERR.
read_answer() { # <tag>
  local rest
  ACR_SIDE=""; ACR_LINE=""; ACR_HUNK=""; ACR_ERR=""
  case "$1" in
    ''|*[!0-9]*) ACR_ERR="no anchor was worked out for this comment"; return 1 ;;
  esac
  eval "rest=\${ANS_$1:-}"
  rest="${rest#*"$TAB"}"
  case "$rest" in
    "OK$TAB"*)
      rest="${rest#*"$TAB"}"
      ACR_SIDE="${rest%%"$TAB"*}"
      rest="${rest#*"$TAB"}"
      ACR_LINE="${rest%%"$TAB"*}"
      ACR_HUNK="${rest#*"$TAB"}"
      return 0
      ;;
    "ERR$TAB"*) ACR_ERR="${rest#*"$TAB"}" ;;
    *)          ACR_ERR="no anchor was worked out for this comment" ;;
  esac
  return 1
}

# `read` with a tab in IFS folds empty columns away, so the row is peeled apart
# by hand; what is left after the fifth tab is the path, tabs and all.
next_column() { # <row>
  COLUMN="${1%%"$TAB"*}"
  ROW="${1#*"$TAB"}"
}

while IFS= read -r row; do
  [ -n "$row" ] || continue
  next_column "$row";  i="$COLUMN"
  next_column "$ROW";  side="$COLUMN"
  next_column "$ROW";  line="$COLUMN"
  next_column "$ROW";  start_line="$COLUMN"
  next_column "$ROW";  start_side="$COLUMN"
  path="$ROW"
  label="comment $(( i + 1 )) ($path:${line:-?} $side)"

  if [ -z "$path" ]; then
    add_bad "comment $(( i + 1 )): no path"
  elif [ -z "$line" ]; then
    add_bad "$label: no line"
  else
    case "$side" in
      RIGHT|LEFT) : ;;
      *)          side="" ;;
    esac
    if [ -z "$side" ]; then
      add_bad "comment $(( i + 1 )) ($path): side must be RIGHT or LEFT"
    elif ! read_answer "$i"; then
      add_bad "$label: $ACR_ERR"
    else
      end_hunk="$ACR_HUNK"
      if [ -n "$start_line" ] && [ "$start_line" != "null" ]; then
        [ -n "$start_side" ] && [ "$start_side" != "null" ] || start_side="$side"
        case "$start_line" in
          ''|*[!0-9]*) add_bad "$label: start_line is not a number: $start_line" ;;
          *)
            if [ "$start_line" -ge "$line" ]; then
              add_bad "$label: start_line $start_line must be before line $line"
            else
              case "$start_side" in
                RIGHT|LEFT) : ;;
                *)          start_side="" ;;
              esac
              if [ -z "$start_side" ]; then
                add_bad "$label: start_side must be RIGHT or LEFT"
              elif ! read_answer "$(( i + COUNT ))"; then
                add_bad "$label: start_line $start_line: $ACR_ERR"
              elif [ "$ACR_HUNK" != "$end_hunk" ]; then
                add_bad "$label: start_line $start_line is in a different hunk than line $line"
              fi
            fi
            ;;
        esac
      fi
    fi
  fi
done < "$WORK/comments.tsv"

if [ -n "$BAD" ]; then
  printf '%s' "$BAD" >&2
  acr_die "$(printf '%s' "$BAD" | grep -c .) of $COUNT comments cannot be anchored in the reviewed diff, nothing was posted"
fi

# ------------------------------------------------------------- the payload --

PAYLOAD=$(jq --arg c "$HEAD_SHA" 'if (.commit_id // "") == "" then .commit_id = $c else . end' "$INPUT")

if [ "$DRY_RUN" = "1" ]; then
  printf '%s\n' "$PAYLOAD"
  exit 0
fi

# ------------------------------------------------------- where it goes ------

# Without owner/name the API path would read repos//pulls/<N>/reviews, which
# names no repository at all. Only posting needs this, so --dry-run has already
# printed its validated payload above.
[ -n "$OWNER_REPO" ] \
  || acr_die "cannot tell which repository to post to: meta.ownerRepo is empty and origin in $REPO_PATH gives no owner/name"
case "$OWNER_REPO" in
  */*/*|/*|*/|*[!-A-Za-z0-9./_]*) acr_die "meta.ownerRepo is not owner/name, refusing to post: $OWNER_REPO" ;;
  */*) : ;;
  *) acr_die "meta.ownerRepo is not owner/name, refusing to post: $OWNER_REPO" ;;
esac

# ---------------------------------------------------------- the head check --

if [ "$FORCE" != "1" ]; then
  LIVE=$( cd "$REPO_PATH" && "${GH:-gh}" pr view "$PR_NUMBER" --json headRefOid --jq '.headRefOid' 2>/dev/null ) \
    || acr_die "cannot read the current head of PR $PR_NUMBER, re-run with --force to post anyway"
  [ "$LIVE" = "$HEAD_SHA" ] \
    || acr_die "PR $PR_NUMBER moved: head is $LIVE, the review was built against $HEAD_SHA (re-scope, or --force)"
fi

# ------------------------------------------------------------- posting ------

printf '%s\n' "$PAYLOAD" > "$REVIEW_DIR/review.json"
"${GH:-gh}" api "repos/$OWNER_REPO/pulls/$PR_NUMBER/reviews" --input "$REVIEW_DIR/review.json" \
  > "$REVIEW_DIR/posted.json" \
  || acr_die "gh api refused the review, see $REVIEW_DIR/review.json"

printf '%s\n' "$PAYLOAD" | jq -r '
  (.comments // [])[]
  | ((.path // "?")
     + ":" + (if (.start_line // null) != null then ((.start_line|tostring) + "-") else "" end)
     + ((.line // "?") | tostring)
     + " side=" + (.side // "RIGHT")
     + " suggestion=" + (if ((.body // "") | contains("```suggestion")) then "yes" else "no" end))
'
