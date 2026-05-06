#!/usr/bin/env bash
# Idempotently set up UFW allow rules for the Arma 3 dedicated server.
#
# IMPORTANT — Docker caveat
# -------------------------
# Docker manages its own iptables chains (DOCKER-USER / DOCKER) which run
# *before* UFW's rules, so anything you publish with `ports:` in
# docker-compose.yml is reachable from the internet whether or not UFW is
# enabled. This script still configures UFW correctly for non-Docker
# traffic (SSH, host services), but to actually firewall Docker-published
# ports you also need `ufw-docker` (https://github.com/chaifeng/ufw-docker).
#
# Run this on the Docker host as root. It is safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Pull ARMA_PORT from .env if present, else default to 2302.
ARMA_PORT="2302"
if [ -f "${ROOT}/.env" ]; then
    val="$(grep -E '^ARMA_PORT=' "${ROOT}/.env" | tail -n1 | cut -d= -f2- | tr -d '"' || true)"
    [ -n "${val}" ] && ARMA_PORT="${val}"
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must run as root (sudo)." >&2
    exit 1
fi

if ! command -v ufw >/dev/null 2>&1; then
    echo "[setup-ufw] Installing ufw..."
    apt-get update -qq
    apt-get install -y --no-install-recommends ufw
fi

# Default policies.
ufw default deny incoming
ufw default allow outgoing

# SSH — make sure we don't lock ourselves out before enabling.
ufw allow OpenSSH || ufw allow 22/tcp comment 'ssh'

# Arma 3 dedicated server ports (UDP). All five shift together if ARMA_PORT
# changes, e.g. ARMA_PORT=2402 => 2402..2406.
for offset in 0 1 2 3 4; do
    port=$(( ARMA_PORT + offset ))
    ufw allow "${port}/udp" comment "arma3"
done

echo
ufw status verbose

cat <<EOM

[setup-ufw] Allow rules are in place.
[setup-ufw] To activate UFW now (won't drop your SSH session if rule above is correct):
              ufw enable
[setup-ufw] To disable later: ufw disable
[setup-ufw] Reminder: Docker-published ports bypass UFW. See the comment at the
            top of this script for context on integrating ufw-docker if you need
            that traffic firewalled.
EOM
