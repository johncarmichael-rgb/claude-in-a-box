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

# ----- copy USER CONFIG (not credentials) from the read-only host mount into a -----
# writable per-container home. The host's .credentials.json is deliberately NOT
# copied: it holds a single-use OAuth refresh token, so a copy that refreshes in
# here would invalidate the host's login (and every later run). Auth for
# non---fresh runs comes from CLAUDE_CODE_OAUTH_TOKEN instead (a long-lived
# 'claude setup-token' token that never refreshes) — see run.sh.
copy_if_present() { [ -e "$1" ] && cp -a "$1" "$2" || true; }
if [ -d /claude-host ]; then
  copy_if_present /claude-host/settings.json     "$AGENT_HOME/.claude/settings.json"
  copy_if_present /claude-host/CLAUDE.md         "$AGENT_HOME/.claude/CLAUDE.md"
fi
copy_if_present /claude-host.json "$AGENT_HOME/.claude.json"

# ----- install bundled skills -----
# Skills baked into the image at /opt/claude-skills (from this repo's ./skills).
# Copy them into ~/.claude/skills AFTER the host-config copy and any home mount,
# so they're present and auto-discovered in every mode (normal and --fresh, where
# run.sh mounts over the home). Claude loads them automatically and selects the
# right one per task based on each skill's description.
if [ -d /opt/claude-skills ]; then
  mkdir -p "$AGENT_HOME/.claude/skills"
  cp -a /opt/claude-skills/. "$AGENT_HOME/.claude/skills/"
fi

chown -R "$HOST_UID:$HOST_GID" "$AGENT_HOME"

# ----- auth check -----
# --fresh: a saved in-container login (.credentials.json on the mounted home).
# default: CLAUDE_CODE_OAUTH_TOKEN (long-lived setup-token), else ANTHROPIC_API_KEY.
FRESH="${CLAUDE_FRESH:-0}"
if [ "$FRESH" = "1" ] && [ -f "$AGENT_HOME/.claude/.credentials.json" ]; then
  echo "Auth: using saved fresh session (host login NOT inherited)"
elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "Auth: using long-lived host token (CLAUDE_CODE_OAUTH_TOKEN from 'claude setup-token')"
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
  echo "ERROR: No auth found. Run 'claude setup-token' on the host and give run.sh" >&2
  echo "       the token ('./run.sh token', or export CLAUDE_CODE_OAUTH_TOKEN)," >&2
  echo "       or pass ANTHROPIC_API_KEY." >&2
  exit 1
fi

if [ -n "$TASK" ]; then
  MODE="headless (one-shot, then exit)"
else
  MODE="interactive (normal Claude TUI)"
fi

# ----- history / resume handling -----
# History is RECORDED BY DEFAULT: run.sh bind-mounts the project's transcript
# store over .claude/projects, so Claude's transcripts outlive the --rm teardown.
#   default     -> start a NEW session (recorded, resumable later)
#   --resume    -> continue a recorded session (interactive: pick from Claude's
#                  native list; headless: most recent)
#   --ephemeral -> store not mounted; the transcript is discarded on exit
RESUME="${CLAUDE_RESUME:-0}"
EPHEMERAL="${CLAUDE_EPHEMERAL:-0}"
RESUME_FLAG=()
HISTORY_NOTE=""
if [ "$EPHEMERAL" = "1" ]; then
  HISTORY_NOTE="ephemeral (not recorded — discarded on exit)"
elif [ "$RESUME" = "1" ]; then
  if [ -n "$TASK" ]; then
    # Headless: no interactive TTY for a picker, so continue the most recent.
    # '--continue' exits non-zero when nothing is recorded, so only pass it when
    # a transcript exists — and say so loudly when one doesn't.
    if find "$AGENT_HOME/.claude/projects" -name '*.jsonl' -type f 2>/dev/null | grep -q .; then
      RESUME_FLAG=(--continue)
      HISTORY_NOTE="resume (headless — continuing most recent session)"
    else
      HISTORY_NOTE="resume requested, but no prior session — recording a new one"
      echo "WARNING: --resume requested but <project>/.claude-box has no transcripts;" >&2
      echo "         running the task as a NEW session instead." >&2
    fi
  else
    # Interactive: ALWAYS pass '--resume' (no id). It opens Claude's native
    # session picker; if nothing is recorded Claude shows "No conversations
    # found" rather than silently dropping you into a fresh, empty session.
    RESUME_FLAG=(--resume)
    if find "$AGENT_HOME/.claude/projects" -name '*.jsonl' -type f 2>/dev/null | grep -q .; then
      HISTORY_NOTE="resume (pick a session from the list)"
    else
      HISTORY_NOTE="resume requested, but <project>/.claude-box has NO transcripts — expect 'No conversations found'"
    fi
  fi
