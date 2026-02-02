#!/usr/bin/env bash
# backupfire.sh - BackupFire runner
#
# Runs backup "actions" defined in an INI config file.
# Supported Types:
#   - Local  : rsync local->local
#   - Remote : rclone local<->remote
#   - Vault  : run a Vault Action (e.g. Database / CopyFiles),
#              then optionally compress and encrypt before copying to destination.
#
# Alpine compatibility:
# - Uses bash built-in getopts (single-letter options).
# - Avoids GNU getopt/longopts.
# - INI parsing relies on awk (available on Alpine).

set -o pipefail

# Resolve script directory (safe when invoked via symlink).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# Source shared helpers.
# Usage: keep backupfire_lib.sh next to this script.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/backupfire_lib.sh"

# ---------------------------
# Constants / defaults
# ---------------------------

SCRIPT_NAME="$(basename -- "$0")"
SCRIPT_VERSION="2.0.0"

# Default config search locations.
CFG_DEFAULT_NAME="default.conf"
CFG_DIRS=("$HOME/.config/backupfire" "/etc/backupfire")

# Safety: directories that are almost always a bad destination.
INVALID_DIR_PREFIXES="/root/,/etc/,/bin/,/boot/,/dev/,/lib/,/lib32/,/lib64/,/libx32/,/proc/"

# External tools (can be overridden by env vars).
RSYNC_CMD_DEFAULT="${RSYNC_CMD:-rsync}"
RCLONE_CMD_DEFAULT="${RCLONE_CMD:-rclone}"
OPENSSL_CMD_DEFAULT="${OPENSSL_CMD:-openssl}"

# ---------------------------
# Globals (set by CLI parsing)
# ---------------------------

_DEBUG=""
_DRY_RUN=""
_LOG="${_LOG:-/dev/null}"
_LOG_DATE="${_LOG_DATE:-+%y-%m-%d %H:%M:%S}"
_LOG_SCRIPT="${_LOG_SCRIPT:-backupfire}"

OPT_ALL=""
OPT_CONFIG="${BACKUPFIRE_CONFIG:-}"
OPT_EMAIL=""   # Reserved for future (email reporting)
OPT_LOG=""
OPT_LIST=""
OPT_HELP=""
OPT_TEST_ENV=""

# Positional: requested actions (section names).
ACTIONS=()

# Internal state for dependency resolution.
declare -A RUN_SET=() WALK_SET=() ERR_SET=()

# Action config is loaded into this associative array before each run.
declare -A cfg=()

# ---------------------------
# Help / usage
# ---------------------------

# print_global_help: show full usage, options, and (when possible) actions.
# Usage: print_global_help
print_global_help() {
  cat <<EOF
${SCRIPT_NAME} - BackupFire Runner (${SCRIPT_VERSION})

SYNOPSIS
  ${SCRIPT_NAME} [options] <action> [action2 ...]
  ${SCRIPT_NAME} [options] -a

DESCRIPTION
  backupfire executes "actions" defined in an INI config file.
  Each action is a section like [pictures] with keys like Type, From, To.

CONFIG
  (default)  ~/.config/backupfire/${CFG_DEFAULT_NAME} (if present)
             /etc/backupfire/${CFG_DEFAULT_NAME}
  -c <file>  use a specific config file

OPTIONS (single-letter for Alpine compatibility)
  -a         run all actions found in config (excluding [General])
  -c <file>  config file path (or just a filename searched in config dirs)
  -o <file>  log file path (default: /dev/null)
  -n         dry-run (print commands only; do not execute)
  -d         debug (verbose logs)
  -l         list actions + short description
  -T         test environment (check required commands), then exit
  -h         show this help

EXAMPLES
  ${SCRIPT_NAME} -c /etc/backupfire/default.conf pictures remote
  ${SCRIPT_NAME} -a -n    # show what would run
  ${SCRIPT_NAME} -T       # verify dependencies
EOF
}


# bk_list_actions: list action sections and their descriptions.
# Usage: bk_list_actions <config_file>
# Output format:
#   <section>  <description>
bk_list_actions() {
  local cfg_file="$1"
  local sec desc

  # fn_ini_list_sections returns newline-separated section names.
  while IFS= read -r sec; do
    [[ -z "${sec}" ]] && continue
    [[ "${sec}" == "General" || "${sec}" == "crontab" || "${sec}" == "Crontab" ]] && continue
    desc="$(fn_ini_get "${cfg_file}" "${sec}" "Description")"
    printf '  %-20s %s\n' "${sec}" "${desc:-}"
  done < <(fn_ini_list_sections "${cfg_file}")
}


