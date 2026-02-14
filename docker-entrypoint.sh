#!/usr/bin/env bash
set -euo pipefail

mode="${1:-cron}"

log() { printf '%s\n' "$*" >&2; }

# Ensure dirs exist (as backup user)
mkdir -p /app/run "$BK_DEST" "$BK_CONFIG_DIR"

generate_and_install_cron() {
  local cronfile="${BK_CRONFILE:?BK_CRONFILE is not set}"

  log "Generating crontab to: $cronfile"
  if ! /app/backupfire.sh -c "$cfg" -C >"$cronfile"; then
    rc=$?
    log "ERROR: backupfire.sh -C failed (exit=$rc). Not starting cron."
    exit "$rc"
  fi

  # Optional: fail if empty output
  if [[ ! -s "$cronfile" ]]; then
    log "ERROR: generated crontab is empty: $cronfile"
    exit 1
  fi

  log "Installing crontab from: $cronfile"
  if ! crontab "$cronfile"; then
    rc=$?
    log "ERROR: crontab install failed (exit=$rc)"
    exit "$rc"
  fi

  log "Installed crontab:"
  crontab -l >&2 || true
}

case "$mode" in
  cron)
    generate_and_install_cron
    log "Starting cron in foreground..."
    exec crond -f -l 2
    ;;

  run)
    shift || true
    log "One-shot run: /app/backupfire.sh $*"
    exec /app/backupfire.sh "$@"
    ;;

  *)
    log "Unknown mode: $mode"
    log "Usage: $0 [cron|run ...]"
    exit 2
    ;;
esac
