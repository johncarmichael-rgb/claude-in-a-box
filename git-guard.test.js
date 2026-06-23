// Unit + integration tests for git-guard.js (the PreToolUse hook).
// Run with:  node --test
//        or: node --test git-guard.test.js

'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const path = require('node:path');

const {
  ALLOWED,
  gitSubcommand,
  denyReason,
  evaluate,
} = require('./git-guard.js');

const GUARD = path.join(__dirname, 'git-guard.js');

// Run the hook as the real subprocess does: feed a hook payload on stdin and
// return { stdout, exit }. The hook always exits 0; a deny is signalled by a
// non-empty JSON body on stdout.
function runHook(payload) {
  const input = typeof payload === 'string' ? payload : JSON.stringify(payload);
  let stdout = '';
  let exit = 0;
  try {
    stdout = execFileSync('node', [GUARD], { input, encoding: 'utf8' });
  } catch (err) {
    exit = err.status ?? 1;
    stdout = (err.stdout || '').toString();
  }
  return { stdout, exit };
}

function bash(command) {
  return { tool_name: 'Bash', tool_input: { command } };
}

// ---------------------------------------------------------------------------
// gitSubcommand — argv parsing
// ---------------------------------------------------------------------------

test('gitSubcommand: returns undefined for non-git commands', () => {
  assert.equal(gitSubcommand('ls -la'), undefined);
  assert.equal(gitSubcommand('npm run digit'), undefined); // "git" substring, not the binary
  assert.equal(gitSubcommand(''), undefined);
  assert.equal(gitSubcommand('   '), undefined);
});

test('gitSubcommand: extracts the subcommand', () => {
  assert.equal(gitSubcommand('git pull'), 'pull');
  assert.equal(gitSubcommand('git log --oneline -10'), 'log');
  assert.equal(gitSubcommand('git diff HEAD~1'), 'diff');
  assert.equal(gitSubcommand('git push origin main'), 'push');
});

test('gitSubcommand: bare git yields empty string', () => {
  assert.equal(gitSubcommand('git'), '');
});

test('gitSubcommand: resolves the basename of an absolute path', () => {
  assert.equal(gitSubcommand('/usr/bin/git push'), 'push');
  assert.equal(gitSubcommand('/usr/local/bin/git pull'), 'pull');
});

test('gitSubcommand: strips leading env-assignments', () => {
  assert.equal(gitSubcommand('GIT_SSH=x git pull'), 'pull');
  assert.equal(gitSubcommand('A=1 B=2 git push'), 'push');
});

test('gitSubcommand: strips zero-arg command wrappers', () => {
  assert.equal(gitSubcommand('sudo git status'), 'status');
  assert.equal(gitSubcommand('env git pull'), 'pull');
  assert.equal(gitSubcommand('nohup git push'), 'push');
});

test('gitSubcommand: known gap — wrappers that take args are NOT followed', () => {
  // The guard skips a wrapper token but not the wrapper's own arguments, so a
  // git hidden behind e.g. `timeout 10 ...` reads as a non-git command and
  // falls through. Acceptable under the cooperative-agent threat model; pinned
  // here so the limitation is explicit and changes to it are deliberate.
  assert.equal(gitSubcommand('timeout 10 git push'), undefined);
  assert.equal(gitSubcommand('xargs -n1 git push'), undefined);
});

test('gitSubcommand: skips git global flags before the subcommand', () => {
  assert.equal(gitSubcommand('git -C /workspace log'), 'log');
  assert.equal(gitSubcommand('git -c user.name=x push'), 'push');
  assert.equal(gitSubcommand('git --no-pager log'), 'log');
  assert.equal(gitSubcommand('git --git-dir=/tmp/x log'), 'log');
});

// ---------------------------------------------------------------------------
// denyReason — full command-string scanning
// ---------------------------------------------------------------------------

test('denyReason: allows the permitted subcommands', () => {
  assert.equal(denyReason('git pull'), null);
  assert.equal(denyReason('git pull origin main'), null);
  assert.equal(denyReason('git log --oneline -10'), null);
  assert.equal(denyReason('git diff HEAD~1'), null);
});

test('denyReason: denies everything else git', () => {
  for (const cmd of [
    'git push origin main',
    'git commit -m hello',
    'git add .',
    'git checkout -b foo',
    'git reset --hard',
    'git merge main',
    'git', // bare
  ]) {
    assert.ok(denyReason(cmd), `expected deny for: ${cmd}`);
  }
});

