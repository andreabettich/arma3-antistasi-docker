#!/usr/bin/env bash
set -euo pipefail

ARMA_DIR="${ARMA_DIR:-/arma3}"
STEAMCMD="${STEAMCMD:-steamcmd}"
ARMA_APPID="${ARMA_APPID:-233780}"

ARMA_BINARY="${ARMA_BINARY:-./arma3server_x64}"
ARMA_PORT="${ARMA_PORT:-2302}"
ARMA_PROFILE="${ARMA_PROFILE:-server}"
ARMA_WORLD="${ARMA_WORLD:-empty}"
ARMA_LIMITFPS="${ARMA_LIMITFPS:-1000}"
ARMA_CONFIG="${ARMA_CONFIG:-server.cfg}"
ARMA_PARAMS="${ARMA_PARAMS:-}"

# server.cfg template variables — defaults make sense for a private game.
export SERVER_HOSTNAME="${SERVER_HOSTNAME:-Antistasi Dedicated}"
export SERVER_PASSWORD="${SERVER_PASSWORD:-}"
export ADMIN_PASSWORD="${ADMIN_PASSWORD:-changeme}"
export MAX_PLAYERS="${MAX_PLAYERS:-20}"
export MISSION_TEMPLATE="${MISSION_TEMPLATE:-Antistasi_Altis.Altis}"
export MISSION_DIFFICULTY="${MISSION_DIFFICULTY:-Regular}"
export BATTLEYE_ENABLE="${BATTLEYE_ENABLE:-1}"            # 0 = disable BE
export VERIFY_SIGNATURES="${VERIFY_SIGNATURES:-2}"        # 0 = off, 2 = enforce

SKIP_INSTALL="${SKIP_INSTALL:-false}"
SKIP_MOD_INSTALL="${SKIP_MOD_INSTALL:-false}"
# When true, run SteamCMD app_update on every start. When false (default),
# skip it if the server binary is already present — avoids re-hitting Steam
# on every restart and prevents login rate-limit lockouts.
FORCE_UPDATE="${FORCE_UPDATE:-false}"
# When true, re-install every mod even if its marker matches.
FORCE_MOD_UPDATE="${FORCE_MOD_UPDATE:-false}"

# Path to the mod manifest. Default looks for /mods.conf inside the container
# (bind-mounted from ./mods.conf on the host). See mods.conf.example.
MODS_FILE="${MODS_FILE:-/mods.conf}"

# Path under which `local` mods live (each one in a subdir). Bind-mount your
# host's ./files there.
MOD_SRC_DIR="${MOD_SRC_DIR:-/mod-src}"

write_marker() {
    # write_marker <name> <value>
    echo "$2" > "${ARMA_DIR}/mods/@$1/.installed-version"
}

install_mod_github() {
    # install_mod_github <name> <owner/repo> <tag>
    local name="$1" repo="$2" tag="$3"
    echo "[entrypoint] Installing ${name} from GitHub (${repo}@${tag})..."
    local tmp api
    tmp="$(mktemp -d)"
    if [ "${tag}" = "latest" ]; then
        api="https://api.github.com/repos/${repo}/releases/latest"
    else
        api="https://api.github.com/repos/${repo}/releases/tags/${tag}"
    fi
    local urls asset_url
    urls="$(curl -fsSL "${api}" \
        | grep -Eo '"browser_download_url": *"[^"]+\.(7z|zip|rar)"' \
        | sed -E 's/.*"(https[^"]+)".*/\1/')"
    asset_url="$(echo "${urls}" | grep -E '\.7z$'  | head -n1 || true)"
    [ -z "${asset_url}" ] && asset_url="$(echo "${urls}" | grep -E '\.zip$' | head -n1 || true)"
    [ -z "${asset_url}" ] && asset_url="$(echo "${urls}" | head -n1 || true)"
    if [ -z "${asset_url}" ]; then
        echo "[entrypoint] ERROR: no release asset for ${repo}@${tag}" >&2
        rm -rf "${tmp}"
        return 1
    fi
    echo "[entrypoint] Asset: ${asset_url}"
    local fname="${tmp}/mod.${asset_url##*.}"
    curl -fsSL -o "${fname}" "${asset_url}"
    local stage="${tmp}/stage"
    mkdir -p "${stage}"
    case "${fname##*.}" in
        7z)  7z x -y -o"${stage}" "${fname}" ;;
        rar) unrar-free -x "${fname}" "${stage}/" ;;
        zip) unzip -q "${fname}" -d "${stage}/" ;;
    esac
    local addons_dir extracted
    addons_dir="$(find "${stage}" -mindepth 1 -maxdepth 4 -type d -iname 'addons' | head -n1)"
    if [ -z "${addons_dir}" ]; then
        echo "[entrypoint] ERROR: no addons/ in ${repo}@${tag} archive. Contents:" >&2
        find "${stage}" -maxdepth 3 -printf '  %p\n' >&2 || true
        rm -rf "${tmp}"
        return 1
    fi
    extracted="$(dirname "${addons_dir}")"
    rm -rf "${ARMA_DIR}/mods/@${name}"
    mv "${extracted}" "${ARMA_DIR}/mods/@${name}"
    write_marker "${name}" "github:${repo}:${tag}"
    rm -rf "${tmp}"
}

