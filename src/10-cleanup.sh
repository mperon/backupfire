#!/usr/bin/env bash
#
# Cleanup functions

# explain the function here
# usage
bk_cleanup() {
  local path
  ((${#CLEANUP[@]} == 0)) && return 0 # Array is empty, nothing to do
  fn_debug "Cleaning up temporary files/directories created.."
  for path in "${CLEANUP[@]}"; do
    if [[ "$path" == /tmp/* ]] || [[ "$path" == /var/folders/* ]]; then
      fn_debug "Cleaning up $path .."
      if [[ -f "$path" ]] || [[ -d "$path" ]]; then
        rm -rf -- "$path" || true
      fi
    fi
  done
  CLEANUP=()
}
