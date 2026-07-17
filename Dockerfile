# syntax=docker/dockerfile:1
#
# FreePBX 17 + Asterisk 22 on Debian 12 (arm64), via slythel2/freepbx-arm64-install.
#
# systemd runs as PID 1 at runtime. During the build, a shim stands in for
# systemctl (see systemctl-shim.sh) because the installer genuinely needs
# mariadb and asterisk to be running while it works.
#
FROM debian:12

# Pin this to a COMMIT SHA, not a branch. See README.
ARG INSTALLER_REF=main

# The installer generates a random FreePBX DB password. We pin it afterwards so
# that rebuilding the image doesn't desync from the existing mysql volume.
ARG FREEPBX_DB_PASS

# Apache's port. Not 80 -- you have another container on this host.
ARG APACHE_PORT=8080

# Used for postfix's mailname and the FreePBX vhost.
ARG PBX_HOSTNAME=pbx.home.arpa

# Baked into the image. A TZ env var on the container does not reliably reach
# services under systemd; /etc/localtime does.
ARG TZ=Etc/UTC

ENV DEBIAN_FRONTEND=noninteractive \
    container=docker \
    TERM=xterm \
    LANG=C.UTF-8

# --------------------------------------------------------------------------
# Base image + systemd
# --------------------------------------------------------------------------
# cron and logrotate are preinstalled on the Raspberry Pi OS the installer
# targets, but absent from debian:12. FreePBX registers crontab entries during
# its install (needs the crontab binary at build time), and asterisk's logs
# need rotating at runtime.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus \
      ca-certificates wget curl gnupg \
      procps psmisc iproute2 less \
      cron logrotate \
 && rm -rf /var/lib/apt/lists/*

# --------------------------------------------------------------------------
# Stop apt/dpkg from trying to start daemons mid-build.
# The shim starts what the installer actually needs, explicitly.
# --------------------------------------------------------------------------
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
 && chmod +x /usr/sbin/policy-rc.d

# --------------------------------------------------------------------------
# Divert the real systemctl and drop the build shim in its place.
# --------------------------------------------------------------------------
COPY systemctl-shim.sh /usr/local/bin/systemctl-shim.sh
RUN chmod +x /usr/local/bin/systemctl-shim.sh \
 && dpkg-divert --local --rename --add /usr/bin/systemctl \
 && ln -sf /usr/local/bin/systemctl-shim.sh /usr/bin/systemctl

# postfix is preseeded from `hostname -f`, which inside a build container is a
# random hex string. Set it before the installer runs.
RUN echo "${PBX_HOSTNAME}" > /etc/mailname \
 && echo "${PBX_HOSTNAME}" > /etc/hostname \
 && ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime \
 && echo "${TZ}" > /etc/timezone

# --------------------------------------------------------------------------
# Run the installer.
#
#   --skipversion  MANDATORY. Its update check does a bare `read` on a newer
#                  release; with no TTY that hits EOF and the script exits 0
#                  having installed nothing. Your build would "succeed" empty.
#   --nochrony     chrony cannot set the clock in a container. The host owns time.
# --------------------------------------------------------------------------
ADD https://raw.githubusercontent.com/slythel2/freepbx-arm64-install/${INSTALLER_REF}/install.sh /tmp/install.sh

RUN set -eux; \
    test -n "${FREEPBX_DB_PASS}" || { echo "FREEPBX_DB_PASS build-arg is required"; exit 1; }; \
    chmod +x /tmp/install.sh; \
    \
    # ---- neuter configure_swap. It runs `swapon` and a bare `sysctl`, both -- \
    # ---- EPERM in an unprivileged build container; under the script's set -e  \
    # ---- that kills the build on any host with <512MB swap and <=4GB RAM ---- \
    # ---- (i.e. most Pis). It would also dd a 1-2GB /swapfile into this layer. \
    # ---- The host owns swap, like time. grep first so a future INSTALLER_REF  \
    # ---- that renames the function fails loudly instead of regressing. ------ \
    grep -q '^configure_swap() {' /tmp/install.sh; \
    sed -i 's/^configure_swap() {/configure_swap() { return 0;/' /tmp/install.sh; \
    \
    # ---- the installer writes a DAHDI stub into /etc/modprobe.d without ----- \
    # ---- mkdir. The dir comes from kmod, present on Pi OS but not in the ---- \
    # ---- debian:12 image; the failed redirect kills the script (set -e). ---- \
    mkdir -p /etc/modprobe.d; \
    \
    # ---- on failure, dump the installer's logs into the build output. The --- \
    # ---- script does `exec 2>>$LOG_FILE`, so the real error is in a file ---- \
    # ---- that dies with the failed build, not on your terminal. ------------- \
    bash /tmp/install.sh --skipversion --nochrony || { \
      ec=$?; \
      echo "==== install.sh failed (exit $ec); tail of /var/log/pbx ===="; \
      tail -n 300 /var/log/pbx/*.log 2>/dev/null || true; \
      echo "==== tail of FreePBX core install log (if it got that far) ===="; \
      tail -n 100 /tmp/freepbx_install.log 2>/dev/null || true; \
      exit "$ec"; \
    }; \
    \
    # ---- pin the FreePBX DB password (installer randomised it) ------------- \
    mysql -u root -e "ALTER USER 'asterisk'@'localhost' IDENTIFIED BY '${FREEPBX_DB_PASS}'; \
                      ALTER USER 'asterisk'@'127.0.0.1' IDENTIFIED BY '${FREEPBX_DB_PASS}'; \
                      FLUSH PRIVILEGES;"; \
    sed -i "s#AMPDBPASS'\] = '[^']*'#AMPDBPASS'] = '${FREEPBX_DB_PASS}'#" /etc/freepbx.conf; \
    mysql -u asterisk -p"${FREEPBX_DB_PASS}" -e "SELECT 1;" >/dev/null; \
    \
    # ---- recreate debian-sys-maint (policy-rc.d blocked mariadb's postinst) - \
    SYSPW="$(awk -F'= *' '/^password/{print $2; exit}' /etc/mysql/debian.cnf || true)"; \
    if [ -n "$SYSPW" ]; then \
      mysql -u root -e "CREATE USER IF NOT EXISTS 'debian-sys-maint'@'localhost' IDENTIFIED BY '${SYSPW}'; \
                        GRANT ALL PRIVILEGES ON *.* TO 'debian-sys-maint'@'localhost' WITH GRANT OPTION; \
                        FLUSH PRIVILEGES;"; \
    fi; \
    \
    # ---- shut everything down cleanly, or the datadir bakes in dirty -------- \
    (asterisk -rx "core stop now" >/dev/null 2>&1 || pkill -x asterisk || true); sleep 2; \
    (apache2ctl -k stop >/dev/null 2>&1 || true); \
    mysqladmin shutdown; \
    rm -f /tmp/install.sh /var/log/mariadb-build.log

# --------------------------------------------------------------------------
# Remove the shim. Real systemctl is restored for runtime.
# --------------------------------------------------------------------------
RUN rm -f /usr/bin/systemctl \
 && dpkg-divert --local --rename --remove /usr/bin/systemctl \
 && rm -f /usr/sbin/policy-rc.d /usr/local/bin/systemctl-shim.sh

# --------------------------------------------------------------------------
# Move Apache off :80 -- network_mode: host means it would fight your other
# container for the port.
# --------------------------------------------------------------------------
RUN sed -i "s/^Listen 80$/Listen ${APACHE_PORT}/" /etc/apache2/ports.conf \
 && sed -i "s|<VirtualHost \*:80>|<VirtualHost *:${APACHE_PORT}>|" \
      /etc/apache2/sites-available/freepbx.conf

# --------------------------------------------------------------------------
# The installer preseeds postfix's mailname from `hostname -f`, which inside
# the build is "buildkitsandbox" -- clobbering the /etc/mailname written above.
# Put it back so voicemail email leaves with a sane origin.
# --------------------------------------------------------------------------
RUN echo "${PBX_HOSTNAME}" > /etc/mailname \
 && postconf -e "myhostname = ${PBX_HOSTNAME}"

# --------------------------------------------------------------------------
# /run is a fresh tmpfs at runtime (see compose), and asterisk.service runs as
# User=asterisk. Asterisk only creates its own run dir when it starts as root
# and drops privileges itself (asterisk.c: "before we drop privileges") -- as
# a plain user it can't mkdir /run/asterisk, and the CLI socket (which the
# HEALTHCHECK depends on) never appears. Let systemd create it instead.
# --------------------------------------------------------------------------
RUN mkdir -p /etc/systemd/system/asterisk.service.d \
 && printf '[Service]\nRuntimeDirectory=asterisk\nRuntimeDirectoryMode=0755\n' \
      > /etc/systemd/system/asterisk.service.d/10-runtime-dir.conf

# --------------------------------------------------------------------------
# systemd hygiene. Done with symlinks rather than `systemctl mask`, which wants
# a running bus. Nothing here is needed in a container and all of it errors.
# --------------------------------------------------------------------------
RUN ln -sf /lib/systemd/system/multi-user.target /etc/systemd/system/default.target \
 && for u in \
      systemd-udevd.service systemd-udevd-control.socket systemd-udevd-kernel.socket \
      systemd-udev-trigger.service systemd-modules-load.service \
      sys-kernel-debug.mount sys-kernel-config.mount sys-kernel-tracing.mount \
      systemd-journald-audit.socket e2scrub_reap.service \
      getty.target console-getty.service ; do \
      ln -sf /dev/null "/etc/systemd/system/$u" ; \
    done

# systemd wants SIGRTMIN+3 to shut down, not SIGTERM.
STOPSIGNAL SIGRTMIN+3

HEALTHCHECK --interval=60s --timeout=15s --start-period=300s --retries=3 \
  CMD asterisk -rx "core show version" >/dev/null 2>&1 || exit 1

CMD ["/lib/systemd/systemd"]