else
  HISTORY_NOTE="recording a new session (resume later with --resume)"
fi

# ----- permission mode -----
# By default we pass --dangerously-skip-permissions for full autonomy (the managed
# git hook and rm deny rules still apply regardless — see managed-settings.json).
# Some models (e.g. Fable) refuse to start under --dangerously-skip-permissions;
# set CLAUDE_SKIP_PERMISSIONS=0 (run.sh --safe) to drop the flag so Claude runs
# with normal permission prompting instead.
SKIP_PERMS="${CLAUDE_SKIP_PERMISSIONS:-1}"
PERM_FLAG=()
if [ "$SKIP_PERMS" = "1" ]; then
  PERM_FLAG=(--dangerously-skip-permissions)
  PERM_NOTE="skip-permissions (full autonomy; managed git/rm guards still apply)"
else
  PERM_NOTE="normal prompting (--dangerously-skip-permissions OFF)"
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
echo " History: $HISTORY_NOTE"
[ -n "$TASK" ] && echo " Task:    $TASK"
echo " git:     pull/log/diff ALLOWED; all other git DENIED (managed hook)"
echo " rm/rmdir: DENIED (enforced via managed settings)"
echo " perms:   $PERM_NOTE"
if [ -d "$AGENT_HOME/.claude/skills" ]; then
  SKILL_COUNT="$(find "$AGENT_HOME/.claude/skills" -maxdepth 2 -name SKILL.md 2>/dev/null | wc -l | tr -d ' ')"
  [ "$SKILL_COUNT" -gt 0 ] && echo " skills:  $SKILL_COUNT loaded (auto-selected per task)"
fi
echo "=========================================="
if [ -z "$TASK" ]; then
  echo
  echo " NOTE: Claude's first-run prompt will ask you to trust \"/workspace\"."
  echo "       That IS your project above — it just lives at /workspace inside"
  echo "       the container. Choose \"Yes, I trust this folder\" to continue."
fi
echo

GUARD="In this sandbox you may ONLY use these git commands: 'git pull', 'git log', and 'git diff'. All other git commands (push, commit, add, checkout, reset, merge, etc.) are denied — leave them to the human. rm and rmdir are also disabled. Do not attempt any of the denied commands."

cd /workspace

# Drop to the host UID and set HOME for both modes. --dangerously-skip-permissions
# (default) gives full autonomy; the managed git hook and rm deny rules still apply
# regardless. With CLAUDE_SKIP_PERMISSIONS=0 the flag is omitted (PERM_FLAG empty)
# so Claude prompts for permissions normally — needed for models like Fable that
# refuse to run under --dangerously-skip-permissions.
if [ -n "$TASK" ]; then
  # Headless: work the task and exit.
  if [ "$SKIP_PERMS" != "1" ]; then
    echo " NOTE: headless run with permission prompting ON — Claude may block" >&2
    echo "       waiting for approvals it can't receive without a TTY." >&2
  fi
  exec gosu "$AGENT_USER" env HOME="$AGENT_HOME" \
    claude "${PERM_FLAG[@]}" \
           "${RESUME_FLAG[@]}" \
           --append-system-prompt "$GUARD" \
           -p "$TASK"
else
  # Interactive: drop you into the normal Claude interface, scoped to /workspace.
  exec gosu "$AGENT_USER" env HOME="$AGENT_HOME" \
    claude "${PERM_FLAG[@]}" \
           "${RESUME_FLAG[@]}" \
           --append-system-prompt "$GUARD"
fi
