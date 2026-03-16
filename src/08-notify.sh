#!/usr/bin/env bash
#
# Filter argument builders

# ---------------------------
# Filter argument builders
# ---------------------------
# bk_add_rsync_filters: append rsync include/exclude/filter arguments to a command array.
# Usage: bk_add_rsync_filters cmd_array[@] "Remote"
BK_HOSTNAME="$(hostname -s 2>/dev/null || echo "${HOSTNAME:-unknown}")"

# remove color codes from text
fn_strip_ansi() {
  sed 's/\x1b\[[0-9;]*m//g'
}

# telegram message
fn_err_message() {
  local status="$1" errfile="${2:-}"  task="${3:-$CURRENT_TASK}"
  local _date="$(date +'%Y-%m-%d %H:%M:%S')"

  local errors=""
  if [[ -n "$errfile" ]] && [[ -s "$errfile" ]]; then
    errors="$(fn_strip_ansi < "$errfile" | head -n 5)"
  fi

  cat <<EOF
backupfire: ${status}

Task:     ${task}
Desc:     ${cfg[Description]:-}
Host:     ${BK_HOSTNAME}
Date:     ${_date}
Config:   ${BK_CONFIG}
EOF
  if [[ -n "$errors" ]]; then
    echo ""
    echo "Errors:"
    echo "$errors"
  fi
}

fn_notify() {
  local task="$1" type="$2" status= key=

  case "$type" in
    success)
      key=NotifySuccess status="✅ Task $task: succeeded"
      ;;
    failed)
      key=NotifyFailed status="❌ Task $task: failed"
      ;;
    *)
      fn_warn "[notify] Notification type is not supported: $type — skipping."; return 0;
      ;;
  esac

  fn_boolean "${cfg[$key]}" || { fn_debug "[notify] $type notifications disabled, skipping."; return 0; }


  # check if notify telegram is on
  if fn_boolean "${cfg[NotifyTelegram]}"; then
      fn_debug "[notify] telegram: sending $type notification"
      fn_notify_telegram "$task" "$type" "$status"
  else
      fn_debug "[notify] telegram disabled, skipping."
  fi

  # check if notify email is on
  if fn_boolean "${cfg[NotifyEmail]}"; then
    fn_debug "[notify] email: sending $type notification"
    fn_notify_email "$task" "$type" "$status"
  else
    fn_debug "[notify] email disabled, skipping."
  fi


}

fn_notify_email() {
  local task="$1" type="$2" status="$3"
  local email_msg= errfile=

  email_msg=$(fn_err_message "$status" "${cfg[ErrorFile]}" "$task")
  email_subject="backupfire: [$task]: $status"

  [[ "$type" == "failed" ]] && errfile="${cfg[ErrorFile]}"
  fn_email_send "$email_subject" "$email_msg" "$errfile"

}

fn_notify_telegram() {
  local task="$1" type="$2" status="$3"
  local tg_msg=
  tg_msg=$(fn_err_message "$status" "${cfg[ErrorFile]}" "$task")

  fn_telegram_send "$tg_msg"
  if [[ "$type" == "failed" ]]; then
    fn_notify_send_doc "${cfg[ErrorFile]}" "fn_telegram_send_document" "Attached ${task} Log File"
    return $?
  fi
  return 0
}

fn_notify_send_doc() {
  local errfile="${1:-}" command="$2"
  shift 2
  local line_count=0 clean_file=

  if [[ -n "$errfile" ]] && [[ -s "$errfile" ]]; then
    line_count="$(fn_strip_ansi < "$errfile" | grep -vc '^[[:space:]]*$')"
  fi

  if [[ "$line_count" -gt 5 ]]; then
    clean_file="$(bk_mktemp -t backupfire.tgdoc.XXXXXX)"
    fn_strip_ansi < "$errfile" > "$clean_file"
    "$command" "$clean_file" "$@"
    return $?
  fi
  return 1
}


fn_telegram_check() {
  local tg_token="${cfg[TelegramToken]:-$TELEGRAM_BOT_TOKEN}"
  local tg_chat_id="${cfg[TelegramChatId]:-$TELEGRAM_CHAT_ID}"
  local tg_notify="${cfg[TelegramNotify]:-${TG_NOTIFY:-1}}"

  fn_boolean "$tg_notify" || { fn_debug "[telegram] notifications disabled, skipping."; return 1; }
  if [[ -z "$tg_token" ]];   then fn_warn "[telegram] TelegramToken is not set — skipping."; return 1; fi
  if [[ -z "$tg_chat_id" ]]; then fn_warn "[telegram] TelegramChatId is not set — skipping."; return 1; fi
  if ! fn_cmd_exists curl;   then fn_warn "[telegram] curl not found — skipping."; return 1; fi
  return 0
}

fn_telegram_curl() {
  local endpoint="$1"; shift
  local tg_token="${cfg[TelegramToken]:-$TELEGRAM_BOT_TOKEN}"
  local tg_chat_id="${cfg[TelegramChatId]:-$TELEGRAM_CHAT_ID}"
  local api_url="https://api.telegram.org/bot${tg_token}/${endpoint}"

  local response http_code
  response=$(curl -fsSL --max-time 30 \
    -w "\n%{http_code}" \
    -X POST "$api_url" \
    -d "chat_id=${tg_chat_id}" \
    "$@" 2>&1)

  http_code="$(printf '%s' "$response" | tail -n1)"

  if [[ "$http_code" == "200" ]]; then
    fn_debug "[telegram] Request succeeded (HTTP 200)."
    return 0
  else
    fn_warn "[telegram] Request failed (HTTP ${http_code:-unknown})."
    return 1
  fi
}

