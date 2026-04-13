#!/usr/bin/env bash
# ClaudePing Installer
# Copies scripts to ~/.config/claudeping/ and registers hooks in Claude Code.
# Usage: bash install.sh            (install)
#        bash install.sh --uninstall  (remove)
#        bash install.sh --update     (update scripts, keep .env)

set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Install location -- safe from accidental deletion
INSTALL_DIR="$HOME/.config/claudeping"
SETTINGS_DIR="$HOME/.claude"
SETTINGS_PATH="$SETTINGS_DIR/settings.json"

# Check node is available
if ! command -v node > /dev/null 2>&1; then
  echo "ClaudePing: ERROR - 'node' is required but not found in PATH." >&2
  echo "ClaudePing: Node.js is included with Claude Code -- ensure it is installed." >&2
  exit 1
fi

install_files() {
  mkdir -p "$INSTALL_DIR"

  # Copy scripts to install directory
  cp "$SCRIPT_DIR/claudeping.sh" "$INSTALL_DIR/claudeping.sh"
  cp "$SCRIPT_DIR/claudeping-interact.js" "$INSTALL_DIR/claudeping-interact.js"

  # Copy .env.example (always update it)
  cp "$SCRIPT_DIR/.env.example" "$INSTALL_DIR/.env.example"

  # Create .env from template if it doesn't exist (preserve existing config)
  if [[ ! -f "$INSTALL_DIR/.env" ]]; then
    cp "$SCRIPT_DIR/.env.example" "$INSTALL_DIR/.env"
    echo "ClaudePing: Created .env config at $INSTALL_DIR/.env"
    echo "ClaudePing: Edit it with your Telegram bot token and chat ID."
  else
    echo "ClaudePing: Keeping existing .env config."
  fi

  # Make scripts executable
  chmod +x "$INSTALL_DIR/claudeping.sh" 2>/dev/null || true
  chmod +x "$INSTALL_DIR/claudeping-interact.js" 2>/dev/null || true

  echo "ClaudePing: Scripts installed to $INSTALL_DIR/"
}

install_hooks() {
  mkdir -p "$SETTINGS_DIR"

  # Hook commands point to the safe install location
  local HOOK_COMMAND="bash \"$INSTALL_DIR/claudeping.sh\""
  local INTERACT_COMMAND="node \"$INSTALL_DIR/claudeping-interact.js\""

  # Backup settings.json
  if [[ -f "$SETTINGS_PATH" ]]; then
    cp "$SETTINGS_PATH" "${SETTINGS_PATH}.bak" 2>/dev/null && \
      echo "ClaudePing: Backed up settings.json to settings.json.bak" || \
      echo "ClaudePing: WARNING - Could not create backup of settings.json"
  fi

  node -e "
    const fs = require('fs');
    const settingsPath = process.argv[1];
    const hookCommand = process.argv[2];
    const interactCommand = process.argv[3];

    let settings = {};
    try {
      settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
    } catch(e) {}

    if (!settings.hooks || typeof settings.hooks !== 'object') {
      settings.hooks = {};
    }

    // Remove any old ClaudePing hooks first (clean reinstall)
    for (const event of Object.keys(settings.hooks)) {
      if (!Array.isArray(settings.hooks[event])) continue;
      settings.hooks[event] = settings.hooks[event].filter(function(group) {
        return !(group.hooks && group.hooks.some(function(h) {
          return h.command && h.command.includes('claudeping');
        }));
      });
      if (settings.hooks[event].length === 0) delete settings.hooks[event];
    }

    // Register notification hooks (async, non-blocking)
    const events = ['Stop', 'Notification', 'SubagentStop'];
    for (const event of events) {
      if (!Array.isArray(settings.hooks[event])) settings.hooks[event] = [];
      settings.hooks[event].push({
        hooks: [{
          type: 'command',
          command: hookCommand,
          timeout: 10,
          async: true
        }]
      });
      console.log('ClaudePing: Registered hook: ' + event);
    }

    // Register interaction hook (questions + tool approvals)
    if (!Array.isArray(settings.hooks.PreToolUse)) settings.hooks.PreToolUse = [];
    settings.hooks.PreToolUse.push({
      matcher: 'AskUserQuestion|Edit|Write|Bash|MultiEdit',
      hooks: [{
        type: 'command',
        command: interactCommand,
        timeout: 3600
      }]
    });
    console.log('ClaudePing: Registered hook: PreToolUse (questions + approvals)');

    fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + '\n');
    console.log('ClaudePing: Settings saved.');
  " "$SETTINGS_PATH" "$HOOK_COMMAND" "$INTERACT_COMMAND"
}

uninstall() {
  # Remove hooks from settings.json
  if [[ -f "$SETTINGS_PATH" ]]; then
    cp "$SETTINGS_PATH" "${SETTINGS_PATH}.bak" 2>/dev/null && \
      echo "ClaudePing: Backed up settings.json" || true

    node -e "
      const fs = require('fs');
      const settingsPath = process.argv[1];
      let settings;
      try { settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8')); } catch(e) { process.exit(0); }
      if (!settings.hooks) { process.exit(0); }

      let removed = 0;
      for (const event of Object.keys(settings.hooks)) {
        if (!Array.isArray(settings.hooks[event])) continue;
        const before = settings.hooks[event].length;
        settings.hooks[event] = settings.hooks[event].filter(function(group) {
          return !(group.hooks && group.hooks.some(function(h) {
            return h.command && h.command.includes('claudeping');
          }));
        });
        removed += before - settings.hooks[event].length;
        if (settings.hooks[event].length === 0) delete settings.hooks[event];
      }

      fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + '\n');
      console.log('ClaudePing: Removed ' + removed + ' hook(s) from settings.json');
    " "$SETTINGS_PATH"
  fi

  # Remove installed files (but preserve .env as backup)
  if [[ -d "$INSTALL_DIR" ]]; then
    if [[ -f "$INSTALL_DIR/.env" ]]; then
      cp "$INSTALL_DIR/.env" "$INSTALL_DIR/.env.backup" 2>/dev/null
      echo "ClaudePing: Saved .env backup to $INSTALL_DIR/.env.backup"
    fi
    rm -f "$INSTALL_DIR/claudeping.sh" "$INSTALL_DIR/claudeping-interact.js" "$INSTALL_DIR/.env.example"
    echo "ClaudePing: Removed scripts from $INSTALL_DIR/"
  fi
}

# Main
case "${1:-}" in
  --uninstall)
    echo "ClaudePing: Uninstalling..."
    uninstall
    echo "ClaudePing: Uninstall complete."
    echo "ClaudePing: Your .env config is preserved at $INSTALL_DIR/.env.backup"
    ;;
  --update)
    echo "ClaudePing: Updating..."
    install_files
    echo ""
    echo "ClaudePing: Scripts updated. Hooks unchanged."
    echo "ClaudePing: Restart Claude Code to use the new version."
    ;;
  *)
    echo "ClaudePing: Installing to $INSTALL_DIR/"
    install_files
    install_hooks
    echo ""
    echo "ClaudePing: Installation complete!"
    echo "ClaudePing: 1. Edit your config: $INSTALL_DIR/.env"
    echo "ClaudePing: 2. Test: bash $INSTALL_DIR/claudeping.sh --test"
    echo "ClaudePing: 3. Restart Claude Code to activate hooks."
    ;;
esac
