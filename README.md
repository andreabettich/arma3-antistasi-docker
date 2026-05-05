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

Antistasi is installed by the entrypoint on first boot:

1. **Default — GitHub release.** Pulls the latest release asset from
   `official-antistasi-community/A3-Antistasi`. Antistasi ships a `.7z`
   (e.g. `@Antistasi_The_Mod_3_11_1.7z`); the entrypoint also handles `.zip` /
   `.rar` as fallbacks. The extracted `@Antistasi_The_Mod_*` folder is renamed
   to `@antistasi` so the `-mod=mods/@antistasi` launch param keeps working
   across Antistasi version bumps.
2. **Optional — Steam Workshop.** Set `MOD_SOURCE=workshop` (in addition to the
   already-required `STEAM_USER` / `STEAM_PASSWORD`). The entrypoint then uses
   `workshop_download_item 107410 2867537125` and retries up to 3× — the
   Workshop path frequently fails for Antistasi with SteamCMD's generic
   `Download item ... failed (Failure)` error, so GitHub is the default.

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
| `SKIP_INSTALL`      | `false`                            | Set to `true` after first install to skip the SteamCMD update on every boot. |
| `SKIP_MOD_INSTALL`  | `false`                            | Set to `true` to keep your existing `mods/@antistasi`. |
| `STEAM_USER`        | _(unset)_                          | **Required.** Steam account login (not SteamID, not display name) that owns Arma 3. |
| `STEAM_PASSWORD`    | _(unset)_                          | **Required.** Password for `STEAM_USER`. |
| `MOD_SOURCE`        | `github`                           | `github` or `workshop`. Workshop is flakier; defaults to GitHub. |

`server.cfg` is copied into the volume on first boot and **not** overwritten
afterwards. To edit it later, change the file inside the volume:

```bash
docker compose exec arma3 vi /arma3/configs/server.cfg
docker compose restart arma3
```

…or copy a new one in from the host with `docker cp`.

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
