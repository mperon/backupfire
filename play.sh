#!/usr/bin/env bash
#vim: ts=4 sw=4 et ft=sh
a_warn=

# get script directory
SCRIPT_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"


DT_FORMAT="%Y%m%d_%H%M%S"
BK_PREFIX=${BK_PREFIX:-bk}
BK_SUFFIX=${BK_SUFFIX:-.enc}
BK_TIME=$(date +"$DT_FORMAT")
BK_TODAY=$(date +"%Y-%m-%d %H:%M:%S")
ACTION_NAME="invtech"

echo "$BK_TIME"
BK_FILE="${BK_PREFIX}_${ACTION_NAME}_${BK_TIME}${BK_SUFFIX}"

echo "$BK_FILE"


# Source shared helpers.
# Usage: keep backupfire_lib.sh next to this script.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/backupfire_lib.sh"


declare -A cfg;

fn_ini_load_sections cfg ./config/new.conf "General,VirtualMachines"


fn_debug_array "cfg"
declare -a cmdArray
fn_cmdline_to_array "cmdArray" "-Cravzp"

declare -p cmdArray
