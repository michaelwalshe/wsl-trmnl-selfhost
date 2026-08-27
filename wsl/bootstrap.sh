#!/bin/bash
# Run once, inside a fresh WSL2 Ubuntu distro, to set up Podman as the
# container runtime for this project. Needs root for the package install
# (run via `wsl -d <distro> -u root -- bash bootstrap.sh`, or `sudo` if you
# have it configured); everything else runs as your normal user.
#
# Why Podman instead of Docker Desktop: no Windows GUI/service layer to
# run, and it's rootless/socket-activated rather than an always-running
# daemon -- lighter weight for something that just needs to sit in the
# background. The `podman-docker` package provides a `docker` command that
# is actually Podman underneath, so every `docker`/`docker compose`
# instruction elsewhere in this repo (and in Terminus's own docs) works
# unchanged.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root (this only installs packages): wsl -d <distro> -u root -- bash bootstrap.sh" >&2
    exit 1
fi

# SUDO_USER covers `sudo bash bootstrap.sh`; UID 1000 covers running this
# directly as root (e.g. `wsl -u root`), since that's WSL's default first
# non-root user regardless of how it's invoked.
TARGET_USER="${TARGET_USER:-${SUDO_USER:-$(getent passwd 1000 | cut -d: -f1)}}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    echo "Could not determine the non-root user to configure. Set TARGET_USER=<username> and re-run." >&2
    exit 1
fi

echo "Installing podman, podman-docker, jq..."
apt-get update -qq
apt-get install -y podman podman-docker jq

# The Ubuntu-packaged docker-compose (v1, Python) is too old to parse
# Terminus's compose file -- it predates the modern Compose Specification
# (no `version:` key, top-level `name:`, etc.). Install the real Compose v2
# Go binary instead, ahead of the old one on PATH.
echo "Installing Docker Compose v2..."
curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" \
    -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

echo "Enabling lingering for $TARGET_USER (lets user services run without an active login)..."
loginctl enable-linger "$TARGET_USER"

echo "Enabling the Podman API socket for $TARGET_USER..."
runuser -l "$TARGET_USER" -c 'systemctl --user enable --now podman.socket'

echo ""
echo "Done. Verify with:"
echo "  docker --version"
echo "  docker compose version"
echo ""
echo "Next: copy wsl/wsl.conf.example to /etc/wsl.conf and wsl/wslconfig.example"
echo "to %UserProfile%\\.wslconfig on Windows, then 'wsl --shutdown' and reopen."
