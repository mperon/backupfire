#!/usr/bin/env bash
#
# Move files functions


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
    bk_util_cp "${cfg[Artifact]}" "$to"

    [[ ! -f "$to" ]] \
      && { fn_error "It was not possible to copy to destination: ${cfg[To]}"; return 1; }

    UPLOADS+=("/$group/:$to")
  done
}

bk_type_backup_movefiles_none() {
  local task="$1" workdir="$2" artifactdir="$3"

  # just copy the file to final destination
  to="${cfg[To]}/${cfg[ArtifactName]}"
  bk_util_cp "${cfg[Artifact]}" "$to"

  [[ ! -f "$to" ]] \
    && { fn_error "It was not possible to copy to destination: ${cfg[To]}"; return 1; }
  # all set
  UPLOADS+=("/:$to")
  return 0
}