install_mod_workshop() {
    # install_mod_workshop <name> <workshop_id>
    local name="$1" wid="$2"
    local src="${ARMA_DIR}/steamapps/workshop/content/107410/${wid}"
    local attempt
    for attempt in 1 2 3; do
        echo "[entrypoint] Downloading ${name} via Workshop (id=${wid}, attempt ${attempt}/3)..."
        "${STEAMCMD}" \
            +force_install_dir "${ARMA_DIR}" \
            "${STEAM_LOGIN[@]}" \
            +workshop_download_item 107410 "${wid}" validate \
            +quit || true
        if [ -d "${src}" ] && [ -n "$(ls -A "${src}" 2>/dev/null)" ]; then
            rm -rf "${ARMA_DIR}/mods/@${name}"
            cp -r "${src}" "${ARMA_DIR}/mods/@${name}"
            write_marker "${name}" "workshop:${wid}"
            return 0
        fi
        echo "[entrypoint] Workshop attempt ${attempt} failed; retrying after 10s..." >&2
        sleep 10
    done
    echo "[entrypoint] ERROR: Workshop download for ${wid} failed after 3 attempts." >&2
    return 1
}

install_mod_local() {
    # install_mod_local <name> <subdir>
    local name="$1" subdir="$2"
    local root="${MOD_SRC_DIR}/${subdir}"
    echo "[entrypoint] Installing ${name} from local path: ${root}"
    if [ ! -d "${root}" ]; then
        echo "[entrypoint] ERROR: ${root} doesn't exist (drop the mod files there)." >&2
        return 1
    fi
    local addons_dir src
    addons_dir="$(find "${root}" -mindepth 1 -maxdepth 4 -type d -iname 'addons' | head -n1)"
    if [ -z "${addons_dir}" ]; then
        echo "[entrypoint] ERROR: no addons/ under ${root}." >&2
        return 1
    fi
    src="$(dirname "${addons_dir}")"
    rm -rf "${ARMA_DIR}/mods/@${name}"
    cp -r "${src}" "${ARMA_DIR}/mods/@${name}"
    write_marker "${name}" "local:${subdir}"
}

mkdir -p "${ARMA_DIR}/configs" "${ARMA_DIR}/configs/profiles/home/${ARMA_PROFILE}" \
         "${ARMA_DIR}/mods" "${ARMA_DIR}/keys"

# server.cfg: render the template every boot so .env / compose env changes
# (hostname, passwords, mission) are picked up on `docker compose restart`.
echo "[entrypoint] Rendering ${ARMA_CONFIG} from template..."
envsubst < "/defaults/server.cfg" > "${ARMA_DIR}/configs/${ARMA_CONFIG}"

if [ "${ADMIN_PASSWORD}" = "changeme" ] || [ -z "${ADMIN_PASSWORD}" ]; then
    echo "[entrypoint] WARNING: ADMIN_PASSWORD is unset or 'changeme' — anyone can claim admin. Set it in .env." >&2
fi