# bk_ini_list_actions: list runnable action section names (one per line).
# Usage: bk_ini_list_actions <config_file>
# Notes:
#   - Skips [General] and [crontab] sections.
bk_ini_list_actions() {
  local cfg_file="$1"
  local sec
  while IFS= read -r sec; do
    [[ -z "${sec}" ]] && continue
    [[ "${sec}" == "General" || "${sec}" == "crontab" || "${sec}" == "Crontab" ]] && continue
    printf '%s\n' "${sec}"
  done < <(fn_ini_list_sections "${cfg_file}")
}

# ---------------------------
# Environment / dependency checks
# ---------------------------

# bk_test_env: verify that required commands are available.
#
# This checks baseline tools and (if a config is loaded) tools implied by the
# action Types in the config.
#
# Usage:
#   bk_test_env [<config_file>]
# Returns:
#   0 if all required commands are present, non-zero otherwise.

bk_test_env() {
  local cfg_file="${1:-${CFG_FILE:-}}"
  local -a required=(awk sed grep find wc du cut date)

  # If we can see the config, detect which Types are used.
  if [[ -n "${cfg_file}" && -r "${cfg_file}" ]]; then
    local types
    types="$(fn_ini_list_types "${cfg_file}")"

    # Local and Vault CopyFiles need rsync.
    if [[ ":${types}:" == *":Local:"* || ":${types}:" == *":Vault:"* ]]; then
      required+=("${RSYNC_CMD_DEFAULT}")
    fi

    # Remote needs rclone.
    if [[ ":${types}:" == *":Remote:"* ]]; then
      required+=("${RCLONE_CMD_DEFAULT}")
    fi

    # Vault compression generally needs tar (+ gzip if tar.gz).
    if [[ ":${types}:" == *":Vault:"* ]]; then
      required+=(tar)
      # Common compressors (only enforced if used at runtime, but handy to precheck).
      required+=(gzip)
    fi

    # Vault encryption needs openssl.
    if fn_ini_any_encrypt_enabled "${cfg_file}"; then
      required+=("${OPENSSL_CMD_DEFAULT}")
    fi
  else
    # Without config, still check the common defaults.
    required+=("${RSYNC_CMD_DEFAULT}" "${RCLONE_CMD_DEFAULT}" tar gzip "${OPENSSL_CMD_DEFAULT}")
  fi

  # Deduplicate command list.
  local -A seen=() missing=0
  local cmd
  for cmd in "${required[@]}"; do
    [[ -z "${cmd}" ]] && continue
    [[ -n "${seen[$cmd]:-}" ]] && continue
    seen[$cmd]=1

    if ! fn_cmd_exists "$cmd"; then
      fn_error "Missing command: $cmd"
      missing=1
    fi
  done

  if [[ "$missing" -ne 0 ]]; then
    fn_error "Environment check failed. Install missing packages."
    return 1
  fi

  fn_info "Environment OK."
  return 0
}


# ---------------------------
# Action execution
# ---------------------------

# bk_validate_action_name: ensure an action section name contains safe characters.
# Usage: bk_validate_action_name <name>
bk_validate_action_name() {
  local action="$1"
  [[ "$action" =~ ^[0-9A-Za-z._-]+$ ]]
}

