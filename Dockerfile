FROM node:24-slim

# git/curl for Claude's own use; gosu lets us drop from root to the host UID at
# runtime so files Claude writes are owned by you, not root.
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    bash \
    ca-certificates \
    gosu \
    && rm -rf /var/lib/apt/lists/*

# Pin / refresh the Claude Code version baked into the image.
#   CLAUDE_CODE_VERSION - npm tag or exact version to install ('latest' default).
#   CACHEBUST           - throwaway value whose only purpose is to invalidate this
#                         layer's build cache so `./run.sh update` re-pulls a fresh
#                         copy even when the version string is unchanged (e.g. the
#                         'latest' tag moved to a newer release). Normal runs leave
#                         it at the default, so the layer stays cached and fast.
ARG CLAUDE_CODE_VERSION=latest
ARG CACHEBUST=0
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# This is a pinned, rebuild-to-update image, and the container runs as a non-root
# UID that can't write to the global npm prefix anyway. Turn off the in-place
# auto-updater so Claude doesn't try (and fail) to update itself on every launch.
# Update the agent by rebuilding the image instead: `./run.sh update`.
ENV DISABLE_AUTOUPDATER=1
# Suppress telemetry only. Do NOT set CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
# here: it also skips the startup bootstrap fetch that reports which extra models
# (e.g. Fable) the account can use, leaving them missing from the /model picker.
ENV DISABLE_TELEMETRY=1

# Managed settings are the HIGHEST precedence config. They cannot be overridden
# by the mounted ~/.claude, by project settings, or by --dangerously-skip-permissions.
# This hard-blocks rm and registers the PreToolUse git guard below.
COPY managed-settings.json /etc/claude-code/managed-settings.json

# The git guard, referenced by the PreToolUse hook in managed-settings.json. It
# allows only `git pull`, `git log`, and `git diff` and denies all other git.
# Pure Node (no jq) so it works on the slim image with no extra packages.
COPY git-guard.js /etc/claude-code/git-guard.js

# Bundled Skills. Each subfolder is one skill (a SKILL.md plus optional support
# files). The entrypoint installs these into the per-container ~/.claude/skills so
# Claude auto-discovers them and picks the right one per task. Baked in (not
# mounted) so they're pinned to the image; add a skill under ./skills and the next
# run.sh build picks it up automatically.
COPY skills /opt/claude-skills

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/entrypoint.sh"]
