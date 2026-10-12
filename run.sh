#!/bin/bash
set -euo pipefail
# Usage: ./run.sh [--fresh] [--safe] <project_path> ["<task>"] [instance_name]

IMAGE=claude-in-a-box:latest
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ----- maintenance subcommands: version / update -----
# This is a rebuild-to-update image: the in-container auto-updater is disabled on
# purpose (see Dockerfile), so Claude Code is pinned to whatever was baked in at
# build time. These subcommands surface that version and refresh it on demand.
#
#   ./run.sh version            show the Claude Code version inside the image,
#                               when the image was built, and the latest on npm.
#   ./run.sh update [version]   rebuild the image, re-pulling Claude Code (the
#                               'latest' npm tag by default, or a version/tag you
#                               name, e.g. ./run.sh update 1.2.3).
#
# Prints the Claude Code version installed in the image, or "" if it can't (image
# missing, or `claude --version` failed). Overrides the entrypoint so we run the
# CLI directly rather than the interactive/headless launcher.
image_claude_version() {
  docker run --rm --entrypoint claude "$IMAGE" --version 2>/dev/null | head -n1 || true
}

# ----- long-lived auth token (non---fresh runs) -----
# Default (inherited) runs authenticate with a long-lived OAuth token minted by
# 'claude setup-token' on the host and passed in as CLAUDE_CODE_OAUTH_TOKEN. We
# deliberately do NOT hand the container the host's ~/.claude/.credentials.json:
# that file holds a short-lived (~8h) access token plus a SINGLE-USE refresh
# token. A copy that refreshes inside the container rotates the refresh token,
# the new one dies with the --rm container, and the host's copy is now invalid —
# so both the host and every later run land on /login. A setup-token never
# refreshes, so there is no chain to fork.
#
# Resolution order: $CLAUDE_CODE_OAUTH_TOKEN env > ./.oauth-token file > prompt.
TOKEN_FILE="$SCRIPT_DIR/.oauth-token"

# Prints the saved token, or "" if none.
saved_oauth_token() {
  [ -f "$TOKEN_FILE" ] && tr -d '[:space:]' < "$TOKEN_FILE" 2>/dev/null || true
}

# Interactively obtain a token (offering to run 'claude setup-token' if the CLI
# is on the host), validate it loosely, and save it 0600. Needs a TTY.
prompt_and_save_token() {
  if ! [ -t 0 ]; then
    echo "Error: no auth token and no TTY to ask for one." >&2
    echo "       Run './run.sh token' interactively once, or export CLAUDE_CODE_OAUTH_TOKEN." >&2
    return 1
  fi
  echo
  echo "Non-fresh runs need a LONG-LIVED token from 'claude setup-token' (run on the host)."
  echo "It lasts ~1 year and never refreshes, so it can't log out your host login."
  if command -v claude >/dev/null 2>&1; then
    printf "Run 'claude setup-token' now? [Y/n]: "
    read -r ans
    if [ "$ans" != "n" ] && [ "$ans" != "N" ]; then
      # setup-token prints the token in the TERMINAL (the browser page only
      # says "you can close this window"), so capture it from the output
      # instead of asking the user to copy it. It's an Ink TUI that wants a
      # real TTY on stdout, so we record it through a pty with 'script'.
      local tok
      tok="$(run_setup_token_capturing)"
      if [ -n "$tok" ]; then
        echo
        echo "Captured the token from 'claude setup-token' output."
        save_token "$tok"
        return 0
      fi
      echo
      echo "(Couldn't find a token in the output — copy the sk-ant-oat… line printed above, if any.)"
    fi
  else
    echo "('claude' is not on this host's PATH — run 'claude setup-token' wherever it is installed.)"
  fi
  printf 'Paste the token (input hidden): '
  local tok
  read -r -s tok
  echo
  tok="$(printf '%s' "$tok" | tr -d '[:space:]')"
  if [ -z "$tok" ]; then
    echo "Error: empty token." >&2
    return 1
  fi
  case "$tok" in
    sk-ant-oat*) ;;
    *) echo "Warning: token doesn't look like a 'claude setup-token' token (expected sk-ant-oat…). Saving anyway." >&2 ;;
  esac
  save_token "$tok"
}

