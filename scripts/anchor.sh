#!/usr/bin/env bash
# Reports where a file/line lands in the reviewed diff, as a GitHub review
# anchor. Usage: anchor.sh <file> <NEW:n|OLD:n>
set -euo pipefail

. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"

usage() { acr_die "usage: anchor.sh <file> <NEW:n|OLD:n>"; }

[ $# -eq 2 ] || usage
[ -n "$1" ] || usage

acr_review_dir

if acr_anchor "$1" "$2"; then
  printf 'side=%s line=%s hunk=%s\n' "$ACR_SIDE" "$ACR_LINE" "$ACR_HUNK"
else
  acr_die "$ACR_ERR"
fi
