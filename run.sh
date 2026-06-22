#!/bin/bash
set -euo pipefail
# Usage: ./run.sh [--fresh] <project_path> ["<task>"] [instance_name]

# ----- option parsing -----
# --fresh / --no-inherit: don't inherit the host login session. Start a brand new
# one instead (handy when you have several Claude Max accounts and want this box
# logged into a different account than your host). The new login is saved per
# instance under ./.sessions/<instance> so it survives container restarts.
# --resume: persist this project's session history so it survives the --rm
# teardown, and continue the most recent conversation on the next run. History
# is stored inside the project at <project>/.claude-box/ (auto git-ignored).
FRESH=0
RESUME=0
while [ $# -gt 0 ]; do
  case "$1" in
    --fresh|--no-inherit) FRESH=1; shift ;;
    --resume|--continue) RESUME=1; shift ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) break ;;
  esac
done

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

Usage: ./run.sh [--fresh] [--resume] <project_path> ["<task>"] [instance_name]

Interactive (default) — opens the normal Claude Code interface inside the
container, scoped to your project. Use this for plan mode, pasting spec
sheets, and back-and-forth work:
  ./run.sh ~/code/weave

Resume — persist this project's conversation history (in <project>/.claude-box,
auto git-ignored) and pick up the most recent session next time:
  ./run.sh --resume ~/code/weave             # first run seeds; later runs continue

Headless single run — give a task and Claude works on it autonomously, then
exits (the original one-shot mode):
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

if [ "$RESUME" -eq 1 ]; then
  # Persist session transcripts into the project itself. Claude writes them to
  # <home>/.claude/projects/<hash>/, and inside the container the hash is always
  # "-workspace" (cwd is /workspace) — so bind-mounting this dir over projects/
  # parks the transcripts in the project, where they outlive the --rm container.
  HISTORY_DIR="$PROJECT_PATH/.claude-box"
  mkdir -p "$HISTORY_DIR"
  EXTRA+=(-e CLAUDE_RESUME=1)
  EXTRA+=(-v "$HISTORY_DIR:/home/agent/.claude/projects")

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
