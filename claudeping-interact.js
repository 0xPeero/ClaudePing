#!/usr/bin/env node
'use strict';

// ClaudePing Interaction Script
// Handles two-way Telegram interaction for Claude Code.
// Supports two modes:
//   1. AskUserQuestion -- sends question with inline keyboard buttons, polls for response
//   2. Tool Approval (Edit, Bash, Write, etc.) -- sends approval request with Allow/Deny buttons
//
// Zero npm dependencies -- uses only Node.js built-ins: fs, path, https.

const fs = require('fs');
const path = require('path');
const https = require('https');

// ===== 1. .env Loading (Pattern 5 from research) =====

function loadEnv() {
  let envDir = __dirname;
  let envPath = path.join(envDir, '.env');

  // Fallback: resolve symlinks and try again
  if (!fs.existsSync(envPath)) {
    try {
      envDir = fs.realpathSync(__dirname);
      envPath = path.join(envDir, '.env');
    } catch (_) {
      // ignore
    }
  }

  if (!fs.existsSync(envPath)) return {};

  const env = {};
  fs.readFileSync(envPath, 'utf8').split('\n').forEach(function (line) {
    line = line.trim();
    if (!line || line.startsWith('#')) return;
    var idx = line.indexOf('=');
    if (idx === -1) return;
    env[line.substring(0, idx).trim()] = line.substring(idx + 1).trim();
  });
  return env;
}

// ===== 2. HTTP POST Helper (Node.js built-in https) =====

function post(url, body) {
  return new Promise(function (resolve, reject) {
    var data = JSON.stringify(body);
    var parsed = new URL(url);
    var req = https.request({
      hostname: parsed.hostname,
      path: parsed.pathname,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(data)
      }
    }, function (res) {
      var chunks = '';
      res.on('data', function (c) { chunks += c; });
      res.on('end', function () {
        try { resolve(JSON.parse(chunks)); }
        catch (_) { resolve({ ok: false, description: chunks }); }
      });
    });
    req.on('error', reject);
    req.write(data);
    req.end();
  });
}

// ===== 3. HTML Escape =====

