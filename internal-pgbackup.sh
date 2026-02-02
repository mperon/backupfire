#!/usr/bin/env bash
#vim: ts=4 sw=4 et ft=sh
a_warn=

# get script directory
SCRIPT_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# DEFAULT VARIABLES
DB_USER=${DB_USER:-postgres}
DB_HOST=${DB_HOST:-localhost}
DB_NAME=${DB_NAME:-postgres}
DB_PASSWORD=${DB_PASSWORD:-}
DB_PORT=${DB_PORT:-5432}
BK_MAXSIZE=${BK_MAXSIZE:-10m}
BK_DEST=${BK_DEST:-}
BK_SPLIT=${BK_SPLIT:-split}
BK_DAYS_TO_KEEP=${BK_DAYS_TO_KEEP:-10}
BK_PREFIX=${BK_PREFIX:-bk}
BK_SUFFIX=${BK_SUFFIX:-.enc}
BK_REMOTE=(${BK_REMOTE:-})
BK_REMOTE_INTERVAL=${BK_REMOTE_INTERVAL:-5} #days
BK_PGDUMP=${BK_PGDUMP:-pg_dump}
BK_PLAIN=${BK_PLAIN:-}
BK_TEST=${BK_TEST:-}
BK_OPENSSL=${BK_OPENSSL:-}
BK_RCLONE=${BK_RCLONE_CONF:-}
BK_RCLONE_CONF=${BK_RCLONE_CONF:-}
BK_PUBKEY_LOC=${BK_PUBKEY_LOC:-}

#fixed ones, cannot be changed in config
BK_CFG_NAME="pgbackup.conf"
BK_TIME=
BK_TODAY=
BK_FILE=
BK_KFILE=
BK_PGDUMP_CMD=
BK_RCLONE_CMD=

#COMMON FUNCTIONS
fn_datediff() {
    d1=$(date -d "$1" +%s)
    d2=$(date -d "$2" +%s)
    echo $(( (d1 - d2) / 86400 ))
}

fn_send_remote() {
    local remote=
    for remote in "$@"; do
        echo "Uploading to remote: ${remote}"
        $BK_RCLONE_CMD copy "${BK_DEST/%\//}/" "${remote/%\//}/" --auto-confirm  \
            --fast-list --quiet --retries 3 \
            --exclude '.*' \
            --retries-sleep 1m --timeout 1m --update
    done
}

fn_error() {
    echo "$@"
    exit 1
}

fn_warn() {
    echo "$@"
    a_warn=1
}

_readlinkf() {
     realpath -q "$1"
}

fn_usage() {
    local scriptname=$(basename $0)
    cat <<HELP_USAGE
    $scriptname - Backup and encrypt pg databases

        [-c FILE] [-C DIR] [-D DEST] [-p] [-x] ...

    ARGUMENTS:
    -c [FILE]   Specify config file (default ~/.config/${BK_CFG_NAME})
    -C [DIR]    Specify config file directory (will load file ${BK_CFG_NAME} from that directory)
    -d [DEST]   Backup destination folder.
    -K [key]    Uses key file.
    -P          Make no encription
    -x          Test configuration
    -h          Show help
HELP_USAGE
    exit 4
}

fn_parse_args() {
    while getopts "c:C:d:K:pxh" OPTION "$@"; do
        case $OPTION in
        c)
            BK_CONFIG="${OPTARG}"
            ;;
        C)
            BK_CONFIG="${OPTARG/%\//}/${BK_CFG_NAME}"
            ;;
        P)
            BK_PLAIN=y
            ;;
        d)
            BK_DEST="${OPTARG/%\//}"
            ;;
        K)
            BK_PUBKEY_LOC="${OPTARG}"
            ;;
        x)
            BK_TEST=y
            ;;
        h)
            fn_usage
            exit 0
            ;;
        *)
            echo "Incorrect options provided"
            exit 1
            ;;
        esac
    done
}

