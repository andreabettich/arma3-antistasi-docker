#!/usr/bin/env bash
# Snapshot the current Antistasi save to ./saves/backups/<timestamp>.vars.Arma3Profile
set -euo pipefail

ARMA_PROFILE="${ARMA_PROFILE:-server}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${ROOT}/profiles/home/${ARMA_PROFILE}/${ARMA_PROFILE}.vars.Arma3Profile"
DEST_DIR="${ROOT}/saves/backups"
DEST="${DEST_DIR}/$(date +%Y-%m-%d-%H%M%S).vars.Arma3Profile"

if [ ! -s "${SRC}" ]; then
    echo "No save yet at ${SRC} — nothing to back up." >&2
    exit 1
fi

mkdir -p "${DEST_DIR}"
cp -p "${SRC}" "${DEST}"
echo "Backed up: ${DEST}"
ls -1tr "${DEST_DIR}" | head -n -10 | while read -r old; do
    [ -n "${old}" ] && rm -f "${DEST_DIR}/${old}"
done
