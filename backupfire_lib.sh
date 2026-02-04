#!/usr/bin/env bash
# backupfire_lib.sh
#
# Shared helper functions for backupfire.sh.
# Designed for Alpine Linux (busybox userspace) with bash installed.
set -o pipefail

###############################################################################
# Default variables
###############################################################################
F_DEBUG=""
F_LOG="${F_LOG:-/dev/null}"
F_LOG_DATE="${F_LOG_DATE:-+%y-%m-%d %H:%M:%S}"
F_LOG_SCRIPT="${F_LOG_SCRIPT:-backupfire}"

###############################################################################
# Colors + Messages and Logging
###############################################################################
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m';
    C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m';
    C_CYAN=$'\033[36m'; C_GREEN=$'\033[0;32m';
else
    C_RESET=; C_DIM=; C_BOLD=; C_RED=; C_YELLOW=; C_BLUE=; C_CYAN=; C_GREEN=;
fi

fn_emit(){ # render
    # Usage:
    #   fn_emit "prefix" "format if %s" "args"
    #   fn_emit "prefix" "arg1" "arg2" ...
    local prefix="${1:-}" fmt=""
    shift || true
    # Determine whether $1 is a printf format (when has %s)
    if [[ $# -gt 1 ]] && [[ "$1" == *%* ]]; then
        fmt="$1"
        shift || true
    else
        for _ in "$@"; do fmt+='%s'; done
        fmt+='\n'
    fi
    # Log hook (optional)
    #__log $(printf "${prefix}${fmt/# /}" "$@")
    printf "%s${fmt/# /}" "${prefix}" "$@"
}

fn_msg(){ # Print a plain message.
    fn_emit "" "$@"
}

fn_log(){ # Print a plain message.
    fn_emit "" "$@"
}

fn_info(){ # Print an info message.
    fn_emit "${C_RESET}${C_BLUE}[info] ${C_RESET}${C_DIM}" "$@" "${C_RESET}"
}

fn_warn(){ # Print a warning message.
    fn_emit "${C_RESET}${C_YELLOW}[warn] ${C_RESET}${C_DIM}" "$@" "${C_RESET}"
}

fn_error(){ # Print an error message to stderr.
    fn_emit "${C_RESET}${C_RED}[error] ${C_RESET}${C_DIM}" "$@" "${C_RESET}" >&2
}

fn_success() {
  fn_emit "${C_RESET}${C_GREEN}[success] ${C_RESET}${C_DIM}" "$@" "${C_RESET}"
}

fn_failed() {
  fn_emit "${C_RESET}${C_RED}[failed] ${C_RESET}${C_DIM}" "$@" "${C_RESET}"
}

fn_die(){ # Print an error and exit.
    error "$@"; exit 1
}

fn_debug() { # show only in debug mode
    (( $F_DEBUG )) && fn_emit "${C_CYAN}[debug] ${C_RESET}${C_DIM}" "$@" "${C_RESET}"
    return 0
}

fn_wait() {
  read -p "Press [Enter] key to continue..."
}

# fn_quote_cmd: render a command array as a shell-escaped one-liner.
# Usage: fn_quote_cmd cmd_array[@]
fn_quote_cmd() {
  local -n _arr_ref="$1"
  local out="" part
  for part in "${_arr_ref[@]}"; do
    out+="$(printf '%q' "$part") "
  done
  printf '%s' "${out% }"
}

# ---------------------------
# Introspection helpers
# ---------------------------

# fn_func_exists: true if a bash function exists.
# Usage: fn_func_exists fn_name
fn_func_exists() { declare -F "$1" >/dev/null 2>&1; }

# fn_cmd_exists: true if all commands exist in PATH.
# Usage: fn_cmd_exists rsync awk sed
fn_cmd_exists() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || return 1
  done
  return 0
}

# fn_boolean: interpret common truthy values.
# Usage: fn_boolean "Y" && echo true
fn_boolean() {
  [[ -z "${1:-}" ]] && return 1
  case "${1,,}" in
    1|true|yes|y|t|s) return 0 ;;
    0|false|no|n|f) return 1 ;;
    *) return 1 ;;
  esac
}

