#!/usr/bin/env bash
# backupfire.sh - Backup tool
#
# Runs backup "tasks" defined in an INI config file.
#
# Supported Types:
#   - Local  : rsync local->local
#   - Remote : rclone local<->remote
#   - Backup : run a Vault Action (e.g. Database / CopyFiles),
#              then optionally compress and encrypt before copying to destination.
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
SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
SCRIPT_VERSION="2.0.1"

# Default config search locations.
CFG_DEFAULT_NAME="default.conf"
CFG_DIRS=("$SCRIPT_DIR/config" "$HOME/config/" "/etc/backupfire")
IGNORE_SECTIONS=("general" "crontab")

# Safety: directories that are almost always a bad destination.
INVALID_DIR_PREFIXES="/etc/,/bin/,/boot/,/dev/,/lib/,/lib32/,/lib64/,/libx32/,/proc/"

# External tools (can be overridden by env vars).
RSYNC_CMD="${RSYNC_CMD:-rsync}"
RCLONE_CMD="${RCLONE_CMD:-rclone}"
OPENSSL_CMD="${OPENSSL_CMD:-openssl}"
RCLONE_CONFIG="${RCLONE_CONFIG:-}"
POSTGRES_CMD="${POSTGRES_CMD:-pgdump}"
POSTGRES_CHECK_CMD="${POSTGRES_CHECK_CMD:-psql}"


# Options variables
###############################################################################
BK_ALL=""
BK_EMAIL="" # Reserved for future (email reporting)
BK_CONFIG="${BK_CONFIG:-}"
BK_LIST=""
BK_HELP=""
BK_DRY_RUN=""
BK_TEST_ENV=""

# Positional: requested tasks (section names).
TASKS=() CLEANUP=() UPLOADS=()

# Internal state for dependency resolution.
declare -A RUN_SET=() WALK_SET=() ERR_SET=()

# Task config is loaded into this associative array before each run.
declare -A cfg=()
TASK= #current task

# ---------------------------
# Task runner
# ---------------------------

# bk_validate_action_name: ensure an action section name contains safe characters.
# Usage: bk_validate_action_name <name>
bk_validate_task_name() {
  local action="$1"
  [[ "$action" =~ ^[0-9A-Za-z._-]+$ ]]
}

# bk_task_deps: get the raw Depends string for an task (may be empty).
# Usage: bk_task_deps <task>
bk_task_deps() {
  fn_ini_get "${BK_CONFIG}" "$1" "Depends"
}

# bk_run_task_tree: run an task and its dependencies (no circular deps).
# Usage: bk_run_task_tree <task>
bk_run_task_tree() {
  local task="$1"

  fn_debug "Running task: $task"

  # Skip non-task meta sections.
  fn_in_array "$task" "${IGNORE_SECTIONS[@]}" && {
    fn_error "This task is system protected:" "$task"
    ERR_SET["$task"]=1
  } && return 1

  if ! bk_validate_task_name "$task"; then
    fn_error "task name has invalid characters: $task"
    ERR_SET["$task"]=1
    return 1
  fi

  # Already done.
  [[ -n "${RUN_SET[$task]:-}" ]] && {
     fn_debug "The task already run: $task "
     return 0
  }

  # Detect circular dependency.
  if [[ -n "${WALK_SET[$task]:-}" ]]; then
    fn_error "Circular dependency detected at task: $task"
    ERR_SET["$task"]=1
    return 1
  fi

  WALK_SET["$task"]=1

  # Run dependencies first.
  local deps_raw deps dep
  deps_raw="$(bk_task_deps "$task")"
  fn_debug "Checking task dependencies: $deps_raw"
  if [[ -n "${deps_raw// }" ]]; then
    IFS=',' read -r -a deps <<<"${deps_raw}"
    for dep in "${deps[@]}"; do
      fn_debug "Task: $task: Running dependency: $dep ..."

      dep="$(fn_trim "$dep")"
      [[ -z "$dep" ]] && continue

      if [[ -n "${ERR_SET[$dep]:-}" ]]; then
        fn_error "task $task requires $dep, but $dep previously failed."
        ERR_SET["$task"]=1
        return 1
      fi

      bk_run_task_tree "$dep" || {
        fn_error "Dependency $dep failed; skipping $task."
        ERR_SET["$task"]=1
        return 1
      }
    done
  fi

  # Run the task itself.
  fn_info "Running task: $task"
  if bk_run_task "$task"; then
    RUN_SET["$task"]=1
    fn_success "$C_RESET" "Task " "$C_BOLD" "$task" "$C_RESET" " was successfull completed."
    return 0
  fi

  fn_failed "$C_RESET" "Task " "$C_BOLD" "$task" "$C_RESET" " failed to complete."
  ERR_SET["$task"]=1
  return 1
}

