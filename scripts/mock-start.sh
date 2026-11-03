#!/bin/bash
# Start (or stop, or check) the mock model server used by the ios-port-E
# end-to-end test.
#
#   scripts/mock-start.sh start      start in the background on 127.0.0.1:19700
#   scripts/mock-start.sh stop       stop the instance this script started
#   scripts/mock-start.sh status     health check + pid
#   scripts/mock-start.sh foreground run in the foreground (Ctrl-C to stop)
#
# Environment
#   MOCK_PORT              default 19700
#   MOCK_CHUNK_DELAY_MS    default 120
#   MOCK_LOG_DIR           default <repo>/logs
#
# The server binds loopback only; nothing outside this Mac can reach it.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE_BIN:-/opt/homebrew/bin/node}"
MOCK_PORT="${MOCK_PORT:-19700}"
LOG_DIR="${MOCK_LOG_DIR:-$REPO_ROOT/logs}"
PID_FILE="$LOG_DIR/mock-server.pid"
OUT_LOG="$LOG_DIR/mock-server.log"

mkdir -p "$LOG_DIR"

if [ ! -x "$NODE_BIN" ]; then
  echo "mock-start: node not found at $NODE_BIN (override with NODE_BIN=...)" >&2
  exit 1
fi

health() {
  curl -sS -m 2 "http://127.0.0.1:${MOCK_PORT}/healthz" 2>/dev/null
}

running_pid() {
  if [ -f "$PID_FILE" ]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null)"
    if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
      echo "$pid"
      return 0
    fi
  fi
  return 1
}

case "${1:-start}" in
  start)
    if pid="$(running_pid)"; then
      echo "mock-start: already running (pid $pid) on port $MOCK_PORT"
      health; echo
      exit 0
    fi
    echo "mock-start: launching $NODE_BIN mock/server.mjs on 127.0.0.1:$MOCK_PORT"
    MOCK_PORT="$MOCK_PORT" MOCK_LOG_DIR="$LOG_DIR" \
      nohup "$NODE_BIN" "$REPO_ROOT/mock/server.mjs" >>"$OUT_LOG" 2>&1 &
    pid=$!
    echo "$pid" >"$PID_FILE"
    for _ in $(seq 1 50); do
      if health >/dev/null 2>&1; then
        echo "mock-start: up (pid $pid)"
        health; echo
        echo "mock-start: log $OUT_LOG"
        exit 0
      fi
      if ! kill -0 "$pid" 2>/dev/null; then
        echo "mock-start: process exited during startup; tail of $OUT_LOG:" >&2
        tail -20 "$OUT_LOG" >&2
        exit 1
      fi
      sleep 0.1
    done
    echo "mock-start: no /healthz answer within 5s; tail of $OUT_LOG:" >&2
    tail -20 "$OUT_LOG" >&2
    exit 1
    ;;
  stop)
    if pid="$(running_pid)"; then
      kill "$pid" 2>/dev/null
      for _ in $(seq 1 30); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
      done
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
      echo "mock-start: stopped pid $pid"
    else
      echo "mock-start: no tracked instance"
    fi
    rm -f "$PID_FILE"
    ;;
  status)
    if pid="$(running_pid)"; then
      echo "mock-start: pid $pid"
    else
      echo "mock-start: no tracked instance"
    fi
    if health; then echo; else echo "mock-start: /healthz not answering on port $MOCK_PORT" >&2; exit 1; fi
    ;;
  foreground)
    exec env MOCK_PORT="$MOCK_PORT" MOCK_LOG_DIR="$LOG_DIR" "$NODE_BIN" "$REPO_ROOT/mock/server.mjs"
    ;;
  *)
    echo "usage: $0 {start|stop|status|foreground}" >&2
    exit 2
    ;;
esac
