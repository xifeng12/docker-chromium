#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-$HOME/chrome-novnc}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
VNC_PORT="${VNC_PORT:-5900}"
DISPLAY_NUM="${DISPLAY_NUM:-99}"
STATUS=0

ok() { echo "[OK] $*"; }
warn() { echo "[WARN] $*"; }
fail() { echo "[FAIL] $*"; STATUS=1; }

if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  if [[ "${VERSION_CODENAME:-}" == "noble" ]]; then
    ok "Ubuntu codename: noble"
  else
    fail "Expected Ubuntu 24.04 noble, got: ${PRETTY_NAME:-unknown}"
  fi
else
  fail "/etc/os-release not found"
fi

ARCH="$(dpkg --print-architecture 2>/dev/null || true)"
if [[ "$ARCH" == "amd64" ]]; then
  ok "Architecture: amd64"
else
  fail "Expected architecture amd64, got: ${ARCH:-unknown}"
fi

if [[ "$(id -u)" == "0" ]]; then
  fail "Do not run Chrome/noVNC as root. Use a normal user account."
else
  ok "Running as non-root user: $(id -un)"
fi

for cmd in google-chrome Xvfb openbox x11vnc websockify python3; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "Command found: $cmd"
  else
    fail "Missing command: $cmd"
  fi
done

for optional_cmd in ss df fc-match pgrep sysctl; do
  if command -v "$optional_cmd" >/dev/null 2>&1; then
    ok "Helper command found: $optional_cmd"
  else
    warn "Helper command missing: $optional_cmd"
  fi
done

if command -v google-chrome >/dev/null 2>&1; then
  google-chrome --version || warn "google-chrome --version failed"
fi

if [[ -d /usr/share/novnc ]]; then
  ok "noVNC web root exists: /usr/share/novnc"
else
  fail "noVNC web root missing: /usr/share/novnc"
fi

if [[ -f "$APP_DIR/vnc.pass" ]]; then
  ok "VNC password file exists: $APP_DIR/vnc.pass"
else
  fail "VNC password file missing: $APP_DIR/vnc.pass"
fi

if [[ -d "$APP_DIR/profile" ]]; then
  ok "Chrome profile directory exists: $APP_DIR/profile"
else
  warn "Chrome profile directory missing: $APP_DIR/profile"
fi

if systemctl list-unit-files chrome-novnc.service >/dev/null 2>&1; then
  ok "systemd unit is installed: chrome-novnc.service"
  systemctl is-active --quiet chrome-novnc.service && ok "service is active" || warn "service is not active"
else
  warn "systemd unit not found: chrome-novnc.service"
fi

if command -v ss >/dev/null 2>&1; then
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq ":${NOVNC_PORT}$"; then
    ok "noVNC port is listening: $NOVNC_PORT"
  else
    warn "noVNC port is not listening: $NOVNC_PORT"
  fi

  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "127\.0\.0\.1:${VNC_PORT}$|localhost:${VNC_PORT}$"; then
    ok "VNC port is listening on localhost: $VNC_PORT"
  else
    warn "VNC port is not listening on localhost: $VNC_PORT"
  fi
fi

if command -v pgrep >/dev/null 2>&1; then
  if pgrep -u "$(id -u)" -f "Xvfb :$DISPLAY_NUM" >/dev/null 2>&1; then
    ok "Xvfb display is running: :$DISPLAY_NUM"
  else
    warn "Xvfb display is not running: :$DISPLAY_NUM"
  fi
fi

if command -v df >/dev/null 2>&1; then
  SHM_KB="$(df -Pk /dev/shm 2>/dev/null | awk 'NR==2{print $2}')"
  if [[ -n "${SHM_KB:-}" ]]; then
    SHM_MB=$((SHM_KB / 1024))
    if (( SHM_MB >= 512 )); then
      ok "/dev/shm size: ${SHM_MB} MB"
    else
      warn "/dev/shm is only ${SHM_MB} MB; Chrome may crash or show blank tabs on heavy pages"
    fi
  else
    warn "Could not determine /dev/shm size"
  fi
fi

if command -v fc-match >/dev/null 2>&1; then
  if fc-match "Noto Sans CJK" >/dev/null 2>&1; then
    MATCHED_FONT="$(fc-match "Noto Sans CJK" | head -n 1)"
    ok "CJK font lookup works: $MATCHED_FONT"
  else
    warn "CJK font lookup failed; Chinese characters may render as boxes"
  fi
else
  warn "fontconfig is not available; cannot verify CJK fonts"
fi

SANDBOX_BIN="/opt/google/chrome/chrome-sandbox"
if [[ -e "$SANDBOX_BIN" ]]; then
  MODE="$(stat -c '%a %U:%G' "$SANDBOX_BIN" 2>/dev/null || true)"
  if [[ -u "$SANDBOX_BIN" && -x "$SANDBOX_BIN" ]]; then
    ok "Chrome setuid sandbox exists: $SANDBOX_BIN ($MODE)"
  else
    warn "Chrome sandbox binary exists but may not be setuid/executable: $SANDBOX_BIN ($MODE)"
  fi
else
  warn "Chrome sandbox binary not found at $SANDBOX_BIN"
fi

if [[ -r /proc/sys/kernel/unprivileged_userns_clone ]]; then
  VALUE="$(cat /proc/sys/kernel/unprivileged_userns_clone)"
  if [[ "$VALUE" == "1" ]]; then
    ok "Chrome sandbox precondition: unprivileged_userns_clone=1"
  else
    warn "unprivileged_userns_clone=$VALUE; Chrome may fail unless sandbox support is fixed"
  fi
else
  warn "Cannot read kernel.unprivileged_userns_clone; verify Chrome sandbox support if Chrome fails"
fi

if command -v sysctl >/dev/null 2>&1; then
  sysctl kernel.unprivileged_userns_clone 2>/dev/null || true
fi

HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [[ -n "$HOST_IP" ]]; then
  echo "Access URL candidate: http://$HOST_IP:$NOVNC_PORT/vnc.html"
else
  echo "Access URL candidate: http://TARGET_IP:$NOVNC_PORT/vnc.html"
fi

exit "$STATUS"
