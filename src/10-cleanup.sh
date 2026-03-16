#!/usr/bin/env bash
#
# Cleanup functions

# explain the function here
# usage
bk_cleanup() {
  local path
  ((${#CLEANUP[@]} == 0)) && return 0
  fn_debug "Cleaning up temporary files/directories created.."

  local tmp_dirs=("/tmp" "/var/folders")
  [[ -n "${TMPDIR:-}" ]] && tmp_dirs+=("${TMPDIR%/}")

  for path in "${CLEANUP[@]}"; do
    local allowed=0
    local tmp_dir
    for tmp_dir in "${tmp_dirs[@]}"; do
      [[ "$path" == "${tmp_dir}/"* ]] && allowed=1 && break
    done
    if (( allowed )); then
      fn_debug "Cleaning up $path .."
      if [[ -f "$path" ]] || [[ -d "$path" ]]; then
        rm -rf -- "$path" || true
      fi
    else
      fn_debug "Skipping cleanup of unrecognized path: $path"
    fi
  done
  CLEANUP=()
}