fn_load_config() {
    # first load defaults
    [[ -f "$HOME/.config/${BK_CFG_NAME}" ]] && source "$HOME/.config/${BK_CFG_NAME}"

    # load config from /app/config path too:
    if [[ -d "$SCRIPT_DIR/config" ]]; then
      # try to load config from this fie
      [[ -f "$SCRIPT_DIR/config/${BK_CFG_NAME}" ]] && source "$SCRIPT_DIR/config/${BK_CFG_NAME}"
    fi
    # if has in dest folder config, loads it
    [[ -n "$BK_DEST" && -f "${BK_DEST/%\//}/${BK_CFG_NAME}" ]] && source "${BK_DEST/%\//}/${BK_CFG_NAME}"

    # for last, check command line for -c or -C tag
    [[ -n "$BK_CONFIG" ]] && [[ -f "$BK_CONFIG" ]] && source "$BK_CONFIG"
    #done config is loaded
    BK_DEST="${BK_DEST/%\//}"
}

fn_prepare_environment() {
    # config loaded, generate variables
    BK_TIME=$(date +"%Y%m%d_%H%M%S")
    BK_TODAY=$(date +"%Y-%m-%d %H:%M:%S")
    BK_FILE="${BK_DEST/%\//}/${BK_PREFIX}_${DB_NAME}_${BK_TIME}"
    BK_KFILE=
    #fixed ones, cannot be changed in config
    BK_CFG_NAME="pgbackup.conf"
    BK_KFILE=
    BK_PGDUMP_CMD=
    BK_RCLONE_CMD=

    #loads correct version of openssl and rclone
    if [[ -z "$BK_OPENSSL" ]]; then
        [[ -f /usr/local/opt/openssl/bin/openssl ]] \
            && BK_OPENSSL=/usr/local/opt/openssl/bin/openssl \
            || BK_OPENSSL=$(command -v openssl)
    fi
    if [[ -z "$BK_RCLONE" ]]; then
        [[ -f /usr/local/bin/rclone ]] \
            && BK_RCLONE=/usr/local/bin/rclone \
            || BK_RCLONE=$(command -v rclone)
    fi

    # check config dir for public key
    [[ -z "$BK_PUBKEY_LOC" ]] && [[ -f "$SCRIPT_DIR/config/pubkey.pem" ]] \
      && BK_PUBKEY_LOC="$SCRIPT_DIR/config/pubkey.pem"
    [[ -z "$BK_PUBKEY_LOC" ]] && [[ -f "$SCRIPT_DIR/config/.pubkey.pem" ]] \
      && BK_PUBKEY_LOC="$SCRIPT_DIR/config/.pubkey.pem"

    #check config dir for rclone
    [[ -z "$BK_RCLONE_CONF" ]] && [[ -f "$SCRIPT_DIR/config/rclone.conf" ]] \
      && BK_RCLONE_CONF="$SCRIPT_DIR/config/rclone.conf"
    [[ -z "$BK_RCLONE_CONF" ]] && [[ -f "$SCRIPT_DIR/config/.rclone.conf" ]] \
      && BK_RCLONE_CONF="$SCRIPT_DIR/config/.rclone.conf"

    # check rclone config and pubkey config in dest folder (last option)
    [[ -z "$BK_RCLONE_CONF" ]] && [[ -f "$BK_DEST/.rclone.conf" ]] \
      && BK_RCLONE_CONF="$BK_DEST/.rclone.conf"
    [[ -z "$BK_PUBKEY_LOC" ]] && [[ -f "$BK_DEST/.pubkey.pem" ]] \
      && BK_PUBKEY_LOC="$BK_DEST/.pubkey.pem"

    #pgdump command
    BK_PGDUMP_CMD="$BK_PGDUMP -h $DB_HOST -p $DB_PORT --format=plain --dbname=$DB_NAME --username=$DB_USER"
    if [[ -n "$DB_PASSWORD" ]]; then
        export PGPASSWORD=$DB_PASSWORD
    else
        BK_PGDUMP_CMD="$BK_PGDUMP_CMD --no-password"
    fi

    #rclone command
    BK_RCLONE_CMD=$BK_RCLONE
    [[ -n "$BK_RCLONE_CONF" ]] && BK_RCLONE_CMD="$BK_RCLONE_CMD --config=$BK_RCLONE_CONF"
}

fn_command_exists() {
    command -v $1 > /dev/null 2>&1
    return ${PIPESTATUS[0]}
}

