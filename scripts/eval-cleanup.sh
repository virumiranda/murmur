#!/bin/bash
# Runs every case in evals/cleanup-cases.txt through the cleanup step and prints what came out,
# so you can check a prompt change against all of them at once.
#
#   ./scripts/eval-cleanup.sh                       # uses the built binary and your config
#   ./scripts/eval-cleanup.sh evals/my-cases.txt 12 # other cases, 12 s between calls
#
# Each line of the cases file is "name|what you'd dictate". The pause keeps Groq's free tier
# (about 8,000 tokens a minute) from cutting in; with a paid plan you can use 0.
set -euo pipefail
cd "$(dirname "$0")/.."

cases="${1:-evals/cleanup-cases.txt}"
pause="${2:-10}"
bin=".build/release/Murmur"
[ -x "$bin" ] || swift build -c release

while IFS='|' read -r name text; do
  [ -z "$name" ] && continue
  out=$("$bin" --clean "$text" 2>/dev/null)
  printf '### %s\n> %s\n%s\n\n' "$name" "$text" "$out"
  sleep "$pause"
done < "$cases"