# bk_load_action_cfg: load [General] plus the requested action section into cfg.
# Usage: bk_load_action_cfg <action>
bk_load_action_cfg() {
  local action="$1"
  declare -gA cfg=()
  fn_ini_load_section "${CFG_FILE}" "General,${action}" cfg
  cfg[Name]="$action"

  # Expand ~ in From/To (common in configs).
  [[ "${cfg[From]:-}" == ~/* ]] && cfg[From]="${HOME}/${cfg[From]#~/}"
  [[ "${cfg[To]:-}" == ~/* ]] && cfg[To]="${HOME}/${cfg[To]#~/}"


  # Normalize paths for keys that are expected to be file paths.
  fn_normalize_cfg_paths cfg "IncludeFrom:ExcludeFrom:FilterFrom:EncryptKeyFile:EncriptKeyFile"
}

# bk_action_deps: get the raw Depends string for an action (may be empty).
# Usage: bk_action_deps <action>
bk_action_deps() {
  fn_ini_get "${CFG_FILE}" "$1" "Depends"
}

# bk_run_action_tree: run an action and its dependencies (no circular deps).
# Usage: bk_run_action_tree <action>
bk_run_action_tree() {
  local action="$1"

  # Skip non-action meta sections.
  [[ "$action" == "General" || "$action" == "crontab" || "$action" == "Crontab" ]] && return 0

  if ! bk_validate_action_name "$action"; then
    fn_error "Action name has invalid characters: $action"
    ERR_SET["$action"]=1
    return 1
  fi

  # Already done.
  [[ -n "${RUN_SET[$action]:-}" ]] && return 0

  # Detect circular dependency.
  if [[ -n "${WALK_SET[$action]:-}" ]]; then
    fn_error "Circular dependency detected at action: $action"
    ERR_SET["$action"]=1
    return 1
  fi

  WALK_SET["$action"]=1

  # Run dependencies first.
  local deps_raw deps dep
  deps_raw="$(bk_action_deps "$action")"
  if [[ -n "${deps_raw// }" ]]; then
    IFS=',' read -r -a deps <<<"${deps_raw}"
    for dep in "${deps[@]}"; do
      dep="$(fn_trim "$dep")"
      [[ -z "$dep" ]] && continue

      if [[ -n "${ERR_SET[$dep]:-}" ]]; then
        fn_error "Action $action requires $dep, but $dep previously failed."
        ERR_SET["$action"]=1
        return 1
      fi

      bk_run_action_tree "$dep" || {
        fn_error "Dependency $dep failed; skipping $action."
        ERR_SET["$action"]=1
        return 1
      }
    done
  fi

  # Run the action itself.
  fn_info "Running action: $action"
  if bk_run_action "$action"; then
    RUN_SET["$action"]=1
    return 0
  fi

  ERR_SET["$action"]=1
  return 1
}

# bk_run_action: load an action config, validate it, and dispatch by Type.
# Usage: bk_run_action <action>
bk_run_action() {
  local action="$1"

  bk_load_action_cfg "$action"

  if [[ ${#cfg[@]} -eq 0 ]]; then
    fn_error "Action [$action] not found in config."
    return 1
  fi

  # Basic validation.
  if [[ -z "${cfg[From]:-}" || ! -d "${cfg[From]}" ]]; then
    fn_error "[$action] From directory does not exist: ${cfg[From]:-(unset)}"
    return 1
  fi
  if [[ -z "${cfg[To]:-}" ]]; then
    fn_error "[$action] To is required."
    return 1
  fi

  # Parse destination into host/path (host empty means local path).
  fn_parse_destination cfg

  # Safety checks only apply to local destinations.
  if [[ -z "${cfg[ToHost]:-}" ]]; then
    if fn_is_subdir "${cfg[To]}" "${cfg[From]}"; then
      fn_error "[$action] Destination is inside origin."
      fn_error "  From: ${cfg[From]}"
      fn_error "  To  : ${cfg[To]}"
      return 1
    fi
    if fn_dir_in "${cfg[To]}" "${INVALID_DIR_PREFIXES}"; then
      fn_error "[$action] Destination appears unsafe (matches protected prefixes)."
      fn_error "  To: ${cfg[To]}"
      fn_error "  Protected: ${INVALID_DIR_PREFIXES}"
      return 1
    fi
  fi

  # Run hook(s) before/after.
  bk_run_hook "Before" || {
    fn_error "[$action] Before hook failed; aborting action."
    return 1
  }

  # Dispatch by type.
  local type="${cfg[Type]:-Local}"
  case "$type" in
    Local)  bk_type_local ;;
    Remote) bk_type_remote ;;
    Vault)  bk_type_vault ;;
    *)
      fn_error "[$action] Unknown Type: $type"
      return 1
      ;;
  esac
  local ret=$?

  if [[ "$ret" -ne 0 ]]; then
    fn_error "[$action] Type execution failed with code $ret"
    return "$ret"
  fi

  bk_run_hook "After" || {
    fn_error "[$action] After hook failed."
    return 1
  }

  return 0
}

# ---------------------------
# Hook (Before/After) execution
# ---------------------------

# bk_run_hook: run Before/After commands from config.
#
# Supports:
# - external executables (absolute path),
# - or built-in hook commands: checkSize, countFiles
#
# The config string can use placeholders like %From%, %To%, %Name%, etc.
# Usage: bk_run_hook Before|After
bk_run_hook() {
  local moment="$1"
  local hook_str=""
  hook_str="${cfg["$moment"]:-}"

  [[ -z "${hook_str// }" ]] && return 0

  # Do not allow calling private functions by prefix (basic guard).
  if [[ "${hook_str:0:1}" == "_" ]]; then
    fn_error "[$moment] Hook cannot execute private function-like names: $hook_str"
    return 1
  fi

  # Expand ~ and ./ (./ means relative to From).
  hook_str="${hook_str/#\~\//${HOME}/}"
  hook_str="${hook_str/#\.\//${cfg[From]}/}"

  # Replace %KEY% placeholders from cfg.
  local k
  for k in "${!cfg[@]}"; do
    hook_str="${hook_str//%${k}%/${cfg[$k]}}"
  done

  # Split to argv array without using eval.
  local -a argv=()
  fn_cmdline_to_array "$hook_str" argv
  [[ ${#argv[@]} -eq 0 ]] && return 0

  # Resolve hook command.
  local cmd="${argv[0]}"
  if [[ -x "$cmd" && -f "$cmd" ]]; then
    : # external executable
  else
    case "$cmd" in
      checkSize)  argv[0]="bk_hook_check_size";;
      countFiles) argv[0]="bk_hook_count_files";;
      *)
        fn_error "Hook command not found: $cmd"
        return 1
        ;;
    esac
  fi

  fn_debug "Running ${moment} hook for ${cfg[Name]}: ${hook_str}"

  # Provide context env vars for the hook.
  local From="${cfg[From]}" To="${cfg[To]}" Name="${cfg[Name]}" Type="${cfg[Type]}" Moment="$moment"
  export From To Name Type Moment

  if [[ -n "${_DRY_RUN}" ]]; then
    fn_info "(dry-run) $(fn_quote_cmd argv)"
    return 0
  fi

  fn_run_logged argv
  local ret=$?

  unset From To Name Type Moment
  return "$ret"
}

# bk_hook_check_size: built-in hook that compares folder size.
# Usage (in config): Before=checkSize "%From%" ">" 10mb
bk_hook_check_size() {
  local folder="$1" oper="$2" size="$3"

  if [[ -z "${folder// }" || ! -d "$folder" ]]; then
    fn_error "[${cfg[Name]}] checkSize: Folder does not exist: $folder"
    return 1
  fi
  if [[ -z "$oper" ]]; then
    fn_error "[${cfg[Name]}] checkSize: Operator is required."
    return 1
  fi

  local size_bytes
  size_bytes="$(fn_human_to_bytes "$size" 2>/dev/null || true)"
  if [[ -z "${size_bytes// }" ]]; then
    fn_error "[${cfg[Name]}] checkSize: Invalid size: $size"
    return 1
  fi

  if ! fn_cmd_exists du cut; then
    fn_error "[${cfg[Name]}] checkSize: du/cut not available."
    return 1
  fi

  local folder_size
  folder_size="$(du -B1 -s "$folder" 2>/dev/null | cut -f1 | tr -d ' ')"
  fn_number_compare "$folder_size" "$oper" "$size_bytes"
}

# bk_hook_count_files: built-in hook that compares number of files (find | wc -l).
# Usage (in config): After=countFiles "%To%" ">=" 1000
bk_hook_count_files() {
  local folder="$1" oper="$2" count="$3"

  if [[ -z "${folder// }" || ! -d "$folder" ]]; then
    fn_error "[${cfg[Name]}] countFiles: Folder does not exist: $folder"
    return 1
  fi
  if [[ -z "$oper" ]]; then
    fn_error "[${cfg[Name]}] countFiles: Operator is required."
    return 1
  fi

  count="${count//[^0-9]/}"
  if [[ -z "${count// }" ]]; then
    fn_error "[${cfg[Name]}] countFiles: Invalid count: $count"
    return 1
  fi

  if ! fn_cmd_exists find wc; then
    fn_error "[${cfg[Name]}] countFiles: find/wc not available."
    return 1
  fi

  local found
  found="$(find "${folder}" 2>/dev/null | wc -l | tr -d ' ')"
  fn_number_compare "$found" "$oper" "$count"
}

# ---------------------------
# Type implementations
# ---------------------------

# bk_type_local: rsync local->local.
# Uses keys: From, To, Options, Includes, Excludes, IncludeFrom, ExcludeFrom, FilterFrom, AutoFilter
bk_type_local() {
  local -a cmd=()

  cmd+=("${RSYNC_CMD_DEFAULT}")

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

  fn_debug "Executing: $(fn_quote_cmd cmd)"
  fn_run_logged cmd
}

# bk_type_remote: rclone sync/copy/etc.
# Uses keys: From, To, Action (rclone verb), Options, Includes/Excludes/include-from/exclude-from/filter-from.
bk_type_remote() {
  local -a cmd=()

  cmd+=("${RCLONE_CMD_DEFAULT}")

  # Action: default to sync.
  cmd+=("${cfg[Action]:-sync}")

  # Extra options (split by spaces).
  if [[ -n "${cfg[Options]:-}" ]]; then
    read -r -a _tmp_opts <<<"${cfg[Options]}"
    cmd+=("${_tmp_opts[@]}")
  fi

  bk_add_rclone_filters cmd

  cmd+=("${cfg[From]}" "${cfg[To]}")

  if [[ -n "${_DRY_RUN}" ]]; then
    fn_info "(dry-run) $(fn_quote_cmd cmd)"
    return 0
  fi

  fn_debug "Executing: $(fn_quote_cmd cmd)"
  fn_run_logged cmd
}

# bk_type_vault: run a Vault Action into a temp working dir, then compress/encrypt/copy.
#
# Required keys:
#   Action=CopyFiles|Database|...
# Optional:
#   Compress=tar.gz|tar|zip| (empty = no compression)
#   EncryptKey=... OR EncryptKeyFile=/path OR EncriptKeyFile=/path
#
# Destination:
#   To can be local path or rclone remote (remote:path).
bk_type_vault() {
  local action_name="${cfg[Name]}"
  local vault_action="${cfg[Action]:-}"

  if [[ -z "${vault_action// }" ]]; then
    fn_error "[$action_name] Vault requires Action=<VaultActionName>"
    return 1
  fi

  # Create temp directories:
  # - workdir: where the Vault Action writes files
  # - artifactdir: where we write archives (kept outside workdir to avoid tar "file changed" warnings)
  local ts workdir artifactdir
  ts="$(date +%Y%m%d_%H%M%S)"
  workdir="$(mktemp -d -t "backupfire.${action_name}.${ts}.work.XXXXXX")" || return 1
  artifactdir="$(mktemp -d -t "backupfire.${action_name}.${ts}.artifacts.XXXXXX")" || { rm -rf "$workdir" || true; return 1; }

  fn_debug "[$action_name] Vault workdir: $workdir"
  fn_debug "[$action_name] Vault artifact dir: $artifactdir"

  # Run the Vault action.
  local fn_name="bk_vault_action_${vault_action}"
  if ! fn_func_exists "$fn_name"; then
    fn_error "[$action_name] Vault action not found: $vault_action (expected function $fn_name)"
    rm -rf "$workdir" "$artifactdir" || true
    return 1
  fi

  # Provide context to the Vault action.
  local WORKDIR="$workdir"
  export WORKDIR

  if [[ -n "${_DRY_RUN}" ]]; then
    fn_info "(dry-run) Vault would run: ${fn_name}"
  else
    "$fn_name" || {
      local ret=$?
      fn_error "[$action_name] Vault action failed (code $ret)."
      rm -rf "$workdir" "$artifactdir" || true
      return "$ret"
    }
  fi

  # Decide packaging output.
  local compress="${cfg[Compress]:-}"
  local base="${action_name}_${ts}"
  local out_file="" tmp_file=""

  if [[ -n "${compress// }" ]]; then
    case "$compress" in
      tar|tar.gz|tgz)
        out_file="${artifactdir}/${base}.tar"
        [[ "$compress" == "tar.gz" || "$compress" == "tgz" ]] && out_file="${out_file}.gz"
        ;;
      zip)
        out_file="${artifactdir}/${base}.zip"
        ;;
      *)
        fn_error "[$action_name] Unsupported Compress format: $compress"
        rm -rf "$workdir" "$artifactdir" || true
        return 1
        ;;
    esac
  else
    # No compression: we will copy the directory as-is (local only) or tar it for remote.
    out_file="${artifactdir}/${base}.tar"
    compress="tar"
  fi

  # Build archive.
  if [[ -n "${_DRY_RUN}" ]]; then
    fn_info "(dry-run) Vault would package workdir -> $(basename -- "$out_file")"
  else
    case "$compress" in
      tar)
        (cd "$workdir" && tar -cf "$out_file" .) || { rm -rf "$workdir" "$artifactdir"; return 1; }
        ;;
      tar.gz|tgz)
        (cd "$workdir" && tar -czf "$out_file" .) || { rm -rf "$workdir" "$artifactdir"; return 1; }
        ;;
      zip)
        if ! fn_cmd_exists zip; then
          fn_error "[$action_name] zip not installed, cannot Compress=zip"
          rm -rf "$workdir" "$artifactdir" || true
          return 1
        fi
        (cd "$workdir" && zip -qr "$out_file" .) || { rm -rf "$workdir" "$artifactdir"; return 1; }
        ;;
    esac
  fi

  # Optional encryption.
  local encrypted_file="" key="" key_file=""
  key_file="${cfg[EncryptKeyFile]:-${cfg[EncriptKeyFile]:-}}"

  if [[ -n "${key_file// }" ]]; then
    if [[ -r "$key_file" ]]; then
      key="$(head -n1 "$key_file" | tr -d '\r\n')"
    else
      fn_error "[$action_name] EncryptKeyFile not readable: $key_file"
      rm -rf "$workdir" "$artifactdir" || true
      return 1
    fi
  else
    key="${cfg[EncryptKey]:-}"
  fi

  if [[ -n "${key// }" ]]; then
    encrypted_file="${out_file}.enc"
    if [[ -n "${_DRY_RUN}" ]]; then
      fn_info "(dry-run) Vault would encrypt: $(basename -- "$out_file") -> $(basename -- "$encrypted_file")"
    else
      if ! fn_cmd_exists "${OPENSSL_CMD_DEFAULT}"; then
        fn_error "[$action_name] openssl not available for encryption"
        rm -rf "$workdir" "$artifactdir" || true
        return 1
      fi

      # AES-256-CBC with PBKDF2; passphrase is provided via cfg.
      "${OPENSSL_CMD_DEFAULT}" enc -aes-256-cbc -salt -pbkdf2 \
        -pass "pass:${key}" -in "$out_file" -out "$encrypted_file" || {
          rm -rf "$workdir" "$artifactdir" || true
          return 1
        }
    fi
  fi

  # Final artifact to copy.
  local artifact="$out_file"
  [[ -n "${encrypted_file}" ]] && artifact="$encrypted_file"

  # Copy to destination.
  if [[ -n "${_DRY_RUN}" ]]; then
    fn_info "(dry-run) Vault would copy artifact to: ${cfg[To]}"
    rm -rf "$workdir" "$artifactdir" || true
    return 0
  fi

  bk_vault_copy_artifact "$artifact" || {
    local ret=$?
    rm -rf "$workdir" "$artifactdir" || true
    return "$ret"
  }

  # Cleanup.
  rm -rf "$workdir" "$artifactdir" || true
  return 0
}

# bk_vault_action_CopyFiles: Vault action that copies From into WORKDIR.
#
# Usage in config:
#   Type=Vault
#   Action=CopyFiles
#   From=/data/source
#
# Notes:
# - Uses rsync to preserve timestamps/permissions where possible.
bk_vault_action_CopyFiles() {
  local action_name="${cfg[Name]}"
  if [[ -z "${WORKDIR:-}" || ! -d "${WORKDIR}" ]]; then
    fn_error "[$action_name] WORKDIR is not set for Vault action"
    return 1
  fi

  local -a cmd=("${RSYNC_CMD_DEFAULT}" -a --delete)

  # Reuse include/exclude semantics for Vault copy.
  bk_add_rsync_filters cmd

  # Trailing slash copies contents, not the directory itself.
  cmd+=("${cfg[From]%/}/" "${WORKDIR%/}/")

  fn_debug "[$action_name] Vault CopyFiles: $(fn_quote_cmd cmd)"
  fn_run_logged cmd
}

# bk_vault_action_Database: Vault action that runs a DB dump command into WORKDIR.
#
# Usage in config (example):
#   Type=Vault
#   Action=Database
#   Command=pg_dump -Fc -f %OUT% mydb
# Optional:
#   Output=filename.dump   (default: <action>_<timestamp>.dump)
#
# Placeholders:
#   %WORKDIR% => WORKDIR
#   %OUT%     => absolute output file inside WORKDIR
bk_vault_action_Database() {
  local action_name="${cfg[Name]}"

  if [[ -z "${WORKDIR:-}" || ! -d "${WORKDIR}" ]]; then
    fn_error "[$action_name] WORKDIR is not set for Vault action"
    return 1
  fi

  local cmdline="${cfg[Command]:-}"
  if [[ -z "${cmdline// }" ]]; then
    fn_error "[$action_name] Database Vault action requires Command=..."
    return 1
  fi

  local out_name="${cfg[Output]:-${cfg[DatabaseOutput]:-}}"
  if [[ -z "${out_name// }" ]]; then
    out_name="${action_name}.dump"
  fi

  local out_path="${WORKDIR%/}/${out_name}"

  # Expand placeholders.
  cmdline="${cmdline//%WORKDIR%/${WORKDIR}}"
  cmdline="${cmdline//%OUT%/${out_path}}"

  local -a argv=()
  fn_cmdline_to_array "$cmdline" argv

  if [[ ${#argv[@]} -eq 0 ]]; then
    fn_error "[$action_name] Invalid Command line"
    return 1
  fi

  fn_debug "[$action_name] Vault Database command: $(fn_quote_cmd argv)"
  fn_run_logged argv
}

# bk_vault_copy_artifact: copy a produced artifact to cfg[To] (local or rclone remote).
# Usage: bk_vault_copy_artifact /path/to/file
bk_vault_copy_artifact() {
  local artifact="$1"
  local action_name="${cfg[Name]}"

  if [[ ! -f "$artifact" ]]; then
    fn_error "[$action_name] Artifact not found: $artifact"
    return 1
  fi

  local file_name
  file_name="$(basename -- "$artifact")"

  if [[ -n "${cfg[ToHost]:-}" ]]; then
    # Remote destination via rclone.
    local dest="${cfg[To]}"
    # If To ends with / treat as directory.
    if [[ "${dest}" == */ ]]; then
      dest="${dest}${file_name}"
    fi

    local -a cmd=("${RCLONE_CMD_DEFAULT}" copyto "$artifact" "$dest")
    fn_debug "[$action_name] Vault remote copy: $(fn_quote_cmd cmd)"
    fn_run_logged cmd
    return $?
  fi

  # Local destination.
  mkdir -p "${cfg[To]}" 2>/dev/null || true
  local -a cmd=(cp -f "$artifact" "${cfg[To]%/}/${file_name}")
  fn_debug "[$action_name] Vault local copy: $(fn_quote_cmd cmd)"
  fn_run_logged cmd
}

