#!/usr/bin/env bash
set -euo pipefail

# Install native Chrome + noVNC from a local offline APT repo.
# Usage:
#   VNC_PASSWORD='strong-password' ./scripts/install-offline.sh --start

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_SRC="$BUNDLE_DIR/repo"
REPO_DST="/opt/chrome-novnc-offline-repo"
APT_LIST="/etc/apt/sources.list.d/chrome-novnc-offline.list"
SERVICE_NAME="chrome-novnc.service"
START_AFTER_INSTALL=false

if [[ "${1:-}" == "--start" ]]; then
  START_AFTER_INSTALL=true
fi

if [[ ! -d "$REPO_SRC" || ! -f "$REPO_SRC/Packages.gz" ]]; then
  echo "ERROR: offline repo not found: $REPO_SRC" >&2
  exit 1
fi

CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
ARCH="$(dpkg --print-architecture)"

if [[ "$CODENAME" != "noble" ]]; then
  echo "ERROR: target must be Ubuntu 24.04 (noble), got: $CODENAME" >&2
  exit 1
fi

if [[ "$ARCH" != "amd64" ]]; then
  echo "ERROR: target must be amd64 for this bundle, got: $ARCH" >&2
  exit 1
fi

TARGET_USER="${TARGET_USER:-${SUDO_USER:-$USER}}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
if [[ -z "$TARGET_HOME" || ! -d "$TARGET_HOME" ]]; then
  echo "ERROR: cannot resolve home directory for user: $TARGET_USER" >&2
  exit 1
fi

APP_DIR="$TARGET_HOME/chrome-novnc"

sudo mkdir -p "$REPO_DST"
sudo cp -a "$REPO_SRC"/*.deb "$REPO_DST/"
sudo cp -a "$REPO_SRC/Packages.gz" "$REPO_DST/"

echo "deb [trusted=yes] file:$REPO_DST ./" | sudo tee "$APT_LIST" >/dev/null

APT_OFFLINE_OPTS=(
  -o "Dir::Etc::sourcelist=$APT_LIST"
  -o "Dir::Etc::sourceparts=-"
  -o "APT::Get::List-Cleanup=0"
)

sudo apt-get "${APT_OFFLINE_OPTS[@]}" update

sudo apt-get "${APT_OFFLINE_OPTS[@]}" install -y \
  google-chrome-stable \
  xvfb \
  openbox \
  x11vnc \
  novnc \
  websockify \
  dbus-x11 \
  fonts-liberation \
  fonts-noto-cjk \
  ca-certificates \
  xdg-utils \
  python3 \
  python3-websockify

sudo -u "$TARGET_USER" mkdir -p "$APP_DIR/profile" "$APP_DIR/logs"
sudo install -m 0755 "$SCRIPT_DIR/start-chrome-novnc.sh" "$APP_DIR/start-chrome-novnc.sh"
sudo install -m 0755 "$SCRIPT_DIR/preflight.sh" "$APP_DIR/preflight.sh"

VNC_PASS_FILE="$APP_DIR/vnc.pass"
if [[ ! -f "$VNC_PASS_FILE" ]]; then
  if [[ -n "${VNC_PASSWORD:-}" ]]; then
    PASS="$VNC_PASSWORD"
  elif [[ -t 0 ]]; then
    read -r -s -p "Set VNC password: " PASS
    echo
  else
    PASS="$(tr -dc 'A-Za-z0-9_@#%+=' </dev/urandom | head -c 24)"
    echo "Generated VNC password: $PASS"
    echo "Save it now; it will not be printed again."
  fi
  sudo -u "$TARGET_USER" x11vnc -storepasswd "$PASS" "$VNC_PASS_FILE" >/dev/null
  sudo chmod 600 "$VNC_PASS_FILE"
  sudo chown "$TARGET_USER:$TARGET_USER" "$VNC_PASS_FILE"
fi

TMP_SERVICE="$(mktemp)"
sed \
  -e "s|__USER__|$TARGET_USER|g" \
  -e "s|__APP_DIR__|$APP_DIR|g" \
  "$BUNDLE_DIR/systemd/$SERVICE_NAME" > "$TMP_SERVICE"
sudo install -m 0644 "$TMP_SERVICE" "/etc/systemd/system/$SERVICE_NAME"
rm -f "$TMP_SERVICE"

sudo systemctl daemon-reload
sudo systemctl enable chrome-novnc.service

if [[ "$START_AFTER_INSTALL" == "true" ]]; then
  sudo systemctl restart chrome-novnc.service
fi

echo
echo "Installed native Chrome noVNC service."
echo "User:       $TARGET_USER"
echo "App dir:    $APP_DIR"
echo "Service:    chrome-novnc.service"
echo "noVNC URL:  http://TARGET_IP:6080/vnc.html"
echo
echo "Next commands:"
echo "  sudo systemctl status chrome-novnc"
echo "  $APP_DIR/preflight.sh"
