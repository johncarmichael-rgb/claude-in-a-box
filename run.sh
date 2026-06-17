#!/bin/bash
set -euo pipefail
# Usage: ./run.sh <project_path> ["<task>"] [instance_name]

PROJECT_PATH="${1:-}"
TASK="${2:-}"
INSTANCE="${3:-1}"

if [ -z "$PROJECT_PATH" ]; then
  cat <<'EOF'

Usage: ./run.sh <project_path> ["<task>"] [instance_name]

Interactive (default) — opens the normal Claude Code interface inside the
container, scoped to your project. Use this for plan mode, pasting spec
sheets, and back-and-forth work:
  ./run.sh ~/code/weave

Headless single run — give a task and Claude works on it autonomously, then
exits (the original one-shot mode):
  ./run.sh ~/code/weave "add input validation to the OAuth flow"

Run 2-3 in parallel on the same codebase (each needs a UNIQUE instance name;
run them in separate terminals, or append & to background them). Pass an empty
task "" to run interactive instances in parallel:
  ./run.sh ~/code/weave "task A" a
  ./run.sh ~/code/weave "task B" b
  ./run.sh ~/code/weave "" c          # interactive, instance c

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
[ -f "$HOME/.claude.json" ] && EXTRA+=(-v "$HOME/.claude.json:/claude-host.json:ro")
[ -n "${ANTHROPIC_API_KEY:-}" ] && EXTRA+=(-e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY")

docker run --rm -it \
  --name "claude-in-a-box-$INSTANCE" \
  -e TASK="$TASK" \
  -e HOST_PROJECT_PATH="$PROJECT_PATH" \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  -v "$PROJECT_PATH:/workspace" \
  -v "$HOME/.claude:/claude-host:ro" \
  "${EXTRA[@]}" \
  "$IMAGE"
