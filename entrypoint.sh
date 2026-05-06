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
# When true, run SteamCMD app_update on every start. When false (default),
# skip it if the server binary is already present — avoids re-hitting Steam
# on every restart and prevents login rate-limit lockouts.
FORCE_UPDATE="${FORCE_UPDATE:-false}"
# local | github | workshop  — auto-picks `local` when LOCAL_MOD_PATH has
# something to copy, otherwise falls back to `github`. Workshop is opt-in.
LOCAL_MOD_PATH="${LOCAL_MOD_PATH:-/mod-src}"
if [ -z "${MOD_SOURCE:-}" ]; then
    if [ -d "${LOCAL_MOD_PATH}" ] \
       && find "${LOCAL_MOD_PATH}" -mindepth 1 -maxdepth 3 -type d -iname 'addons' \
              -print -quit 2>/dev/null | grep -q .; then
        MOD_SOURCE="local"
    else
        MOD_SOURCE="github"
    fi
fi

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
ARMA_BIN_PATH="${ARMA_DIR}/arma3server_x64"
if [ "${SKIP_INSTALL}" = "true" ]; then
    echo "[entrypoint] SKIP_INSTALL=true — skipping SteamCMD."
elif [ -x "${ARMA_BIN_PATH}" ] && [ "${FORCE_UPDATE}" != "true" ]; then
    echo "[entrypoint] arma3server_x64 already installed — skipping SteamCMD. Set FORCE_UPDATE=true to force an update."
else
    echo "[entrypoint] Installing/updating Arma 3 server (appid=${ARMA_APPID})..."
    if ! "${STEAMCMD}" \
            +force_install_dir "${ARMA_DIR}" \
            "${STEAM_LOGIN[@]}" \
            +app_update "${ARMA_APPID}" validate \
            +quit; then
        echo "[entrypoint] SteamCMD app_update failed. Sleeping 5 minutes before exit so the container restart loop doesn't trigger a Steam login rate-limit lockout." >&2
        sleep 300
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

install_antistasi_local() {
    echo "[entrypoint] Installing Antistasi from local path: ${LOCAL_MOD_PATH}"
    if [ ! -d "${LOCAL_MOD_PATH}" ]; then
        echo "[entrypoint] ERROR: ${LOCAL_MOD_PATH} doesn't exist (mount your mod files there)." >&2
        return 1
    fi
    local addons_dir src
    addons_dir="$(find "${LOCAL_MOD_PATH}" -mindepth 1 -maxdepth 4 -type d -iname 'addons' | head -n1)"
    if [ -z "${addons_dir}" ]; then
        echo "[entrypoint] ERROR: no addons/ directory under ${LOCAL_MOD_PATH}." >&2
        return 1
    fi
    src="$(dirname "${addons_dir}")"
    echo "[entrypoint] Local mod root: ${src}"
    rm -rf "${ARMA_DIR}/mods/@antistasi"
    cp -r "${src}" "${ARMA_DIR}/mods/@antistasi"
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
        7z)  7z x -y -o"${stage}" "${fname}" ;;
        rar) unrar-free -x "${fname}" "${stage}/" ;;
        zip) unzip -q "${fname}" -d "${stage}/" ;;
    esac
    # The mod root is whichever directory contains an `addons/` subdir.
    # That's universal for Arma 3 mods regardless of how the wrapper folder
    # is named (or whether one exists at all).
    local addons_dir extracted
    addons_dir="$(find "${stage}" -mindepth 1 -maxdepth 4 -type d -iname 'addons' | head -n1)"
    if [ -z "${addons_dir}" ]; then
        echo "[entrypoint] ERROR: no addons/ directory found in archive. Layout was:" >&2
        find "${stage}" -maxdepth 3 -printf '  %p\n' >&2 || true
        return 1
    fi
    extracted="$(dirname "${addons_dir}")"
    echo "[entrypoint] Mod root: ${extracted}"
    rm -rf "${ARMA_DIR}/mods/@antistasi"
    mv "${extracted}" "${ARMA_DIR}/mods/@antistasi"
    rm -rf "${tmp}"
}

if [ "${SKIP_MOD_INSTALL}" != "true" ] && [ ! -d "${ARMA_DIR}/mods/@antistasi/addons" ]; then
    echo "[entrypoint] MOD_SOURCE=${MOD_SOURCE}"
    case "${MOD_SOURCE}" in
        local)
            install_antistasi_local
            ;;
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
            echo "[entrypoint] ERROR: unknown MOD_SOURCE='${MOD_SOURCE}' (expected 'local', 'github', or 'workshop')." >&2
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
