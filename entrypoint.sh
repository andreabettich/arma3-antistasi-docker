#!/usr/bin/env bash
set -euo pipefail

ARMA_DIR="${ARMA_DIR:-/arma3}"
STEAMCMD="${STEAMCMD:-steamcmd}"
ARMA_APPID="${ARMA_APPID:-233780}"
ANTISTASI_WORKSHOP_ID="${ANTISTASI_WORKSHOP_ID:-2867537125}"

ARMA_BINARY="${ARMA_BINARY:-./arma3server_x64}"
ARMA_PORT="${ARMA_PORT:-2302}"
ARMA_PROFILE="${ARMA_PROFILE:-server}"
ARMA_WORLD="${ARMA_WORLD:-empty}"
ARMA_LIMITFPS="${ARMA_LIMITFPS:-1000}"
ARMA_CONFIG="${ARMA_CONFIG:-server.cfg}"
ARMA_PARAMS="${ARMA_PARAMS:-}"

SKIP_INSTALL="${SKIP_INSTALL:-false}"
SKIP_MOD_INSTALL="${SKIP_MOD_INSTALL:-false}"
# github | workshop  — github is more reliable; large Workshop items often
# fail with the generic SteamCMD "(Failure)" error.
MOD_SOURCE="${MOD_SOURCE:-github}"

mkdir -p "${ARMA_DIR}/configs" "${ARMA_DIR}/mods" "${ARMA_DIR}/keys"

# server.cfg: copy default once, never overwrite a user-edited file
if [ ! -f "${ARMA_DIR}/configs/${ARMA_CONFIG}" ]; then
    cp "/defaults/server.cfg" "${ARMA_DIR}/configs/${ARMA_CONFIG}"
fi

# ---- Build SteamCMD login args ----
# Anonymous works for SteamCMD itself but Arma 3 Dedicated Server (233780) is
# no longer reliably installable anonymously — Steam returns "No subscription".
# If STEAM_USER/STEAM_PASSWORD are set, log in with that account (must own Arma 3).
if [ -n "${STEAM_USER:-}" ] && [ -n "${STEAM_PASSWORD:-}" ]; then
    STEAM_LOGIN=( +login "${STEAM_USER}" "${STEAM_PASSWORD}" )
    echo "[entrypoint] Using Steam account: ${STEAM_USER}"
else
    STEAM_LOGIN=( +login anonymous )
    echo "[entrypoint] Using anonymous Steam login (may fail with 'No subscription' for app ${ARMA_APPID})"
fi

# ---- Install / update Arma 3 dedicated server via SteamCMD ----
if [ "${SKIP_INSTALL}" != "true" ]; then
    echo "[entrypoint] Installing/updating Arma 3 server (appid=${ARMA_APPID})..."
    if ! "${STEAMCMD}" \
            +force_install_dir "${ARMA_DIR}" \
            "${STEAM_LOGIN[@]}" \
            +app_update "${ARMA_APPID}" validate \
            +quit; then
        echo "[entrypoint] SteamCMD app_update failed. Sleeping 30s before exit so the container restart loop doesn't hammer Steam." >&2
        sleep 30
        exit 1
    fi
fi

# ---- Install Antistasi mod ----
# Strategy:
#   1. If STEAM_USER + STEAM_PASSWORD set, use SteamCMD workshop_download_item (Workshop)
#   2. Otherwise download the latest GitHub release archive
install_antistasi_workshop() {
    local src="${ARMA_DIR}/steamapps/workshop/content/107410/${ANTISTASI_WORKSHOP_ID}"
    local attempt
    for attempt in 1 2 3; do
        echo "[entrypoint] Downloading Antistasi via Steam Workshop (id=${ANTISTASI_WORKSHOP_ID}, attempt ${attempt}/3)..."
        "${STEAMCMD}" \
            +force_install_dir "${ARMA_DIR}" \
            "${STEAM_LOGIN[@]}" \
            +workshop_download_item 107410 "${ANTISTASI_WORKSHOP_ID}" validate \
            +quit || true
        if [ -d "${src}" ] && [ -n "$(ls -A "${src}" 2>/dev/null)" ]; then
            rm -rf "${ARMA_DIR}/mods/@antistasi"
            cp -r "${src}" "${ARMA_DIR}/mods/@antistasi"
            return 0
        fi
        echo "[entrypoint] Workshop download attempt ${attempt} failed; retrying after 10s..." >&2
        sleep 10
    done
    echo "[entrypoint] ERROR: Workshop download for ${ANTISTASI_WORKSHOP_ID} failed after 3 attempts." >&2
    return 1
}

