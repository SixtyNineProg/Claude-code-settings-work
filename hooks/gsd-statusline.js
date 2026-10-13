#!/usr/bin/env node
// gsd-hook-version: 1.42.3
// Claude Code Statusline - GSD Edition
// Shows: model | current task (or GSD state) | directory | context usage

const fs = require('fs');
const path = require('path');
const os = require('os');

// --- Config + last-command readers ------------------------------------------

/**
 * Walk up from dir looking for .planning/config.json and return its parsed contents.
 * Returns {} if not found or unreadable.
 */
function readGsdConfig(dir) {
  const home = os.homedir();
  let current = dir;
  for (let i = 0; i < 10; i++) {
    const candidate = path.join(current, '.planning', 'config.json');
    if (fs.existsSync(candidate)) {
      try {
        return JSON.parse(fs.readFileSync(candidate, 'utf8')) || {};
      } catch (e) {
        return {};
      }
    }
    const parent = path.dirname(current);
    if (parent === current || current === home) break;
    current = parent;
  }
  return {};
}

/**
 * Lookup a dotted key path (e.g. 'statusline.show_last_command') in a config
 * object that may use either nested or flat keys.
 */
function getConfigValue(cfg, keyPath) {
  if (!cfg || typeof cfg !== 'object') return undefined;
  if (keyPath in cfg) return cfg[keyPath];
  const parts = keyPath.split('.');
  let cur = cfg;
  for (const p of parts) {
    if (cur == null || typeof cur !== 'object' || !(p in cur)) return undefined;
    cur = cur[p];
  }
  return cur;
}

/**
 * Extract the most recently invoked slash command from a Claude Code JSONL
 * transcript file. Returns the command name (no leading slash) or null.
 *
 * Claude Code embeds slash invocations in user messages as
 *   <command-name>/foo</command-name>
 * We scan lines from the end of the file, stopping at the first match.
 */
