#!/usr/bin/env bash
# ClaudePing - Telegram notifications for Claude Code
# Accepts JSON on stdin from Claude Code hooks, formats it into
# a card-style HTML notification, and sends via Telegram Bot API.

trap 'exit 0' ERR

# ===== 1. Handle flags BEFORE reading stdin =====
IS_TEST=""
INPUT=""

if [[ "${1:-}" == "--mode" ]]; then
  # Toggle response mode: notify or interactive
  SCRIPT_DIR_MODE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  ENV_MODE="$SCRIPT_DIR_MODE/.env"
  NEW_MODE="${2:-}"
  if [[ "$NEW_MODE" != "notify" && "$NEW_MODE" != "interactive" ]]; then
    echo "Usage: bash claudeping.sh --mode <notify|interactive>"
    echo ""
    echo "  notify      - Telegram notification only, answer in Claude Code"
    echo "  interactive - Answer from Telegram with inline buttons (blocks Claude Code)"
    if [[ -f "$ENV_MODE" ]]; then
      CURRENT=$(grep "^CLAUDEPING_MODE=" "$ENV_MODE" 2>/dev/null | cut -d= -f2)
      echo ""
      echo "  Current: ${CURRENT:-notify (default)}"
    fi
    exit 0
  fi
  if [[ -f "$ENV_MODE" ]] && grep -q "^CLAUDEPING_MODE=" "$ENV_MODE" 2>/dev/null; then
    sed -i.bak "s/^CLAUDEPING_MODE=.*/CLAUDEPING_MODE=$NEW_MODE/" "$ENV_MODE" && rm -f "${ENV_MODE}.bak"
  else
    echo "CLAUDEPING_MODE=$NEW_MODE" >> "$ENV_MODE"
  fi
  echo "ClaudePing: Mode set to '$NEW_MODE'"
  [[ "$NEW_MODE" == "notify" ]] && echo "  Notifications on Telegram, answer in Claude Code"
  [[ "$NEW_MODE" == "interactive" ]] && echo "  Answer from Telegram (blocks Claude Code while waiting)"
  exit 0
fi

if [[ "${1:-}" == "--test" ]]; then
  INPUT='{"hook_event_name":"Stop","cwd":"'"$(pwd)"'","session_id":"test-123","transcript_path":"/tmp/test.jsonl","stop_hook_active":false}'
  IS_TEST=1
else
  # Read stdin FIRST (before source or other commands that consume it)
  INPUT=$(cat)
fi

