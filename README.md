# Arma 3 Antistasi — Dockerized Dedicated Server

Runs an Arma 3 dedicated server on Linux with the Antistasi mod family
(Community or Ultimate) plus any support mods you list in `mods.conf`.
Intended for an Ubuntu 24.04 host, but the image is self-contained
and runs on any Linux Docker host.

## Layout

| File                 | Purpose                                                                 |
| -------------------- | ----------------------------------------------------------------------- |
| `Dockerfile`         | `ubuntu:24.04` base + SteamCMD + 32-bit libs the Arma 3 server needs.   |
| `entrypoint.sh`      | Installs/updates Arma 3, downloads Antistasi, launches `arma3server_x64`. |
| `server.cfg`         | Server config with the Antistasi mission cycle (Altis preconfigured).   |
| `docker-compose.yml` | Compose service exposing UDP ports 2302–2306 with a persistent volume.  |
| `mods.conf.example`  | Mod manifest template — copy to `mods.conf` and edit. |

## Quickstart (Ubuntu 24.04 host)

```bash
sudo apt install docker.io docker-compose-v2

# in this directory
cp .env.example .env
# edit .env and fill in STEAM_USER / STEAM_PASSWORD (account that owns Arma 3)
# and ADMIN_PASSWORD / SERVER_HOSTNAME / SERVER_PASSWORD as desired

cp mods.conf.example mods.conf
# edit mods.conf — pick which Antistasi flavor + which support mods

# Bind-mount dirs need to be writable by UID 1000 (the steam user inside
# the container). Skip this step if you'd rather use named volumes only.
mkdir -p ./files ./profiles ./saves/import ./saves/backups
sudo chown -R 1000:1000 ./files ./profiles ./saves

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

> **Before exposing the server publicly**, set `ADMIN_PASSWORD` in `.env` to
> something private. That password is what you type after `#login` in chat
> to become server admin. The entrypoint warns in the logs if it's left as
> the default `changeme`.

## How mods are installed

The server boots from a `mods.conf` manifest — one mod per line, format
`name|source|spec|tag`. Copy `mods.conf.example` to `mods.conf`, edit, then
`docker compose up -d`. The entrypoint reads the manifest, installs each mod
in order, and launches the server with `-mod=mods/@a;mods/@b;...`.

### Sources

- **`github`** — pulls a release asset from `https://github.com/<spec>`.
  `spec` is `owner/repo`; `tag` is the release tag (e.g. `v11.9.9`,
  `3.11.1`) or `latest`. Handles `.7z`, `.zip`, and `.rar` archives, and
  detects the mod root via its `addons/` directory regardless of whether the
  archive has a wrapper folder.
- **`workshop`** — downloads via SteamCMD. `spec` is the numeric workshop
  ID; `tag` is ignored (use `-`). Requires `STEAM_USER` and `STEAM_PASSWORD`.
  Less reliable than `github` for large items.
- **`local`** — copies from `./files/<spec>/` on the host. `spec` is the
  subdir name; `tag` is ignored (use `-`). Use this when you already have
  the mod files (e.g. extracted Workshop downloads from a dev rig).

### Example manifest (Antistasi Ultimate + CBA + ACE)

```
antistasi_ultimate|github|Antistasi-Ultimate-Community/A3-Antistasi-Ultimate|latest
cba_a3|workshop|450814997|-
ace3|workshop|463939057|-
```

Install order matters — dependencies must come first (CBA before ACE).

Per-mod state lives in `mods/@<name>/.installed-version`. When the requested
spec doesn't match the marker, the entrypoint re-downloads on next boot.
To force a re-install of every mod once: `FORCE_MOD_UPDATE=true docker
compose up -d`.

Mod `.bikey` files are copied into `/arma3/keys/` so signature checking
(`verifySignatures = 2`) works for every loaded mod. The entire mod tree is
lowercased on Linux (Arma 3 is case-sensitive there).

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
| `ARMA_BINARY`        | `./arma3server_x64`                | Server binary launched from `/arma3`. Override e.g. for `arma3serverprofiling_x64`. |
| `ARMA_WORLD`         | `empty`                            | Map preloaded by the engine before any mission loads. `empty` is the standard for dedicated servers. |
| `SKIP_INSTALL`       | `false`                            | Hard-skip SteamCMD entirely (no login attempt). |
| `FORCE_UPDATE`       | `false`                            | Re-run `app_update` on every start even if the binary is already present. Default `false` so restarts don't re-hit Steam — repeated logins can trip Steam's per-account rate limiter. |
| `SKIP_MOD_INSTALL`   | `false`                            | Set to `true` to keep the existing `mods/@antistasi`. |
| `MODS_FILE`          | `/mods.conf`                       | Path inside the container to the mod manifest (bind-mounted from `./mods.conf`). |
| `MOD_SRC_DIR`        | `/mod-src`                         | Container path where `local`-source mods are read from (bind-mounted from `./files`). |
| `FORCE_MOD_UPDATE`   | `false`                            | One-shot: re-install every mod even if markers match. |
| `BATTLEYE_ENABLE`    | `1`                                | `0` to disable BattlEye on the server. Useful for debugging client kicks. |
| `VERIFY_SIGNATURES`  | `2`                                | `0` = off, `2` = enforce signed mods. Drop to `0` if `verifySignatures = 2` is rejecting clients while you investigate. |

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

## Updating mods

Edit `mods.conf` — change the tag, add a row, remove a row — then
`docker compose restart arma3`. Only mods whose marker no longer matches
the manifest are re-downloaded; everything else is left alone.

```bash
# pin Antistasi Ultimate to a specific release
sed -i 's|antistasi_ultimate|github|.*|antistasi_ultimate|github|Antistasi-Ultimate-Community/A3-Antistasi-Ultimate|v11.9.9|' mods.conf
docker compose restart arma3

# force a one-shot reinstall of every mod (no edits needed)
FORCE_MOD_UPDATE=true docker compose up -d
```

Marker values per source:
- `github`: `github:<owner/repo>:<tag>`
- `workshop`: `workshop:<id>`
- `local`: `local:<subdir>`

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

# force-reinstall every mod (next boot):
FORCE_MOD_UPDATE=true docker compose up -d

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
