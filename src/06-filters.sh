#!/usr/bin/env bash
#
# Filter argument builders

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
      _cmd_ref+=("--filter=merge ${cfg[${pref}FilterFrom]}")
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
    _cmd_ref+=("--filter-from=${cfg[${pref}FilterFrom]}")
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