# ---------------------------
# Filter argument builders
# ---------------------------

# bk_add_rsync_filters: append rsync include/exclude/filter arguments to a command array.
# Usage: bk_add_rsync_filters cmd_array[@]
bk_add_rsync_filters() {
  local -n _cmd_ref="$1"

  # AutoFilter: look for dotfiles under From/.<prefix>*.conf
  local auto_prefix="${cfg[AutoFilterPrefix]:-}"
  local pfx=""
  [[ -n "${auto_prefix// }" ]] && pfx="${auto_prefix}."

  if fn_boolean "${cfg[AutoFilter]:-}"; then
    local base="${cfg[From]%/}/.${pfx}"
    [[ -f "${base}includes.conf" ]] && _cmd_ref+=("--include-from=${base}includes.conf")
    [[ -f "${base}excludes.conf" ]] && _cmd_ref+=("--exclude-from=${base}excludes.conf")
    if [[ -f "${base}filters.conf" ]]; then
      # rsync "merge" filter file
      _cmd_ref+=("--filter=merge ${base}filters.conf")
    fi
  fi

  # Explicit filter file.
  if [[ -n "${cfg[FilterFrom]:-}" ]]; then
    if [[ -r "${cfg[FilterFrom]}" ]]; then
      _cmd_ref+=("--filter=merge ${cfg[FilterFrom]}")
    else
      fn_error "[${cfg[Name]}] FilterFrom not readable: ${cfg[FilterFrom]}"
      return 1
    fi
  fi

  # Include/exclude from file.
  if [[ -n "${cfg[IncludeFrom]:-}" ]]; then
    [[ -r "${cfg[IncludeFrom]}" ]] || { fn_error "IncludeFrom not readable: ${cfg[IncludeFrom]}"; return 1; }
    _cmd_ref+=("--include-from=${cfg[IncludeFrom]}")
  fi
  if [[ -n "${cfg[ExcludeFrom]:-}" ]]; then
    [[ -r "${cfg[ExcludeFrom]}" ]] || { fn_error "ExcludeFrom not readable: ${cfg[ExcludeFrom]}"; return 1; }
    _cmd_ref+=("--exclude-from=${cfg[ExcludeFrom]}")
  fi

  # Inline Includes/Excludes (comma-separated).
  local s
  if [[ -n "${cfg[Includes]:-}" ]]; then
    IFS=',' read -r -a _arr <<<"${cfg[Includes]}"
    for s in "${_arr[@]}"; do
      s="$(fn_trim "$s")"
      [[ -z "$s" ]] && continue
      _cmd_ref+=("--include=$s")
    done
  fi
  if [[ -n "${cfg[Excludes]:-}" ]]; then
    IFS=',' read -r -a _arr <<<"${cfg[Excludes]}"
    for s in "${_arr[@]}"; do
      s="$(fn_trim "$s")"
      [[ -z "$s" ]] && continue
      _cmd_ref+=("--exclude=$s")
    done
  fi
}