fn_test_env() {
    echo "Running test on environment:"
    # check dest directory
    [[ ! -d "${BK_DEST}" ]] && fn_error "Destination directory [$BK_DEST] doesnt exists!"

    #check files
    # config check properly
    if [[ -z "$BK_PLAIN" ]]; then
        [[ ! -f "$BK_PUBKEY_LOC" ]] && fn_warn "Public key file not found: $BK_PUBKEY_LOC !"
        fn_command_exists $BK_OPENSSL || fn_warn "Command BK_OPENSSL not found: $BK_OPENSSL !"
    fi
    # check commands
    fn_command_exists $BK_RCLONE || fn_warn "Command BK_RCLONE not found: $BK_RCLONE !"
    fn_command_exists $BK_PGDUMP || fn_warn "Command BK_PGDUMP not found: $BK_PGDUMP !"
    fn_command_exists gzip || fn_warn "Command gzip not found !"
    [[ -n "$a_warn" ]] && fn_error "Invalid environment!"

    # check each individual command
    # test pubkey
    if [[ -z "$BK_PLAIN" ]]; then
        echo "ola" | $BK_OPENSSL pkeyutl -encrypt -pubin -inkey $BK_PUBKEY_LOC > /dev/null
        if [[ $? -gt 0 ]]; then
            fn_error "Invalid key $BK_PUBKEY_LOC ! "
        fi
    fi

    #check pgconection
    echo $BK_PGDUMP_CMD --schema-only > /dev/null
    if [[ $? -gt 0 ]]; then
        fn_error "Cannot connect to database using command: $BK_PGDUMP_CMD ! "
    fi

    #finally
    [[ -n "$a_warn" ]] && fn_error "Invalid environment!"

    #if we ok
    echo "All check pass!"
}

fn_check_env() {
    # make sure bk_dest exists
    [[ -z "${BK_DEST}" ]] && fn_error "Destination directory [$BK_DEST] is not set!"
    [[ -n "${BK_DEST}" ]] && [[ ! -d "${BK_DEST}" ]] && mkdir -p "${BK_DEST}"
}

fn_do_backup() {
    # make backup locally
    echo "Backuping ${DB_NAME} ..."
    if [[ -n "$BK_PLAIN" ]]; then
        fn_do_plain
    else
        fn_do_encrypted
    fi
}

fn_remote() {
    if [[  "${#BK_REMOTE[@]}" -gt 0 ]]; then
        echo "Sending to remote server.."
        fn_send_remote "${BK_REMOTE[@]}"
    else
        echo "No remote server configured."
    fi
}

fn_cleanup() {
    echo "Cleaning up folder ${BK_DEST} .."
    find $BK_DEST -maxdepth 1 -mtime +$BK_DAYS_TO_KEEP -name "${BK_PREFIX}_${DB_NAME}_*${BK_SUFFIX}*" -delete
}

fn_do_plain() {
    echo "Unincripted Backup Mode."
    # no encripted backup
    $BK_PGDUMP_CMD \
    | gzip -9 - \
    > ${BK_FILE} || fn_error "Cannot dump database!"
}

fn_do_encrypted() {
    echo "Encripted backup mode!"
    #generate key based on public key
    BK_DIR=$(mktemp -d)
    trap "rm -rf $BK_DIR" EXIT

    BK_FILE=$(_readlinkf "$BK_FILE")
    BK_PUBKEY_LOC=$(_readlinkf "$BK_PUBKEY_LOC")
    BK_FILENAME="${BK_FILE##*/}"

    cd $BK_DIR

    #generate key
    $BK_OPENSSL rand -base64 256 > key
    $BK_OPENSSL pkeyutl -encrypt -inkey $BK_PUBKEY_LOC \
        -pubin -in key -out ${BK_FILENAME}.key

    # do the backup
    $BK_PGDUMP_CMD \
        | gzip -9 - \
        | $BK_OPENSSL enc -aes-256-cbc -a -md sha512 -pbkdf2 -iter 1000000 -salt -pass "file:./key" \
        > ${BK_FILENAME}.enc || fn_error "Cannot dump database!"

    tar -czf "${BK_FILE}${BK_SUFFIX}" "${BK_FILENAME}.key" "${BK_FILENAME}.enc"
}

fn_main() {
    # first parse arguments
    fn_parse_args "$@"
    # load config file
    fn_load_config

    # prepare enviroment
    fn_prepare_environment
    # verify if is to test enviroment
    if [[ -n "$BK_TEST" ]]; then
        fn_test_env
    else
        #check environment
        fn_check_env
        # do the backup
        fn_do_backup
        #send to remotes
        fn_remote
        #cleanup stuff
        fn_cleanup
    fi
}

# run the module
fn_main "$@"
exit $?
