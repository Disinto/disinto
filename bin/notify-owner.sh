#!/usr/bin/env bash
# =============================================================================
# notify-owner.sh — host-side only, called by the healer (bin/healer.sh)
# under the AD-006 exception (#1970). Never source it from lib/ or an agent.
#
# Usage: bin/notify-owner.sh TEXT
#
# The owner does not watch the forge. They read the Telegram group the host's
# alert bot already posts to, and may take a day or more to answer. This is
# the only sender: a deterministic host-side process that runs no model.
#
# Reads TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID from the environment. When
# either is empty: print "notify-owner: not configured" to stderr and exit 0.
# A missing channel never blocks the caller.
#
# Otherwise POST TEXT, truncated to 4000 characters, to the Telegram
# sendMessage method:
#   curl -s -m 15 -X POST \
#     "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
#     --data-urlencode "chat_id=..." --data-urlencode "text=..." \
#     -d disable_web_page_preview=true
# Exit 0 when the reply has "ok":true. Otherwise print
# "notify-owner: telegram send failed: <description from the reply, or the
# curl exit code>" to stderr and exit 1.
#
# The token must never be printed. Error messages carry only the reply's
# description (or the curl exit code). No set -x. curl's own stderr is
# discarded: its error text can include the request URL, and the token lives
# in that URL.
#
# Does not source lib/env.sh. This is a host-side script, not an agent, and
# env.sh is the agent environment (it can require USER/HOME and unsets
# external-action tokens). The healer job renders TELEGRAM_BOT_TOKEN and
# TELEGRAM_CHAT_ID into this process alone.
# =============================================================================
set -euo pipefail
# Drop bash -x / inherited tracing before the token is expanded. This script
# never enables xtrace.
set +x

# _notify_reply_ok REPLY — 0 when REPLY is a Telegram body whose top-level
# ok field is true. Whitespace around the field is ignored; a later
# occurrence inside the sent text is not.
_notify_reply_ok() {
  local compact="${1//[[:space:]]/}"
  case "$compact" in
    '{"ok":true}' | '{"ok":true,'*) return 0 ;;
    *) return 1 ;;
  esac
}

# _notify_description REPLY — print the description string, or nothing.
# Compact JSON and a single space after the colon are both accepted.
# The value is not unescaped; Telegram error descriptions are plain text.
_notify_description() {
  local reply="$1" rest=""
  case "$reply" in
    *'"description":"'*)
      rest="${reply#*\"description\":\"}"
      printf '%s' "${rest%%\"*}"
      ;;
    *'"description": "'*)
      rest="${reply#*\"description\": \"}"
      printf '%s' "${rest%%\"*}"
      ;;
  esac
}

# _notify_redact TEXT SECRET — print TEXT with every SECRET removed.
# SECRET is matched literally, including slashes and colons, so a token
# cannot leak through a description that echoes the request.
_notify_redact() {
  local text="$1" secret="$2" out=""
  if [ -z "$secret" ] || [ -z "$text" ]; then
    printf '%s' "$text"
    return 0
  fi
  while [[ "$text" == *"$secret"* ]]; do
    out+="${text%%"$secret"*}"
    text="${text#*"$secret"}"
  done
  printf '%s' "${out}${text}"
}

text="${1:-}"
token="${TELEGRAM_BOT_TOKEN:-}"
chat_id="${TELEGRAM_CHAT_ID:-}"

if [ -z "$token" ] || [ -z "$chat_id" ]; then
  printf 'notify-owner: not configured\n' >&2
  exit 0
fi

# Telegram's sendMessage cap is 4096; the issue stays under it at 4000.
text="${text:0:4000}"

reply=""
rc=0
# stderr is discarded: curl's own error text can include the request URL,
# and the token lives in that URL. The caller hears the exit code only.
reply="$(
  curl -s -m 15 -X POST \
    "https://api.telegram.org/bot${token}/sendMessage" \
    --data-urlencode "chat_id=${chat_id}" \
    --data-urlencode "text=${text}" \
    -d disable_web_page_preview=true \
    2>/dev/null
)" || rc=$?

if _notify_reply_ok "$reply"; then
  exit 0
fi

desc="$(_notify_description "$reply")"
if [ -z "$desc" ]; then
  desc="$rc"
fi
desc="$(_notify_redact "$desc" "$token")"
printf 'notify-owner: telegram send failed: %s\n' "$desc" >&2
exit 1