# bk_add_rclone_filters: append rclone include/exclude/filter arguments to a command array.
# Usage: bk_add_rclone_filters cmd_array[@]
bk_add_rclone_filters() {
  local -n _cmd_ref="$1"

  local auto_prefix="${cfg[AutoFilterPrefix]:-}"
  local pfx=""
  [[ -n "${auto_prefix// }" ]] && pfx="${auto_prefix}."

  if fn_boolean "${cfg[AutoFilter]:-}"; then
    local base="${cfg[From]%/}/.${pfx}"
    [[ -f "${base}filters.conf" ]] && _cmd_ref+=("--filter-from=${base}filters.conf")
    [[ -f "${base}includes.conf" ]] && _cmd_ref+=("--include-from=${base}includes.conf")
    [[ -f "${base}excludes.conf" ]] && _cmd_ref+=("--exclude-from=${base}excludes.conf")
  fi

  if [[ -n "${cfg[FilterFrom]:-}" ]]; then
    [[ -r "${cfg[FilterFrom]}" ]] || { fn_error "FilterFrom not readable: ${cfg[FilterFrom]}"; return 1; }
    _cmd_ref+=("--filter-from=${cfg[FilterFrom]}")
  fi
  if [[ -n "${cfg[IncludeFrom]:-}" ]]; then
    [[ -r "${cfg[IncludeFrom]}" ]] || { fn_error "IncludeFrom not readable: ${cfg[IncludeFrom]}"; return 1; }
    _cmd_ref+=("--include-from=${cfg[IncludeFrom]}")
  fi
  if [[ -n "${cfg[ExcludeFrom]:-}" ]]; then
    [[ -r "${cfg[ExcludeFrom]}" ]] || { fn_error "ExcludeFrom not readable: ${cfg[ExcludeFrom]}"; return 1; }
    _cmd_ref+=("--exclude-from=${cfg[ExcludeFrom]}")
  fi

  local s
  if [[ -n "${cfg[Includes]:-}" ]]; then
    IFS=',' read -r -a _arr <<<"${cfg[Includes]}"
    for s in "${_arr[@]}"; do
      s="$(fn_trim "$s")"
      [[ -z "$s" ]] && continue
      _cmd_ref+=("--include=$s")
    done
  fi
  if [[ -n "${cfg[Excludes]:-}" ]]; then
    IFS=',' read -r -a _arr <<<"${cfg[Excludes]}"
    for s in "${_arr[@]}"; do
      s="$(fn_trim "$s")"
      [[ -z "$s" ]] && continue
      _cmd_ref+=("--exclude=$s")
    done
  fi
}


