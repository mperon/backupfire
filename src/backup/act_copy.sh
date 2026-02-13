#!/usr/bin/env bash
#
# Copyfiles action


bk_action_copyfiles() {
  local task="$1" workdir="$2" artifactdir="$3"
  # RUN COPY FILES
  local -a cmd=()

  cmd+=("${RSYNC_CMD}")

  # CopyOptions: default to common rsync flags.
  local rsync_opts=""
  local -a cmdArr
  fn_cmdline_to_array cmdArr "${cfg[CopyOptions]:--Cravzp}"
  cmd+=("${cmdArr[@]}")

  # Add include/exclude/filter arguments.
  # Without prefix, options are: Includes=, Excludes=, etc..
  bk_add_rsync_filters cmd

  # Copy files to workdir
  cmd+=("${cfg[From]}" "$workdir")

  fn_run "${cmd[@]}"

}
