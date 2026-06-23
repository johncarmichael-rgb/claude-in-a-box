#!/usr/bin/env node
// PreToolUse hook: gate `git` inside Claude-in-a-Box.
//
// Why a hook and not a permission rule? In Claude Code, permission rules are
// evaluated deny -> ask -> allow, and "rule specificity does not change the
// order": a broad `deny Bash(git:*)` blocks every git call and CANNOT carry an
// allowlist exception like `allow Bash(git pull:*)`. So to permit a *subset* of
// git while blocking the rest we inspect the command in a PreToolUse hook, which
// can return a per-call deny that holds even under --dangerously-skip-permissions.
//
// Threat model matches the rest of this box: a COOPERATIVE agent. We catch
// direct git invocations (including leading env-assignments, common wrappers,
// absolute paths, and git global flags before the subcommand). We do NOT chase
// git smuggled through `bash -c "git ..."` — same caveat the README documents
// for the old managed deny rule. Tighten here if you need airtight enforcement.

const fs = require('fs');

// Only these git subcommands are allowed. `pull` to fetch upstream changes;
// `log` and `diff` so the agent can learn from history. Extend as needed.
const ALLOWED = new Set(['pull', 'log', 'diff']);

// Command prefixes that wrap another command; skip them to find the real argv0.
const WRAPPERS = new Set([
  'env', 'sudo', 'command', 'builtin', 'exec',
  'time', 'timeout', 'nice', 'nohup', 'stdbuf', 'xargs',
]);

// git global flags that take a value (so we skip the value too when hunting for
// the subcommand). Everything else starting with '-' is a valueless global flag.
const GIT_FLAGS_WITH_VALUE = new Set([
  '-C', '-c', '--git-dir', '--work-tree', '--namespace', '--exec-path',
  '--super-prefix', '--config-env',
]);

function readStdin() {
  try { return fs.readFileSync(0, 'utf8'); } catch { return ''; }
}

function deny(reason) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: reason,
    },
  }));
  process.exit(0);
}

// Falling through (exit 0, no decision) defers to normal permission handling;
// under --dangerously-skip-permissions that means the command runs.
function allow() { process.exit(0); }

function basename(tok) { return tok.replace(/^.*\//, ''); }

// Find the git subcommand in a single command segment, or undefined if the
// segment is not a git invocation.
function gitSubcommand(segment) {
  const tokens = segment.trim().split(/\s+/).filter(Boolean);
  let i = 0;
  // Strip leading VAR=value assignments and command wrappers (env, sudo, ...).
  while (i < tokens.length) {
    const t = tokens[i];
    if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(t)) { i++; continue; }
    if (WRAPPERS.has(basename(t))) { i++; continue; }
    break;
  }
  if (i >= tokens.length) return undefined;
  if (basename(tokens[i]) !== 'git') return undefined;

  // argv0 is git: walk past global flags to the subcommand.
  let j = i + 1;
  while (j < tokens.length) {
    const tk = tokens[j];
    if (GIT_FLAGS_WITH_VALUE.has(tk)) { j += 2; continue; }
    if (tk.startsWith('-')) { j++; continue; }
    return tk;
  }
  return ''; // bare `git` with no subcommand
}

// Scan a full Bash command string and return a deny reason if it contains a
// disallowed git invocation, or null if it's fine to run. Pure + side-effect
// free so it can be unit tested directly.
function denyReason(command) {
  if (!command || typeof command !== 'string') return null;
  // Split into independently-run subcommands on shell separators.
  const segments = command.split(/&&|\|\||;|\||\n/);
  for (const seg of segments) {
    const sub = gitSubcommand(seg);
    if (sub === undefined) continue; // not a git command
    if (!ALLOWED.has(sub)) {
      return (
        `git '${sub || '(no subcommand)'}' is blocked in this sandbox. ` +
        `Only 'git pull', 'git log', and 'git diff' are permitted — leave ` +
        `all other version-control actions to the human running this container.`
      );
    }
  }
  return null;
}

// Decide on a parsed PreToolUse payload. Returns the hookSpecificOutput object
// to emit (a deny), or null to fall through (allow).
function evaluate(data) {
  if (!data || data.tool_name !== 'Bash') return null;
  const command = data.tool_input && data.tool_input.command;
  const reason = denyReason(command);
  if (!reason) return null;
  return {
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: reason,
    },
  };
}

function main() {
  let data = {};
  try { data = JSON.parse(readStdin()); } catch { allow(); }
  const output = evaluate(data);
  if (output) deny(output.hookSpecificOutput.permissionDecisionReason);
  allow();
}

module.exports = { ALLOWED, gitSubcommand, denyReason, evaluate };

if (require.main === module) main();