fn_telegram_send() {
  local message="${1:-}"
  local parse_mode="${2:-Markdown}"

  if [[ -z "$message" ]]; then fn_warn "[telegram] empty message — skipping."; return 1; fi
  fn_telegram_check || return 1

  fn_debug "[telegram] Sending message..."
  fn_telegram_curl "sendMessage" \
    --data-urlencode "text=${message}" \
    -d "parse_mode=${parse_mode}" \
    -d "disable_web_page_preview=true"
}

fn_telegram_send_document() {
  local filepath="$1"
  local caption="$2"
  caption="${caption:0:1000}" #telegram limit

  if [[ ! -f "$filepath" ]]; then fn_warn "[telegram] file not found: $filepath — skipping."; return 1; fi
  fn_telegram_check || return 1

  # strip ansi codes into a temp file before sending
  fn_debug "[telegram] Sending document: $filepath"
  fn_telegram_curl "sendDocument" \
    -F "caption=${caption}" \
    -F "document=@${filepath}"
}


# ---------------------------------------------------------------------------
# Email helpers
# ---------------------------------------------------------------------------
fn_email_build_header() {
  local subject="$1" email_from="$2" to_header="$3" boundary="$4"
  cat <<EOF
From: $email_from
To: $to_header
Subject: $subject
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="${boundary}"

EOF
}

fn_email_build_part() {
  local content_type="$1" body="$2" boundary="$3"
  cat <<EOF
--${boundary}
Content-Type: ${content_type}

${body}

EOF
}

fn_email_build_attachment_part() {
  local filepath="$1" boundary="$2"
  local attachment_name="${CURRENT_TASK}-errors.log"
  local encoded_file="$(base64 < "$filepath")"
  cat <<EOF
--${boundary}
Content-Type: text/plain; charset=UTF-8; name="${attachment_name}"
Content-Transfer-Encoding: base64
Content-Disposition: attachment; filename="${attachment_name}"

${encoded_file}

EOF
}

fn_email_build_footer() {
  local boundary="$1"
  echo "--${boundary}--"
}

fn_email_build() {
  local subject="$1" body="$2" email_from="$3" to_header="$4" filepath="$5"
  local boundary="==boundary_$(date +%s)=="
  fn_email_build_header "$subject" "$email_from" "$to_header" "$boundary"
  fn_email_build_part "text/plain; charset=UTF-8" "$body" "$boundary"
  fn_notify_send_doc "$filepath" fn_email_build_attachment_part "$boundary"
  fn_email_build_footer "$boundary"
}

fn_email_send_curl() {
  local email_smtp="$1" email_user="$2" email_pass="$3"
  local email_from="$4" to_header="$5"
  shift 5
  local rcpt_args=("$@")

  fn_debug "[email] Sending via $email_smtp to $to_header"

  curl -fsSL --max-time 15 \
    --url "$email_smtp" \
    --user "${email_user}:${email_pass}" \
    --mail-from "$email_from" \
    "${rcpt_args[@]}" \
    --upload-file -

  local ret=$?
  if [[ $ret -eq 0 ]]; then
    fn_debug "[email] Email sent successfully to: $to_header"
  else
    fn_warn "[email] Email failed (exit code $ret)."
  fi
  return $ret
}

fn_email_send() {
  local subject="$1" body="$2" errfile="${3:-}"

  local email_to="${cfg[NotifyEmailTo]}"
  local email_from="${cfg[EmailFrom]}"
  local email_smtp="${cfg[EmailSmtp]}"
  local email_user="${cfg[EmailUser]}"
  local email_pass="${cfg[EmailPass]}"

  if [[ -z "$email_to" ]];   then fn_debug "[email] EmailTo is not set — skipping."; return 0; fi
  if [[ -z "$email_smtp" ]]; then fn_warn "[email] EmailSmtp is not set — skipping."; return 1; fi
  if ! fn_cmd_exists curl;   then fn_warn "[email] curl not found — skipping."; return 1; fi

  local rcpt_args=() recipients=()
  IFS=',' read -r -a recipients <<< "$email_to"
  for rcpt in "${recipients[@]}"; do
    rcpt="$(fn_trim "$rcpt")"
    [[ -z "$rcpt" ]] && continue
    rcpt_args+=(--mail-rcpt "$rcpt")
  done

  if [[ ${#rcpt_args[@]} -eq 0 ]]; then
    fn_warn "[email] No valid recipients found — skipping."
    return 1
  fi

  local to_header
  to_header="$(IFS=', '; echo "${recipients[*]}")"

  fn_email_build "$subject" "$body" "$email_from" "$to_header" "$errfile" \
    | fn_email_send_curl "$email_smtp" "$email_user" "$email_pass" "$email_from" "$to_header" "${rcpt_args[@]}"
}
