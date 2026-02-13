#!/usr/bin/env bash
#
# Database Actions


bk_action_postgres_check() {
  local needed=("Host" "Name") n=

  #verify if was alreasy checked
  (("${cfg[DbChecked]:-0}")) && return 0

  # parse url:
  declare -A conn;
  if [[ -n "${cfg[From]:-}" ]] && [[ "${cfg[From]}" == *"://"* ]]; then
    fn_parse_uri_scheme conn "${cfg[From]}"
    [[ -n "${conn[Host]}" && -n "${conn[Name]:-}" ]] \
      || {
        fn_error "Invalid connection string: format should be: scheme://user[:pass]@host[:port]/db_name";
        fn_error "It was: ${cfg[From]}. Change Task From= value to adjust."
        return 1
      }
      # sets in the main function
      for k in "${!conn[@]}"; do
        cfg[Db${k}]="${conn[$k]}"
      done
  fi

  # check database variables again
  for n in "${needed[@]}"; do
    if [[ -z "${cfg[Db$n]:-}" ]]; then
      fn_error "The $n is empty and it's required"
      fn_error "You must set connection string [From=] or [Db${n}=] properly"
      return 1
    fi
  done
  cfg[DbChecked]=1
}

# run postgres command with arguments parsed.
bk_action_postgres_run() {
  local app="${1:-$POSTGRES_CMD}"
  shift
  local -a cmd=()

  bk_action_postgres_check || return 2

  # set default arguments:
  cmd=("$app" -h "${cfg[DbHost]:-localhost}")
  [[ "$app" == *"_dumpall" ]] ||  cmd+=(-d "${cfg[DbName]:-postgres}")

  [[ -n "${cfg[DbPort]}" ]] && cmd+=(-p "${cfg[DbPort]}") || cmd+=(-p 5432)
  [[ -n "${cfg[DbUser]}" ]] && cmd+=(-U "${cfg[DbUser]}")

  # Only set PGPASSWORD if provided (avoid clobbering existing env)
  if [[ -n "${cfg[DbPass]:-}" ]]; then
    export PGPASSWORD="${cfg[DbPass]}"
  else
    cmd+=(--no-password)
  fi

  fn_run "${cmd[@]}" "$@"
  local ret=$?

  # Remove the password
  export -n PGPASSWORD

  return $ret
}

bk_action_postgres() {
  local task="$1" workdir="$2" artifactdir="$3"
  local -a opts=("--format=directory" "--jobs=4" "--compress=0" --no-owner --no-privileges --blobs)
  local file_ext="${cfg[DbFileExtension]:-}" file_name=
  local -a cmd=()

  # test connection
  if ! bk_action_postgres_run "${POSTGRES_CHECK_CMD}" -c 'SELECT 1;' -tA; then
    fn_error "Connection wasn't stablished with database!"
    return 2
  fi

  #load command line options from config
  if [[ -n "${cfg[DbBackupOpts]:-}" ]]; then
    fn_cmdline_to_array opts "${cfg[DbBackupOpts]:-}"
  fi

  [[ -n "$file_ext" ]] && file_name="$(bk_build_artifact_name)${file_ext}"

  # connection is ok! run backup
  bk_action_postgres_run "${POSTGRES_CMD}" "${opts[@]}" \
    --file="$workdir/$file_name"

  # check command return
  if [[ $? -ne 0 ]]; then
    fn_error "Failed to run Backup job!"
    return 2
  fi
}
