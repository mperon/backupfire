#!/usr/bin/env bash
#
# Remote

bk_type_backup_remote() {
  local task="$1" workdir="$2" artifactdir="$3"
  local -a cmd=()

  # ignore upload if not set
  if [[ -z "${cfg[Remote]:-}" ]]; then
    return 0
  fi

  [[ ! -d "${cfg[To]}" ]] \
    && { fn_error "Remote: Task destination is not a valid directory: ${cfg[To]}"; return 1; }

  # loads rclone
  bk_add_rclone_cmd cmd

  # add action
  cmd+=("copy")

  #add default options
  if fn_boolean "${cfg[RemoteDefaultOpts]:-}"; then
    cmd+=("--auto-confirm" "--fast-list" "--quiet" "--retries" "3")
    cmd+=("--exclude" "'.*'" "--retries-sleep" "1m" "--timeout" "1m")
    cmd+=("--update")
  fi

  # Extra options
  if [[ -n "${cfg[RemoteOptions]:-}" ]]; then
    local -a cmdArr
    fn_cmdline_to_array "cmdArr" "${cfg[RemoteOptions]}"
    cmd+=("${cmdArr[@]}")
  fi
  #add filters
  # Every option should have Remote as prefix
  # for example: RemoteExcludes=, RemoteIncludes=, etc..
  bk_add_rclone_filters cmd "Remote"

  # add source and destination
  # source will be to (local) and remote will get the remote dest
  cmd+=("${cfg[To]}" "${cfg[Remote]}")

  #execute
  fn_run "${cmd[@]}"
}
