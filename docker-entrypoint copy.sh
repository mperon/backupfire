#!/usr/bin/env sh
# docker-entrypoint.sh
#
# Generates /etc/crontabs/root from:
#   - environment variables, and/or
#   - the [crontab] section in BACKUPFIRE_CONFIG
# Then starts crond in foreground.

set -eu

SCRIPT_PATH="/usr/local/bin/backupfire.sh"
CONF_FILE="${BACKUPFIRE_CONFIG:-/etc/backupfire/default.conf}"

# ini_get: read a key from an INI file (case-sensitive section + key).
# Usage: ini_get "crontab" "Schedule" "/path/file.conf"
ini_get() {
  section="$1"; key="$2"; file="$3"
  awk -v section="$section" -v key="$key" '
    function trim(s){sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); return s}
    BEGIN{cur=""}
    /^[[:space:]]*[#;]/ {next}
    /^[[:space:]]*\[/ {
      cur=$0
      gsub(/^[[:space:]]*\[/,"",cur)
      gsub(/\][[:space:]]*$/,"",cur)
      next
    }
    cur==section && index($0,"=")>0 {
      line=$0
      sub(/[[:space:]]*[#;].*$/, "", line)
      split(line,a,"=")
      k=trim(a[1])
      v=trim(substr(line, index(line,"=")+1))
      gsub(/^"|"$/, "", v)
      if (k==key) { print v; exit }
    }
  ' "$file" 2>/dev/null || true
}

# Read config-based defaults if the file exists.
CFG_ENABLED=""
CFG_SCHEDULE=""
CFG_ARGS=""
CFG_LOG=""

if [ -f "$CONF_FILE" ]; then
  CFG_ENABLED="$(ini_get crontab Enabled "$CONF_FILE")"
  CFG_SCHEDULE="$(ini_get crontab Schedule "$CONF_FILE")"
  CFG_ARGS="$(ini_get crontab Args "$CONF_FILE")"
  CFG_LOG="$(ini_get crontab LogFile "$CONF_FILE")"
fi

# Environment overrides.
ENABLED="${CRON_ENABLED:-$CFG_ENABLED}"
SCHEDULE="${CRON_SCHEDULE:-$CFG_SCHEDULE}"
ARGS="${CRON_ARGS:-$CFG_ARGS}"
LOGFILE="${CRON_LOG_FILE:-${CFG_LOG:-/var/log/backupfire/cron.log}}"

# Defaults.
[ -z "${SCHEDULE}" ] && SCHEDULE="0 3 * * *"
[ -z "${ARGS}" ] && ARGS="-a -c $CONF_FILE"

# If explicitly disabled, run once and exit.
case "${ENABLED}" in
  0|N|n|No|no|FALSE|false)
    echo "[entrypoint] CRON disabled; running once: $SCRIPT_PATH $ARGS" >&2
    exec $SCRIPT_PATH $ARGS
    ;;
  *) : ;;
esac

# Ensure log file exists.
mkdir -p "$(dirname "$LOGFILE")"
: > "$LOGFILE" || true

# Write crontab for root.
# BusyBox cron uses /etc/crontabs/<user>
CRON_FILE="/etc/crontabs/root"

# Redirect output to LOGFILE.
# Note: ARGS is expanded by /bin/sh in cron context.
echo "${SCHEDULE} ${SCRIPT_PATH} ${ARGS} >> ${LOGFILE} 2>&1" > "$CRON_FILE"

echo "[entrypoint] Using config: ${CONF_FILE}" >&2
echo "[entrypoint] Cron schedule: ${SCHEDULE}" >&2
echo "[entrypoint] Cron command : ${SCRIPT_PATH} ${ARGS}" >&2
echo "[entrypoint] Cron log     : ${LOGFILE}" >&2

# Start crond in foreground.
exec crond -f -l 8