# Auto-import a savegame: anything dropped into /saves/import as
# *.vars.Arma3Profile gets copied into the active profile slot if no save
# is present yet. The newest file wins.
SAVE_DEST="${ARMA_DIR}/configs/profiles/home/${ARMA_PROFILE}/${ARMA_PROFILE}.vars.Arma3Profile"
if [ -d /saves/import ] && [ ! -s "${SAVE_DEST}" ]; then
    # Use a glob with nullglob so no matches => empty array (no failure under
    # set -e + pipefail).
    shopt -s nullglob
    saves=(/saves/import/*.vars.Arma3Profile)
    shopt -u nullglob
    if [ "${#saves[@]}" -gt 0 ]; then
        # newest by mtime
        import=""
        for f in "${saves[@]}"; do
            if [ -z "${import}" ] || [ "${f}" -nt "${import}" ]; then
                import="${f}"
            fi
        done
        echo "[entrypoint] Importing savegame: ${import} -> ${SAVE_DEST}"
        mkdir -p "$(dirname "${SAVE_DEST}")"
        cp -f "${import}" "${SAVE_DEST}"
    fi
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

# ---- Install mods from manifest ----
declare -a MOD_NAMES=()

if [ "${SKIP_MOD_INSTALL}" = "true" ]; then
    echo "[entrypoint] SKIP_MOD_INSTALL=true — using whatever's already on disk."
elif [ ! -f "${MODS_FILE}" ]; then
    echo "[entrypoint] WARNING: no manifest at ${MODS_FILE}; launching with no mods." >&2
else
    echo "[entrypoint] Reading manifest: ${MODS_FILE}"
    while IFS='|' read -r name source spec tag || [ -n "${name}" ]; do
        # trim whitespace
        name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"
        source="${source#"${source%%[![:space:]]*}"}"; source="${source%"${source##*[![:space:]]}"}"
        spec="${spec#"${spec%%[![:space:]]*}"}"; spec="${spec%"${spec##*[![:space:]]}"}"
        tag="${tag#"${tag%%[![:space:]]*}"}"; tag="${tag%"${tag##*[![:space:]]}"}"

        # skip blanks and comments
        [ -z "${name}" ] && continue
        case "${name}" in \#*) continue ;; esac

        MOD_NAMES+=("${name}")

        case "${source}" in
            github)   requested_marker="github:${spec}:${tag}" ;;
            workshop) requested_marker="workshop:${spec}" ;;
            local)    requested_marker="local:${spec}" ;;
            *)
                echo "[entrypoint] ERROR: ${name}: unknown source '${source}' (github|workshop|local)" >&2
                exit 1
                ;;
        esac

        need_install=true
        if [ -d "${ARMA_DIR}/mods/@${name}/addons" ] \
           && [ -f "${ARMA_DIR}/mods/@${name}/.installed-version" ] \
           && [ "${FORCE_MOD_UPDATE}" != "true" ]; then
            installed_marker="$(cat "${ARMA_DIR}/mods/@${name}/.installed-version")"
            if [ "${installed_marker}" = "${requested_marker}" ]; then
                echo "[entrypoint] ${name}: already installed (${installed_marker}) — skipping."
                need_install=false
            else
                echo "[entrypoint] ${name}: refresh (installed=${installed_marker}, requested=${requested_marker})"
            fi
        fi

        if [ "${need_install}" = "true" ]; then
            case "${source}" in
                github)
                    install_mod_github "${name}" "${spec}" "${tag}"
                    ;;
                workshop)
                    if [ -z "${STEAM_USER:-}" ] || [ -z "${STEAM_PASSWORD:-}" ]; then
                        echo "[entrypoint] ERROR: ${name}: workshop source requires STEAM_USER + STEAM_PASSWORD" >&2
                        exit 1
                    fi
                    install_mod_workshop "${name}" "${spec}"
                    ;;
                local)
                    install_mod_local "${name}" "${spec}"
                    ;;
            esac
        fi
    done < "${MODS_FILE}"
fi

# Arma 3 on Linux is case-sensitive; lowercase every mod tree we installed,
# and copy any .bikey files into the server keys dir.
for name in "${MOD_NAMES[@]}"; do
    [ -d "${ARMA_DIR}/mods/@${name}" ] || continue
    find "${ARMA_DIR}/mods/@${name}" -depth -execdir bash -c '
        for f; do
            l="${f,,}"
            [ "$f" != "$l" ] && mv -- "$f" "$l" || true
        done
    ' _ {} +
    if [ -d "${ARMA_DIR}/mods/@${name}/keys" ]; then
        cp -f "${ARMA_DIR}/mods/@${name}/keys/"*.bikey "${ARMA_DIR}/keys/" 2>/dev/null || true
    fi
done

# ---- Build launch command ----
MOD_PARAM=""
if [ "${#MOD_NAMES[@]}" -gt 0 ]; then
    mod_paths=()
    for name in "${MOD_NAMES[@]}"; do
        [ -d "${ARMA_DIR}/mods/@${name}" ] && mod_paths+=("mods/@${name}")
    done
    if [ "${#mod_paths[@]}" -gt 0 ]; then
        # Arma 3 separates mod entries with `;`
        old_ifs="$IFS"; IFS=';'
        MOD_PARAM="-mod=${mod_paths[*]}"
        IFS="$old_ifs"
    fi
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
