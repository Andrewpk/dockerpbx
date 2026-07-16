#!/bin/bash
# ---------------------------------------------------------------------------
# BUILD-TIME ONLY systemctl shim.
#
# The FreePBX ARM64 installer calls systemctl to enable/start/probe mariadb,
# apache2, asterisk and fail2ban. systemd cannot be PID 1 during `docker build`,
# so this stands in for it:
#
#   enable     -> create the real multi-user.target.wants symlink, so that when
#                 systemd IS PID 1 at runtime it genuinely starts the unit
#   start/restart -> actually launch the daemon, because the installer depends
#                 on mariadb and asterisk really running (it runs SQL and
#                 `asterisk -rx`)
#   is-active  -> probe the real process, because the installer hard-fails if
#                 mariadb doesn't come up
#   everything else -> no-op success
#
# This file is diverted OVER /usr/bin/systemctl during the build and removed
# again afterwards. It must never be present in the final image.
# ---------------------------------------------------------------------------
set -u

cmd="${1:-}"
shift || true

units=()
for a in "$@"; do
  case "$a" in
    -*) continue ;;
    *)  units+=("${a%.service}") ;;
  esac
done

find_unit() {
  local u="$1" p
  for p in "/etc/systemd/system/$u.service" \
           "/lib/systemd/system/$u.service" \
           "/usr/lib/systemd/system/$u.service"; do
    [ -f "$p" ] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

start_unit() {
  case "$1" in
    mariadb|mysql|mysqld)
      mysqladmin ping >/dev/null 2>&1 && return 0
      mkdir -p /run/mysqld
      chown mysql:mysql /run/mysqld
      # policy-rc.d blocked the postinst start, so the datadir may be uninitialised
      if [ ! -d /var/lib/mysql/mysql ]; then
        mariadb-install-db --user=mysql --datadir=/var/lib/mysql >/dev/null 2>&1 || true
      fi
      nohup /usr/sbin/mariadbd --user=mysql >/var/log/mariadb-build.log 2>&1 &
      for _ in $(seq 1 60); do
        mysqladmin ping >/dev/null 2>&1 && return 0
        sleep 1
      done
      echo "shim: mariadb failed to start; see /var/log/mariadb-build.log" >&2
      return 1
      ;;
    apache2)
      # Do NOT source /etc/apache2/envvars here: its first lines expand the
      # unset ${APACHE_CONFDIR}, and under this script's `set -u` an expansion
      # error aborts the whole shell -- `|| true` cannot catch it. apache2ctl
      # sources envvars itself (via /bin/sh, no set -u), so it isn't needed.
      mkdir -p /var/run/apache2
      apache2ctl -k restart >/dev/null 2>&1 || apache2ctl -k start >/dev/null 2>&1 || true
      return 0
      ;;
    asterisk)
      pkill -x asterisk >/dev/null 2>&1 || true
      sleep 1
      mkdir -p /var/run/asterisk
      chown asterisk:asterisk /var/run/asterisk
      /usr/sbin/asterisk -U asterisk -G asterisk >/dev/null 2>&1 || true
      for _ in $(seq 1 30); do
        asterisk -rx "core show version" >/dev/null 2>&1 && return 0
        sleep 1
      done
      echo "shim: asterisk did not come up; see /var/log/asterisk/messages" >&2
      return 1
      ;;
    fail2ban)
      # Not started at build. Real systemd starts it at runtime (it needs journald).
      return 0
      ;;
    *)
      return 0
      ;;
  esac
}

case "$cmd" in
  enable)
    for u in ${units[@]+"${units[@]}"}; do
      p="$(find_unit "$u")" || continue
      mkdir -p /etc/systemd/system/multi-user.target.wants
      ln -sf "$p" "/etc/systemd/system/multi-user.target.wants/$u.service"
    done
    ;;

  disable)
    for u in ${units[@]+"${units[@]}"}; do
      rm -f "/etc/systemd/system/multi-user.target.wants/$u.service"
    done
    ;;

  start|restart|reload-or-restart|try-restart|reload)
    for u in ${units[@]+"${units[@]}"}; do
      start_unit "$u" || exit 1
    done
    ;;

  stop)
    for u in ${units[@]+"${units[@]}"}; do
      case "$u" in
        mariadb)  mysqladmin shutdown  >/dev/null 2>&1 || true ;;
        apache2)  apache2ctl -k stop   >/dev/null 2>&1 || true ;;
        asterisk) pkill -x asterisk    >/dev/null 2>&1 || true ;;
      esac
    done
    ;;

  is-active)
    for u in ${units[@]+"${units[@]}"}; do
      case "$u" in
        mariadb)  mysqladmin ping        >/dev/null 2>&1 || exit 3 ;;
        apache2)  pgrep -x apache2       >/dev/null 2>&1 || exit 3 ;;
        asterisk) pgrep -x asterisk      >/dev/null 2>&1 || exit 3 ;;
        fail2ban) : ;;   # started by real systemd at runtime
        *)        : ;;
      esac
    done
    echo active
    ;;

  *)
    # daemon-reload, daemon-reexec, mask, unmask, preset, status, show, ...
    exit 0
    ;;
esac

exit 0