# ===== 3. Load .env from script directory (symlink-safe) =====
resolve_script_dir() {
  local source="${BASH_SOURCE[0]}"
  while [[ -L "$source" ]]; do
    local dir="$(cd -P "$(dirname "$source")" && pwd)"
    source="$(readlink "$source")"
    [[ "$source" != /* ]] && source="$dir/$source"
  done
  echo "$(cd -P "$(dirname "$source")" && pwd)"
}
SCRIPT_DIR="$(resolve_script_dir)"
ENV_FILE="$SCRIPT_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
  while IFS='=' read -r key value; do
    key="${key%%[[:space:]]*}"
    value="${value##[[:space:]]}"
    value="${value%[[:space:]]}"
    [[ -z "$key" || "$key" == \#* ]] && continue
    case "$key" in
      CLAUDEPING_*) export "$key=$value" ;;
    esac
  done < "$ENV_FILE"
fi

# ===== 4. Validate required variables =====
if [[ -z "${CLAUDEPING_BOT_TOKEN:-}" ]] || [[ -z "${CLAUDEPING_CHAT_ID:-}" ]]; then
  exit 0
fi

# ===== 5. HTML escape function =====
html_escape() {
  local text="$1"
  text="${text//&/&amp;}"
  text="${text//</&lt;}"
  text="${text//>/&gt;}"
  printf '%s' "$text"
}

# ===== 6. Parse JSON via node (no eval -- line-delimited for safety) =====
# Node outputs one value per line. Newlines within values replaced with spaces.
PARSED="$(echo "$INPUT" | node -e "
  let d='';
  process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try {
      const j=JSON.parse(d);
      const cwd = (j.cwd||'').replace(/[\\\\/]+/g,'/');
      const project = cwd.split('/').filter(Boolean).pop() || 'unknown';
      const event = j.hook_event_name || 'unknown';
      const title = (j.title || '').replace(/\n/g, ' ');
      const message = (j.message || '').replace(/\n/g, ' ');
      const toolName = j.tool_name || '';
      const notifType = j.notification_type || '';
      const emojiMap = {
        'Stop':         ['&#9989;', 'Task Complete'],
        'SubagentStop': ['&#9989;', 'Subagent Complete'],
      };
      const notifMap = {
        'permission_prompt': ['&#128272;', 'Needs Approval'],
        'idle_prompt':       ['&#10067;', 'Needs Input'],
      };
      const pair = notifMap[notifType] || emojiMap[event] || (event === 'Notification' ? ['&#128276;', 'Notification'] : ['&#128221;', 'Event']);
      [project, event, title, message, toolName, notifType, pair[0], pair[1]].forEach(v => console.log(v));
    } catch(e) {
      ['unknown','unknown','','','','','&#128221;','Event'].forEach(v => console.log(v));
    }
  });
" 2>/dev/null)" || PARSED=""

{
  read -r CP_PROJECT
  read -r CP_EVENT
  read -r CP_TITLE
  read -r CP_MESSAGE
  read -r CP_TOOL
  read -r CP_NOTIF_TYPE
  read -r CP_EMOJI
  read -r CP_EVENT_LABEL
} <<< "$PARSED"
CP_PROJECT="${CP_PROJECT:-unknown}"
CP_EVENT="${CP_EVENT:-unknown}"

# ===== 6b. Event filtering: check if current event is in allowed list =====
EVENTS="${CLAUDEPING_EVENTS:-Stop,Notification}"
if [[ ",$EVENTS," != *",$CP_EVENT,"* ]]; then
  exit 0
fi

# ===== 6c. Silent notification: check per-event CLAUDEPING_SILENT_* var =====
DISABLE_NOTIFICATION="false"
if [[ "$CP_EVENT" =~ ^[A-Za-z]+$ ]]; then
  SILENT_VAR="CLAUDEPING_SILENT_$(echo "$CP_EVENT" | tr '[:lower:]' '[:upper:]')"
  if [[ "${!SILENT_VAR}" == "true" ]]; then
    DISABLE_NOTIFICATION="true"
  fi
fi

# ===== 7. Emoji and event label =====
# CP_EMOJI and CP_EVENT_LABEL are set by the node JSON parser above.
# Emojis are HTML numeric entities (&#9989; etc.) rendered by Telegram's HTML parser.
if [[ "$IS_TEST" == "1" ]]; then
  EMOJI="&#128225;"
  EVENT_LABEL="Test Notification"
else
  EMOJI="${CP_EMOJI:-&#128221;}"
  EVENT_LABEL="${CP_EVENT_LABEL:-Event}"
fi

# ===== 8. Build status line =====
STATUS_LINE=""

if [[ "$IS_TEST" == "1" ]]; then
  STATUS_LINE="Connection Test"
elif [[ "$CP_EVENT" == "Stop" ]]; then
  STATUS_LINE="Finished"
elif [[ "$CP_NOTIF_TYPE" == "idle_prompt" ]]; then
  STATUS_LINE="Waiting for input"
elif [[ "$CP_NOTIF_TYPE" == "permission_prompt" ]]; then
  STATUS_LINE="Waiting for approval"
elif [[ "$CP_EVENT" == "Notification" ]]; then
  STATUS_LINE="Notification"
elif [[ "$CP_EVENT" == "SubagentStop" ]]; then
  STATUS_LINE="Finished"
else
  # Capitalize first letter of CP_EVENT
  STATUS_LINE="$(echo "${CP_EVENT:0:1}" | tr '[:lower:]' '[:upper:]')${CP_EVENT:1}"
fi

# ===== 9. Build summary text =====
SUMMARY_TEXT=""

if [[ "$IS_TEST" == "1" ]]; then
  SUMMARY_TEXT="This is a test notification from ClaudePing.
Your Telegram bot is configured correctly.
Bot token and chat ID are valid.

Setup complete -- you will receive notifications
when Claude Code needs your attention."
elif [[ -n "$CP_MESSAGE" ]]; then
  ESCAPED_MESSAGE="$(html_escape "$CP_MESSAGE")"
  if [[ -n "$CP_TITLE" ]]; then
    ESCAPED_TITLE="$(html_escape "$CP_TITLE")"
    SUMMARY_TEXT="<b>${ESCAPED_TITLE}</b>
${ESCAPED_MESSAGE}"
  else
    SUMMARY_TEXT="$ESCAPED_MESSAGE"
  fi
elif [[ -n "$CP_TOOL" ]]; then
  ESCAPED_TOOL="$(html_escape "$CP_TOOL")"
  SUMMARY_TEXT="Tool: ${ESCAPED_TOOL}"
elif [[ "$CP_EVENT" == "Stop" ]]; then
  SUMMARY_TEXT="Claude has finished responding.
Check your terminal for results."
else
  SUMMARY_TEXT="Event received from Claude Code."
fi

# ===== 10. Build card message =====
ESCAPED_PROJECT="$(html_escape "$CP_PROJECT")"

MESSAGE="${EMOJI} <b>${EVENT_LABEL}</b>

<b>Project:</b> <code>${ESCAPED_PROJECT}</code>
<b>Status:</b> ${STATUS_LINE}

${SUMMARY_TEXT}"

# ===== 11. Truncate if needed (Telegram limit: 4096 chars) =====
if [[ ${#MESSAGE} -gt 3500 ]]; then
  MESSAGE="${MESSAGE:0:3500}

[...truncated]"
fi

# ===== 12. Send via curl =====
if [[ "${IS_TEST:-}" == "1" ]]; then
  RESPONSE=$(curl -s -X POST \
    --connect-timeout 3 \
    --max-time 5 \
    "https://api.telegram.org/bot${CLAUDEPING_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${CLAUDEPING_CHAT_ID}" \
    --data-urlencode "text=${MESSAGE}" \
    -d "parse_mode=HTML" \
    -d "disable_notification=${DISABLE_NOTIFICATION}" \
    -d "disable_web_page_preview=true") || true

  if echo "$RESPONSE" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{const j=JSON.parse(d);process.exit(j.ok?0:1)})" 2>/dev/null; then
    echo "ClaudePing: Test notification sent successfully!"
  else
    echo "ClaudePing: Failed to send test notification. Check your .env values." >&2
    echo "ClaudePing: Ensure you have messaged your bot (/start) before testing." >&2
  fi
else
  curl -s -X POST \
    --connect-timeout 3 \
    --max-time 5 \
    "https://api.telegram.org/bot${CLAUDEPING_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${CLAUDEPING_CHAT_ID}" \
    --data-urlencode "text=${MESSAGE}" \
    -d "parse_mode=HTML" \
    -d "disable_notification=${DISABLE_NOTIFICATION}" \
    -d "disable_web_page_preview=true" \
    > /dev/null 2>&1 || true
fi

exit 0
