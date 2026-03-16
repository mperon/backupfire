#!/usr/bin/env bash
# ---------------------------
# Main function
# ---------------------------

# main function
# bk_main: program entry point.
# Usage: bk_main
bk_main() {
  trap bk_cleanup EXIT INT TERM

  bk_parse_args "$@"

  # Help.
  if [[ -n "${BK_HELP:-}" ]]; then
    bk_cmd_print_help
    return 0
  fi

  # decryption
  if [[ -n "${BK_DECRYPT}" ]]; then
    if [[ -n "$BK_LIST" ]] || [[ -n "$BK_TEST_ENV" ]] || \
      [[ -n "$BK_ALL" ]] || [[ -n "$BK_GEN_CRON" ]] || \
      [[ "${#TASKS[@]}" -gt 0 ]]; then
      fn_error "You cant pass other arguments to -D except the path"
      return 2
    fi
    bk_cmd_decrypt
    return $?
  fi


  # load config
  if ! bk_resolve_config; then
    fn_error "Config file not found or not readable."
    fn_die "Use -c <file> to specify a config."
  fi

  if [[ -n "${BK_GEN_CRON:-}" ]]; then
    fn_debug "Generation crontab jobs:"
    bk_cmd_generate_cron
    return 0
  fi

  # List actions.
  if [[ -n "${BK_LIST:-}" ]]; then
    bk_cmd_list_tasks "${BK_CONFIG}"
    return 0
  fi

  # Test environment.
  if [[ -n "${BK_TEST_ENV:-}" ]]; then
    bk_cmd_test_env "${BK_CONFIG}"
    return $?
  fi

  # Determine actions to run.
  if [[ -n "${BK_ALL:-}" ]]; then
    # option -a was selected
    bk_cmd_all_runnable_tasks
    if [[ ${#TASKS[@]} -eq 0 ]]; then
      fn_error "No tasks found to run!"
      return 2
    fi
  fi

  if [[ ${#TASKS[@]} -eq 0 ]]; then
    fn_error "You must provide at least one action, or use -a"
    bk_cmd_print_help
    return 2
  fi

  # Execute each requested action (with deps).
  local task ret=0
  for task in "${TASKS[@]}"; do
    if ! bk_task_run_tree "$task"; then
      ret=1
    fi
  done

  #cleanup
  bk_cleanup

  return "$ret"
}

# argument parsing
# ---------------------------
# CLI parsing / main
# ---------------------------
# bk_parse_args: parse CLI args with getopts.
# Usage: bk_parse_args "$@"
bk_parse_args() {
  local opt
  while getopts ":ac:e:D:k:dlhTC" opt; do
    case "$opt" in
      a) BK_ALL=1;;
      c) BK_CONFIG="$OPTARG";;
      C) BK_GEN_CRON=1;;
      e) BK_EMAIL="$OPTARG";;
      D) BK_DECRYPT="$OPTARG";;
      k) BK_DECRYPT_KEY="$OPTARG";;
      d) F_DEBUG=1;;
      l) BK_LIST=1;;
      T) BK_TEST_ENV=1;;
      h) BK_HELP=1;;
      :) fn_error "Option -$OPTARG requires an argument"; BK_HELP=1;;
      \?) fn_error "Unknown option: -$OPTARG"; BK_HELP=1;;
    esac
  done
  shift $((OPTIND - 1))

  # Remaining args are tasks.
  TASKS=("$@")
}

# bk_resolve_config: find and validate the config file.
# Usage: bk_resolve_config
# Sets: CFG_FILE
bk_resolve_config() {
  local requested="${BK_CONFIG:-$CFG_DEFAULT_NAME}"

  fn_debug "Trying to load config file: $requested"

  # Ensure user config dir exists (useful outside containers).
  mkdir -p "${CFG_DIRS[0]}" 2>/dev/null || true

  [[ -n "${BK_CONFIG}" ]] && [[ -r "${BK_CONFIG}" ]] && {
    fn_debug "Config file found: $BK_CONFIG"
    return 0
  }

  fn_debug "Config file not found. Searching.."
  # if not, search in directoies
  local dir
  for dir in "${CFG_DIRS[@]}"; do
    if [[ -r "${dir}/${requested}" ]]; then
      BK_CONFIG="${dir}/${requested}"
      fn_debug "Config file found: $BK_CONFIG"
      return 0
    fi
  done
  return 1
}
