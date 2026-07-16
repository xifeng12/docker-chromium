#!/usr/bin/env bash
set -euo pipefail

# Build an offline APT bundle for native Chrome + noVNC on Ubuntu 24.04 amd64.
# Run this on an ONLINE Ubuntu 24.04 amd64 machine or a clean Ubuntu 24.04 VM/container.
#
# PACKAGE_PROFILE=minimal  -> smallest practical bundle for Chrome + Xvfb + noVNC.
# PACKAGE_PROFILE=desktop  -> default; adds desktop/media/font packages inspired by
#                             common containerized Chrome setups, while validating
#                             every package against the Ubuntu 24.04 apt index.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${OUT_DIR:-$NATIVE_DIR/offline-bundle}"
REPO_DIR="$OUT_DIR/repo"
PKG_LIST="$OUT_DIR/package-list.txt"
ROOT_LIST="$OUT_DIR/root-package-list.txt"
SKIPPED_LIST="$OUT_DIR/skipped-packages.txt"
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
ARCH="$(dpkg --print-architecture)"
PACKAGE_PROFILE="${PACKAGE_PROFILE:-desktop}"

if [[ "$CODENAME" != "noble" ]]; then
  echo "ERROR: this builder expects Ubuntu 24.04 (noble), got: $CODENAME" >&2
  exit 1
fi

if [[ "$ARCH" != "amd64" ]]; then
  echo "ERROR: this builder currently expects amd64, got: $ARCH" >&2
  exit 1
fi

if [[ "$PACKAGE_PROFILE" != "minimal" && "$PACKAGE_PROFILE" != "desktop" ]]; then
  echo "ERROR: PACKAGE_PROFILE must be 'minimal' or 'desktop', got: $PACKAGE_PROFILE" >&2
  exit 1
fi

mkdir -p "$REPO_DIR"
rm -f "$REPO_DIR"/*.deb "$REPO_DIR"/Packages.gz "$PKG_LIST" "$ROOT_LIST" "$SKIPPED_LIST"

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

CORE_PACKAGES=(
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
  iproute2
  procps
  psmisc
  fontconfig
)

# Desktop/media/font compatibility packages. These are inspired by long-lived
# containerized Chrome setups such as jessfraz/dockerfiles, but this native
# builder validates every candidate before including it. Some historical package
# names differ across Debian/Ubuntu releases, so unavailable candidates are
# recorded in skipped-packages.txt instead of breaking the bundle.
DESKTOP_PACKAGES=(
  hicolor-icon-theme
  libcanberra-gtk-module
  libcanberra-gtk3-module
  libgl1
  libgl1-mesa-dri
  libglx-mesa0
  libpulse0
  libv4l-0
  fonts-symbola
  fonts-dejavu
  fonts-dejavu-core
  fonts-dejavu-extra
  libnss3
  libatk-bridge2.0-0
  libatk1.0-0
  libatspi2.0-0
  libcups2
  libdrm2
  libgbm1
  libgtk-3-0
  libx11-xcb1
  libxcb-dri3-0
  libxcomposite1
  libxdamage1
  libxfixes3
  libxkbcommon0
  libxrandr2
)

REQUESTED_PACKAGES=("${CORE_PACKAGES[@]}")
if [[ "$PACKAGE_PROFILE" == "desktop" ]]; then
  REQUESTED_PACKAGES+=("${DESKTOP_PACKAGES[@]}")
fi

: > "$ROOT_LIST"
: > "$SKIPPED_LIST"

for pkg in "${REQUESTED_PACKAGES[@]}"; do
  if apt-cache show "$pkg" >/dev/null 2>&1; then
    echo "$pkg" >> "$ROOT_LIST"
  else
    echo "$pkg" >> "$SKIPPED_LIST"
  fi
done
sort -u -o "$ROOT_LIST" "$ROOT_LIST"

# Expand the dependency closure package-by-package. Running apt-rdepends once for
# the whole list is fragile when optional package names are unavailable.
cp "$ROOT_LIST" "$PKG_LIST.tmp"
while IFS= read -r pkg; do
  [[ -z "$pkg" ]] && continue
  apt-rdepends "$pkg" 2>/dev/null | \
    awk '/^[A-Za-z0-9][A-Za-z0-9+.-]+$/{print $1}' >> "$PKG_LIST.tmp" || {
      echo "$pkg" >> "$SKIPPED_LIST"
    }
done < "$ROOT_LIST"

sort -u "$PKG_LIST.tmp" > "$PKG_LIST"
rm -f "$PKG_LIST.tmp"
sort -u -o "$SKIPPED_LIST" "$SKIPPED_LIST"

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

sort -u -o "$SKIPPED_LIST" "$SKIPPED_LIST"
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz
popd >/dev/null

# Copy native deployment files into a self-contained bundle directory.
BUNDLE_ROOT="$OUT_DIR/chrome-novnc-offline"
rm -rf "$BUNDLE_ROOT"
mkdir -p "$BUNDLE_ROOT"
cp -a "$NATIVE_DIR/scripts" "$BUNDLE_ROOT/"
cp -a "$NATIVE_DIR/systemd" "$BUNDLE_ROOT/"
cp -a "$REPO_DIR" "$BUNDLE_ROOT/repo"
cp "$ROOT_LIST" "$BUNDLE_ROOT/root-package-list.txt"
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
echo "Package profile: $PACKAGE_PROFILE"
echo "Root packages: $ROOT_LIST"
echo "Resolved package list: $PKG_LIST"
echo
echo "Skipped package candidates, if any:"
if [[ -s "$SKIPPED_LIST" ]]; then
  cat "$SKIPPED_LIST"
else
  echo "  none"
fi
