#!/bin/bash
set -euo pipefail

# ----- input -----
# TASK is optional. If set, Claude runs headless (-p) on that task and exits.
# If empty/unset, Claude launches in INTERACTIVE mode (the normal TUI) so you
# can use plan mode, paste spec sheets, and work back-and-forth.
TASK="${TASK:-}"

HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"
AGENT_HOME=/home/agent

# ----- ensure a user matching the host UID/GID exists -----
# Files written to /workspace end up owned by you (not root), and git inside the
# container sees a matching owner so there is no "dubious ownership" error.
# node:20 already ships a 'node' user at UID 1000, so reuse whatever user owns
# the host UID; only create 'agent' if nothing does.
mkdir -p "$AGENT_HOME/.claude"
if getent passwd "$HOST_UID" >/dev/null; then
  AGENT_USER="$(getent passwd "$HOST_UID" | cut -d: -f1)"
else
  AGENT_USER=agent
  getent group "$HOST_GID" >/dev/null || groupadd -g "$HOST_GID" agent
  useradd -u "$HOST_UID" -g "$HOST_GID" -M -d "$AGENT_HOME" -s /bin/bash agent
fi

# ----- copy auth + user config from the read-only host mount into a writable -----
# per-container home. Token refresh then works AND never writes back to the host,
# so a container can't corrupt your host credential file.
copy_if_present() { [ -e "$1" ] && cp -a "$1" "$2" || true; }
if [ -d /claude-host ]; then
  copy_if_present /claude-host/.credentials.json "$AGENT_HOME/.claude/.credentials.json"
  copy_if_present /claude-host/settings.json     "$AGENT_HOME/.claude/settings.json"
  copy_if_present /claude-host/CLAUDE.md         "$AGENT_HOME/.claude/CLAUDE.md"
fi
copy_if_present /claude-host.json "$AGENT_HOME/.claude.json"
chown -R "$HOST_UID:$HOST_GID" "$AGENT_HOME"

# ----- auth check (the real credential file is .credentials.json) -----
FRESH="${CLAUDE_FRESH:-0}"
if [ -f "$AGENT_HOME/.claude/.credentials.json" ]; then
  if [ "$FRESH" = "1" ]; then
    echo "Auth: using saved fresh session (host login NOT inherited)"
  else
    echo "Auth: using inherited host login session"
  fi
elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  echo "Auth: using ANTHROPIC_API_KEY"
elif [ "$FRESH" = "1" ] && [ -z "$TASK" ]; then
  # Fresh + interactive + no saved login yet: that's expected on first run. Let
  # Claude start so you can log in (run /login). It'll be saved for next time.
  echo "Auth: no saved session yet — log in when Claude starts (use /login)."
  echo "      Your login is saved under ./.sessions/${CLAUDE_INSTANCE:-?} for next time."
elif [ "$FRESH" = "1" ]; then
  echo "ERROR: --fresh headless run needs a saved session or ANTHROPIC_API_KEY." >&2
  echo "       Start an interactive '--fresh' run first and log in, then re-run." >&2
  exit 1
else
  echo "ERROR: No auth found. Either log in on the host with 'claude login'" >&2
  echo "       (so ~/.claude/.credentials.json exists), or pass ANTHROPIC_API_KEY." >&2
  exit 1
fi

if [ -n "$TASK" ]; then
  MODE="headless (one-shot, then exit)"
else
  MODE="interactive (normal Claude TUI)"
fi

# ----- resume handling -----
# When --resume is set, the project's transcript store is bind-mounted over
# .claude/projects. If a prior transcript exists, continue it; otherwise start
# fresh (this run seeds the store for next time).
RESUME="${CLAUDE_RESUME:-0}"
RESUME_FLAG=()
RESUME_NOTE=""
if [ "$RESUME" = "1" ]; then
  if find "$AGENT_HOME/.claude/projects" -name '*.jsonl' -type f 2>/dev/null | grep -q .; then
    RESUME_FLAG=(--continue)
    RESUME_NOTE="resume (continuing most recent session)"
  else
    RESUME_NOTE="resume (no prior session — starting fresh, will be saved)"
  fi
fi

HOST_PROJECT_PATH="${HOST_PROJECT_PATH:-}"

echo
echo "=========================================="
echo " Claude in a Box"
[ -n "$HOST_PROJECT_PATH" ] && echo " Project: $HOST_PROJECT_PATH"
echo "          (mounted inside the container as /workspace)"
echo " Mode:    $MODE"
if [ "$FRESH" = "1" ]; then
  echo " Session: fresh (host login NOT inherited; saved per instance)"
else
  echo " Session: inherited from host"
fi
[ -n "$RESUME_NOTE" ] && echo " History: $RESUME_NOTE"
[ -n "$TASK" ] && echo " Task:    $TASK"
echo " git/rm:  DENIED (enforced via managed settings)"
echo "=========================================="
if [ -z "$TASK" ]; then
  echo
  echo " NOTE: Claude's first-run prompt will ask you to trust \"/workspace\"."
  echo "       That IS your project above — it just lives at /workspace inside"
  echo "       the container. Choose \"Yes, I trust this folder\" to continue."
fi
echo

GUARD="git, rm and rmdir are disabled in this sandbox and will be denied. Do not attempt them. Leave version control and file deletion to the human running this container."

cd /workspace

# Drop to the host UID and set HOME for both modes. --dangerously-skip-permissions
# gives full autonomy; the managed deny rules still block git/rm regardless.
if [ -n "$TASK" ]; then
  # Headless: work the task and exit.
  exec gosu "$AGENT_USER" env HOME="$AGENT_HOME" \
    claude --dangerously-skip-permissions \
           "${RESUME_FLAG[@]}" \
           --append-system-prompt "$GUARD" \
           -p "$TASK"
else
  # Interactive: drop you into the normal Claude interface, scoped to /workspace.
  exec gosu "$AGENT_USER" env HOME="$AGENT_HOME" \
    claude --dangerously-skip-permissions \
           "${RESUME_FLAG[@]}" \
           --append-system-prompt "$GUARD"
fi
