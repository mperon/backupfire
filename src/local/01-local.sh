#!/usr/bin/env bash
#

# Local Type
# bk_type_local: rsync local->local.
# Uses keys: From, To, Options, Includes, Excludes, IncludeFrom, ExcludeFrom, FilterFrom, AutoFilter
bk_type_local() {
  local -a cmd=()

  cmd+=("${RSYNC_CMD}")

  # Options: default to common rsync flags.
  local rsync_opts="${cfg[Options]:--Cravzp}"
  # Split options string by spaces (simple; users should not quote inside Options).
  # If you need quoting, prefer placing flags directly in the action file or extend parser.
  read -r -a _tmp_opts <<<"${rsync_opts}"
  cmd+=("${_tmp_opts[@]}")

  # Add include/exclude/filter arguments.
  bk_add_rsync_filters cmd

  # Append From and To.
  cmd+=("${cfg[From]}" "${cfg[To]}")

  # Dry-run: print the command exactly once.
  if [[ -n "${_DRY_RUN}" ]]; then
    fn_info "(dry-run) $(fn_quote_cmd cmd)"
    return 0
  fi

  fn_run "${cmd[@]}"
}
