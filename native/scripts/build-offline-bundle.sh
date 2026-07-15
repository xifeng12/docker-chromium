#!/usr/bin/env bash
set -euo pipefail

# Build an offline APT bundle for native Chrome + noVNC on Ubuntu 24.04 amd64.
# Run this on an ONLINE Ubuntu 24.04 amd64 machine or a clean Ubuntu 24.04 VM/container.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${OUT_DIR:-$NATIVE_DIR/offline-bundle}"
REPO_DIR="$OUT_DIR/repo"
PKG_LIST="$OUT_DIR/package-list.txt"
SKIPPED_LIST="$OUT_DIR/skipped-packages.txt"
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
ARCH="$(dpkg --print-architecture)"

if [[ "$CODENAME" != "noble" ]]; then
  echo "ERROR: this builder expects Ubuntu 24.04 (noble), got: $CODENAME" >&2
  exit 1
fi

if [[ "$ARCH" != "amd64" ]]; then
  echo "ERROR: this builder currently expects amd64, got: $ARCH" >&2
  exit 1
fi

mkdir -p "$REPO_DIR"
rm -f "$REPO_DIR"/*.deb "$REPO_DIR"/Packages.gz "$PKG_LIST" "$SKIPPED_LIST"

sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg dpkg-dev apt-rdepends

sudo install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/google-linux-signing-key.asc ]]; then
  curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | \
    sudo tee /etc/apt/keyrings/google-linux-signing-key.asc >/dev/null
fi
sudo chmod a+r /etc/apt/keyrings/google-linux-signing-key.asc

sudo tee /etc/apt/sources.list.d/google-chrome.sources >/dev/null <<'EOF'
Types: deb
URIs: https://dl.google.com/linux/chrome/deb/
Suites: stable
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/google-linux-signing-key.asc
EOF

sudo apt-get update

ROOT_PACKAGES=(
  google-chrome-stable
  xvfb
  openbox
  x11vnc
  novnc
  websockify
  dbus-x11
  fonts-liberation
  fonts-noto-cjk
  ca-certificates
  xdg-utils
  python3
  python3-websockify
)

printf '%s\n' "${ROOT_PACKAGES[@]}" > "$PKG_LIST.tmp"

# apt-rdepends expands the dependency closure. We keep only package-name lines and
# then validate each package with apt-cache before downloading.
apt-rdepends "${ROOT_PACKAGES[@]}" 2>/dev/null | \
  awk '/^[A-Za-z0-9][A-Za-z0-9+.-]+$/{print $1}' >> "$PKG_LIST.tmp"

sort -u "$PKG_LIST.tmp" > "$PKG_LIST"
rm -f "$PKG_LIST.tmp"
: > "$SKIPPED_LIST"

pushd "$REPO_DIR" >/dev/null
while IFS= read -r pkg; do
  [[ -z "$pkg" ]] && continue
  if apt-cache show "$pkg" >/dev/null 2>&1; then
    echo "Downloading $pkg"
    if ! apt-get download "$pkg"; then
      echo "$pkg" >> "$SKIPPED_LIST"
    fi
  else
    echo "$pkg" >> "$SKIPPED_LIST"
  fi
done < "$PKG_LIST"

dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz
popd >/dev/null

# Copy native deployment files into a self-contained bundle directory.
BUNDLE_ROOT="$OUT_DIR/chrome-novnc-offline"
rm -rf "$BUNDLE_ROOT"
mkdir -p "$BUNDLE_ROOT"
cp -a "$NATIVE_DIR/scripts" "$BUNDLE_ROOT/"
cp -a "$NATIVE_DIR/systemd" "$BUNDLE_ROOT/"
cp -a "$REPO_DIR" "$BUNDLE_ROOT/repo"
cp "$PKG_LIST" "$BUNDLE_ROOT/package-list.txt"
cp "$SKIPPED_LIST" "$BUNDLE_ROOT/skipped-packages.txt"
cp "$NATIVE_DIR/README.md" "$BUNDLE_ROOT/README.md"

TARBALL="$OUT_DIR/chrome-novnc-offline-noble-amd64.tar.gz"
tar -C "$OUT_DIR" -czf "$TARBALL" chrome-novnc-offline
sha256sum "$TARBALL" > "$TARBALL.sha256"

echo
echo "Offline bundle created:"
echo "  $TARBALL"
echo "  $TARBALL.sha256"
echo
echo "Skipped package candidates, if any:"
if [[ -s "$SKIPPED_LIST" ]]; then
  cat "$SKIPPED_LIST"
else
  echo "  none"
fi
