# dockerpbx

FreePBX 17 + Asterisk 22 on Debian 12, in a Docker container, on a Raspberry Pi
(arm64). Yes, really.

The build wraps [slythel2/freepbx-arm64-install](https://github.com/slythel2/freepbx-arm64-install)
(the `freepbx-arm64-raspberry` branch), which was written for bare-metal
Raspberry Pi OS. Three tricks make it work in a container:

1. **systemd is PID 1 at runtime** (`privileged` + `cgroup: host` + tmpfs on
   `/run`). FreePBX's world is systemd units; faking them with supervisord is
   where most attempts die.
2. **A build-time systemctl shim** (`systemctl-shim.sh`). systemd can't run
   during `docker build`, but the installer genuinely needs mariadb and
   asterisk *running* while it works. The shim launches them directly, and
   translates `systemctl enable` into the real `multi-user.target.wants`
   symlinks so the runtime boot is genuine. It is diverted over
   `/usr/bin/systemctl` for the build and removed from the final image.
3. **Named volumes, not bind mounts.** Docker seeds an empty named volume from
   the image's content at that path, which is how the installed FreePBX and
   the populated MariaDB datadir escape the image into persistent storage on
   first run. Bind mounts would shadow the install with empty directories.

Be honest with yourself about what the result is: a VM with extra steps. Host
networking (SIP/RTP need real source addresses), privileged (systemd). What you
gain over bare metal is an image you can rebuild, roll back, and put beside
other containers on the same Pi.

## Requirements

- Raspberry Pi 4 or 5 (2GB+ RAM; 4GB+ recommended), 64-bit OS, Docker + compose.
- **Build on the Pi itself** (or any arm64 machine). The Asterisk artifact is
  arm64-only; `platform: linux/arm64` in the compose file makes an amd64 build
  fail fast unless you have qemu/binfmt set up — and an emulated build that
  compiles nothing but *runs* mariadb and the FreePBX installer under qemu is
  slow enough that you don't want it anyway.
- ~4GB free disk for the build, plus your volumes.

## Quickstart

```sh
cp .env.example .env

# 1. Pin the installer to a commit SHA:
git ls-remote https://github.com/slythel2/freepbx-arm64-install freepbx-arm64-raspberry
#    -> put that SHA in .env as INSTALLER_REF

# 2. Generate the DB password (once, then never change it):
openssl rand -base64 24 | tr -d '/+='
#    -> put it in .env as FREEPBX_DB_PASS

# 3. Build and run. The build downloads a ~120MB Asterisk artifact and all
#    FreePBX modules; expect 30-60+ minutes on a Pi.
docker compose build
docker compose up -d
```

Then open `http://<pi-address>:8080/admin` and set the admin credentials
(FreePBX's first-boot screen). Give the container a few minutes on first start;
the healthcheck allows 5.

## What's pinned and what isn't

`INSTALLER_REF` pins `install.sh` only. The script then fetches:

- helper files (`asterisk.service`, fail2ban jails, my.cnf, …) from the **tip**
  of the `freepbx-arm64-raspberry` branch,
- the Asterisk tarball from the repo's **latest** GitHub release
  (sha256-verified against the release's own checksum — integrity, not
  reproducibility),
- FreePBX itself from `mirror.freepbx.org` (`17.0-latest`).

So a rebuild months later is *not* byte-identical. That's an upstream design
choice this repo can't fix without forking. It's fine for a homelab; know it.

## Day 2

- **Upgrades happen inside the running container** (`fwconsole ma upgradeall`,
  module admin in the GUI), not by rebuilding the image. The volumes hold
  `/var/www/html`, `/var/lib/asterisk`, `/etc/asterisk` and the DB — they
  shadow whatever a newer image contains, so rebuilding the image does not
  upgrade a deployed system.
- **Start over**: `docker compose down -v` (destroys the PBX config and CDRs),
  then `up -d` re-seeds from the image.
- **Backups**: use FreePBX's Backup & Restore module, or snapshot the named
  volumes. `FREEPBX_DB_PASS` in `.env` is part of your backup — the image and
  the mysql volume must agree on it.
- **Logs**: asterisk logs live in the `freepbx_logs` volume and are rotated by
  logrotate in-container. `docker exec freepbx journalctl -b` for the rest.

## Security notes, since this is a phone system

- `privileged` + host networking means the container is root-equivalent on the
  host. Treat it like a VM, because it is one.
- The admin UI listens on `0.0.0.0:${APACHE_PORT}` on the host. Firewall it to
  your LAN; don't port-forward it.
- fail2ban inside the container bans into the host's iptables — that's the
  point of host networking, bans hit the actual attacker.
- MariaDB binds to `127.0.0.1:3306`, which with host networking is the *host's*
  loopback. Password-protected, but local processes can reach it.
- The DB password is visible in `docker history` (build arg) and in
  `/etc/freepbx.conf` inside the image. The image is local and never pushed;
  keep it that way.
