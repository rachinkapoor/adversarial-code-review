#!/usr/bin/env bash
# The candidate ledger: a markdown table in $REVIEW_DIR/candidates.md.
#
#   ledger.sh add <angle> <file> <NEW:n|OLD:n> <summary>   prints the new id
#   ledger.sh set <id> <status> [evidence]
#   ledger.sh list [status]
set -euo pipefail

. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"

HEADER='| id | angle | file:line | summary | status | evidence |'
SEPARATOR='|---|---|---|---|---|---|'
STATUSES="new merged cut verifying CONFIRMED PLAUSIBLE REFUTED latent"

usage() {
  acr_die "usage: ledger.sh add <angle> <file> <NEW:n|OLD:n> <summary> | ledger.sh set <id> <status> [evidence] | ledger.sh list [status]"
}

# Unescaped pipes separate the columns, so a pipe inside a field is escaped and
# control characters that would break the row are flattened to spaces.
cell() { printf '%s' "$1" | sed -e 's/|/\\|/g' | tr '\n\r\t' '   '; }

LEDGER=""   # set once REVIEW_DIR is known

# Splits a table row on its unescaped pipes and trims each column, so that
# field N is the same column in every row no matter what the text holds.
ROW_AWK='
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function unsentinel(s,   out, p) {
  out = ""
  while ((p = index(s, "\001")) > 0) {
    out = out substr(s, 1, p - 1) "\\|"
    s = substr(s, p + 1)
  }
  return out s
}
function fields(line, f,   tmp, n, i) {
  tmp = line
  gsub(/\\\|/, "\001", tmp)
  n = split(tmp, f, "|")
  for (i = 1; i <= n; i++) f[i] = unsentinel(trim(f[i]))
  return n
}
'

ensure_table() {
  if [ ! -f "$LEDGER" ]; then
    printf '%s\n%s\n' "$HEADER" "$SEPARATOR" > "$LEDGER"
  fi
}

# The highest candidate number in the table, 0 when there are no rows.
last_id() {
  awk "$ROW_AWK"'
    NR > 2 {
      fields($0, f)
      if (f[2] ~ /^C[0-9]+$/) { n = substr(f[2], 2) + 0; if (n > m) m = n }
    }
    END { print m + 0 }
  ' "$LEDGER"
}

row_exists() { # <id>
  awk -v id="$1" "$ROW_AWK"'
    NR > 2 { fields($0, f); if (f[2] == id) found = 1 }
    END { exit found ? 0 : 1 }
  ' "$LEDGER"
}

valid_status() { # <status>
  local s
  for s in $STATUSES; do [ "$s" = "$1" ] && return 0; done
  return 1
}

cmd=${1:-}
[ -n "$cmd" ] || usage
shift || true

acr_review_dir create
LEDGER="$REVIEW_DIR/candidates.md"

case "$cmd" in
  add)
    [ $# -eq 4 ] || usage
    # Reading the highest id and appending the next one is one step for the
    # caller, so parallel finders must not interleave it or they share an id.
    acr_lock ledger
    ensure_table
    id="C$(( $(last_id) + 1 ))"
    printf '| %s | %s | %s | %s | %s | %s |\n' \
      "$id" "$(cell "$1")" "$(cell "$2:$3")" "$(cell "$4")" "new" "" >> "$LEDGER"
    acr_unlock
    printf '%s\n' "$id"
    ;;

  set)
    [ $# -ge 2 ] && [ $# -le 3 ] || usage
    id="$1"; status="$2"; evidence="${3:-}"
    valid_status "$status" || acr_die "unknown status: $status (allowed: $STATUSES)"
    # Rewriting the whole table is a read-modify-write, so it holds the same
    # lock as `add`: without it one parallel update overwrites another.
    acr_lock ledger
    [ -f "$LEDGER" ] || acr_die "no ledger yet: $LEDGER"
    row_exists "$id" || acr_die "unknown candidate id: $id"
    tmp="$LEDGER.$$"
    awk -v id="$id" -v st="$status" -v ev="$(cell "$evidence")" "$ROW_AWK"'
      NR <= 2 { print; next }
      {
        n = fields($0, f)
        if (f[2] != id || n < 7) { print; next }
        f[6] = st
        if (ev != "") f[7] = ev
        printf "| %s | %s | %s | %s | %s | %s |\n", f[2], f[3], f[4], f[5], f[6], f[7]
      }
    ' "$LEDGER" > "$tmp"
    mv "$tmp" "$LEDGER"
    acr_unlock
    ;;

  list)
    [ $# -le 1 ] || usage
    [ -f "$LEDGER" ] || acr_die "no ledger yet: $LEDGER"
    want="${1:-}"
    if [ -n "$want" ]; then
      valid_status "$want" || acr_die "unknown status: $want (allowed: $STATUSES)"
    fi
    awk -v want="$want" "$ROW_AWK"'
      NR <= 2 { print; next }
      { n = fields($0, f); if (want == "" || f[6] == want) print }
    ' "$LEDGER"
    ;;

  *) usage ;;
esac