install_antistasi_github() {
    echo "[entrypoint] Downloading Antistasi from GitHub releases..."
    local tmp
    tmp="$(mktemp -d)"
    local api="https://api.github.com/repos/official-antistasi-community/A3-Antistasi/releases/latest"
    local urls asset_url
    urls="$(curl -fsSL "${api}" \
        | grep -Eo '"browser_download_url": *"[^"]+\.(7z|zip|rar)"' \
        | sed -E 's/.*"(https[^"]+)".*/\1/')"
    # Antistasi ships .7z (e.g. @Antistasi_The_Mod_3_11_1.7z); fall back to zip/rar
    asset_url="$(echo "${urls}" | grep -E '\.7z$'  | head -n1 || true)"
    [ -z "${asset_url}" ] && asset_url="$(echo "${urls}" | grep -E '\.zip$' | head -n1 || true)"
    [ -z "${asset_url}" ] && asset_url="$(echo "${urls}" | head -n1 || true)"
    if [ -z "${asset_url}" ]; then
        echo "[entrypoint] ERROR: could not resolve Antistasi release asset URL" >&2
        return 1
    fi
    echo "[entrypoint] Asset: ${asset_url}"
    local fname="${tmp}/antistasi.${asset_url##*.}"
    curl -fsSL -o "${fname}" "${asset_url}"
    local stage="${tmp}/stage"
    mkdir -p "${stage}"
    case "${fname##*.}" in
        7z)  7z x -y -o"${stage}" "${fname}" >/dev/null ;;
        rar) unrar-free -x "${fname}" "${stage}/" ;;
        zip) unzip -q "${fname}" -d "${stage}/" ;;
    esac
    # Archive contains a top-level @Antistasi_The_Mod_X_Y_Z folder — find it
    local extracted
    extracted="$(find "${stage}" -maxdepth 2 -type d -iname '@*' | head -n1)"
    if [ -z "${extracted}" ]; then
        echo "[entrypoint] ERROR: no @<mod> folder found in archive" >&2
        return 1
    fi
    rm -rf "${ARMA_DIR}/mods/@antistasi"
    mv "${extracted}" "${ARMA_DIR}/mods/@antistasi"
    rm -rf "${tmp}"
}

if [ "${SKIP_MOD_INSTALL}" != "true" ] && [ ! -d "${ARMA_DIR}/mods/@antistasi/addons" ]; then
    case "${MOD_SOURCE}" in
        workshop)
            if [ -z "${STEAM_USER:-}" ] || [ -z "${STEAM_PASSWORD:-}" ]; then
                echo "[entrypoint] ERROR: MOD_SOURCE=workshop requires STEAM_USER and STEAM_PASSWORD." >&2
                exit 1
            fi
            install_antistasi_workshop
            ;;
        github)
            install_antistasi_github
            ;;
        *)
            echo "[entrypoint] ERROR: unknown MOD_SOURCE='${MOD_SOURCE}' (expected 'github' or 'workshop')." >&2
            exit 1
            ;;
    esac
fi

# Lowercase the mod tree (Arma 3 on Linux is case-sensitive)
if [ -d "${ARMA_DIR}/mods/@antistasi" ]; then
    find "${ARMA_DIR}/mods/@antistasi" -depth -execdir bash -c '
        for f; do
            l="${f,,}"
            [ "$f" != "$l" ] && mv -- "$f" "$l" || true
        done
    ' _ {} +
fi

# Copy mod bikeys into the server keys dir (signature checking)
if [ -d "${ARMA_DIR}/mods/@antistasi/keys" ]; then
    cp -f "${ARMA_DIR}/mods/@antistasi/keys/"*.bikey "${ARMA_DIR}/keys/" 2>/dev/null || true
fi

# ---- Build launch command ----
MOD_PARAM=""
if [ -d "${ARMA_DIR}/mods/@antistasi" ]; then
    MOD_PARAM="-mod=mods/@antistasi"
fi

cd "${ARMA_DIR}"

LAUNCH=( "${ARMA_BINARY}"
    "-limitFPS=${ARMA_LIMITFPS}"
    "-world=${ARMA_WORLD}"
    "-port=${ARMA_PORT}"
    "-name=${ARMA_PROFILE}"
    "-profiles=${ARMA_DIR}/configs/profiles"
    "-config=${ARMA_DIR}/configs/${ARMA_CONFIG}"
)
[ -n "${MOD_PARAM}" ] && LAUNCH+=( "${MOD_PARAM}" )
# Split user-supplied params on whitespace
if [ -n "${ARMA_PARAMS}" ]; then
    # shellcheck disable=SC2206
    LAUNCH+=( ${ARMA_PARAMS} )
fi

mkdir -p "${ARMA_DIR}/configs/profiles"

echo "[entrypoint] Launching: ${LAUNCH[*]}"
exec "${LAUNCH[@]}"