function htmlEscape(text) {
  if (!text) return '';
  return String(text)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

// ===== 4. Read stdin =====

function readStdin() {
  return new Promise(function (resolve) {
    var data = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', function (chunk) { data += chunk; });
    process.stdin.on('end', function () { resolve(data); });
  });
}

// ===== 5. Telegram API Helpers =====

function telegramUrl(token, method) {
  return 'https://api.telegram.org/bot' + token + '/' + method;
}

async function sendMessage(token, chatId, text, replyMarkup) {
  var body = {
    chat_id: chatId,
    text: text,
    parse_mode: 'HTML',
    disable_web_page_preview: true
  };
  if (replyMarkup) {
    body.reply_markup = replyMarkup;
  }
  return post(telegramUrl(token, 'sendMessage'), body);
}

async function getUpdates(token, offset, timeoutSec) {
  var result = await post(telegramUrl(token, 'getUpdates'), {
    offset: offset,
    timeout: timeoutSec,
    allowed_updates: ['callback_query', 'message']
  });
  return (result.ok && Array.isArray(result.result)) ? result.result : [];
}

async function answerCallbackQuery(token, callbackQueryId) {
  return post(telegramUrl(token, 'answerCallbackQuery'), {
    callback_query_id: callbackQueryId
  });
}

async function editMessageText(token, chatId, messageId, newText) {
  return post(telegramUrl(token, 'editMessageText'), {
    chat_id: chatId,
    message_id: messageId,
    text: newText,
    parse_mode: 'HTML',
    reply_markup: { inline_keyboard: [] }
  });
}

// ===== 6. Flush Stale Updates + Check Mode Toggle =====

function updateEnvMode(newMode) {
  if (newMode !== 'notify' && newMode !== 'interactive') return;
  var envDir = __dirname;
  var envPath = path.join(envDir, '.env');
  if (!fs.existsSync(envPath)) {
    try { envDir = fs.realpathSync(__dirname); envPath = path.join(envDir, '.env'); } catch (_) {}
  }
  if (!fs.existsSync(envPath)) return;

  var content = fs.readFileSync(envPath, 'utf8');
  if (/^CLAUDEPING_MODE=/m.test(content)) {
    content = content.replace(/^CLAUDEPING_MODE=.*/m, 'CLAUDEPING_MODE=' + newMode);
  } else {
    content += '\nCLAUDEPING_MODE=' + newMode + '\n';
  }
  fs.writeFileSync(envPath, content);
}

async function flushUpdates(token, chatId) {
  var result = await post(telegramUrl(token, 'getUpdates'), {
    offset: -1,
    limit: 1,
    timeout: 0
  });
  var offset = 0;
  if (result.ok && Array.isArray(result.result) && result.result.length > 0) {
    var last = result.result[result.result.length - 1];
    offset = last.update_id + 1;

    // Check if the last update is a mode toggle
    if (last.callback_query && last.callback_query.data &&
        last.callback_query.data.startsWith('mode:') &&
        String(last.callback_query.message.chat.id) === String(chatId)) {
      var newMode = last.callback_query.data.substring(5);
      updateEnvMode(newMode);
      await answerCallbackQuery(token, last.callback_query.id);
      await sendMessage(token, chatId,
        '&#9989; <b>Mode switched to ' + htmlEscape(newMode) + '</b>\n\n' +
        (newMode === 'interactive'
          ? 'Questions will now show buttons on Telegram. Answer here.'
          : 'Questions will show on Telegram as notifications. Answer in Claude Code.'));
      // Return the new mode so caller can use it
      return { offset: offset, modeChanged: newMode };
    }

    await post(telegramUrl(token, 'getUpdates'), {
      offset: offset, limit: 1, timeout: 0
    });
  }
  return { offset: offset, modeChanged: null };
}

// ===== 7. Recover Full Label from Truncated callback_data =====

function recoverLabel(callbackData, options) {
  // Strip "ans:" prefix
  var truncated = callbackData.substring(4);

  // Try exact match first
  for (var i = 0; i < options.length; i++) {
    if (options[i].label === truncated) return options[i].label;
  }

  // Try prefix match for truncated labels (>60 chars)
  for (var j = 0; j < options.length; j++) {
    if (options[j].label.substring(0, 60) === truncated) return options[j].label;
  }

  // Fallback: return the truncated value
  return truncated;
}

// ===== 8. Main =====

(async function main() {
  try {
    // a. Read stdin and parse JSON
    var raw = await readStdin();
    if (!raw || !raw.trim()) {
      process.exit(0);
    }

    var input;
    try {
      input = JSON.parse(raw);
    } catch (_) {
      process.stderr.write('claudeping-interact: failed to parse stdin JSON\n');
      process.exit(0);
    }

    var toolName = input.tool_name || '';
    var toolInput = input.tool_input || {};

    // Extract project name from cwd
    var cwd = input.cwd || '';
    var segments = cwd.replace(/\\/g, '/').split('/').filter(Boolean);
    var project = segments.length > 0 ? segments[segments.length - 1] : 'unknown';
    var escapedProject = htmlEscape(project);

    // b. Load and validate .env
    var env = loadEnv();
    var token = env.CLAUDEPING_BOT_TOKEN || '';
    var chatId = env.CLAUDEPING_CHAT_ID || '';
    var timeoutSeconds = parseInt(env.CLAUDEPING_RESPONSE_TIMEOUT, 10) || 1800;
    var mode = (env.CLAUDEPING_MODE || 'notify').toLowerCase().trim();

    if (!token || !chatId || token === 'your-bot-token-here' || chatId === 'your-chat-id-here') {
      process.exit(0);
    }

    // c. Determine mode: AskUserQuestion or Tool Approval
    var isAskUserQuestion = toolName === 'AskUserQuestion' &&
      toolInput.questions && toolInput.questions.length > 0;

    // For non-AskUserQuestion tools, this is a tool approval request
    var isToolApproval = !isAskUserQuestion && toolName;

    if (!isAskUserQuestion && !isToolApproval) {
      process.exit(0);
    }

    // d. Flush stale Telegram updates and check for mode toggle
    var flushResult = await flushUpdates(token, chatId);
    var offset = flushResult.offset;
    if (flushResult.modeChanged) {
      mode = flushResult.modeChanged;
    }

    // ===== MODE 1: Tool Approval (Edit, Bash, Write, etc.) =====
    // Non-blocking: send notification to Telegram, exit immediately.
    // Claude Code shows its native approval UI. User answers in whichever they see first.
    if (isToolApproval) {
      var toolSummary = '';
      if (toolName === 'Bash' || toolName === 'bash') {
        toolSummary = htmlEscape((toolInput.command || toolInput.description || '').substring(0, 500));
      } else if (toolName === 'Edit' || toolName === 'MultiEdit') {
        var filePath = toolInput.file_path || '';
        toolSummary = '<b>File:</b> <code>' + htmlEscape(filePath) + '</code>';
        if (toolInput.old_string) {
          toolSummary += '\n<b>Replace:</b> <code>' + htmlEscape(toolInput.old_string.substring(0, 150)) + '</code>';
        }
      } else if (toolName === 'Write') {
        var writeFile = toolInput.file_path || '';
        toolSummary = '<b>File:</b> <code>' + htmlEscape(writeFile) + '</code>';
      } else {
        toolSummary = '<b>Tool:</b> <code>' + htmlEscape(toolName) + '</code>';
      }

      var approvalText = '&#128272; <b>Needs Approval</b>\n\n' +
        '<b>Project:</b> <code>' + escapedProject + '</code>\n' +
        '<b>Tool:</b> <code>' + htmlEscape(toolName) + '</code>\n\n' +
        toolSummary + '\n\n' +
        '<i>Respond in Claude Code</i>';

      var approvalToggle = mode === 'interactive'
        ? [{ text: '🔔 Switch to Notify', callback_data: 'mode:notify' }]
        : [{ text: '💬 Switch to Interactive', callback_data: 'mode:interactive' }];

      await sendMessage(token, chatId, approvalText, { inline_keyboard: [approvalToggle] });
      // Exit immediately -- don't block Claude Code's native approval UI
      process.exit(0);
    }

    // ===== MODE 2: AskUserQuestion =====
    var question = toolInput.questions[0];
    var questionText = question.question || '';
    var header = question.header || '';
    var options = (question.options && Array.isArray(question.options)) ? question.options : [];

    // d2. Build inline keyboard (only for interactive mode)
    var keyboard = null;
    if (mode === 'interactive' && options.length > 0) {
      keyboard = options.map(function (opt) {
        return [{
          text: opt.label,
          callback_data: 'ans:' + opt.label.substring(0, 60)
        }];
      });
      keyboard.push([{
        text: 'Other (type your answer)...',
        callback_data: 'ans:__OTHER__'
      }]);
    }

    // e. Build HTML message
    var escapedQuestion = htmlEscape(questionText);
    var messageText = '&#10067; <b>Claude has a question</b>\n\n' +
      '<b>Project:</b> <code>' + escapedProject + '</code>\n\n';

    if (header) {
      messageText += '<b>' + htmlEscape(header) + '</b>\n\n';
    }

    messageText += escapedQuestion;

    // Show options as text list in notify mode
    if (mode === 'notify' && options.length > 0) {
      messageText += '\n\n<b>Options:</b>';
      for (var oi = 0; oi < options.length; oi++) {
        messageText += '\n' + (oi + 1) + '. ' + htmlEscape(options[oi].label);
      }
      messageText += '\n\n<i>Respond in Claude Code</i>';
    }

    // Add mode toggle button
    var toggleButton = mode === 'interactive'
      ? [{ text: '🔔 Switch to Notify', callback_data: 'mode:notify' }]
      : [{ text: '💬 Switch to Interactive', callback_data: 'mode:interactive' }];

    if (keyboard) {
      // Interactive mode: append toggle as last row
      keyboard.push(toggleButton);
    } else {
      // Notify mode: toggle is the only button
      keyboard = [toggleButton];
    }

    // f. Send message to Telegram
    var replyMarkup = { inline_keyboard: keyboard };
    var sendResult = await sendMessage(token, chatId, messageText, replyMarkup);

    if (!sendResult.ok) {
      process.stderr.write('claudeping-interact: sendMessage failed: ' +
        (sendResult.description || 'unknown error') + '\n');
      process.exit(0);
    }

    var sentMessageId = sendResult.result.message_id;
    var sentTimestamp = Math.floor(Date.now() / 1000);

    // In notify mode, exit immediately -- user answers in Claude Code
    if (mode === 'notify') {
      process.exit(0);
    }

    // g. Poll for response (interactive mode only)
    var internalDeadline = Date.now() + (timeoutSeconds - 30) * 1000;
    var answer = null;
    var waitingForOtherText = false;

    while (Date.now() < internalDeadline) {
      var remainingSec = Math.min(
        Math.floor((internalDeadline - Date.now()) / 1000),
        30
      );
      if (remainingSec <= 0) break;

      var updates = await getUpdates(token, offset, remainingSec);

      for (var i = 0; i < updates.length; i++) {
        var update = updates[i];
        offset = update.update_id + 1;

        if (update.callback_query &&
            update.callback_query.message &&
            update.callback_query.message.message_id === sentMessageId &&
            String(update.callback_query.message.chat.id) === String(chatId)) {

          await answerCallbackQuery(token, update.callback_query.id);
          var cbData = update.callback_query.data || '';

          // Handle mode toggle during active polling
          if (cbData.startsWith('mode:')) {
            var newMode = cbData.substring(5);
            updateEnvMode(newMode);
            await editMessageText(token, chatId, sentMessageId,
              '&#9989; <b>Mode switched to ' + htmlEscape(newMode) + '</b>\n\n' +
              (newMode === 'notify'
                ? 'Questions will now show as notifications. Answer in Claude Code.'
                : 'Questions will now show buttons on Telegram. Answer here.') +
              '\n\n<i>This question: respond in Claude Code</i>');
            // Flush and exit -- Claude Code falls back to native UI
            await post(telegramUrl(token, 'getUpdates'), {
              offset: offset, limit: 1, timeout: 0
            });
            process.exit(0);
          }

          if (cbData === 'ans:__OTHER__') {
            waitingForOtherText = true;
            await sendMessage(token, chatId, 'Type your response below...');
            await editMessageText(token, chatId, sentMessageId,
              '&#9999;&#65039; <b>Typing response...</b>\n\n' +
              '<b>Project:</b> <code>' + escapedProject + '</code>\n\n' +
              (header ? '<b>' + htmlEscape(header) + '</b>\n\n' : '') +
              escapedQuestion);
            break;
          }

          answer = recoverLabel(cbData, options);
          await editMessageText(token, chatId, sentMessageId,
            '&#9989; <b>Answered</b>\n\n' +
            '<b>Project:</b> <code>' + escapedProject + '</code>\n\n' +
            (header ? '<b>' + htmlEscape(header) + '</b>\n\n' : '') +
            escapedQuestion + '\n\n' +
            '<b>Selected:</b> ' + htmlEscape(answer));
          break;
        }

        if (update.message &&
            update.message.text &&
            String(update.message.chat.id) === String(chatId) &&
            update.message.date >= sentTimestamp) {

          answer = update.message.text;
          await editMessageText(token, chatId, sentMessageId,
            '&#9989; <b>Answered</b>\n\n' +
            '<b>Project:</b> <code>' + escapedProject + '</code>\n\n' +
            (header ? '<b>' + htmlEscape(header) + '</b>\n\n' : '') +
            escapedQuestion + '\n\n' +
            '<b>Response:</b> ' + htmlEscape(answer));
          break;
        }
      }

      if (answer !== null) break;
    }

    // g2. Flush offset
    await post(telegramUrl(token, 'getUpdates'), {
      offset: offset, limit: 1, timeout: 0
    });

    // h. Handle timeout
    if (answer === null) {
      await editMessageText(token, chatId, sentMessageId,
        '&#9203; <b>Response Timed Out</b>\n\n' +
        '<b>Project:</b> <code>' + escapedProject + '</code>\n\n' +
        (header ? '<b>' + htmlEscape(header) + '</b>\n\n' : '') +
        escapedQuestion + '\n\n' +
        '<i>Timed out. Please answer in the terminal.</i>');
      process.exit(0);
    }

    // i. Output answer to Claude Code
    var output = {
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecision: 'allow',
        updatedInput: {
          questions: toolInput.questions,
          answers: {}
        }
      }
    };
    output.hookSpecificOutput.updatedInput.answers[questionText] = answer;

    process.stdout.write(JSON.stringify(output));
    process.exit(0);

  } catch (err) {
    // Top-level error handler: log to stderr, exit 0, no stdout
    process.stderr.write('claudeping-interact: ' + (err.message || String(err)) + '\n');
    process.exit(0);
  }
})();
