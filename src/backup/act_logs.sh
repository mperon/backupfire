#!/usr/bin/env bash
#
# DockerLogs Action


bk_action_dockerlogs() {
  local task="$1" workdir="$2" artifactdir="$3"
  # check connection
  if ! bk_action_dockerlogs_check; then
    fn_error "Was not possible to connect with docker";
    fn_error "Check if the docker socket is avaliable and configure"
    fn_error "with DockerSocket=${cfg[DockerSocket]:-/var/run/docker.sock}"
    return 1
  fi

  fn_debug "Running docker logs on services: ${cfg[From]:-}"

  # execute docker and backup file in workdir=
  bk_action_dockerlogs_each "${cfg[From]:-}" "bk_action_dockerlogs_getlog" "$workdir"
}


# Check connection with Docker (To do Docker Logs)
bk_action_dockerlogs_check() {
  bk_util_docker_run info >/dev/null 2>&1
  return $?
}

bk_action_dockerlogs_name() {
  local fmt='%s%s_' ts=
  for _ in "$@"; do fmt+='%s'; done
  # create timestamp if not defined (to be reused in other file compositions)
  bk_utils_set_timestamp
  printf "$fmt" "${cfg[FilePrefix]}" "${cfg[DateStr]}" "$@"
}


bk_action_dockerlogs_getlog() {
  local cid="${1:-}" name="${2:-}" workdir="${3:-}"
  local file_name=$(bk_action_dockerlogs_name "$name")
  shift 3
  file_name=$(sanitize_name "$file_name")
  #generate logs for cid file
  bk_util_docker_run logs "$cid" > "$workdir/${file_name}.log" 2>&1
}


bk_action_dockerlogs_each() {
  local cid= name= query="${1:-}" action="${2:-}"
  local filters=()
  shift 2
  IFS=',' read -r -a filters <<< "$query"

  fn_debug "Starting backup of services: "

  bk_util_docker_run ps --format '{{.ID}} {{.Names}}' \
  | while IFS=' ' read -r cid name; do
    # verifica se alguma query bate
    for s in "${filters[@]}"; do
      s="${s//[[:space:]]/}"; s="${s,,}"; query="$s"
      if [[ -z "$query" ]] || [[ "${query// /}" == "all" ]] || [[ "$name" == *"${query// /}"* ]]; then
        fn_debug "Backuping up logs from $name"
        "$action" "$cid" "$name" "$@"
        break
      fi
    done
  done
}
