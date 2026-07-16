#!/usr/bin/env bash
set -euo pipefail

# Start native visual Chrome through Xvfb + Openbox + x11vnc + noVNC.
# This script is intended to be run by systemd as a normal user.

DISPLAY_NUM="${DISPLAY_NUM:-99}"
export DISPLAY=":$DISPLAY_NUM"
WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
DEPTH="${DEPTH:-24}"
VNC_PORT="${VNC_PORT:-5900}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
APP_DIR="${APP_DIR:-$HOME/chrome-novnc}"
PROFILE_DIR="${PROFILE_DIR:-$APP_DIR/profile}"
LOG_DIR="${LOG_DIR:-$APP_DIR/logs}"
VNC_PASS_FILE="${VNC_PASS_FILE:-$APP_DIR/vnc.pass}"
START_URL="${START_URL:-about:blank}"

mkdir -p "$PROFILE_DIR" "$LOG_DIR"

if [[ "$(id -u)" -eq 0 ]]; then
  echo "ERROR: do not run Chrome as root." >&2
  exit 1
fi

for cmd in Xvfb openbox x11vnc websockify google-chrome; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: missing command: $cmd" >&2
    exit 1
  fi
done

if [[ ! -f "$VNC_PASS_FILE" ]]; then
  echo "ERROR: missing VNC password file: $VNC_PASS_FILE" >&2
  echo "Create it with: x11vnc -storepasswd 'strong-password' '$VNC_PASS_FILE'" >&2
  exit 1
fi

# Best-effort cleanup for manual restarts. systemd also kills the cgroup on stop.
pkill -u "$(id -u)" -f "Xvfb :$DISPLAY_NUM" 2>/dev/null || true
pkill -u "$(id -u)" -f "x11vnc .*:$DISPLAY_NUM" 2>/dev/null || true
pkill -u "$(id -u)" -f "websockify .* $NOVNC_PORT" 2>/dev/null || true

PIDS=()
cleanup() {
  for pid in "${PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

Xvfb "$DISPLAY" \
  -screen 0 "${WIDTH}x${HEIGHT}x${DEPTH}" \
  -ac \
  +extension GLX \
  +render \
  -noreset \
  >"$LOG_DIR/xvfb.log" 2>&1 &
PIDS+=("$!")
sleep 1

openbox \
  >"$LOG_DIR/openbox.log" 2>&1 &
PIDS+=("$!")
sleep 1

x11vnc \
  -display "$DISPLAY" \
  -forever \
  -shared \
  -rfbport "$VNC_PORT" \
  -passwdfile "$VNC_PASS_FILE" \
  -localhost \
  >"$LOG_DIR/x11vnc.log" 2>&1 &
PIDS+=("$!")
sleep 1

websockify \
  --web=/usr/share/novnc/ \
  "0.0.0.0:$NOVNC_PORT" \
  "127.0.0.1:$VNC_PORT" \
  >"$LOG_DIR/websockify.log" 2>&1 &
PIDS+=("$!")
sleep 1

google-chrome \
  --display="$DISPLAY" \
  --user-data-dir="$PROFILE_DIR" \
  --no-first-run \
  --disable-dev-shm-usage \
  --password-store=basic \
  --window-size="${WIDTH},${HEIGHT}" \
  "$START_URL" \
  >"$LOG_DIR/chrome.log" 2>&1 &
CHROME_PID="$!"
PIDS+=("$CHROME_PID")

wait "$CHROME_PID"
