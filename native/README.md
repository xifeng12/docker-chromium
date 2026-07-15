# Native Chrome noVNC for Ubuntu 24.04

This directory adds a **non-Docker** deployment path for running a visual Chrome browser on an Ubuntu 24.04 command-line machine.

It is intentionally separate from the upstream LinuxServer Docker image logic. The original repository remains Docker-first; this native layer is for offline machines where installing Docker is inconvenient or not allowed.

## Target scenario

```text
Online build machine
  -> builds an offline APT bundle
  -> copy bundle to offline Ubuntu 24.04 target
  -> install Chrome + Xvfb + Openbox + x11vnc + noVNC + websockify
  -> access visual Chrome from another browser
```

Default access URL after installation:

```text
http://TARGET_IP:6080/vnc.html
```

The actual browser runs on a virtual X display on the target machine. noVNC exposes that display through a normal web page.

## Architecture

```text
Google Chrome
  -> Xvfb virtual display :99
  -> Openbox window manager
  -> x11vnc on 127.0.0.1:5900
  -> websockify/noVNC on 0.0.0.0:6080
  -> client browser opens http://TARGET_IP:6080/vnc.html
```

## Files

```text
native/
├── README.md
├── scripts/
│   ├── build-offline-bundle.sh
│   ├── install-offline.sh
│   ├── preflight.sh
│   └── start-chrome-novnc.sh
└── systemd/
    └── chrome-novnc.service
```

## Build the offline bundle on an online Ubuntu 24.04 amd64 machine

Use a clean Ubuntu 24.04 environment when possible. This reduces the risk of missing dependencies because the online build machine already has packages installed.

```bash
cd native
chmod +x scripts/*.sh
./scripts/build-offline-bundle.sh
```

The script creates:

```text
native/offline-bundle/
├── repo/
│   ├── *.deb
│   └── Packages.gz
├── package-list.txt
├── skipped-packages.txt
└── chrome-novnc-offline-noble-amd64.tar.gz
```

Copy `native/offline-bundle/chrome-novnc-offline-noble-amd64.tar.gz` to the offline target machine.

## Install on the offline Ubuntu 24.04 target

On the target machine:

```bash
tar -xzf chrome-novnc-offline-noble-amd64.tar.gz
cd chrome-novnc-offline
chmod +x scripts/*.sh
VNC_PASSWORD='change-this-password' ./scripts/install-offline.sh --start
```

If `VNC_PASSWORD` is omitted and the script runs in an interactive terminal, it prompts for a password. In non-interactive mode it generates one and prints it once.

After installation, open from a machine that can reach the target:

```text
http://TARGET_IP:6080/vnc.html
```

Then enter the VNC password.

## Service commands

```bash
sudo systemctl status chrome-novnc
sudo systemctl restart chrome-novnc
sudo systemctl stop chrome-novnc
journalctl -u chrome-novnc -f
```

Runtime files are placed under:

```text
$HOME/chrome-novnc/
├── profile/
├── logs/
└── vnc.pass
```

## Preflight check

Run this on the target machine after install:

```bash
~/chrome-novnc/preflight.sh
```

It checks OS, architecture, required commands, port usage, service status, and the Chrome sandbox precondition.

## Security notes

This native mode runs directly on the host, not inside a container. Treat it as a host service.

Recommended minimum controls:

1. Keep it on a trusted LAN only.
2. Use a strong VNC password.
3. Do not expose port `6080` directly to the public Internet.
4. Use a VPN, SSH tunnel, or reverse proxy with strong authentication for remote access.
5. Run Chrome as a normal user, not root.

This implementation deliberately does **not** add `--no-sandbox` by default. If Chrome fails because the target host disallows unprivileged user namespaces, fix the host sandbox support instead of disabling the sandbox. Only use `--no-sandbox` as a last resort and document the risk.

## Common troubleshooting

### noVNC page opens but the screen is blank

Check service logs:

```bash
journalctl -u chrome-novnc -n 200 --no-pager
cat ~/chrome-novnc/logs/*.log
```

### Port 6080 is already used

Set a different port in the systemd unit:

```ini
Environment=NOVNC_PORT=6081
```

Then reload and restart:

```bash
sudo systemctl daemon-reload
sudo systemctl restart chrome-novnc
```

### Chrome exits immediately

Check:

```bash
google-chrome --version
sysctl kernel.unprivileged_userns_clone 2>/dev/null || true
cat ~/chrome-novnc/logs/chrome.log
```

### Chinese characters render as boxes

Make sure `fonts-noto-cjk` was installed from the offline bundle.