function readLastSlashCommand(transcriptPath) {
  if (!transcriptPath || typeof transcriptPath !== 'string') return null;
  let content;
  try {
    if (!fs.existsSync(transcriptPath)) return null;
    // Read only the tail — typical transcripts grow large. 256 KiB comfortably
    // covers dozens of recent turns while staying cheap per render.
    const stat = fs.statSync(transcriptPath);
    const MAX = 256 * 1024;
    const start = Math.max(0, stat.size - MAX);
    const fd = fs.openSync(transcriptPath, 'r');
    try {
      const buf = Buffer.alloc(stat.size - start);
      fs.readSync(fd, buf, 0, buf.length, start);
      content = buf.toString('utf8');
    } finally {
      fs.closeSync(fd);
    }
  } catch (e) {
    return null;
  }
  // Find the LAST occurrence — scan right-to-left via lastIndexOf on the tag.
  const tagClose = '</command-name>';
  const idx = content.lastIndexOf(tagClose);
  if (idx < 0) return null;
  const openTag = '<command-name>';
  const openIdx = content.lastIndexOf(openTag, idx);
  if (openIdx < 0) return null;
  let name = content.slice(openIdx + openTag.length, idx).trim();
  // Strip a leading slash if present, and any trailing arguments-on-same-line noise.
  if (name.startsWith('/')) name = name.slice(1);
  // Command names in Claude Code transcripts are plain identifiers like "gsd-plan-phase"
  // or namespaced like "plugin:skill". Reject anything with whitespace/newlines/control chars.
  if (!name || /[\s\\"<>]/.test(name) || name.length > 80) return null;
  return name;
}

// --- GSD state reader -------------------------------------------------------

/**
 * Walk up from dir looking for .planning/STATE.md.
 * Returns parsed state object or null.
 */
function readGsdState(dir) {
  const home = os.homedir();
  let current = dir;
  for (let i = 0; i < 10; i++) {
    const candidate = path.join(current, '.planning', 'STATE.md');
    if (fs.existsSync(candidate)) {
      try {
        return parseStateMd(fs.readFileSync(candidate, 'utf8'));
      } catch (e) {
        return null;
      }
    }
    const parent = path.dirname(current);
    if (parent === current || current === home) break;
    current = parent;
  }
  return null;
}

/**
 * Parse STATE.md frontmatter + Phase line from body.
 *
 * Returns:
 *   { status, milestone, milestoneName, phaseNum, phaseTotal, phaseName,
 *     activePhase, nextAction, nextPhases, completedPhases, totalPhases, percent }
 */
function parseStateMd(content) {
  const state = {};
  const fmMatch = content.match(/^---\n([\s\S]*?)\n---/);
  if (fmMatch) {
    const fm = fmMatch[1];
    for (const line of fm.split('\n')) {
      const m = line.match(/^(\w+):\s*(.+)/);
      if (!m) continue;
      const [, key, val] = m;
      const v = val.trim().replace(/^['"]|['"]$/g, '');
      if (key === 'status') state.status = v === 'null' ? null : v;
      if (key === 'milestone') state.milestone = v === 'null' ? null : v;
      if (key === 'milestone_name') state.milestoneName = v === 'null' ? null : v;
      if (key === 'active_phase') state.activePhase = (v === 'null' || v === '') ? null : v;
      if (key === 'next_action') state.nextAction = (v === 'null' || v === '') ? null : v;
    }
    const npFlowMatch = fm.match(/^next_phases:\s*\[([^\]]*)\]/m);
    if (npFlowMatch) {
      const items = npFlowMatch[1].split(',').map(s => s.trim().replace(/^['"]|['"]$/g, '')).filter(Boolean);
      state.nextPhases = items.length > 0 ? items : null;
    } else {
      const npBlockMatch = fm.match(/^next_phases:\s*\n((?:[ \t]*-[ \t]*[^\n]+\n?)*)/m);
      if (npBlockMatch) {
        const items = npBlockMatch[1]
          .split('\n')
          .map(line => line.match(/^[ \t]*-[ \t]*(.+)$/))
          .filter(Boolean)
          .map(m => m[1].trim().replace(/^['"]|['"]$/g, ''))
          .filter(Boolean);
        state.nextPhases = items.length > 0 ? items : null;
      }
    }
    const progMatch = fm.match(/^progress:\s*\n((?:[ \t]+\w+:.*\n?)+)/m);
    if (progMatch) {
      const cp = progMatch[1].match(/^[ \t]+completed_phases:\s*(\d+)/m);
      const tp = progMatch[1].match(/^[ \t]+total_phases:\s*(\d+)/m);
      const pc = progMatch[1].match(/^[ \t]+percent:\s*(\d+)/m);
      if (cp) state.completedPhases = cp[1];
      if (tp) state.totalPhases = tp[1];
      if (pc) state.percent = pc[1];
    }
  }
  const phaseMatch = content.match(/^Phase:\s*(\d+)\s+of\s+(\d+)(?:\s+\(([^)]+)\))?/m);
  if (phaseMatch) {
    state.phaseNum = phaseMatch[1];
    state.phaseTotal = phaseMatch[2];
    state.phaseName = phaseMatch[3] || null;
  }
  if (!state.status) {
    const bodyStatus = content.match(/^Status:\s*(.+)/m);
    if (bodyStatus) {
      const raw = bodyStatus[1].trim().toLowerCase();
      if (raw.includes('ready to plan') || raw.includes('planning')) state.status = 'planning';
      else if (raw.includes('execut')) state.status = 'executing';
      else if (raw.includes('complet') || raw.includes('archived')) state.status = 'complete';
    }
  }
  return state;
}

function renderProgressBar(percent) {
  if (percent == null || isNaN(percent)) return '';
  const pct = Math.max(0, Math.min(100, parseInt(percent, 10)));
  const filled = Math.floor(pct / 10);
  const bar = '█'.repeat(filled) + '░'.repeat(10 - filled);
  return `[${bar}] ${pct}%`;
}

function formatGsdState(s) {
  const parts = [];
  if (s.milestone || s.milestoneName) {
    const ver = s.milestone || '';
    const name = (s.milestoneName && s.milestoneName !== 'milestone') ? s.milestoneName : '';
    const bar = renderProgressBar(s.percent);
    const pieces = [ver, name, bar].filter(Boolean);
    if (pieces.length > 0) parts.push(pieces.join(' '));
  }
  const phasesStr = (s.nextPhases && s.nextPhases.length > 0) ? s.nextPhases.join('/') : null;
  if (s.activePhase) {
    const stage = s.status || '';
    parts.push(stage ? `Phase ${s.activePhase} ${stage}` : `Phase ${s.activePhase}`);
  } else if (s.nextAction && phasesStr) {
    parts.push(`next ${s.nextAction} ${phasesStr}`);
  } else if (Number(s.percent) === 100 || (s.completedPhases && s.totalPhases && s.completedPhases === s.totalPhases)) {
    parts.push('milestone complete');
  } else {
    if (s.status) parts.push(s.status);
    if (s.phaseNum && s.phaseTotal) {
      const phase = s.phaseName
        ? `${s.phaseName} (${s.phaseNum}/${s.phaseTotal})`
        : `ph ${s.phaseNum}/${s.phaseTotal}`;
      parts.push(phase);
    }
  }
  return parts.join(' · ');
}

// --- stdin ------------------------------------------------------------------

function runStatusline() {
  let input = '';
  const stdinTimeout = setTimeout(() => process.exit(0), 3000);
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', chunk => input += chunk);
  process.stdin.on('end', () => {
    clearTimeout(stdinTimeout);
    try {
      const data = JSON.parse(input);
      const model = data.model?.display_name || 'Claude';
      const dir = data.workspace?.current_dir || process.cwd();
      const session = data.session_id || '';

      // Prefer explicit used/total tokens when available. Fall back to
      // remaining_percentage only when absolute counts are absent.
      const cw = data.context_window || {};
      const usedTokens = (cw.used_tokens != null) ? cw.used_tokens
        : (cw.current_usage && (cw.current_usage.input_tokens ?? cw.current_usage.used_tokens)) ?? null;
      const totalCtx = (cw.total_tokens != null) ? cw.total_tokens
        : (cw.max_tokens != null ? cw.max_tokens : null);
      const remaining = (cw.remaining_percentage != null) ? cw.remaining_percentage : null;

      let ctx = '';

      if (usedTokens != null && totalCtx != null && totalCtx > 0) {
        const usedPct = Math.max(0, Math.min(100, Math.round((usedTokens / totalCtx) * 100)));
        const filled = Math.floor(usedPct / 10);
        const bar = '█'.repeat(filled) + '░'.repeat(10 - filled);
        if (usedPct < 50) {
          ctx = ` \x1b[32m${bar} ${usedPct}%\x1b[0m`;
        } else if (usedPct < 65) {
          ctx = ` \x1b[33m${bar} ${usedPct}%\x1b[0m`;
        } else if (usedPct < 80) {
          ctx = ` \x1b[38;5;208m${bar} ${usedPct}%\x1b[0m`;
        } else {
          ctx = ` \x1b[5;31m💀 ${bar} ${usedPct}%\x1b[0m`;
        }

        const rawUsedPct = usedPct;
        const remPct = Math.max(0, Math.min(100, 100 - rawUsedPct));
        const sessionSafe = session && !/[/\\]|\.\./.test(session);
        if (sessionSafe) {
          try {
            const bridgePath = path.join(os.tmpdir(), `claude-ctx-${session}.json`);
            const bridgeData = JSON.stringify({
              session_id: session,
              remaining_percentage: remPct,
              used_pct: rawUsedPct,
              timestamp: Math.floor(Date.now() / 1000)
            });
            fs.writeFileSync(bridgePath, bridgeData);
          } catch (e) {}
        }

      } else if (remaining != null) {
        const acw = parseInt(process.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW || '0', 10);
        const AUTO_COMPACT_BUFFER_PCT = (totalCtx && acw > 0)
          ? Math.min(100, (acw / totalCtx) * 100)
          : 16.5;

        let used = 0;
        if (totalCtx != null && !isNaN(AUTO_COMPACT_BUFFER_PCT)) {
          const usableRemaining = Math.max(0, ((remaining - AUTO_COMPACT_BUFFER_PCT) / (100 - AUTO_COMPACT_BUFFER_PCT)) * 100);
          used = Math.max(0, Math.min(100, Math.round(100 - usableRemaining)));
        } else {
          used = Math.max(0, Math.min(100, Math.round(100 - remaining)));
        }

        const filled = Math.floor(used / 10);
        const bar = '█'.repeat(filled) + '░'.repeat(10 - filled);

        if (used < 50) {
          ctx = ` \x1b[32m${bar} ${used}%\x1b[0m`;
        } else if (used < 65) {
          ctx = ` \x1b[33m${bar} ${used}%\x1b[0m`;
        } else if (used < 80) {
          ctx = ` \x1b[38;5;208m${bar} ${used}%\x1b[0m`;
        } else {
          ctx = ` \x1b[5;31m💀 ${bar} ${used}%\x1b[0m`;
        }

        const rawUsedPct = Math.round(100 - remaining);
        const sessionSafe = session && !/[/\\]|\.\./.test(session);
        if (sessionSafe) {
          try {
            const bridgePath = path.join(os.tmpdir(), `claude-ctx-${session}.json`);
            const bridgeData = JSON.stringify({
              session_id: session,
              remaining_percentage: remaining,
              used_pct: rawUsedPct,
              timestamp: Math.floor(Date.now() / 1000)
            });
            fs.writeFileSync(bridgePath, bridgeData);
          } catch (e) { /* swallow */ }
        }
      }

      // Current task from todos
      let task = '';
      const homeDir = os.homedir();
      const claudeDir = process.env.CLAUDE_CONFIG_DIR || path.join(homeDir, '.claude');
      const todosDir = path.join(claudeDir, 'todos');
      if (session && fs.existsSync(todosDir)) {
        try {
          const files = fs.readdirSync(todosDir)
            .filter(f => f.startsWith(session) && f.includes('-agent-') && f.endsWith('.json'))
            .map(f => ({ name: f, mtime: fs.statSync(path.join(todosDir, f)).mtime }))
            .sort((a, b) => b.mtime - a.mtime);

          if (files.length > 0) {
            try {
              const todos = JSON.parse(fs.readFileSync(path.join(todosDir, files[0].name), 'utf8'));
              const inProgress = todos.find(t => t.status === 'in_progress');
              if (inProgress) task = inProgress.activeForm || '';
            } catch (e) {}
          }
        } catch (e) {
          // Silently fail on file system errors - don't break statusline
        }
      }

      const gsdStateStr = task ? '' : formatGsdState(readGsdState(dir) || {});

      let gsdUpdate = '';
      const sharedCacheFile = path.join(homeDir, '.cache', 'gsd', 'gsd-update-check.json');
      const legacyCacheFile = path.join(claudeDir, 'cache', 'gsd-update-check.json');
      const cacheFile = fs.existsSync(sharedCacheFile) ? sharedCacheFile : legacyCacheFile;
      if (fs.existsSync(cacheFile)) {
        try {
          const cache = JSON.parse(fs.readFileSync(cacheFile, 'utf8'));
          if (cache.update_available) {
            gsdUpdate = '\x1b[33m⬆ /gsd:update\x1b[0m │ ';
          }
          if (cache.stale_hooks && cache.stale_hooks.length > 0) {
            const isDevInstall = (() => {
              if (!cache.installed || !cache.latest || cache.latest === 'unknown') return false;
              const parseV = v => v.replace(/^v/, '').split('.').map(Number);
              const [ai, bi, ci] = parseV(cache.installed);
              const [an, bn, cn] = parseV(cache.latest);
              return ai > an || (ai === an && bi > bn) || (ai === an && bi === bn && ci > cn);
            })();
            if (isDevInstall) {
              gsdUpdate += '\x1b[33m⚠ dev install — re-run installer to sync hooks\x1b[0m │ ';
            } else {
              gsdUpdate += '\x1b[31m⚠ stale hooks — run /gsd:update\x1b[0m │ ';
            }
          }
        } catch (e) {}
      }

      let lastCmdSuffix = '';
      let position = 'end';
      try {
        const cfg = readGsdConfig(dir);
        if (getConfigValue(cfg, 'statusline.show_last_command') === true) {
          const transcriptPath = data.transcript_path;
          const lastCmd = readLastSlashCommand(transcriptPath);
          if (lastCmd) {
            lastCmdSuffix = ` │ \x1b[2mlast: /${lastCmd}\x1b[0m`;
          }
        }
        const cfgPos = getConfigValue(cfg, 'statusline.context_position');
        if (cfgPos != null) position = cfgPos;
      } catch (e) { }

      const dirname = path.basename(dir);
      const middle = task
        ? `\x1b[1m${task}\x1b[0m`
        : gsdStateStr
          ? `\x1b[2m${gsdStateStr}\x1b[0m`
          : null;

      process.stdout.write(composeStatusline({ gsdUpdate, model, ctx, middle, dirname, lastCmdSuffix, position }));
    } catch (e) {
      // Silent fail - don't break statusline on parse errors
    }
  });
}

// --- Layout composer --------------------------------------------------------

function composeStatusline({
  gsdUpdate = '',
  model,
  ctx = '',
  middle = null,
  dirname,
  lastCmdSuffix = '',
  position = 'end',
} = {}) {
  const modelSeg = `\x1b[2m${model}\x1b[0m`;
  const dirSeg = `\x1b[2m${dirname}\x1b[0m`;
  const pos = position === 'front' ? 'front' : 'end';

  if (pos === 'front') {
    if (middle) return `${gsdUpdate}${modelSeg}${ctx} │ ${middle} │ ${dirSeg}${lastCmdSuffix}`;
    return `${gsdUpdate}${modelSeg}${ctx} │ ${dirSeg}${lastCmdSuffix}`;
  }
  if (middle) return `${gsdUpdate}${modelSeg} │ ${middle} │ ${dirSeg}${ctx}${lastCmdSuffix}`;
  return `${gsdUpdate}${modelSeg} │ ${dirSeg}${ctx}${lastCmdSuffix}`;
}

module.exports = {
  readGsdState, parseStateMd, formatGsdState,
  readGsdConfig, getConfigValue, readLastSlashCommand,
  composeStatusline,
};

function renderStatusline(data) {
  const model = data.model?.display_name || 'Claude';
  const dir = data.workspace?.current_dir || process.cwd();
  const dirname = path.basename(dir);

  let lastCmdSuffix = '';
  let position = 'end';
  try {
    const cfg = readGsdConfig(dir);
    if (getConfigValue(cfg, 'statusline.show_last_command') === true) {
      const lastCmd = readLastSlashCommand(data.transcript_path);
      if (lastCmd) {
        lastCmdSuffix = ` │ \x1b[2mlast: /${lastCmd}\x1b[0m`;
      }
    }
    const cfgPos = getConfigValue(cfg, 'statusline.context_position');
    if (cfgPos != null) position = cfgPos;
  } catch (e) { /* swallow */ }

  const gsdStateStr = formatGsdState(readGsdState(dir) || {});
  const middle = gsdStateStr ? `\x1b[2m${gsdStateStr}\x1b[0m` : null;
  return composeStatusline({ model, ctx: '', middle, dirname, lastCmdSuffix, position });
}

module.exports.renderStatusline = renderStatusline;

if (require.main === module) runStatusline();
