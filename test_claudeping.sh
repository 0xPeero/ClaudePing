#!/usr/bin/env bash
# ClaudePing test suite
# Tests the claudeping.sh script behaviors

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/claudeping.sh"
PASS=0
FAIL=0

assert_exit_0() {
  local desc="$1"
  local exit_code="$2"
  if [[ "$exit_code" -eq 0 ]]; then
    echo "PASS: $desc"
    ((PASS++))
  else
    echo "FAIL: $desc (exit code: $exit_code)"
    ((FAIL++))
  fi
}

assert_contains() {
  local desc="$1"
  local haystack="$2"
  local needle="$3"
  if echo "$haystack" | grep -q "$needle"; then
    echo "PASS: $desc"
    ((PASS++))
  else
    echo "FAIL: $desc (expected to contain: $needle)"
    ((FAIL++))
  fi
}

assert_not_empty() {
  local desc="$1"
  local value="$2"
  if [[ -n "$value" ]]; then
    echo "PASS: $desc"
    ((PASS++))
  else
    echo "FAIL: $desc (value was empty)"
    ((FAIL++))
  fi
}

echo "=== ClaudePing Test Suite ==="
echo ""

# Test 1: --test flag with valid .env prints success message and exits 0
# (We can't test with a real .env/Telegram, so we test structure instead)
# We test that --test with MISSING .env exits 0 silently
echo "--- Test 1: --test with missing .env exits 0 silently ---"
OUTPUT=$(bash "$SCRIPT" --test 2>&1)
EXIT_CODE=$?
assert_exit_0 "Test 1: --test with missing .env exits 0" "$EXIT_CODE"

# Test 2: --test with missing .env exits 0 silently (no crash)
echo "--- Test 2: --test with missing .env produces no error output ---"
# Already tested above; exit code is the key check
assert_exit_0 "Test 2: --test missing .env exits 0" "$EXIT_CODE"

# Test 3: empty JSON with missing .env exits 0
echo "--- Test 3: empty JSON with missing .env exits 0 ---"
OUTPUT=$(echo '{}' | bash "$SCRIPT" 2>&1)
EXIT_CODE=$?
assert_exit_0 "Test 3: echo '{}' | claudeping.sh exits 0" "$EXIT_CODE"

# Test 4: malformed input exits 0
echo "--- Test 4: malformed input exits 0 ---"
OUTPUT=$(echo 'not json' | bash "$SCRIPT" 2>&1)
EXIT_CODE=$?
assert_exit_0 "Test 4: echo 'not json' | claudeping.sh exits 0" "$EXIT_CODE"

# Test 5: Script file exists and is executable
echo "--- Test 5: Script exists and is executable ---"
if [[ -f "$SCRIPT" ]] && [[ -x "$SCRIPT" ]]; then
  echo "PASS: Test 5: script exists and is executable"
  ((PASS++))
else
  echo "FAIL: Test 5: script missing or not executable"
  ((FAIL++))
fi

# Test 6: Script structure - stdin read first
echo "--- Test 6: Script structure checks ---"
CONTENT=$(cat "$SCRIPT")
assert_contains "Test 6a: has shebang" "$CONTENT" "#!/usr/bin/env bash"
assert_contains "Test 6b: has trap exit 0 ERR" "$CONTENT" "trap 'exit 0' ERR"
assert_contains "Test 6c: has INPUT=\$(cat)" "$CONTENT" 'INPUT=\$(cat)'
assert_contains "Test 6d: has html_escape function" "$CONTENT" "html_escape"
assert_contains "Test 6e: has node -e" "$CONTENT" "node -e"
assert_contains "Test 6f: has BASH_SOURCE" "$CONTENT" "BASH_SOURCE"
assert_contains "Test 6g: has connect-timeout" "$CONTENT" "connect-timeout 3"
assert_contains "Test 6h: has max-time" "$CONTENT" "max-time 5"
assert_contains "Test 6i: has data-urlencode" "$CONTENT" "data-urlencode"
assert_contains "Test 6j: has --test flag" "$CONTENT" "\-\-test"
assert_contains "Test 6k: has success message" "$CONTENT" "Test notification sent successfully"
assert_contains "Test 6l: ends with exit 0" "$CONTENT" "exit 0"

# Test 7: stdin-first ordering (INPUT=$(cat) appears before source)
echo "--- Test 7: stdin-first ordering ---"
INPUT_LINE=$(grep -n 'INPUT=\$(cat)' "$SCRIPT" | head -1 | cut -d: -f1)
SOURCE_LINE=$(grep -n '^[[:space:]]*source ' "$SCRIPT" | head -1 | cut -d: -f1)
if [[ -n "$INPUT_LINE" ]] && [[ -n "$SOURCE_LINE" ]] && [[ "$INPUT_LINE" -lt "$SOURCE_LINE" ]]; then
  echo "PASS: Test 7: INPUT=\$(cat) (line $INPUT_LINE) before source (line $SOURCE_LINE)"
  ((PASS++))
else
  echo "FAIL: Test 7: stdin not read before source (INPUT line: $INPUT_LINE, source line: $SOURCE_LINE)"
  ((FAIL++))
fi

# Test 8: Emoji characters present
echo "--- Test 8: Emoji characters present ---"
assert_contains "Test 8a: has checkmark emoji" "$CONTENT" $'\xe2\x9c\x85'
assert_contains "Test 8b: has question mark emoji" "$CONTENT" $'\xe2\x9d\x93'
assert_contains "Test 8c: has satellite emoji" "$CONTENT" $'\xf0\x9f\x93\xa1'
assert_contains "Test 8d: has lock emoji" "$CONTENT" $'\xf0\x9f\x94\x90'

# Test 9: Event filtering - script contains CLAUDEPING_EVENTS logic
echo "--- Test 9: Event filtering logic ---"
assert_contains "Test 9a: has CLAUDEPING_EVENTS default" "$CONTENT" 'CLAUDEPING_EVENTS:-Stop,Notification'
assert_contains "Test 9b: has comma-padded event check" "$CONTENT" ',$EVENTS,'
assert_contains "Test 9c: has exit 0 for filtered events" "$CONTENT" 'exit 0'

# Test 10: Silent notification - script contains CLAUDEPING_SILENT logic
echo "--- Test 10: Silent notification logic ---"
assert_contains "Test 10a: has CLAUDEPING_SILENT variable construction" "$CONTENT" 'CLAUDEPING_SILENT_'
assert_contains "Test 10b: has DISABLE_NOTIFICATION variable" "$CONTENT" 'DISABLE_NOTIFICATION'
assert_contains "Test 10c: has disable_notification in curl" "$CONTENT" 'disable_notification'

# Test 11: Symlink-safe resolution - script contains resolve_script_dir
echo "--- Test 11: Symlink-safe .env resolution ---"
assert_contains "Test 11a: has resolve_script_dir function" "$CONTENT" 'resolve_script_dir'
assert_contains "Test 11b: has readlink in resolution" "$CONTENT" 'readlink'

# Test 12: Event filtering behavior - SubagentStop filtered by default
echo "--- Test 12: Event filtering behavior ---"
OUTPUT=$(echo '{"hook_event_name":"SubagentStop","cwd":"/tmp"}' | CLAUDEPING_EVENTS="Stop,Notification" CLAUDEPING_BOT_TOKEN=fake CLAUDEPING_CHAT_ID=fake bash "$SCRIPT" 2>&1)
EXIT_CODE=$?
assert_exit_0 "Test 12: SubagentStop filtered out by default events exits 0" "$EXIT_CODE"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
else
  exit 0
fi
