#!/usr/bin/env bash
#
# remote section

# ---------------------------
# rclone config finder
# ---------------------------
bk_add_rclone_cmd() {
  local -n _cmd_ref="$1"

  _cmd_ref+=("${RCLONE_CMD}")

  #config file
  if [[ -z "$RCLONE_CONFIG" ]]; then
    local dirs=("${CFG_DIRS[@]}" "$HOME") files=("rclone.conf" ".rclone.conf")
    # search in the config dir first:
    for d in "${dirs[@]}"; do
      for f in "${files[@]}"; do
        [[ -f "$d/$f" ]] && [[ -r "$d/$f" ]] && {
          RCLONE_CONFIG="$d/$f"
          break 2
        }
      done
    done
  fi
  if [[ -f "$RCLONE_CONFIG" ]] && [[ -r "$RCLONE_CONFIG" ]]; then
    _cmd_ref+=("--config=${RCLONE_CONFIG}")
    return 0
  fi
  fn_debug "RCLONE config not found or invalid: $RCLONE_CONFIG!"
  return 1
}
