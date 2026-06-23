#!/bin/bash
set -euo pipefail
# Usage: ./run.sh [--fresh] <project_path> ["<task>"] [instance_name]

# ----- option parsing -----
# --fresh / --no-inherit: don't inherit the host login session. Start a brand new
# one instead (handy when you have several Claude Max accounts and want this box
# logged into a different account than your host). The new login is saved per
# instance under ./.sessions/<instance> so it survives container restarts. On a
# later run that reuses a saved login, you're shown which account (email) it is
# and asked to confirm — answer 'n' to drop it and log in as someone else.
#
# Session history is RECORDED BY DEFAULT: every run's transcript is persisted
# inside the project at <project>/.claude-box/ (auto git-ignored) so it survives
# the --rm teardown and can be resumed later.
# --resume: instead of starting a new session, pick a recorded one to continue
#   (interactive shows Claude's native session picker; headless continues the
#   most recent session).
# --ephemeral / --no-history: opt OUT of recording. Burnable session — nothing is
#   written to the project and the transcript is discarded on exit.
FRESH=0
RESUME=0
EPHEMERAL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --fresh|--no-inherit) FRESH=1; shift ;;
    --resume|--continue) RESUME=1; shift ;;
    --ephemeral|--no-history) EPHEMERAL=1; shift ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) break ;;
  esac
done

# --resume needs recorded history to resume FROM; --ephemeral throws it away.
if [ "$RESUME" -eq 1 ] && [ "$EPHEMERAL" -eq 1 ]; then
  echo "Error: --resume and --ephemeral are mutually exclusive (nothing to resume from a burnable session)." >&2
  exit 1
fi

PROJECT_PATH="${1:-}"
TASK="${2:-}"
# Instance name is OPTIONAL. If given, the container is named claude-in-a-box-<name>
# (predictable name; also the slot for --fresh logins under .sessions/<name>). If
# omitted, we leave --name off so Docker auto-assigns a unique random name — that
# lets you run N containers in parallel without naming any of them.
INSTANCE="${3:-}"
INSTANCE_KEY="${INSTANCE:-default}"   # stable key for .sessions when unnamed

if [ -z "$PROJECT_PATH" ]; then
  cat <<'EOF'

Usage: ./run.sh [--fresh] [--resume|--ephemeral] <project_path> ["<task>"] [instance_name]

Interactive (default) — opens the normal Claude Code interface inside the
container, scoped to your project. The session is RECORDED to
<project>/.claude-box (auto git-ignored) so you can resume it later:
  ./run.sh ~/code/weave

Resume — instead of starting a new session, choose a recorded one to continue.
Interactive shows Claude's native session picker; headless continues the most
recent session:
  ./run.sh --resume ~/code/weave

Ephemeral — opt out of recording. Burnable session: nothing is written to the
project and the transcript is discarded on exit:
  ./run.sh --ephemeral ~/code/weave

Headless single run — give a task and Claude works on it autonomously, then
exits (also recorded unless you pass --ephemeral):
  ./run.sh ~/code/weave "add input validation to the OAuth flow"

Fresh session — do NOT inherit the host login. Start a brand new one and log
in inside the container (useful when you have several Claude Max accounts and
want this box on a different one than your host). The login is saved per
instance under ./.sessions/<instance> and reused on the next run:
  ./run.sh --fresh ~/code/weave              # interactive; log in when it starts
  ./run.sh --fresh ~/code/weave "" work      # same, saved under instance "work"

Parallel — the instance name is OPTIONAL. Omit it and Docker auto-assigns a
unique random container name, so you can launch as many as you like with no
bookkeeping (separate terminals, or append & to background them):
  ./run.sh ~/code/weave "task A"
  ./run.sh ~/code/weave "task B"
  ./run.sh ~/code/weave                # interactive
Name them explicitly only if you want a predictable container name or a
specific --fresh login slot (the empty "" is just a placeholder for the task):
  ./run.sh ~/code/weave "task A" a
  ./run.sh ~/code/weave "" c           # interactive, named instance c

Note: parallel agents share the same files. Give them non-overlapping work,
or they may clobber each other's edits.
EOF
  exit 1
fi

# Absolute, validated project path
PROJECT_PATH="$(cd "$PROJECT_PATH" && pwd)"
IMAGE=claude-in-a-box:latest
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Build once (no-op if image is already up to date)
docker build -t "$IMAGE" "$SCRIPT_DIR"

# Optional mounts/env assembled as arrays so quoting is safe
EXTRA=()