# bk_main: program entry point.
# Usage: bk_main "$@"
bk_main() {
  bk_parse_args "$@"

  # Apply logging option.
  if [[ -n "${OPT_LOG:-}" ]]; then
    _LOG="$OPT_LOG"
  fi

  # Resolve config unless help-only and user didn't ask for action listing.
  if [[ -n "${OPT_CONFIG:-}" || -z "${OPT_HELP:-}" || -n "${OPT_LIST:-}" || -n "${OPT_ALL:-}" || ${#ACTIONS[@]} -gt 0 || -n "${OPT_TEST_ENV:-}" ]]; then
    bk_resolve_config "${OPT_CONFIG:-}" || {
      # If user only asked for help, still show help even without config.
      if [[ -n "${OPT_HELP:-}" ]]; then
        print_global_help
        return 0
      fi
      return 1
    }
  fi

  # Help.
  if [[ -n "${OPT_HELP:-}" ]]; then
    if [[ ${#ACTIONS[@]} -gt 0 ]]; then
      print_action_help "${ACTIONS[0]}" || true
    else
      print_global_help
    fi
    return 0
  fi

  # List actions.
  if [[ -n "${OPT_LIST:-}" ]]; then
    bk_list_actions "${CFG_FILE}"
    return 0
  fi

  # Test environment.
  if [[ -n "${OPT_TEST_ENV:-}" ]]; then
    bk_test_env "${CFG_FILE}"
    return $?
  fi

  # Determine actions to run.
  if [[ -n "${OPT_ALL:-}" ]]; then
    mapfile -t ACTIONS < <(bk_ini_list_actions "${CFG_FILE}")
  fi

  if [[ ${#ACTIONS[@]} -eq 0 ]]; then
    fn_error "You must provide at least one action, or use -a"
    print_global_help
    return 2
  fi

  fn_debug "Config file: ${CFG_FILE}"
  fn_debug "Dry-run   : ${_DRY_RUN:-0}"
  fn_debug "Debug     : ${_DEBUG:-0}"
  fn_debug "Actions   : ${ACTIONS[*]}"

  # Execute each requested action (with deps).
  local act ret=0
  for act in "${ACTIONS[@]}"; do
    if ! bk_run_action_tree "$act"; then
      ret=1
    fi
  done

  return "$ret"
}

bk_main "$@"
