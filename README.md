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

Set these in `.env` (preferred) or `docker-compose.yml`. The entrypoint
re-renders `server.cfg` from a template on every boot, so changes apply
on `docker compose restart arma3` — no need to edit a file inside the volume.

### Server name and passwords

```
SERVER_HOSTNAME=My Antistasi Server
SERVER_PASSWORD=joinpassword       # leave empty for a public server
ADMIN_PASSWORD=pick-something-strong
```

In-game, type `#login <ADMIN_PASSWORD>` in chat to claim admin, then
`#missions` to open the mission selector. The entrypoint logs a warning if
`ADMIN_PASSWORD` is left as `changeme`.

### All env vars

| Var                  | Default                            | Notes |
| -------------------- | ---------------------------------- | ----- |
| `SERVER_HOSTNAME`    | `Antistasi Dedicated`              | Display name in the server browser. |
| `SERVER_PASSWORD`    | _(empty)_                          | Join password. Empty = public. |
| `ADMIN_PASSWORD`     | `changeme`                         | In-game `#login <pwd>` to gain admin. **Change this.** |
| `MAX_PLAYERS`        | `20`                               | Player slot count. |
| `MISSION_TEMPLATE`   | `Antistasi_Altis.Altis`            | Mission to load (e.g. `Antistasi_Tanoa.Tanoa`, `Antistasi_Enoch.Enoch`). |
| `MISSION_DIFFICULTY` | `Regular`                          | `Recruit` / `Regular` / `Veteran` / `Custom`. |
| `STEAM_USER`         | _(unset)_                          | **Required** Steam login (not SteamID) that owns Arma 3. |
| `STEAM_PASSWORD`     | _(unset)_                          | **Required.** Password for `STEAM_USER`. |
| `ARMA_PORT`          | `2302`                             | UDP game port. Update `ports:` mapping if you change this. |
| `ARMA_PROFILE`       | `server`                           | Profile name (used for `-name=` and the save path). |
| `ARMA_LIMITFPS`      | `1000`                             | Server FPS cap. |
| `ARMA_CONFIG`        | `server.cfg`                       | Config file under `/arma3/configs/`. |
| `ARMA_PARAMS`        | `-autoInit -loadMissionToMemory`   | Extra CLI flags appended to `arma3server_x64`. |
| `SKIP_INSTALL`       | `false`                            | Hard-skip SteamCMD entirely (no login attempt). |
| `FORCE_UPDATE`       | `false`                            | Run `app_update` even if the binary is already present. |
| `SKIP_MOD_INSTALL`   | `false`                            | Set to `true` to keep the existing `mods/@antistasi`. |
| `MOD_SOURCE`         | _auto_                             | `local`, `github`, or `workshop`. Auto-picks `local` when `./files` has Antistasi, else `github`. |
| `LOCAL_MOD_PATH`     | `/mod-src`                         | Path inside the container the local-mod source reads from. |
| `ANTISTASI_VERSION`  | `latest`                           | GitHub release tag (e.g. `3.11.1`) or `latest`. |
| `FORCE_MOD_UPDATE`   | `false`                            | One-shot: re-install the mod even if the marker matches. |

## Savegames

The container's profile directory is bind-mounted to `./profiles` on the host,
so the live save file is just a regular file you can copy, edit, scp, or
back up:

```
./profiles/home/${ARMA_PROFILE}/${ARMA_PROFILE}.vars.Arma3Profile
```

With the default `ARMA_PROFILE=server`, that's
`./profiles/home/server/server.vars.Arma3Profile`.

### Importing a save you already have

```bash
# from your laptop
scp ~/Documents/Arma\ 3\ -\ Other\ Profiles/<profile>/<profile>.vars.Arma3Profile \
    root@server:/opt/arma3/arma3-antistasi-docker/saves/import/myrun.vars.Arma3Profile
```

The entrypoint copies the newest `*.vars.Arma3Profile` from `./saves/import`
into the active profile slot **only if no save exists yet** (so re-imports
don't accidentally clobber server progress). To force-replace a save mid-run,
use `scripts/restore-save.sh` (see below) or copy the file directly to the
profile path above and `docker compose restart arma3`.

> **Caveat:** Singleplayer Antistasi saves and dedicated-server saves are
> stored under different variable names inside the same `.vars.Arma3Profile`.
> If your local game was a singleplayer / host-on-LAN session, the dedicated
> server may not see it as a loadable save. Workaround: load it locally
> first, use Antistasi's in-game admin "Backup save" tool to convert it,
> and import that.

### Backups

```bash
# snapshot the current save (keeps the 10 most recent in saves/backups/)
./scripts/backup-save.sh

# restore an earlier snapshot
./scripts/restore-save.sh saves/backups/2026-05-06-103015.vars.Arma3Profile
docker compose restart arma3
```

For automated backups, drop a cron entry on the host:

```cron
*/30 * * * * cd /opt/arma3/arma3-antistasi-docker && ./scripts/backup-save.sh >>/var/log/arma3-backup.log 2>&1
```

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

## Host firewall (UFW)

```bash
sudo ./scripts/setup-ufw.sh   # adds allow rules; does NOT enable UFW yet
sudo ufw enable               # enable once you've verified rules look right
```

Rules added (idempotent, safe to re-run):

- `OpenSSH` — keep your SSH session alive.
- `2302..2306/udp` — the five Arma 3 server ports. The base shifts with
  `ARMA_PORT` from `.env` if you've moved the server off the default.
- Default: deny incoming, allow outgoing.

> **Docker caveat:** Docker manages its own iptables chain ahead of UFW, so
> any port published in `docker-compose.yml` is reachable from the internet
> *regardless* of UFW. The setup script handles non-Docker traffic correctly
> (SSH and any host services). To also firewall Docker-published ports, look
> at [`ufw-docker`](https://github.com/chaifeng/ufw-docker), which patches
> rules into `DOCKER-USER`. Ask if you want me to wire that in.

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