if [ "$FRESH" -eq 1 ]; then
  # Fresh session: don't mount any host credentials/config, so nothing is
  # inherited. Persist this instance's own login on the host instead, so it
  # survives the --rm teardown and is reused next time. We mount it straight
  # over the container's home so Claude reads/writes its login there directly.
  SESSION_DIR="$SCRIPT_DIR/.sessions/$INSTANCE_KEY"
  mkdir -p "$SESSION_DIR/.claude"
  # .claude.json must exist as a FILE before mounting, or Docker creates a dir.
  [ -f "$SESSION_DIR/.claude.json" ] || echo '{}' > "$SESSION_DIR/.claude.json"

  # If this instance already has a saved login, confirm WHICH account it is
  # before reusing it — so you never run as the wrong Claude account by accident.
  # The logged-in email lives in .claude.json under oauthAccount.emailAddress.
  if [ -f "$SESSION_DIR/.claude/.credentials.json" ]; then
    SAVED_EMAIL="$(node -e 'const fs=require("fs");try{const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));const o=j.oauthAccount||{};process.stdout.write(o.emailAddress||o.email||"")}catch(e){}' "$SESSION_DIR/.claude.json" 2>/dev/null || true)"
    [ -z "$SAVED_EMAIL" ] && SAVED_EMAIL="(unknown account)"
    # Only prompt when we can actually act on "log in as another": interactive
    # (no TASK) and a real TTY. Headless can't run /login, so just report it.
    if [ -z "$TASK" ] && [ -t 0 ]; then
      printf 'Fresh session "%s" is logged in as: %s\n' "$INSTANCE_KEY" "$SAVED_EMAIL"
      printf 'Continue as this account? [Y/n] (n = log in as another): '
      read -r ans
      if [ "$ans" = "n" ] || [ "$ans" = "N" ]; then
        echo "Clearing saved login for instance \"$INSTANCE_KEY\" — log in when Claude starts (use /login)."
        rm -f "$SESSION_DIR/.claude/.credentials.json"
        echo '{}' > "$SESSION_DIR/.claude.json"
      else
        echo "Continuing as $SAVED_EMAIL."
      fi
    else
      echo "Fresh session \"$INSTANCE_KEY\" account: $SAVED_EMAIL"
    fi
  fi

  EXTRA+=(-e CLAUDE_FRESH=1)
  EXTRA+=(-e CLAUDE_INSTANCE="$INSTANCE_KEY")
  EXTRA+=(-v "$SESSION_DIR/.claude:/home/agent/.claude")
  EXTRA+=(-v "$SESSION_DIR/.claude.json:/home/agent/.claude.json")
else
  # Inherit the host login session + user config (read-only; copied into a
  # writable per-container home by the entrypoint).
  EXTRA+=(-v "$HOME/.claude:/claude-host:ro")
  [ -f "$HOME/.claude.json" ] && EXTRA+=(-v "$HOME/.claude.json:/claude-host.json:ro")
  # API key is only a fallback for inherited mode. In --fresh mode we omit it on
  # purpose so the brand new interactive login isn't shadowed by a host key.
  [ -n "${ANTHROPIC_API_KEY:-}" ] && EXTRA+=(-e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY")
fi

if [ "$EPHEMERAL" -eq 1 ]; then
  # Burnable session: don't persist anything. Claude writes its transcript to the
  # container-local home, which the --rm teardown discards.
  EXTRA+=(-e CLAUDE_EPHEMERAL=1)
else
  # DEFAULT: persist session transcripts into the project itself. Claude writes
  # them to <home>/.claude/projects/<hash>/, and inside the container the hash is
  # always "-workspace" (cwd is /workspace) — so bind-mounting this dir over
  # projects/ parks the transcripts in the project, where they outlive the --rm
  # container and can be resumed on a later run.
  HISTORY_DIR="$PROJECT_PATH/.claude-box"
  mkdir -p "$HISTORY_DIR"
  EXTRA+=(-v "$HISTORY_DIR:/home/agent/.claude/projects")
  [ "$RESUME" -eq 1 ] && EXTRA+=(-e CLAUDE_RESUME=1)

  # Keep the history out of the user's git tree via .git/info/exclude — a LOCAL,
  # untracked ignore, so we never touch their committed .gitignore.
  GIT_DIR="$PROJECT_PATH/.git"
  if [ -d "$GIT_DIR" ]; then
    EXCLUDE="$GIT_DIR/info/exclude"
    mkdir -p "$GIT_DIR/info"
    if [ ! -f "$EXCLUDE" ] || ! grep -qxF '.claude-box/' "$EXCLUDE" 2>/dev/null; then
      printf '%s\n' '.claude-box/' >> "$EXCLUDE"
    fi
  fi
fi

# Name the container only if you asked for an instance name. Otherwise leave it
# off so Docker auto-assigns a unique random name and N parallel runs never clash.
NAME_ARGS=()
[ -n "$INSTANCE" ] && NAME_ARGS=(--name "claude-in-a-box-$INSTANCE")

docker run --rm -it \
  "${NAME_ARGS[@]}" \
  -e TASK="$TASK" \
  -e HOST_PROJECT_PATH="$PROJECT_PATH" \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  -v "$PROJECT_PATH:/workspace" \
  "${EXTRA[@]}" \
  "$IMAGE"