# fn_trim: trim leading/trailing whitespace.
# Usage: fn_trim "  hello  "  -> "hello"
fn_trim() {
  local s="$*"
  # shellcheck disable=SC2001
  s="${s#"${s%%[!$' \t\r\n']*}"}"
  s="${s%"${s##*[!$' \t\r\n']}"}"
  printf '%s' "$s"
}

# fn_normalize_cfg_paths: expand ~/ and resolve ./ relative-to-From for selected keys.
# Usage: fn_normalize_cfg_paths cfg "IncludeFrom:ExcludeFrom:FilterFrom"
fn_normalize_cfg_paths() {
  local -n _cfg="$1"
  local keys_csv="${2:-}"
  local key val

  IFS=':' read -r -a _keys <<<"$keys_csv"
  for key in "${_keys[@]}"; do
    [[ -z "$key" ]] && continue
    val="${_cfg[$key]:-}"
    [[ -z "${val// }" ]] && continue

    # Expand ~/
    [[ "$val" == ~/* ]] && val="${HOME}/${val#~/}"

    # Resolve ./ relative to From (only when From is present)
    if [[ "$val" == ./* && -n "${_cfg[From]:-}" ]]; then
      val="${_cfg[From]%/}/${val#./}"
    fi

    _cfg[$key]="$val"
  done
}

# fn_parse_destination: parse cfg[To] into cfg[ToHost]/cfg[ToPath].
# For rclone remotes, To looks like "remote:/path".
# For local paths, ToHost is empty and ToPath == To.
# Usage: fn_parse_destination cfg
fn_parse_destination() {
  local -n _cfg="$1"
  local to="${_cfg[To]:-}"

  _cfg[ToHost]=""
  _cfg[ToPath]="${to}"

  # Treat as remote only when it looks like "name:/..." (common rclone syntax).
  if [[ "$to" =~ ^[A-Za-z0-9._-]+: ]]; then
    _cfg[ToHost]="${to%%:*}"
    _cfg[ToPath]="${to#*:}"
  fi
}

# ---------------------------
# Path / filesystem helpers
# ---------------------------

# fn_abspath: convert a path to an absolute normalized path.
# Usage: fn_abspath "/tmp"  -> /tmp
# Notes: prefers realpath; falls back to readlink -f; finally best-effort.
fn_abspath() {
  local p="${1:-}"
  [[ -z "$p" ]] && return 1

  # Expand ~
  [[ "$p" == ~/* ]] && p="${HOME}/${p#~/}"

  if fn_cmd_exists realpath; then
    realpath "$p" 2>/dev/null && return 0
  fi
  if fn_cmd_exists readlink; then
    readlink -f "$p" 2>/dev/null && return 0
  fi

  # Best-effort: if directory exists, cd -P into it.
  if [[ -d "$p" ]]; then
    (cd "$p" 2>/dev/null && pwd -P)
    return $?
  fi

  # If file exists, resolve its directory.
  if [[ -e "$p" ]]; then
    local d b
    d="$(dirname "$p")" || return 1
    b="$(basename "$p")" || return 1
    (cd "$d" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$b")
    return $?
  fi

  return 1
}

# fn_is_subdir: true if DIR_B is inside DIR_A.
# Usage: fn_is_subdir "/dst" "/src"  (checks if dst is subdir of src)
fn_is_subdir() {
  local dir_b="$1" dir_a="$2"
  dir_a="$(fn_abspath "$dir_a")" || return 1
  dir_b="$(fn_abspath "$dir_b")" || return 1

  [[ "${dir_b}" == "${dir_a}"/* ]] && return 0
  return 1
}

# fn_dir_in: true if dir starts with any prefix in a comma-separated list.
# Usage: fn_dir_in "/etc/passwd" "/etc/,/root/"
fn_dir_in() {
  local dir="$1" list="$2" item
  IFS=',' read -r -a _items <<<"$list"
  for item in "${_items[@]}"; do
    [[ -z "$item" ]] && continue
    [[ "${dir}" == "${item}"* ]] && return 0
  done
  return 1
}

# ---------------------------
# Command-line parsing helpers
# ---------------------------

# fn_cmdline_to_array: split a command line string into an array, honoring simple quotes.
# Usage:
#   local -a cmd
#   fn_cmdline_to_array cmd "echo 'hello world'"
#   printf '%q\n' "${cmd[@]}"
fn_cmdline_to_array() {
  local out_name="${1:-}" str="${2:-}"
  [[ $out_name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
    || { printf 'fn_cmdline_to_array: bad out var name: %q\n' "$out_name" >&2; return 2; }

  local -n toCmdArray="$out_name"   # <- writes into caller's array
  toCmdArray=()

  # Normalize consecutive quotes.
  str="$(printf '%s' "$str" | sed -Ee 's/[\"]+/"/g' -e "s/[']+/'/g")"

  for ((i=0; i<${#str}; i++)); do
    char="${str:i:1}"

    if [[ "$char" == '"' || "$char" == "'" ]]; then
      if [[ "$prev" != '\\' ]]; then
        if [[ "$quote" == "$char" ]]; then
          quote=""
        else
          quote="$char"
        fi
        prev="$char"
        continue
      fi
    fi

    if [[ "$char" == ' ' && -z "$quote" ]]; then
      if [[ -n "$token" ]]; then
        toCmdArray+=("$token")
        token=""
      fi
      prev="$char"
      continue
    fi

    token+="$char"
    prev="$char"
  done

  [[ -n "$token" ]] && toCmdArray+=("$token")
}

# ---------------------------
# Size / numeric helpers
# ---------------------------

# fn_human_to_bytes: convert human readable sizes to bytes.
# Usage: fn_human_to_bytes "10MB"  -> 10000000
fn_human_to_bytes() {
  local s="${1:-}" num unit m had=0
  [[ $s =~ ^[[:space:]]*([0-9]+([.][0-9]+)?)[[:space:]]*([[:alpha:]]*)[[:space:]]*$ ]] \
    || { echo 0; return 1; }
  num="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[3]}"

  shopt -q nocasematch && had=1
  shopt -s nocasematch
  case "$unit" in
    "")  m=1 ;;
    k|ki|kib) m=1024 ;;
    m|mi|mib) m=1048576 ;;
    g|gi|gib) m=1073741824 ;;
    t|ti|tib) m=1099511627776 ;;
    kb) m=1000 ;;
    mb) m=1000000 ;;
    gb) m=1000000000 ;;
    tb) m=1000000000000 ;;
    *)  echo 0; ((had)) || shopt -u nocasematch; return 1 ;;
  esac
  ((had)) || shopt -u nocasematch

  awk -v n="$num" -v m="$m" 'BEGIN{printf "%.0f\n", n*m}'
}


# fn_number_compare: compare integers with an operator.
# Usage: fn_number_compare 10 ">=" 9
fn_number_compare() {
  local a="$1" op="$2" b="$3"
  case "$op" in
    ">")  [[ "$a" -gt "$b" ]] ;;
    ">=") [[ "$a" -ge "$b" ]] ;;
    "="|"==") [[ "$a" -eq "$b" ]] ;;
    "<")  [[ "$a" -lt "$b" ]] ;;
    "<=") [[ "$a" -le "$b" ]] ;;
    "!=") [[ "$a" -ne "$b" ]] ;;
    *) return 1 ;;
  esac
}

# ---------------------------
# INI parsing helpers
# ---------------------------


# fn_ini_list_sections: print section names, one per line.
# Usage: fn_ini_list_sections /etc/backupfire/default.conf
fn_ini_list_sections() {
  local file="$1"
  awk '
    /^[[:space:]]*[#;]/ {next}
    /^[[:space:]]*\[/ {
      cur=$0
      gsub(/^[[:space:]]*\[/,"",cur)
      gsub(/\][[:space:]]*$/,"",cur)
      if (length(cur)>0) { print cur }
    }
  ' "$file"
}


# fn_ini_get: get a key value from a section.
# Usage: fn_ini_get file section key
fn_ini_get() {
  local file="$1" section="$2" key="$3"
  awk -v sec="$section" -v k="$key" '
    function ltrim(s){sub(/^[ \t\r\n]+/,"",s); return s}
    function rtrim(s){sub(/[ \t\r\n]+$/,"",s); return s}
    function trim(s){return rtrim(ltrim(s))}

    BEGIN{insec=0}
    /^[[:space:]]*[#;]/ {next}
    /^[[:space:]]*\[/ {
      cur=$0
      gsub(/^[[:space:]]*\[/,"",cur)
      gsub(/\][[:space:]]*$/,"",cur)
      insec = (cur==sec)
      next
    }
    insec==1 {
      line=$0
      # strip inline comments (simple)
      sub(/[[:space:]]*[#;].*$/, "", line)
      if (index(line, "=")>0) {
        split(line, a, "=")
        kk=trim(a[1])
        vv=trim(substr(line, index(line,"=")+1))
        gsub(/^"|"$/, "", vv)
        gsub(/^\x27|\x27$/, "", vv)
        if (kk==k) { print vv; exit }
      }
    }
  ' "$file"
}

# fn_ini_load_sections: load multiple sections into a bash associative array.
# Later sections override earlier ones.
# Usage: declare -A cfg; fn_ini_load_sections cfg "/path/file" "General,myaction"
fn_ini_load_sections() {
  local -n _out="$1"
  local file="$2" sections_csv="$3"
  local sec line key val

  _out=()

  IFS=',' read -r -a _secs <<<"$sections_csv"

  for sec in "${_secs[@]}"; do
    [[ -z "${sec// }" ]] && continue

    # Stream parse: only keys inside [sec]
    while IFS= read -r line || [[ -n "$line" ]]; do
      # Trim left
      line="${line#${line%%[!$'\t\r\n ']*}}"
      [[ -z "$line" ]] && continue
      [[ "$line" == \#* || "$line" == \;* ]] && continue

      if [[ "$line" == \[*\] ]]; then
        # new section
        local cur="${line#[}"; cur="${cur%]}"
        if [[ "$cur" == "$sec" ]]; then
          _insec=1
        else
          _insec=
        fi
        continue
      fi

      [[ -z "${_insec:-}" ]] && continue
      [[ "$line" != *"="* ]] && continue

      key="${line%%=*}"
      val="${line#*=}"

      # strip inline comments (simple; ignores comment chars inside quotes)
      val="${val%%\#*}"; val="${val%%;*}"

      # trim whitespace
      key="${key%${key##*[!$'\t\r\n ']}}"; key="${key#${key%%[!$'\t\r\n ']*}}"
      val="${val%${val##*[!$'\t\r\n ']}}"; val="${val#${val%%[!$'\t\r\n ']*}}"

      # strip surrounding quotes
      [[ "$val" == '"'*'"' ]] && val="${val#\"}" && val="${val%\"}"
      [[ "$val" == "'"*"'" ]] && val="${val#\'}" && val="${val%\'}"

      _out["$key"]="$val"
    done <"$file"
  done
}


# fn_in_array: Search in array (case insensitive)
# Usage: args=("a" "b" "C"); fn_in_array "c" "${args[@]}"
fn_in_array() {
  local search="${1,,}" item=
  shift
  # Iterate through the array
  for item in "$@"; do
      [[ "$search" == "${item,,}" ]] && return 0
  done
  return 1
}


# stat_bytes: print apparent file size in bytes (follows symlinks).
# Usage: stat_bytes PATH
dir_du_bytes() {
  du -sk -- "$1" 2>/dev/null | awk '{print $1*1024}';
}

# fn_format_epoch: format an epoch timestamp (seconds since Unix epoch) using date.
# Usage: fn_format_epoch EPOCH [FORMAT]
#   EPOCH   - integer seconds since 1970-01-01 00:00:00 UTC (e.g., "$(date +%s)")
#   FORMAT  - optional date format string (default: %Y%m%d_%H%M%S)
# Output:
#   Prints the formatted timestamp to stdout.
# Compatibility:
#   - macOS (BSD date): uses `date -r <epoch> +<fmt>`
#   - Alpine/Linux (GNU/BusyBox date): uses `date -d "@<epoch>" +<fmt>`
fn_format_epoch() {
  local epoch="$1" fmt="${2:-%Y%m%d_%H%M%S}"
  if date -r "$epoch" +"$fmt" >/dev/null 2>&1; then
    date -r "$epoch" +"$fmt"      # macOS
  else
    date -d "@$epoch" +"$fmt"     # Alpine/Linux
  fi
}


# bn_debug_array: Print all keys/values from a Bash associative array (debug helper).
# Usage:
#   bn_debug_array ARRAYNAME
# Example:
#   declare -A cfg=([Type]="Vault" [Compress]="tar.gz")
#   bn_debug_array cfg
# Output:
#   [cfg] 2 keys
#   cfg[Compress]=tar.gz
#   cfg[Type]=Vault
fn_debug_array() {
  local name="${1:-}"
  [[ -n "$name" ]] || { printf 'bn_debug_array: missing ARRAYNAME\n' >&2; return 1; }

  # Validate "name" looks like a variable name
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
    printf 'bn_debug_array: invalid array name: %q\n' "$name" >&2
    return 1
  }

  # Ensure it exists and is an associative array
  local decl
  decl="$(declare -p "$name" 2>/dev/null)" || {
    printf 'bn_debug_array: %s is not set\n' "$name" >&2
    return 1
  }
  [[ "$decl" == "declare -A "* ]] || {
    printf 'bn_debug_array: %s is not an associative array\n' "$name" >&2
    return 1
  }

  # Nameref to the caller's assoc array
  local -n a="$name"

  printf '[%s] %d keys\n' "$name" "${#a[@]}"

  # Print sorted by key if sort exists; otherwise unsorted.
  if command -v sort >/dev/null 2>&1; then
    local k
    while IFS= read -r k; do
      printf '%s[%s]=%q\n' "$name" "$k" "${a[$k]}"
    done < <(printf '%s\n' "${!a[@]}" | sort)
  else
    local k
    for k in "${!a[@]}"; do
      printf '%s[%s]=%q\n' "$name" "$k" "${a[$k]}"
    done
  fi
}

# ---------------------------
# Actions utilities
# ---------------------------
# fn_parse_uri_scheme: parse "scheme://user[:pass]@host[:port]/db" into an assoc array.
# Usage: declare -A conn; fn_parse_uri_scheme "conn" "postgres://marcos@server/api"; echo ${conn[Host]};
# Sets keys (empty if missing): Scheme User Pass Host Port Database
fn_parse_uri_scheme() {
  local out="$1" uri="$2" rest auth hostport path
  [[ $out =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n m="$out"; m=([Scheme]= [User]= [Pass]= [Host]= [Port]= [Name]=)

  m[Scheme]="${uri%%://*}"; rest="${uri#*://}"

  # split path (/db...) if present
  hostport="$rest"; path=""
  [[ "$rest" == */* ]] && { hostport="${rest%%/*}"; path="${rest#*/}"; }

  # split auth@hostport if present
  if [[ "$hostport" == *@* ]]; then
    auth="${hostport%%@*}"; hostport="${hostport#*@}"
    m[User]="${auth%%:*}"; [[ "$auth" == *:* ]] && m[Pass]="${auth#*:}"
  fi

  # host[:port]
  m[Host]="${hostport%%:*}"
  [[ "$hostport" == *:* ]] && m[Port]="${hostport#*:}"

  # db/path (keep first segment as db)
  [[ -n "$path" ]] && m[Name]="${path%%\?*}"
}