# bk_run_task: load an task config, validate it, and dispatch by Type.
# Usage: bk_run_task <task>
bk_run_task() {
  local task="$1"
  TASK="$task"

  bk_load_task_cfg "$task"

  if [[ ${#cfg[@]} -eq 0 ]]; then
    fn_error "Task [$task] not found in config."
    return 1
  fi
  # check skip
  if fn_boolean "${cfg[Skip]:-}"; then
    fn_debug "Skipping Task $task as configured.."
    return 0
  fi
  #check essential configurations:
  if [[ -z "${cfg[Type]:-}" ]] || [[ -z "${cfg[From]:-}" ]] || \
     [[ -z "${cfg[To]:-}" ]]; then
        fn_error "You need to set Type=, From=, and To= in the task configuration"
        return 1
  fi

  bk_run_hook "Before" || {
    fn_debug "[$task] Before hook failed; aborting action."
    return 1
  }

  # dispatch to Type.
  local type="${cfg[Type]:-}"
  case "${type,,}" in
    backup)  bk_type_backup ;;
    local) bk_type_local ;;
    remote) bk_type_local ;;
    *)
      fn_error "[$task] Unknown Type: $type"
      return 1
      ;;
  esac
  local ret=$?
  if [[ "$ret" -ne 0 ]]; then
    fn_error "[$task] Type execution failed with code $ret"
    return "$ret"
  fi

  bk_run_hook "After" || {
    fn_debug "[$task] After hook failed."
    return 1
  }

}

