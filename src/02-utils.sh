#!/usr/bin/env bash
#
# Utilities functions

# ---------------------------
# Utilities
# ---------------------------
# fn_run: run a command; silence stdout+stderr unless F_DEBUG=1
fn_run() {
  if (( ${F_DEBUG:-0} )); then
    # print command and show output and error
    local -a cmd=("$@")
    fn_debug ">> $(fn_quote_cmd cmd)"
    "$@"
  else
    #ignore output
    "$@" 2>/dev/null
  fi
}

# bk_build_artifact_name
# Uses keys: DateFormat, FilePrefix
# usagbk_build_artifact_namee: bk_build_artifact_name "daily" ".enc"
bk_build_artifact_name() {
  local fmt='%s%s_%s' ts=
  for _ in "$@"; do fmt+='%s'; done
  # create timestamp if not defined (to be reused in other file compositions)
  bk_utils_set_timestamp
  printf "$fmt" "${cfg[FilePrefix]}" "${cfg[DateStr]}" "${cfg[Name]}" "$@"
}

# crate a temporary file and add to the cleanup list
bk_mktemp() {
  local tmp=$(mktemp "$@")
  CLEANUP+=("$tmp")
  printf '%s' "$tmp"
}


# bk_mktemp_set: create temp path and assign it to a variable/expression, plus register cleanup.
# Usage: bk_mktemp_set 'cfg[WorkDir]' "$task" "to"
bk_mktemp_set() {
  local target="$1" task="$2" kind="$3" type="${4:-dir}"
  local tmp= tpl="backupfire.${task}.${kind}.XXXXXX"
  local args=()
  case "${type,,}" in
    f|file|-f);;
    dir|d|-d) args+=('-d');;
  esac

  tmp="$(mktemp "${args[@]}" -t "$tpl" 2>/dev/null)" || \
    tmp="$(mktemp "${args[@]}" "${TMPDIR:-/tmp}/${tpl}")" || \
    return 1
  CLEANUP+=("$tmp")
  printf -v "$target" '%s' "$tmp"
}


# copy file utility
bk_util_cp() {
  local from="$1" to="$2"
  fn_run rsync -a -- "$from" "$to"
  fn_debug "Moving files from: ${from} to: ${to}"
}

# ensure timestamp is set
bk_utils_set_timestamp() {
  [[ -z "${cfg[Timestamp]:-}" ]] && {
    local ts="$(date +"${cfg[DateFormat]-%Y%m%d%H%M%S}")" || return 1
    cfg[Timestamp]="$(date +%s)"
    cfg[DateStr]="$ts"
  }
}

#format date timestamp using format = $1
bk_format_timestamp() {
  local format="${1:-%s}"
  bk_utils_set_timestamp
  fn_format_epoch "${cfg[Timestamp]}" "${format}"
}

# run docker command
bk_util_docker_run() {
  local sock="${cfg[DockerSocket]:-}"

  if [[ -n "$sock" ]]; then
    ${DOCKER_CMD} -H "unix://$sock" "$@"
  else
    ${DOCKER_CMD} "$@"
  fi
}


# sanitize name
# remove emoji, non-ansi chars and spaces from file name.
sanitize_name() {
  printf '%s' "${1-}" \
  | LC_ALL=C tr ' /:' '___' \
  | tr $'\t' '_' \
  | tr -cd '\000-\177' \
  | tr -cd '[:alnum:]_.-'
}
