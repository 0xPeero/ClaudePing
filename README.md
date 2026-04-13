# ClaudePing

Telegram notifications and two-way interaction for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Get instant alerts when Claude finishes a task, and respond to questions directly from Telegram -- without switching back to your terminal.

## Features

- **Task completion notifications** -- know when Claude is done
- **Two-way interaction** -- answer Claude's questions from Telegram via inline keyboard buttons or freeform text
- **Tool approval notifications** -- see what Claude wants to do before approving
- **Switchable modes** -- toggle between notify (answer in Claude Code) and interactive (answer in Telegram) via a button
- **Card-style messages** -- HTML-formatted notifications with emoji prefixes and project name
- **Configurable events** -- choose which events trigger notifications
- **Silent mode** -- per-event silent notifications (no sound)
- **Cross-platform** -- Windows (Git Bash), macOS, and Linux
- **Zero dependencies** -- uses only bash, curl, and Node.js (all included with Claude Code)
- **Non-blocking** -- notification hooks run async, never slowing down Claude
- **Safe install** -- scripts live in `~/.config/claudeping/`, safe from accidental deletion
- **One-command install/update/uninstall**

## How It Works

```
Claude Code event  -->  Hook fires  -->  claudeping.sh  -->  Telegram notification
                                                                    |
Claude asks question  -->  PreToolUse hook  -->  claudeping-interact.js
                                                      |
                                                 Send inline buttons to Telegram
                                                      |
                                                 User taps button / types reply
                                                      |
                                                 Feed answer back to Claude Code
```

## Quick Start

### 1. Clone the repo

```bash
git clone https://github.com/0xPeero/ClaudePing.git
cd ClaudePing
```

### 2. Create a Telegram bot

1. Open Telegram and message [@BotFather](https://t.me/BotFather)
2. Send `/newbot` and follow the prompts
3. Copy the **bot token**

### 3. Get your chat ID

Message your new bot (send `/start`), then run:

```bash
curl -s "https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates" \
  | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>console.log(JSON.parse(d).result[0].message.chat.id))"
```

### 4. Install

```bash
bash install.sh
```

This copies scripts to `~/.config/claudeping/`, creates a config file, and registers hooks in Claude Code.

### 5. Configure

Edit `~/.config/claudeping/.env` with your bot token and chat ID:

```
CLAUDEPING_BOT_TOKEN=your-bot-token-here
CLAUDEPING_CHAT_ID=your-chat-id-here
```

### 6. Test

```bash
bash ~/.config/claudeping/claudeping.sh --test
```

You should receive a test notification on Telegram.

### 7. Done

Restart any open Claude Code sessions to pick up the new hooks. You can safely delete the cloned repo -- everything is installed in `~/.config/claudeping/`.

## Updating

Pull the latest changes and re-run the installer:

```bash
cd ClaudePing
git pull
bash install.sh --update
```

This updates the scripts while keeping your `.env` config intact.

## Configuration

All settings are in `~/.config/claudeping/.env`.

### Required

| Variable | Description |
|----------|-------------|
| `CLAUDEPING_BOT_TOKEN` | Telegram bot token from @BotFather |
| `CLAUDEPING_CHAT_ID` | Your Telegram chat ID |

### Optional

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDEPING_EVENTS` | `Stop,Notification` | Events that trigger notifications. Available: `Stop`, `Notification`, `SubagentStop` |
| `CLAUDEPING_SILENT_STOP` | `false` | Silent (no sound) notifications for task completion |
| `CLAUDEPING_SILENT_NOTIFICATION` | `false` | Silent notifications for questions/approvals |
| `CLAUDEPING_SILENT_SUBAGENTSTOP` | `false` | Silent notifications for subagent completion |
| `CLAUDEPING_RESPONSE_TIMEOUT` | `1800` | Seconds to wait for a Telegram response (two-way interaction). Default: 30 minutes |
| `CLAUDEPING_MODE` | `notify` | `notify` = answer in Claude Code, `interactive` = answer in Telegram. Toggle via button on Telegram |

## Notification Types

| Event | Emoji | When it fires |
|-------|-------|---------------|
| Task Complete | &#9989; | Claude finishes responding |
| Needs Input | &#10067; | Claude has a follow-up question |
| Needs Approval | &#128272; | Claude needs tool permission |
| Subagent Complete | &#9989; | A subagent finishes (opt-in via `CLAUDEPING_EVENTS`) |

## Two-Way Interaction

### Modes

Every question and approval notification includes a mode toggle button at the bottom:

- **Notify mode** (default) -- Questions show on both Telegram and Claude Code. Answer in Claude Code. Telegram shows the options as text for reference.
- **Interactive mode** -- Questions show inline keyboard buttons on Telegram. Answer by tapping a button or typing a response. Claude Code waits for your Telegram reply.

Tap the toggle to switch. Takes effect on the next question.

### Questions

When Claude asks a question (via `AskUserQuestion`):

- **Notify mode**: Telegram shows the question and options as text. Answer in Claude Code.
- **Interactive mode**: Telegram shows inline keyboard buttons. Tap a button, tap "Other" to type a custom response, or do nothing (30 min timeout, falls back to Claude Code).

### Tool Approvals

When Claude needs permission to run a tool (Edit, Write, Bash), Telegram shows what tool is being used and what it wants to do. Answer in Claude Code.

## Manual Installation

If you prefer not to use `install.sh`, copy scripts to `~/.config/claudeping/` and add hooks to `~/.claude/settings.json`:

### Notification hooks

```json
{
  "hooks": {
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "bash \"~/.config/claudeping/claudeping.sh\"",
        "timeout": 10,
        "async": true
      }]
    }],
    "Notification": [{
      "hooks": [{
        "type": "command",
        "command": "bash \"~/.config/claudeping/claudeping.sh\"",
        "timeout": 10,
        "async": true
      }]
    }]
  }
}
```

### Two-way interaction hook

```json
{
  "hooks": {
    "PreToolUse": [{
      "matcher": "AskUserQuestion|Edit|Write|Bash|MultiEdit",
      "hooks": [{
        "type": "command",
        "command": "node \"~/.config/claudeping/claudeping-interact.js\"",
        "timeout": 3600
      }]
    }]
  }
}
```

Note: the interaction hook must **not** have `"async": true` -- it needs to be synchronous so Claude waits for your response.

## Uninstall

```bash
bash install.sh --uninstall
```

Removes hooks from `~/.claude/settings.json` and scripts from `~/.config/claudeping/`. Your `.env` config is saved as `.env.backup`.

## Files

| File | Purpose |
|------|---------|
| `claudeping.sh` | Notification script -- reads hook JSON, formats HTML card, sends to Telegram |
| `claudeping-interact.js` | Two-way interaction -- sends inline buttons, polls for response, feeds answer back |
| `install.sh` | Installer -- copies to `~/.config/claudeping/`, registers hooks, supports update and uninstall |
| `.env.example` | Configuration template |
| `test_claudeping.sh` | Test suite |

## License

MIT
