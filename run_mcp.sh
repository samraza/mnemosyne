#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="${SCRIPT_DIR}/.venv"
TRANSPORT="sse"
PORT="9090"
BANK="default"
TS_ENDPOINT="" # must be the complete format of machine where mcp will run e.g. machine.fable-vibe.ts.net
PID_DIR="/tmp/mnemosyne-mcp"

COMMAND=""

usage() {
  echo "Usage: $0 <start|stop|restart|status> [--bank <name>] [--port <port>] [--transport <stdio|sse>] [--ts-endpoint <host>]"
  echo ""
  echo "Commands:"
  echo "  start    Start the MCP server in the background"
  echo "  stop     Stop the MCP server and remove Tailscale routes"
  echo "  restart  Stop then start"
  echo "  status   Show all running mnemosyne MCP servers"
  echo ""
  echo "Options:"
  echo "  --bank        Memory bank (default: ${BANK})"
  echo "  --port        SSE port (default: ${PORT})"
  echo "  --transport   stdio or sse (default: ${TRANSPORT})"
  echo "  --ts-endpoint Tailscale hostname, e.g. machine.fable-vibe.ts.net (overrides TS_ENDPOINT)"
  echo ""
  echo "Examples:"
  echo "  $0 start --bank default --port 9090 --ts-endpoint macbook-pro.fable-vibe.ts.net"
  echo "  $0 start --bank work    --port 9091 --ts-endpoint macbook-pro.fable-vibe.ts.net"
  echo "  $0 start --bank personal --port 9092 --ts-endpoint macbook-pro.fable-vibe.ts.net"
  echo "  $0 stop  --bank default"
  echo "  $0 restart --bank work --port 9091 --ts-endpoint macbook-pro.fable-vibe.ts.net"
  echo "  $0 status"
  exit 1
}

if [[ $# -gt 0 && "$1" != --* ]]; then
  COMMAND="$1"; shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bank)        BANK="$2";        shift 2 ;;
    --port)        PORT="$2";        shift 2 ;;
    --transport)   TRANSPORT="$2";   shift 2 ;;
    --ts-endpoint) TS_ENDPOINT="$2"; shift 2 ;;
    -h|--help)     usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

mkdir -p "$PID_DIR"
PID_FILE="${PID_DIR}/mnemosyne-${BANK}.pid"
LOG_FILE="${PID_DIR}/mnemosyne-${BANK}.log"

do_stop() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" && echo "Stopped mnemosyne MCP server (bank=${BANK}, pid=${pid})"
    else
      echo "Process ${pid} was not running (stale pid file)"
    fi
    rm -f "$PID_FILE"
  else
    echo "No running server found for bank=${BANK}"
  fi
  tailscale serve --set-path="/${BANK}" off 2>/dev/null && echo "Removed Tailscale route /${BANK}" || true
  tailscale serve --set-path="/${BANK}/messages" off 2>/dev/null && echo "Removed Tailscale route /${BANK}/messages" || true
}

do_start() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      echo "Already running (bank=${BANK}, pid=${pid})"
      exit 1
    fi
    rm -f "$PID_FILE"
  fi

  # shellcheck source=/dev/null
  source "${VENV_DIR}/bin/activate"

  create_out=$(mnemosyne bank create "${BANK}" 2>&1) && echo "Created bank: ${BANK}" || {
    [[ "$create_out" == *"already exists"* ]] || { echo "$create_out" >&2; exit 1; }
  }

  if [[ -z "${TS_ENDPOINT}" ]]; then
    echo "Warning: TS_ENDPOINT is not set. Set it in the script or pass --ts-endpoint <host>."
  fi

  tailscale serve --bg --set-path="/${BANK}" "http://127.0.0.1:${PORT}/sse"
  tailscale serve --bg --set-path="/${BANK}/messages" "http://127.0.0.1:${PORT}/messages"

  mnemosyne mcp --bank "$BANK" --transport "$TRANSPORT" --port "$PORT" >> "$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"

  echo "Started mnemosyne MCP server"
  echo "  bank:     ${BANK}"
  echo "  pid:      $(cat "$PID_FILE")"
  echo "  log:      ${LOG_FILE}"
  echo "  endpoint: https://${TS_ENDPOINT}/${BANK}"
}

do_status() {
  local found=0
  shopt -s nullglob
  for pid_file in "${PID_DIR}"/mnemosyne-*.pid; do
    found=1
    local bank pid status
    bank=$(basename "$pid_file" .pid | sed 's/^mnemosyne-//')
    pid=$(cat "$pid_file")
    if kill -0 "$pid" 2>/dev/null; then
      status="running"
    else
      status="stopped (stale pid file)"
    fi
    echo "  ${bank}: ${status} (pid=${pid})"
  done
  [[ $found -eq 0 ]] && echo "No mnemosyne MCP servers found"
}

case "${COMMAND}" in
  start)   do_start ;;
  stop)    do_stop ;;
  restart) do_stop; do_start ;;
  status)  do_status ;;
  *)       usage ;;
esac