# bk_load_task_cfg: load [General] plus the requested task section into cfg.
# Usage: bk_load_task_cfg <task>
bk_load_task_cfg() {
  local task="$1"
  declare -gA cfg=()
  fn_ini_load_sections cfg "${BK_CONFIG}" "General,${task}"
  cfg[Name]="$task"
  # Expand ~ in From/To (common in configs).
  [[ "${cfg[From]:-}" == ~/* ]] && cfg[From]="${HOME}/${cfg[From]#~/}"
  [[ "${cfg[To]:-}" == ~/* ]] && cfg[To]="${HOME}/${cfg[To]#~/}"

  # Normalize paths for keys that are expected to be file paths.
  fn_normalize_cfg_paths cfg "IncludeFrom:ExcludeFrom:FilterFrom:EncryptKeyFile:EncriptKeyFile"
}

# ---------------------------
# Type implementations
# ---------------------------
bk_type_backup() {
  # prepare the environment.
  local w_dir a_dir task
  # Create temp directories:
  # - workdir: where the Vault Action writes files
  # - artifactdir: where we write archives (kept outside workdir to avoid tar "file changed" warnings)
  task="${cfg[Name]}"
  cfg[WorkDir]="$(bk_mktemp -d -t "backupfire.${task}.work")"
  cfg[ArtifactDir]="$(bk_mktemp -d -t "backupfire.${task}.artifacts")"
  w_dir="${cfg[WorkDir]}" a_dir="${cfg[ArtifactDir]}"
  fn_debug "[$task]      Task workdir: ${cfg[WorkDir]}"
  fn_debug "[$task] Task artifact dir: ${cfg[ArtifactDir]}"

  # dispatch to Action.
  local action="${cfg[Action]:-copy}"
  case "${action,,}" in
    postgres|db|database)
      fn_debug "Running action: $action:"
      bk_action_postgres "$task" "$w_dir" "$a_dir"
      ;;
    copy|copyfiles)
      fn_debug "Running action: $action:"
      bk_action_copyfiles "$task" "$w_dir" "$a_dir"
      ;;
    *)
      fn_error "[$task] Type Backup: Unknown Action: $action"
      return 1
      ;;
  esac
  local ret=$?
  if [[ "$ret" -ne 0 ]]; then
    fn_error "[$task] Action ($action) execution failed with code $ret"
    return "$ret"
  fi

  #check if To is a temporary directory:
  if [[ "${cfg[To]}" == tmp:* ]]; then
    cfg[OriginalTo]="${cfg[To]}"
    cfg[To]="$(bk_mktemp -d -t "backupfire.${task}.to")"
    fn_debug "Using a temporary dest! It will be deleted at end of the execution:"
    fn_debug "${cfg[To]}"
  fi

  # action was executed, now compression
  if ! bk_type_backup_compression "$task" "$w_dir" "$a_dir"; then
    return 1
  fi

  # now encryption
  if ! bk_type_backup_encryption "$task" "$w_dir" "$a_dir"; then
    return 1
  fi

  # move to destination dir
  if ! bk_type_backup_movefiles "$task" "$w_dir" "$a_dir"; then
    return 1
  fi

  # now remote upload
  if ! bk_type_backup_remote "$task" "$w_dir" "$a_dir"; then
    return 1
  fi
}

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
  local -a cmd=()
  local -a env=()

  bk_action_postgres_check || return 2

  # set default arguments:
  cmd=("$app" -h "${cfg[DbHost]:-localhost}")
  [[ "$app" == *"_dumpall" ]] ||  cmd+=(-d "${cfg[DbName]:-postgres}")

  [[ -n "${cfg[DbPort]}" ]] && cmd+=(-p "${cfg[DbPort]}") || cmd+=(-p 5432)
  [[ -n "${cfg[DbUser]}" ]] && cmd+=(-U "${cfg[DbUser]}")

  # Only set PGPASSWORD if provided (avoid clobbering existing env)
  if [[ -n "${cfg[DbPass]:-}" ]]; then
    env=(PGPASSWORD="${cfg[DbPass]}")
  else
    cmd+=(--no-password)
  fi
  local -a all_cmd=("${env[@]}" "${cmd[@]}" "$@")

  "${env[@]}" "${cmd[@]}" "$@"
}

bk_action_postgres() {
  local task="$1" workdir="$2" artifactdir="$3"
  local -a opts=("--format=directory" "--jobs=4" "--compress=0" --no-owner --no-privileges --blobs)
  local file_ext="${cfg[DbFileExtension]:-}" file_name=
  local -a cmd=()

  # test connection
  if ! bk_action_postgres_run fn_run "${POSTGRES_CHECK_CMD}" -c 'SELECT 1;' -tA; then
    fn_error "Connection wasn't stablished with database!"
    return 2
  fi

  #load command line options from config
  if [[ -n "$cfg[DbBackupOpts]:-}" ]]; then
    fn_cmdline_to_array opts "$cfg[DbBackupOpts]:-}"
  fi

  [[ -n "$file_ext" ]] && file_name="$(bk_build_artifact_name)${file_ext}"

  # connection is ok! run backup
  bk_action_postgres_run fn_run "${POSTGRES_CMD}" "${opts[@]}" \
    --file="$workdir/$file_name"
  # check command return
  if [[ $? -ne 0 ]]; then
    fn_error "Failed to run Backup job!"
    return 2
  fi
}

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

  # Append From and To.
  cmd+=("${cfg[From]}" "$artifactdir")

  fn_run "${cmd[@]}"

}

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
  #todo: uncomment
  #fn_run "${cmd[@]}"
}

bk_type_backup_movefiles() {
  local task="$1" workdir="$2" artifactdir="$3"
  local struct="${cfg[BackupStructure]:-tree}"

  [[ ! -f "${cfg[Artifact]}" ]] \
    && { fn_error "Task artifact file doesn't exist: ${cfg[Artifact]}"; return 1; }

  [[ ! -d "${cfg[To]}" ]] && mkdir -p "${cfg[To]}" || true

  [[ ! -d "${cfg[To]}" ]] \
      && { fn_error "MoveFiles: Task destination is not a valid directory: ${cfg[To]}"; return 1; }

  UPLOADS=()

  if ! fn_boolean "${cfg[BackupLimit]}"; then
    struct=none
  fi

  fn_debug "Moving files to dest: ${cfg[To]}"

  case "$struct" in
    none)
      bk_type_backup_movefiles_none "$task" "$w_dir" "$a_dir"
      ;;
    tree)
      bk_type_backup_movefiles_tree "$task" "$w_dir" "$a_dir"
      ;;
    *)
      fn_error "[$task] Unsupported BackupStructure format: $struct"
      return 1
      ;;
  esac
  # structure as tree
  return $?
}

bk_type_backup_movefiles_tree() {
  local task="$1" workdir="$2" artifactdir="$3" to= group=

  local groups=("yearly" "monthly" "weekly" "daily")
  local now=$(date +"%Y-%m-%d")
  local week=$(date +"%u")

  # create a file in each group
  for group in "${groups[@]}"; do
    [[ ! -d "${cfg[To]}/$group" ]] && mkdir -p "${cfg[To]}/$group" || true
    case "$group" in
      yearly)
        [[ "$now" != *"-01-01" ]] && continue #only first day of the year
        ;;
      monthly)
        [[ "$now" != *"-01" ]] && continue #only first day of the month
        ;;
      weekly)
        [[ "$week" != "1" ]] && continue # only mondays
        ;;
    esac
    [[ ! -d "${cfg[To]}/$group" ]] \
      && { fn_error "Task destination is not a valid directory: ${cfg[To]}/$group"; return 1; }

    to="${cfg[To]}/$group/${cfg[ArtifactName]}"
    bk_type_backup_util_cp "${cfg[Artifact]}" "$to"

    [[ ! -f "$to" ]] \
      && { fn_error "It was not possible to copy to destination: ${cfg[To]}"; return 1; }

    UPLOADS+=("/$group/:$to")
  done
}

bk_type_backup_movefiles_none() {
  local task="$1" workdir="$2" artifactdir="$3"

  # just copy the file to final destination
  to="${cfg[To]}/${cfg[ArtifactName]}"
  bk_type_backup_util_cp "${cfg[Artifact]}" "$to"

  [[ ! -f "$to" ]] \
    && { fn_error "It was not possible to copy to destination: ${cfg[To]}"; return 1; }
  # all set
  UPLOADS+=("/:$to")
  return 0
}

bk_type_backup_util_cp() {
  local from="$1" to="$2"
  fn_run rsync -a -- "$from" "$to"
  fn_debug "Moving files from: ${from} to: ${to}"
}

# format task date with format: $1
bk_type_backup_util_date() {
  local format="${1:-%s}"
  [[ -z "${cfg[Timestamp]:-}" ]] && {
    ts="$(date +"${cfg[DateFormat]-%Y%m%d%H%M%S}")" || return 1
    cfg[Timestamp]="$(date +%s)"
    cfg[DateStr]="$ts"
  }
  fn_format_epoch "${cfg[Timestamp]}" "${format}"
}


bk_type_backup_encryption() {
  local task="$1" workdir="$2" artifactdir="$3"

  [[ -z "${cfg[EncryptKeyFile]}" ]] && [[ -z "${cfg[EncryptKey]}" ]] && { \
    fn_debug "Encription was disabled. skipping..."
    return 0
  }

  if ! bk_backup_encryption_checks; then
    return 1
  fi

  # checks if directory exists
  [[ ! -d "${cfg[ArtifactDir]}" ]] \
    && { fn_error "Task artifact dir doesn't exist: ${cfg[ArtifactDir]}"; return 1; }

  [[ ! -f "${cfg[Artifact]}" ]] \
    && { fn_error "Task artifact file doesn't exist: ${cfg[Artifact]}"; return 1; }

  [[ ! -r "${cfg[PEMKeyFile]}" ]] \
    && { fn_error "The encription key was not generated: ${cfg[PEMKeyFile]}"; return 1; }

  fn_debug "Encryption enabled. Using Key at: ${cfg[PEMKeyFile]}"

  pushd "${cfg[ArtifactDir]}" >/dev/null || return 1

    local secret="$(bk_mktemp -t "backupfire.${task}.secret")"
    local artifact="$(bk_build_artifact_name)"

    fn_debug "Encryption: Generating private key from public provided key.."
    #generate a private key to be used
    fn_run $OPENSSL_CMD rand -base64 256 > "$secret"
    fn_run $OPENSSL_CMD pkeyutl -encrypt -inkey "${cfg[PEMKeyFile]}" \
      -pubin -in "$secret" -out "${artifact}.secret"

    fn_debug "Encrypting data.."
    fn_run $OPENSSL_CMD enc -aes-256-cbc -salt -pbkdf2 -pass "file:$secret" \
      -in "${cfg[Artifact]}" -out "${artifact}.enc"

    #delete the key as soon possible
    rm -f -- "$secret"

    fn_debug "Packing encripted data in: ${artifact}.backup"

    # pack everything in a tar file (withouth compression)
    fn_run tar -cf "${artifact}.backup" "${artifact}.secret" \
      "${artifact}.enc"

    # sets the final production file
    cfg[Artifact]="$artifactdir/${artifact}.backup"
    cfg[ArtifactName]="${artifact}.backup"
    cfg[ArtifactExt]=".backup"

  popd >/dev/null || return 1

}

bk_backup_encryption_checks() {
  local tempk= firstline=
  local keyf="$(bk_mktemp -t "backupfire.${task}.keyfile")"
  local sshk="$(bk_mktemp -t "backupfire.${task}.ssh-temp")"

  #check if encription key is set (file or text)
  if [[ -n "${cfg[EncryptKeyFile]}" ]]; then
    [[ ! -f "${cfg[EncryptKeyFile]}" ]] && fn_error "Key file doesn't exists!" && return 1
    # check if file is a PEM file
    IFS= read -r firstline < "${cfg[EncryptKeyFile]}"
    if [[ "$firstline" == *"-----BEGIN "* ]]; then
      # key is a valid pem key
      cat "${cfg[EncryptKeyFile]}" > "$keyf"
      cfg[PEMKeyFile]="$keyf"
      return 0
    else
      # need to be converted
      tempk=1
      cat "${cfg[EncryptKeyFile]}" > "$sshk"
    fi
  elif [[ -n "${cfg[EncryptKey]}" ]]; then
    if [[ "${cfg[EncryptKey]}" == ssh-* ]]; then
      # its a valid key. generate pem from it
      tempk=1
      printf '%s' "${cfg[EncryptKey]}" > "$sshk"
    else
      fn_error "Unsupported key format. Need to be: ssh-rsa XXX"
      return 1
    fi
  fi
  chmod 0644 "$sshk" 2>/dev/null || true
  # if its a temp key, convert:
  if [[ "$tempk" -gt 0 ]]; then
    if ssh-keygen -f "$sshk" -e -m PEM >"$keyf" 2>/dev/null; then
      IFS= read -r firstline < "$keyf"
      if [[ "$firstline" == *"-----BEGIN "* ]]; then
        cfg[PEMKeyFile]="$keyf"
        return 0
      fi
    fi
  fi
  fn_error "Invaid key! Set EncryptKeyFile or EncryptKey in Task settigs.."
  return 1
}

# bk_type_backup_compression: Compress files based in the algoritm
# Uses key: Compression=
bk_type_backup_compression() {
  local task="$1" workdir="$2" artifactdir="$3"
  local compress file_name out_file ext

  # default Compression=tar (cannot exist Backup without compression).
  compress="${cfg[Compression]-tar}"
  file_name="$(bk_build_artifact_name)"

  fn_debug "Packing workdir in: $compress"

  case "$compress" in
    tar)
      out_file="${artifactdir}/${file_name}.tar"
      ext=".tar"
      (cd "$workdir" && tar -cf "$out_file" . ) || { fn_error "Failed to compress into $out_file"; return 1; }
      ;;
    tar.gz|tgz)
      out_file="${artifactdir}/${file_name}.tar.gz"
      ext=".tar.gz"
      (cd "$workdir" && tar -czf "$out_file" . ) || { fn_error "Failed to compress into $out_file"; return 1; }
      ;;
    zip)
      out_file="${artifactdir}/${file_name}.zip"
      ext=".zip"
      (cd "$workdir" && zip -qr "$out_file" . ) || { fn_error "Failed to compress into $out_file"; return 1; }
      ;;
    *)
      fn_error "[$task] Unsupported Compress format: $compress"
      return 1
      ;;
  esac
  # sets artifact
  cfg[Artifact]="$out_file"
  cfg[ArtifactName]="${file_name}${ext}"
  cfg[ArtifactExt]="${ext}"

  fn_debug "Artifact generated: ${cfg[ArtifactName]}"

  # remove workdir
  #rm -rf -- "$workdir/*"
}

# bk_build_artifact_name
# Uses keys: DateFormat, FilePrefix
# usage: bk_build_artifact_name "daily" ".enc"
bk_build_artifact_name() {
  local fmt='%s%s_%s' ts=
  for _ in "$@"; do fmt+='%s'; done
  # create timestamp if not defined (to be reused in other file compositions)
  [[ -z "${cfg[Timestamp]:-}" ]] && {
    ts="$(date +"${cfg[DateFormat]-%Y%m%d%H%M%S}")" || return 1
    cfg[Timestamp]="$(date +%s)"
    cfg[DateStr]="$ts"
  }
  printf "$fmt" "${cfg[FilePrefix]}" "${cfg[Name]}" "${cfg[DateStr]}" "$@"
}

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
    "$@" >/dev/null 2>&1
  fi
}


# ---------------------------
# Filter argument builders
# ---------------------------

# bk_add_rsync_filters: append rsync include/exclude/filter arguments to a command array.
# Usage: bk_add_rsync_filters cmd_array[@] "Remote"
bk_add_rsync_filters() {
  local -n _cmd_ref="$1"
  local pref="${2:-}" #prefix for include,Exclude and AutoFilters

  # AutoFilter: look for dotfiles under From/.<prefix>*.conf
  local auto_prefix="${cfg[${pref}AutoFilterPrefix]:-}"
  local pfx=""
  [[ -n "${auto_prefix// }" ]] && pfx="${auto_prefix}."

  if fn_boolean "${cfg[${pref}AutoFilter]:-}"; then
    local base="${cfg[From]%/}/.${pfx}"
    [[ -f "${base}includes.conf" ]] && _cmd_ref+=("--include-from=${base}includes.conf")
    [[ -f "${base}excludes.conf" ]] && _cmd_ref+=("--exclude-from=${base}excludes.conf")
    [[ -f "${base}filters.conf" ]] && _cmd_ref+=("--filter=merge ${base}filters.conf")
  fi

  # Explicit filter file.
  if [[ -n "${cfg[${pref}FilterFrom]:-}" ]]; then
    if [[ -r "${cfg[${pref}FilterFrom]}" ]]; then
      _cmd_ref+=("--filter=merge ${cfg[FilterFrom]}")
    else
      fn_error "[${cfg[Name]}] ${pref}FilterFrom not readable: ${cfg[${pref}FilterFrom]}"
      return 1
    fi
  fi

  # Include/exclude from file.
  if [[ -n "${cfg[${pref}IncludeFrom]:-}" ]]; then
    [[ -r "${cfg[${pref}IncludeFrom]}" ]] || { fn_error "${pref}IncludeFrom not readable: ${cfg[${pref}IncludeFrom]}"; return 1; }
    _cmd_ref+=("--include-from=${cfg[${pref}IncludeFrom]}")
  fi
  if [[ -n "${cfg[${pref}ExcludeFrom]:-}" ]]; then
    [[ -r "${cfg[${pref}ExcludeFrom]}" ]] || { fn_error "${pref}ExcludeFrom not readable: ${cfg[${pref}ExcludeFrom]}"; return 1; }
    _cmd_ref+=("--exclude-from=${cfg[${pref}ExcludeFrom]}")
  fi

  # Inline Includes/Excludes (comma-separated).
  local s
  if [[ -n "${cfg[${pref}Includes]:-}" ]]; then
    IFS=',' read -r -a _arr <<<"${cfg[${pref}Includes]}"
    for s in "${_arr[@]}"; do
      s="$(fn_trim "$s")"
      [[ -z "$s" ]] && continue
      _cmd_ref+=("--include=$s")
    done
  fi
  if [[ -n "${cfg[${pref}Excludes]:-}" ]]; then
    IFS=',' read -r -a _arr <<<"${cfg[${pref}Excludes]}"
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
  local pref="${2:-}" #prefix for include,Exclude and AutoFilters

  local auto_prefix="${cfg[${pref}AutoFilterPrefix]:-}"
  local pfx=""
  [[ -n "${auto_prefix// }" ]] && pfx="${auto_prefix}."

  if fn_boolean "${cfg[${pref}AutoFilter]:-}"; then
    local base="${cfg[From]%/}/.${pfx}"
    [[ -f "${base}filters.conf" ]] && _cmd_ref+=("--filter-from=${base}filters.conf")
    [[ -f "${base}includes.conf" ]] && _cmd_ref+=("--include-from=${base}includes.conf")
    [[ -f "${base}excludes.conf" ]] && _cmd_ref+=("--exclude-from=${base}excludes.conf")
  fi

  if [[ -n "${cfg[${pref}FilterFrom]:-}" ]]; then
    [[ -r "${cfg[${pref}FilterFrom]}" ]] || { fn_error "${pref}FilterFrom not readable: ${cfg[${pref}FilterFrom]}"; return 1; }
    _cmd_ref+=("--filter-from=${cfg[FilterFrom]}")
  fi
  if [[ -n "${cfg[${pref}IncludeFrom]:-}" ]]; then
    [[ -r "${cfg[${pref}IncludeFrom]}" ]] || { fn_error "${pref}IncludeFrom not readable: ${cfg[${pref}IncludeFrom]}"; return 1; }
    _cmd_ref+=("--include-from=${cfg[${pref}IncludeFrom]}")
  fi
  if [[ -n "${cfg[${pref}ExcludeFrom]:-}" ]]; then
    [[ -r "${cfg[${pref}ExcludeFrom]}" ]] || { fn_error "ExcludeFrom not readable: ${cfg[${pref}ExcludeFrom]}"; return 1; }
    _cmd_ref+=("--exclude-from=${cfg[${pref}ExcludeFrom]}")
  fi

  local s
  if [[ -n "${cfg[${pref}Includes]:-}" ]]; then
    IFS=',' read -r -a _arr <<<"${cfg[${pref}Includes]}"
    for s in "${_arr[@]}"; do
      s="$(fn_trim "$s")"
      [[ -z "$s" ]] && continue
      _cmd_ref+=("--include=$s")
    done
  fi
  if [[ -n "${cfg[${pref}Excludes]:-}" ]]; then
    IFS=',' read -r -a _arr <<<"${cfg[${pref}Excludes]}"
    for s in "${_arr[@]}"; do
      s="$(fn_trim "$s")"
      [[ -z "$s" ]] && continue
      _cmd_ref+=("--exclude=$s")
    done
  fi
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
  hook_str="${cfg[$moment]:-}"

  [[ -z "${hook_str// }" ]] && return 0

  fn_debug "Running $moment Hook:" "$hook_str"

  # Do not allow calling private functions by prefix (basic guard).
  if [[ "${hook_str:0:3}" == "fn_" ]]; then
    fn_error "[${cfg[Name]}][$moment] Hook cannot execute private function-like names: $hook_str"
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
  local -a cmdArr
  fn_cmdline_to_array "cmdArr" "$hook_str"
  [[ ${#cmdArr[@]} -eq 0 ]] && return 0

  # Resolve hook command.
  local cmd="${cmdArr[0]}"
  if [[ -x "$cmd" && -f "f$cmd" ]]; then
    : # external executable
  else
    case "$cmd" in
      checkSize)  cmdArr[0]="bk_hook_check_size";;
      countFiles) cmdArr[0]="bk_hook_count_files";;
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

  "${cmdArr[@]}"
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
  folder_size=$(dir_du_bytes "$folder")
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
# Help / usage
# ---------------------------
# print_global_help: show full usage, options, and (when possible) tasks.
# Usage: print_global_help
print_global_help() {
  cat <<EOF
${SCRIPT_NAME} - BackupFire Runner (${SCRIPT_VERSION})

SYNOPSIS
  ${SCRIPT_NAME} [options] <task> [task2 ...]
  ${SCRIPT_NAME} [options] -a

DESCRIPTION
  backupfire executes "tasks" defined in an INI config file.
  Each task is a section like [pictures] with keys like Type, From, To.

CONFIG
  (default)  ./config/${CFG_DEFAULT_NAME}
             ~/.config/backupfire/${CFG_DEFAULT_NAME} (if present)
             /etc/backupfire/${CFG_DEFAULT_NAME} (if present)

  -c <file>  use a specific config file

OPTIONS
  -a         run all tasks found in config (Ignore ones with Skip=True)
  -c <file>  config file path (or just a filename searched in config dirs)
  -n         dry-run (print commands only; do not execute)
  -d         debug (verbose logs)
  -l         list tasks + short description
  -T         test environment (check required commands), then exit
  -h         show this help

EXAMPLES
  ${SCRIPT_NAME} -c default.conf pictures remote
  ${SCRIPT_NAME} -a -n    # show what would run
  ${SCRIPT_NAME} -T       # verify dependencies
EOF
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


# ---------------------------
# List TASKs
# ---------------------------
# bk_list_tasks: list task sections and their descriptions.
# Usage: bk_list_tasks <config_file>
# Output format:
#   <section>  <description>
bk_list_tasks() {
  local cfg_file="$1"
  local sec desc
  cat <<EOF
${SCRIPT_NAME} - BackupFire Runner (${SCRIPT_VERSION})

DESCRIPTION
  backupfire executes "tasks" defined in an INI config file.
  Each task is a section like [pictures] with keys like Type, From, To.

CONFIG FILE:
  $BK_CONFIG

AVALIABLE TASKS
EOF
  # fn_ini_list_sections returns newline-separated section names.
  while IFS= read -r sec; do
    [[ -z "${sec}" ]] && continue
    fn_in_array "$sec" "${IGNORE_SECTIONS[@]}" && continue
    desc="$(fn_ini_get "${cfg_file}" "${sec}" "Description")"
    [[ -z "$desc" ]] && desc="(no description found)"
    fn_msg '  %-20s %s\n' "${sec}" "${desc:-}"
  done < <(fn_ini_list_sections "${cfg_file}")
}

set_all_runnable_tasks() {
  local cfg_file="${1:-$BK_CONFIG}"
  local skip=

  TASKS=()
  fn_debug "Searching for runnable tasks...(used option -a)"

  while IFS= read -r sec; do
    [[ -z "${sec}" ]] && continue
    # check if its in the ignore list
    fn_in_array "$sec" "${IGNORE_SECTIONS[@]}" && continue
    # check if its to skip
    skip="$(fn_ini_get "${cfg_file}" "${sec}" "Skip")"
    fn_boolean "${skip,,}" || TASKS+=("$sec")
  done < <(fn_ini_list_sections "${cfg_file}")

  fn_debug "Tasks loaded:" "${TASKS[@]}"
}

# ---------------------------
# CLI parsing / main
# ---------------------------
# bk_parse_args: parse CLI args with getopts.
# Usage: bk_parse_args "$@"
bk_parse_args() {
  local opt
  while getopts ":ac:e:ndlhT" opt; do
    case "$opt" in
      a) BK_ALL=1;;
      c) BK_CONFIG="$OPTARG";;
      e) BK_EMAIL="$OPTARG";;
      n) BK_DRY_RUN=1;;
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

bk_mktemp() {
  local tmp=$(mktemp "$@")
  CLEANUP+=("$tmp")
  printf '%s' "$tmp"
}

bk_cleanup() {
  local path
  ((${#CLEANUP[@]} == 0)) && return 0 # Array is empty, nothing to do
  fn_debug "Cleaning up temporary directories created.."
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


# bk_main: program entry point.
# Usage: bk_main "$@"
bk_main() {
  trap bk_cleanup EXIT INT TERM

  bk_parse_args "$@"

  # Help.
  if [[ -n "${BK_HELP:-}" ]]; then
    print_global_help
    return 0
  fi

  # load config
  if ! bk_resolve_config; then
    fn_error "Config file not found or not readable."
    die "Use -c <file> to specify a config."
  fi

  # List actions.
  if [[ -n "${BK_LIST:-}" ]]; then
    bk_list_tasks "${BK_CONFIG}"
    return 0
  fi

  # Test environment.
  if [[ -n "${BK_TEST_ENV:-}" ]]; then
    bk_test_env "${BK_CONFIG}"
    return $?
  fi

  # Determine actions to run.
  if [[ -n "${BK_ALL:-}" ]]; then
    set_all_runnable_tasks
    if [[ ${#TASKS[@]} -eq 0 ]]; then
      fn_error "No tasks found to run!"
      exit 1
    fi
  fi

  if [[ ${#TASKS[@]} -eq 0 ]]; then
    fn_error "You must provide at least one action, or use -a"
    print_global_help
    return 2
  fi

  # Execute each requested action (with deps).
  local task ret=0
  for task in "${TASKS[@]}"; do
    if ! bk_run_task_tree "$task"; then
      ret=1
    fi
  done

  #cleanup
  bk_cleanup

  return "$ret"
}

bk_main "$@"