# Writes the token to TOKEN_FILE (0600) and says so.
save_token() {
  ( umask 077; printf '%s\n' "$1" > "$TOKEN_FILE" )
  chmod 600 "$TOKEN_FILE" 2>/dev/null || true
  echo "Saved to $TOKEN_FILE (git-ignored). Replace with './run.sh token', forget with './run.sh token clear'."
}

# Runs 'claude setup-token' on the user's terminal exactly as normal (browser
# flow, output and all) while recording what it prints through a pty, then
# prints the sk-ant-oat… token it displayed — or "" if none was found.
run_setup_token_capturing() {
  local cap tok
  cap="$(mktemp)" || return 0
  if script --version >/dev/null 2>&1; then
    # util-linux (Linux): -q quiet, -c command, logfile last.
    script -q -c "claude setup-token" "$cap" >/dev/tty 2>&1 </dev/tty || true
  elif command -v script >/dev/null 2>&1; then
    # BSD / macOS: logfile first, then the command.
    script -q "$cap" claude setup-token >/dev/tty 2>&1 </dev/tty || true
  else
    # No pty recorder — run plainly; the caller falls back to a paste prompt.
    claude setup-token >/dev/tty 2>&1 </dev/tty || true
    rm -f "$cap"
    return 0
  fi
  # The TUI wraps long lines to the terminal width, so a narrow terminal can
  # split the token across lines. Turn cursor-movement/erase escapes (TUI
  # redraws) into paragraph breaks, drop colour escapes and CRs, trim each
  # line, join each blank-line-separated paragraph back into one line (the
  # token is printed as a paragraph of its own), then keep the longest match
  # (redraws can leave partial copies in the recording). Plain sed/awk only,
  # written to work with both GNU and BSD/macOS tools.
  local esc; esc="$(printf '\033')"
  tok="$(sed -e "s/${esc}\[[0-9;?]*[ABCDEFGHJKST]/\\
\\
/g" -e "s/${esc}\[[0-9;?]*[A-Za-z]//g" -e "s/${esc}[()][A-Za-z0-9]//g" -e 's/\r//g' "$cap" \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        | awk 'BEGIN{RS="";ORS="\n"}{gsub(/\n/,""); print}' \
        | grep -a -o -E 'sk-ant-oat[0-9]*-[A-Za-z0-9_-]{40,}' \
        | awk '{ if (length($0) > length(best)) best=$0 } END{ print best }')" || true
  rm -f "$cap"
  printf '%s' "$tok"
}

usage() {
  cat <<'EOF'

Usage: ./run.sh [--fresh] [--resume|--ephemeral] [--safe] <project_path> ["<task>"] [instance_name]
       ./run.sh help|version|update|token

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

Safe — drop --dangerously-skip-permissions so Claude prompts for permissions
normally (the managed git/rm guards still apply either way). Needed for models
like Fable that refuse to run under --dangerously-skip-permissions:
  ./run.sh --safe ~/code/weave

Headless single run — give a task and Claude works on it autonomously, then
exits (also recorded unless you pass --ephemeral):
  ./run.sh ~/code/weave "add input validation to the OAuth flow"

Auth (default) — the container authenticates with a LONG-LIVED token from
'claude setup-token' on the host, NOT your host's ~/.claude/.credentials.json.
(Copying that file forks the OAuth refresh chain: refresh tokens are single-use,
so the first in-container refresh logs out the host and every later run.) On the
first run it offers to run 'claude setup-token' for you and captures the token
it prints in the terminal (the browser never shows it; nothing to copy). It's
saved to ./.oauth-token (0600, git-ignored) and reused. Or export CLAUDE_CODE_OAUTH_TOKEN to skip the file.
Your host user config (settings.json, CLAUDE.md, .claude.json) is still inherited.
  ./run.sh token              set / replace the saved token
  ./run.sh token clear        forget it

Fresh session — do NOT inherit the host login or token. Start a brand new one
and log in inside the container (useful when you have several Claude Max accounts and
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

Resources — at startup you're offered a resource-limit preset (unrestricted /
low / medium / high) that caps the container's RAM, CPUs and process count so a
runaway agent can't degrade the host. Your last choice is remembered and used as
the default next time. Skip the prompt with an env var:
  CLAUDE_RESOURCES=medium       ./run.sh ~/code/weave
  CLAUDE_RESOURCES=unrestricted ./run.sh ~/code/weave
Presets: unrestricted (no caps) | low (2G/1cpu/256) | medium (4G/2cpu/512)
         | high (8G/4cpu/1024)

Colours — at startup you're offered a colour scheme that recolours THIS
terminal (background + text) for the session, then restores it on exit, so
parallel sessions are easy to tell apart. Skip the prompt with an env var:
  CLAUDE_COLOR=midnight ./run.sh ~/code/weave
  CLAUDE_COLOR=default  ./run.sh ~/code/weave   # leave colours untouched
Schemes: default midnight forest plum slate crimson mocha mono

Maintenance:
  ./run.sh help               show this help (also --help / -h).
  ./run.sh version            show the Claude Code version baked into the image,
                              its build date, and the latest release on npm.
  ./run.sh update [version]   rebuild the image, re-pulling Claude Code ('latest'
                              by default, or a version/tag: ./run.sh update 1.2.3).
                              This is how you update Claude — the in-container
                              auto-updater is disabled by design.
  ./run.sh token [clear]      set/replace (or forget) the long-lived auth token
                              used by non---fresh runs (from 'claude setup-token').
EOF
}

case "${1:-}" in
  help|--help|-h)
    usage
    exit 0
    ;;
  version|--version|-v)
    if command -v node >/dev/null 2>&1; then
      BOX_VER="$(node -p "require('$SCRIPT_DIR/package.json').version" 2>/dev/null || true)"
      [ -n "$BOX_VER" ] && echo "claude-in-a-box: $BOX_VER"
    fi
    if docker image inspect "$IMAGE" >/dev/null 2>&1; then
      BUILT="$(docker image inspect -f '{{.Created}}' "$IMAGE" 2>/dev/null || true)"
      INIMG="$(image_claude_version)"
      echo "image:           $IMAGE (built ${BUILT:-unknown})"
      echo "Claude Code:     ${INIMG:-unknown} (installed in image)"
    else
      echo "image:           $IMAGE not built yet — run './run.sh update' to build it."
    fi
    if command -v npm >/dev/null 2>&1; then
      LATEST="$(npm view @anthropic-ai/claude-code version 2>/dev/null || true)"
      [ -n "$LATEST" ] && echo "Latest on npm:   $LATEST"
    fi
    exit 0
    ;;
  token|--token|login)
    case "${2:-}" in
      clear|--clear|forget)
        if [ -f "$TOKEN_FILE" ]; then rm -f "$TOKEN_FILE"; echo "Forgot saved token ($TOKEN_FILE)."
        else echo "No saved token to forget."; fi
        exit 0
        ;;
      "") prompt_and_save_token; exit $? ;;
      *) echo "Unknown: ./run.sh token $2 (use './run.sh token' or './run.sh token clear')" >&2; exit 1 ;;
    esac
    ;;
  update|upgrade|--update)
    TARGET="${2:-latest}"
    BEFORE=""
    docker image inspect "$IMAGE" >/dev/null 2>&1 && BEFORE="$(image_claude_version)"
    echo "Updating Claude Code in $IMAGE to '@$TARGET' (rebuilding image)..."
    # CACHEBUST forces the npm-install layer to re-run even when TARGET is an
    # unchanged tag like 'latest', so we always fetch the newest matching build.
    docker build \
      --build-arg CLAUDE_CODE_VERSION="$TARGET" \
      --build-arg CACHEBUST="$(date +%s)" \
      -t "$IMAGE" "$SCRIPT_DIR"
    AFTER="$(image_claude_version)"
    echo
    echo "Claude Code: ${BEFORE:-none} -> ${AFTER:-unknown}"
    exit 0
    ;;
