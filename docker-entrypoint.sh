#!/usr/bin/env bash
set -Eeuo pipefail

# ----------------------------
# Helpers
# ----------------------------
log() { echo -e "\033[1;32m[info]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*"; }
err() { echo -e "\033[1;31m[error]\033[0m $*"; }
die() { err "$*"; exit 1; }

make_wrapper() {
  # Wrapper lives in /app and must be writable by pgbackup
  cat > /app/pgbackup <<'EOF'
#!/usr/bin/env bash
# pgbackup wrapper template
# - This file is a model for the generated /app/pgbackup wrapper.
# - The entrypoint writes a concrete version at container start.
# - It injects BK_* and DB_* env vars and then drops privileges.
# - Do not edit the generated /app/pgbackup directly.

set -Eeuo pipefail
export HOME="/home/backup"

# Exported variables are injected here by the entrypoint.
EOF
  # Export every env var that starts with BK_ or DB_
  # compgen -e lists exported environment variable names
  local name val
  while IFS= read -r name; do
    case "$name" in
      BK_*|DB_*)
        # Read value (may include '='), then single-quote safely for bash
        val="${!name-}"
        val=${val//\'/\'\"\'\"\'}
        printf "export %s='%s'\n" "$name" "$val" >> /app/pgbackup
        ;;
    esac
  done < <(compgen -e | LC_ALL=C sort)

  cat >> /app/pgbackup <<'EOF'
# run the real command
exec /app/internal-pgbackup.sh $@
EOF

  chmod +x /app/pgbackup
  chown backup:backup /app/pgbackup
}

run_once() {
  make_wrapper
  log "Running once:"
  log exec /app/pgbackup "$@"
  exec /app/pgbackup "$@"
}

run_cron() {
  make_wrapper "$@"

  log "Running cron service..."

  # BusyBox crond reads /etc/crontabs/root with format:
  # m h dom mon dow command
  local cron_dir="${BK_CRONTABS_DIR:-/app/crontabs}"
  mkdir -p "$cron_dir"
  local cron_file="$cron_dir/pgbackup"

  {
    echo 'SHELL=/bin/bash'
    echo 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
    echo "${BK_CRON} /app/pgbackup >>/dev/stdout 2>>/dev/stderr"
  } > $cron_file

  # dcron expects crontab files to be 0600 or it may ignore them
  chmod 0600 "$cron_file"

  log "[cron] schedule: ${BK_CRON}"
  exec crond -f -l 2 -L /dev/stdout -c "$cron_dir"
}

test_env() {
  make_wrapper "$@"
  log "Testing the environment..."
  tail -f /dev/null
}

# Best-effort: ensure /app is writable by pgbackup (bind mounts may override host perms)
chown -R pgbackup:pgbackup /app 2>/dev/null || true
chmod -R u+rwX /app 2>/dev/null || true

# load actions
ACTION=${1:-}
shift

if [[ "$ACTION" == "test" ]]; then
  test_env "$@"
elif [[ "${ACTION}" == "cron" ]]; then
  [[ -z "${BK_CRON}" ]] && die "BK_CRON is required for cron mode"
  run_cron "$@"
elif [[ "${ACTION}" == "run" ]]; then
  run_once "$@"
else
  exec "$@"
fi
