# Arma 3 Antistasi — Dockerized Dedicated Server

Runs an Arma 3 dedicated server on Linux with the
[Antistasi](https://github.com/official-antistasi-community/A3-Antistasi) mod
preinstalled. Intended for an Ubuntu 24.04 host, but the image is self-contained
and runs on any Linux Docker host.

## Layout

| File                 | Purpose                                                                 |
| -------------------- | ----------------------------------------------------------------------- |
| `Dockerfile`         | `ubuntu:24.04` base + SteamCMD + 32-bit libs the Arma 3 server needs.   |
| `entrypoint.sh`      | Installs/updates Arma 3, downloads Antistasi, launches `arma3server_x64`. |
| `server.cfg`         | Server config with the Antistasi mission cycle (Altis preconfigured).   |
| `docker-compose.yml` | Compose service exposing UDP ports 2302–2306 with a persistent volume.  |

## Quickstart (Ubuntu 24.04 host)

```bash
sudo apt install docker.io docker-compose-v2

# in this directory
cp .env.example .env
# edit .env and fill in STEAM_USER / STEAM_PASSWORD (account that owns Arma 3)
docker compose up -d --build
docker compose logs -f
```

> **Steam credentials are required.** Anonymous SteamCMD login is rejected by
> Steam for app 233780 (`Failed to install app '233780' (No subscription)`).
> Use an account that owns Arma 3. The credentials are read from `.env`
> (gitignored) and consumed only inside the container.
>
> If your account has Steam Guard, you'll need to authorize the login once —
> `docker compose run --rm arma3 steamcmd +login $STEAM_USER` interactively
> on the host, accept the email/2FA code, then bring the stack up normally.

First boot pulls ~15 GB of Arma 3 data into the named volume `arma3-data`. After
that, restarts are fast.

> **Before exposing the server publicly**, edit `server.cfg` and change
> `passwordAdmin = "changeme"` to something private. That password is what you
> type after `#login` in chat to become server admin.

## How mods are installed

Antistasi is installed by the entrypoint on first boot. Three sources, in
auto-detect order:

1. **Local (recommended).** Drop the extracted `@Antistasi_The_Mod_*` folder
   into `./files/` on the host (the dir is bind-mounted into the container at
   `/mod-src`). Easy to update: replace the folder, `docker compose restart
   arma3`. No network / no Steam dependency. Auto-picked when `./files` has a
   directory containing `addons/`.
2. **GitHub release.** Pulls the latest `.7z` (with `.zip` / `.rar`
   fallbacks) from `official-antistasi-community/A3-Antistasi`. Used when
   `./files` is empty.
3. **Steam Workshop.** Opt in with `MOD_SOURCE=workshop` (also requires
   `STEAM_USER` / `STEAM_PASSWORD`). Workshop is the least reliable path —
   SteamCMD often fails large items with the generic
   `Download item ... failed (Failure)` error — so it's not a default.

Whatever the source, the resulting mod root is renamed to `@antistasi` so the
`-mod=mods/@antistasi` launch param keeps working across version bumps.

The mod tree is lowercased after extraction (Arma 3 on Linux is
case-sensitive). Mod `.bikey` files are copied into `/arma3/keys/` so signature
checking (`verifySignatures = 2`) works.

## Configuration

Edit `docker-compose.yml` to change runtime behavior. Useful env vars:

| Var                 | Default                            | Notes |
| ------------------- | ---------------------------------- | ----- |
| `ARMA_PORT`         | `2302`                             | UDP game port. If you change this, also update the `ports:` mapping. |
| `ARMA_PROFILE`      | `server`                           | Profile name (used for `-name=` and `-profiles=`). |
| `ARMA_LIMITFPS`     | `1000`                             | Server FPS cap. |
| `ARMA_CONFIG`       | `server.cfg`                       | Config file under `/arma3/configs/`. |
| `ARMA_PARAMS`       | `-autoInit -loadMissionToMemory`   | Extra CLI flags appended to `arma3server_x64`. |
| `SKIP_INSTALL`      | `false`                            | Hard-skip SteamCMD entirely (no login attempt). |
| `FORCE_UPDATE`      | `false`                            | Run `app_update` even if the server binary is already present. By default we skip SteamCMD when `arma3server_x64` exists, to avoid Steam login rate limits on restart. |
| `SKIP_MOD_INSTALL`  | `false`                            | Set to `true` to keep your existing `mods/@antistasi`. |
| `STEAM_USER`        | _(unset)_                          | **Required.** Steam account login (not SteamID, not display name) that owns Arma 3. |
| `STEAM_PASSWORD`    | _(unset)_                          | **Required.** Password for `STEAM_USER`. |
| `MOD_SOURCE`        | _auto_                             | `local`, `github`, or `workshop`. If unset, picks `local` when `./files` has an Antistasi folder, else `github`. |
| `LOCAL_MOD_PATH`    | `/mod-src`                         | Path inside the container that the local-mod source reads from (bind-mounted from `./files`). |
| `ANTISTASI_VERSION` | `latest`                           | GitHub release tag (e.g. `3.11.1`) or `latest`. Drives the version marker; changing it triggers a re-download on next start. |
| `FORCE_MOD_UPDATE`  | `false`                            | One-shot: re-install the mod even if the installed marker matches the requested version. |

`server.cfg` is copied into the volume on first boot and **not** overwritten
afterwards. To edit it later, change the file inside the volume:

```bash
docker compose exec arma3 vi /arma3/configs/server.cfg
docker compose restart arma3
```

…or copy a new one in from the host with `docker cp`.

## Updating Antistasi

The entrypoint records the installed version in
`mods/@antistasi/.installed-version`. When the requested version doesn't
match the marker, the mod is re-downloaded on next start.

```bash
# pin to a specific release
echo 'ANTISTASI_VERSION=3.11.1' >> .env
docker compose restart arma3

# always track the latest GitHub release
echo 'ANTISTASI_VERSION=latest' >> .env
docker compose restart arma3

# one-shot forced re-install (no version bump):
FORCE_MOD_UPDATE=true docker compose up -d
```

Marker values per source:

- `github`: the release tag, or `latest`.
- `local`: literal `local` (drop in new files and set `FORCE_MOD_UPDATE=true`
  once to refresh).
- `workshop`: `workshop:<id>`.

## Ports

All UDP. Map every one of these on your firewall / router:

| Port  | Purpose            |
| ----- | ------------------ |
| 2302  | Game traffic       |
| 2303  | Steam query        |
| 2304  | Steam master       |
| 2305  | VON (voice)        |
| 2306  | BattlEye           |

## Common operations

```bash
# tail server log (the in-game log; not stdout)
docker compose exec arma3 tail -f /arma3/configs/profiles/server.log

# update Arma 3 to latest:
docker compose down
docker compose up -d            # entrypoint runs SteamCMD validate

# force-reinstall Antistasi (next boot):
docker compose exec arma3 rm -rf /arma3/mods/@antistasi
docker compose restart arma3

# wipe everything and start over:
docker compose down -v          # -v deletes the arma3-data volume
```

## Becoming admin in-game

In the in-game chat:

```
#login <passwordAdmin from server.cfg>
#missions
```

The first command makes you admin; the second opens the mission selector so you
can start an Antistasi mission.

## Troubleshooting

- **First boot is slow / appears stuck.** It's downloading ~15 GB. Watch
  `docker compose logs -f` — SteamCMD prints download progress.
- **`arma3server_x64: not found`.** SteamCMD failed. Most often this is a
  network/firewall block on Steam's CDN. Re-run `docker compose up -d`.
- **Mod signature mismatch.** Make sure clients are loading the *same*
  Antistasi version as the server (Antistasi: only one Antistasi mod loaded at
  a time, loaded as `-mod` not `-servermod`).
- **BattlEye kicks everyone.** Set `battlEye = 0` in `server.cfg` while
  debugging, then re-enable.
- **Steam returns `Rate Limit Exceeded`.** Stop the container immediately
  (`docker compose stop`) — the restart loop is what's causing it. Wait
  30–60+ minutes for the cooldown to clear, then bring it back up. Once the
  server binary is installed, the entrypoint won't re-call SteamCMD on
  subsequent restarts (set `FORCE_UPDATE=true` only when you actually want to
  patch).
- **Antistasi `.7z` extraction fails.** The image installs `p7zip-full` — if
  you've stripped it, reinstall it. RAR5 fallback uses `unrar-free`, which
  doesn't handle RAR5; in that case set `STEAM_USER` / `STEAM_PASSWORD` to
  switch to Workshop.

## References

- Antistasi beginner's guide:
  <https://official-antistasi-community.github.io/A3-Antistasi-Docs/beginners_guide/raw_beginners_guide.html>
- Arma 3 dedicated server wiki:
  <https://community.bistudio.com/wiki/Arma_3:_Dedicated_Server>
- Inspiration / reference image: <https://github.com/BrettMayson/Arma3Server>