esac

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
SKIP_PERMS=1
while [ $# -gt 0 ]; do
  case "$1" in
    --fresh|--no-inherit) FRESH=1; shift ;;
    --resume|--continue) RESUME=1; shift ;;
    --ephemeral|--no-history) EPHEMERAL=1; shift ;;
    --safe|--no-skip-permissions|--permissions) SKIP_PERMS=0; shift ;;
    --help|-h) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1 (see ./run.sh --help)" >&2; exit 1 ;;
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
  usage
  exit 1
fi

# Absolute, validated project path
PROJECT_PATH="$(cd "$PROJECT_PATH" && pwd)"

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
  # Inherit the host USER CONFIG only (settings.json, CLAUDE.md, .claude.json),
  # mounted read-only and copied into a writable per-container home by the
  # entrypoint. The host's .credentials.json is NOT used — see the token notes
  # above TOKEN_FILE for why (single-use refresh tokens).
  EXTRA+=(-v "$HOME/.claude:/claude-host:ro")
  [ -f "$HOME/.claude.json" ] && EXTRA+=(-v "$HOME/.claude.json:/claude-host.json:ro")

  # Auth: long-lived setup-token (env, then saved file, then prompt), falling
  # back to ANTHROPIC_API_KEY. Both are omitted in --fresh mode on purpose so a
  # brand new in-container login isn't shadowed by a host credential.
  OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}"
  [ -z "$OAUTH_TOKEN" ] && OAUTH_TOKEN="$(saved_oauth_token)"
  if [ -z "$OAUTH_TOKEN" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    prompt_and_save_token || exit 1
    OAUTH_TOKEN="$(saved_oauth_token)"
  fi
  if [ -n "$OAUTH_TOKEN" ]; then
    EXTRA+=(-e CLAUDE_CODE_OAUTH_TOKEN="$OAUTH_TOKEN")
  else
    EXTRA+=(-e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY")
  fi
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

# ----- resource limits -----
# By default a container shares the HOST's full CPU, RAM and process table, so a
# runaway agent (fork bomb, memory leak, busy loop) can degrade the whole machine.
# Pick a preset here and we pass the matching --memory / --cpus / --pids-limit caps
# to `docker run`. The choice is REMEMBERED in ./.resource-preset and offered as the
# default next time. Skip the prompt with CLAUDE_RESOURCES=<name>, e.g.
#   CLAUDE_RESOURCES=medium ./run.sh ~/code/weave
#   CLAUDE_RESOURCES=unrestricted ./run.sh ~/code/weave
# Presets (name -> RAM / CPUs / max processes):
RES_NAMES=( unrestricted low medium high )
RES_LABEL=( "Unrestricted — no caps (full host CPU/RAM/processes). A runaway agent CAN degrade the host." \
            "Low          — 2 GB RAM, 1 CPU,  256 procs. Light tasks; safe to run several in parallel." \
            "Medium       — 4 GB RAM, 2 CPUs, 512 procs. Balanced default for most work." \
            "High         — 8 GB RAM, 4 CPUs, 1024 procs. Heavy builds / large test suites." )
RES_MEM=(  "" "2g"  "4g"  "8g"  )
RES_CPUS=( "" "1"   "2"   "4"   )
RES_PIDS=( "" "256" "512" "1024" )

RES_PREF_FILE="$SCRIPT_DIR/.resource-preset"
SAVED_RES=""
[ -f "$RES_PREF_FILE" ] && SAVED_RES="$(tr -d '[:space:]' < "$RES_PREF_FILE" 2>/dev/null || true)"

# Resolve a preset name to its index; empty + non-zero exit if not found.
res_index() {
  local want="$1" i
  for i in "${!RES_NAMES[@]}"; do
    [ "${RES_NAMES[$i]}" = "$want" ] && { printf '%s' "$i"; return 0; }
  done
  return 1
}

RES_CHOICE=""
if [ -n "${CLAUDE_RESOURCES:-}" ]; then
  # Non-interactive override.
  if res_index "$CLAUDE_RESOURCES" >/dev/null; then
    RES_CHOICE="$CLAUDE_RESOURCES"
  else
    echo "Unknown CLAUDE_RESOURCES=\"$CLAUDE_RESOURCES\" — valid: ${RES_NAMES[*]}. Falling back to a prompt/default." >&2
  fi
fi

if [ -z "$RES_CHOICE" ] && [ -t 0 ] && [ -t 1 ]; then
  # Interactive menu. Default to the last saved choice, else medium.
  RES_DEF_IDX=2
  if [ -n "$SAVED_RES" ] && RES_DI="$(res_index "$SAVED_RES")"; then RES_DEF_IDX="$RES_DI"; fi
  echo
  echo "Pick resource limits for this container (caps a runaway agent can't exceed):"
  for i in "${!RES_NAMES[@]}"; do
    mark="  "; [ "$i" -eq "$RES_DEF_IDX" ] && mark="* "
    printf '  %d)%s%s\n' "$((i+1))" "$mark" "${RES_LABEL[$i]}"
  done
  printf 'Choice [%d]: ' "$((RES_DEF_IDX+1))"
  read -r rpick
  [ -z "$rpick" ] && rpick=$((RES_DEF_IDX+1))
  if [[ "$rpick" =~ ^[0-9]+$ ]] && [ "$rpick" -ge 1 ] && [ "$rpick" -le "${#RES_NAMES[@]}" ]; then
    RES_CHOICE="${RES_NAMES[$((rpick-1))]}"
  else
    RES_CHOICE="${RES_NAMES[$RES_DEF_IDX]}"
    echo "Not a valid choice — using default ($RES_CHOICE)."
  fi
fi

# Non-interactive with nothing chosen: reuse the saved preset if any, otherwise
# default to 'unrestricted' so existing headless/CI runs behave exactly as before.
if [ -z "$RES_CHOICE" ]; then
  if [ -n "$SAVED_RES" ] && res_index "$SAVED_RES" >/dev/null; then
    RES_CHOICE="$SAVED_RES"
  else
    RES_CHOICE="unrestricted"
  fi
fi

# Remember the choice for next time (best-effort; never fatal).
printf '%s\n' "$RES_CHOICE" > "$RES_PREF_FILE" 2>/dev/null || true

# Translate the chosen preset into docker flags.
RES_ARGS=()
RES_IDX="$(res_index "$RES_CHOICE")"
if [ -n "${RES_MEM[$RES_IDX]}" ]; then
  RES_ARGS+=(--memory "${RES_MEM[$RES_IDX]}" --cpus "${RES_CPUS[$RES_IDX]}" --pids-limit "${RES_PIDS[$RES_IDX]}")
  echo "Resources: $RES_CHOICE — ${RES_MEM[$RES_IDX]} RAM, ${RES_CPUS[$RES_IDX]} CPU, ${RES_PIDS[$RES_IDX]} procs (remembered)"
else
  echo "Resources: unrestricted — no CPU/RAM/process caps (remembered)"
fi

# ----- terminal colour picker -----
# Running Claude in several terminals at once is confusing when they all look
# identical. Pick a background + text colour here and we recolour THIS terminal
# (via OSC escape sequences, understood by every modern terminal emulator) for
# the lifetime of the session, then restore it on exit. Purely cosmetic — it
# just tags the window so you can tell parallel sessions apart at a glance.
#
# Set CLAUDE_COLOR=<name> to skip the prompt (handy for aliases / scripts), e.g.
#   CLAUDE_COLOR=midnight ./run.sh ~/code/weave
# Use CLAUDE_COLOR=default (or run without a TTY) to leave colours untouched.
COLOR_NAMES=( default midnight forest plum slate crimson mocha mono )
COLOR_LABEL=( "Default (leave terminal as-is)" \
              "Midnight  — deep blue"          \
              "Forest    — dark green"         \
              "Plum      — dark purple"        \
              "Slate     — blue-grey"          \
              "Crimson   — dark red"           \
              "Mocha     — dark brown"         \
              "Mono      — black / green"      )
COLOR_BG=( ""        "#0b1e3b" "#0c2415" "#241033" "#1c2128" "#2a0d0d" "#241a12" "#000000" )
COLOR_FG=( ""        "#e6f0ff" "#d7f5d7" "#f0e0ff" "#dfe6ee" "#ffdede" "#f5e9d7" "#33ff66" )

# "#rrggbb" -> "r g b" (decimal), for truecolor swatch preview.
hex_rgb() { local h="${1#\#}"; printf '%d %d %d' "0x${h:0:2}" "0x${h:2:2}" "0x${h:4:2}"; }

CHOSEN_BG=""
CHOSEN_FG=""
CHOSEN_NAME=""

# Resolve an index for a scheme name; empty if not found.
color_index() {
  local want="$1" i
  for i in "${!COLOR_NAMES[@]}"; do
    [ "${COLOR_NAMES[$i]}" = "$want" ] && { printf '%s' "$i"; return 0; }
  done
  return 1
}

if [ -n "${CLAUDE_COLOR:-}" ]; then
  # Non-interactive override.
  if idx="$(color_index "$CLAUDE_COLOR")"; then
    CHOSEN_NAME="${COLOR_NAMES[$idx]}"; CHOSEN_BG="${COLOR_BG[$idx]}"; CHOSEN_FG="${COLOR_FG[$idx]}"
  else
    echo "Unknown CLAUDE_COLOR=\"$CLAUDE_COLOR\" — leaving terminal colours unchanged." >&2
  fi
elif [ -t 0 ] && [ -t 1 ]; then
  # Interactive: show a menu with a live swatch of each scheme.
  echo
  echo "Pick a colour for this terminal session (tells parallel sessions apart):"
  for i in "${!COLOR_NAMES[@]}"; do
    if [ -n "${COLOR_BG[$i]}" ]; then
      read -r br bgc bb <<<"$(hex_rgb "${COLOR_BG[$i]}")"
      read -r fr fgc fb <<<"$(hex_rgb "${COLOR_FG[$i]}")"
      swatch="$(printf '\033[48;2;%d;%d;%dm\033[38;2;%d;%d;%dm  Aa Claude  \033[0m' \
                "$br" "$bgc" "$bb" "$fr" "$fgc" "$fb")"
    else
      swatch="             "
    fi
    printf '  %d) %s  %s\n' "$((i+1))" "$swatch" "${COLOR_LABEL[$i]}"
  done
  printf 'Choice [1]: '
  read -r pick
  [ -z "$pick" ] && pick=1
  if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#COLOR_NAMES[@]}" ]; then
    idx=$((pick-1))
    CHOSEN_NAME="${COLOR_NAMES[$idx]}"; CHOSEN_BG="${COLOR_BG[$idx]}"; CHOSEN_FG="${COLOR_FG[$idx]}"
  else
    echo "Not a valid choice — leaving terminal colours unchanged."
  fi
fi

# Apply the chosen colours to this terminal and arrange to restore them on exit.
# OSC 11 = background, OSC 10 = foreground; OSC 111/110 reset each to default.
if [ -n "$CHOSEN_BG" ] || [ -n "$CHOSEN_FG" ]; then
  reset_colors() { printf '\033]111\007\033]110\007' > /dev/tty 2>/dev/null || true; }
  trap reset_colors EXIT INT TERM
  {
    [ -n "$CHOSEN_BG" ] && printf '\033]11;%s\007' "$CHOSEN_BG"
    [ -n "$CHOSEN_FG" ] && printf '\033]10;%s\007' "$CHOSEN_FG"
  } > /dev/tty 2>/dev/null || true
  echo "Terminal colour: $CHOSEN_NAME (restored on exit)"
fi

# Name the container only if you asked for an instance name. Otherwise leave it
# off so Docker auto-assigns a unique random name and N parallel runs never clash.
NAME_ARGS=()
[ -n "$INSTANCE" ] && NAME_ARGS=(--name "claude-in-a-box-$INSTANCE")

docker run --rm -it \
  "${NAME_ARGS[@]}" \
  -e TASK="$TASK" \
  -e CLAUDE_SKIP_PERMISSIONS="$SKIP_PERMS" \
  -e HOST_PROJECT_PATH="$PROJECT_PATH" \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  -v "$PROJECT_PATH:/workspace" \
  "${RES_ARGS[@]}" \
  "${EXTRA[@]}" \
  "$IMAGE"
