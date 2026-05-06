#!/usr/bin/env bash
# Replace the active Antistasi save with a backup file.
# Usage: scripts/restore-save.sh <path/to/file.vars.Arma3Profile>
set -euo pipefail

ARMA_PROFILE="${ARMA_PROFILE:-server}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${ROOT}/profiles/home/${ARMA_PROFILE}/${ARMA_PROFILE}.vars.Arma3Profile"

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <file.vars.Arma3Profile>" >&2
    echo "Available backups:" >&2
    ls -1t "${ROOT}/saves/backups/"*.vars.Arma3Profile 2>/dev/null | head -10 >&2 || echo "  (none)" >&2
    exit 1
fi

SRC="$1"
[ -s "${SRC}" ] || { echo "Source file is empty or missing: ${SRC}" >&2; exit 1; }

mkdir -p "$(dirname "${DEST}")"
if [ -s "${DEST}" ]; then
    cp -p "${DEST}" "${DEST}.bak.$(date +%s)"
fi
cp -f "${SRC}" "${DEST}"
echo "Restored: ${SRC} -> ${DEST}"
echo "Now restart the server: docker compose restart arma3"