test('denyReason: allows non-git commands', () => {
  assert.equal(denyReason('ls -la'), null);
  assert.equal(denyReason('npm run digit'), null);
  assert.equal(denyReason('echo "git push is just text here"'), null);
});

test('denyReason: ignores empty / non-string input', () => {
  assert.equal(denyReason(''), null);
  assert.equal(denyReason(undefined), null);
  assert.equal(denyReason(null), null);
  assert.equal(denyReason(42), null);
});

test('denyReason: inspects each segment across shell separators', () => {
  // allowed-only chains stay allowed
  assert.equal(denyReason('cd /workspace && git pull'), null);
  assert.equal(denyReason('git log | head -5'), null);
  assert.equal(denyReason('git diff; git log'), null);

  // a denied git anywhere in the chain trips the guard
  assert.ok(denyReason('git diff && git push'));
  assert.ok(denyReason('cd /tmp && git commit -m x'));
  assert.ok(denyReason('git log || git reset --hard'));
  assert.ok(denyReason('echo hi | git push'));
});

test('denyReason: reason names the offending subcommand', () => {
  assert.match(denyReason('git push'), /git 'push' is blocked/);
  assert.match(denyReason('git'), /\(no subcommand\)/);
});

// ---------------------------------------------------------------------------
// evaluate — decision on a parsed payload
// ---------------------------------------------------------------------------

test('evaluate: returns null (allow) for non-Bash tools', () => {
  assert.equal(evaluate({ tool_name: 'Read', tool_input: { file_path: '/x' } }), null);
  assert.equal(evaluate({ tool_name: 'Edit', tool_input: {} }), null);
});

test('evaluate: returns null for malformed / empty payloads', () => {
  assert.equal(evaluate(null), null);
  assert.equal(evaluate({}), null);
  assert.equal(evaluate({ tool_name: 'Bash' }), null); // no tool_input
  assert.equal(evaluate({ tool_name: 'Bash', tool_input: {} }), null); // no command
});

test('evaluate: returns null for allowed git', () => {
  assert.equal(evaluate(bash('git pull')), null);
  assert.equal(evaluate(bash('git diff')), null);
});

test('evaluate: returns a well-formed deny object for blocked git', () => {
  const out = evaluate(bash('git push origin main'));
  assert.deepEqual(Object.keys(out), ['hookSpecificOutput']);
  assert.equal(out.hookSpecificOutput.hookEventName, 'PreToolUse');
  assert.equal(out.hookSpecificOutput.permissionDecision, 'deny');
  assert.match(out.hookSpecificOutput.permissionDecisionReason, /git 'push' is blocked/);
});

test('ALLOWED is exactly pull/log/diff', () => {
  assert.deepEqual([...ALLOWED].sort(), ['diff', 'log', 'pull']);
});

// ---------------------------------------------------------------------------
// Integration — the actual stdin -> stdout hook contract
// ---------------------------------------------------------------------------

test('hook: allowed git produces no output and exits 0', () => {
  const { stdout, exit } = runHook(bash('git pull origin main'));
  assert.equal(exit, 0);
  assert.equal(stdout.trim(), '');
});

test('hook: blocked git emits a deny payload and exits 0', () => {
  const { stdout, exit } = runHook(bash('git push origin main'));
  assert.equal(exit, 0);
  const decision = JSON.parse(stdout);
  assert.equal(decision.hookSpecificOutput.permissionDecision, 'deny');
  assert.match(decision.hookSpecificOutput.permissionDecisionReason, /Only 'git pull'/);
});

test('hook: non-Bash tool falls through to allow', () => {
  const { stdout, exit } = runHook({ tool_name: 'Read', tool_input: { file_path: '/x' } });
  assert.equal(exit, 0);
  assert.equal(stdout.trim(), '');
});

test('hook: malformed JSON on stdin falls through to allow (fails open)', () => {
  const { stdout, exit } = runHook('not json at all');
  assert.equal(exit, 0);
  assert.equal(stdout.trim(), '');
});

test('hook: empty stdin falls through to allow', () => {
  const { stdout, exit } = runHook('');
  assert.equal(exit, 0);
  assert.equal(stdout.trim(), '');
});
