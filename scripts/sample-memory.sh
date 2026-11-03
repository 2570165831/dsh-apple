#!/bin/bash
# Measure the app's resident memory in the simulator.
#
# Same method the B-stage report used, so the two sets of numbers are comparable:
# `ps -o rss=` against the app process once per second, then average and range.
#
# Usage: scripts/sample-memory.sh <label> <seconds>
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="${1:-idle}"
DURATION="${2:-30}"
OUT="$ROOT/logs"

PID=$(ps -axo pid,comm | awk '/DSHPortC\.app\/DSHPortC$/{print $1; exit}')
if [ -z "${PID:-}" ]; then
  echo "DSHPortC process not running; launch the app first" >&2
  exit 1
fi

mkdir -p "$OUT"
FILE="$OUT/memory-$LABEL.txt"
{
  echo "# label=$LABEL pid=$PID started=$(date -u +%FT%TZ)"
  for _ in $(seq 1 "$DURATION"); do
    # One line per second: rss (KB), cpu percent, virtual size (KB).
    ps -o rss=,pcpu=,vsz= -p "$PID" | awk '{printf "rss_kb=%s cpu_pct=%s vsz_kb=%s\n", $1, $2, $3}'
    sleep 1
  done
} > "$FILE"

echo "label=$LABEL pid=$PID samples=$DURATION"
awk -F'[= ]+' '/rss_kb=/ {sum+=$2; n++; if($2>max)max=$2; if(min==""||$2<min)min=$2}
  END {if(n) printf "rss avg=%.1f MB min=%.1f MB max=%.1f MB (n=%d)\n", sum/n/1024, min/1024, max/1024, n}' "$FILE"
awk -F'[= ]+' '/cpu_pct=/ {sum+=$4; n++} END {if(n) printf "cpu avg=%.1f%% (n=%d)\n", sum/n, n}' "$FILE"
