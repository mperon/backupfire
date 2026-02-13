#!/usr/bin/env bash
#
# Backup Type

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
  bk_mktemp_set 'cfg[WorkDir]' "$task" "work"
  bk_mktemp_set 'cfg[ArtifactDir]' "$task" "artifacts"
  w_dir="${cfg[WorkDir]}" a_dir="${cfg[ArtifactDir]}"
  fn_debug "[$task]      Task workdir: ${cfg[WorkDir]}"
  fn_debug "[$task] Task artifact dir: ${cfg[ArtifactDir]}"

  declare -p CLEANUP
  fn_wait

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
    dockerlogs|logs)
      fn_debug "Running action: $action:"
      bk_action_dockerlogs "$task" "$w_dir" "$a_dir"
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
    bk_mktemp_set 'cfg[To]' "$task" "to"
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
