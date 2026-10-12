# Claude in a Box

Claude Code running with --dangerously-skip-permissions but containerised in docker:

  In Bypass Permissions mode, Claude Code will not ask for your approval before running potentially dangerous commands.

Two modes:
- **Interactive (default):** pass just the project path and you get the normal Claude Code interface inside the container. Use plan mode, paste in spec sheets, and work back-and-forth — exactly like running Claude locally, but with the container's guardrails. This is the recommended way to work.
- **Headless (one-shot):** also pass a task string and Claude works on it autonomously, then exits.

Either way, your code changes persist via the mounted volume.

The container limits the blast radius to **your machine** — Claude can't touch the rest of the host. It does **not** sandbox the code itself: edits write straight through to your project. Your safety net for the code is git (`git reset` / `git checkout .`).

To keep Claude from touching version control or deleting files, **`git`, `rm`, and `rmdir` are hard-blocked** inside the container (see below). You do those yourself afterward.

## Quick start

Assuming you already have Docker installed and Claude Code logged in on the host:

```bash
# 1. Clone and enter the project
git clone https://github.com/johncarmichael-rgb/claude-in-a-box.git
cd claude-in-a-box

# 2. Make the run script executable
chmod +x run.sh entrypoint.sh

# 3. Launch interactive mode on your project (empty task "", instance name "a")
./run.sh /weave/1-weave-code "" a
```

The first run asks for a long-lived auth token: it offers to run `claude setup-token` for you and picks the token out of what it prints in the terminal, so there is nothing to copy. (The browser page only says "you can close this window"; the token itself is printed in the terminal.) It's saved to `./.oauth-token` and reused from then on — see [Authentication](#authentication).

That drops you into the normal Claude Code interface scoped to your project. See [Usage](#usage) for headless and parallel modes.

## Requirements

This runs Claude Code **inside Docker**, so you need Docker on the host:

- **Docker Engine** (or Docker Desktop) with the **`docker compose`** plugin — `run.sh` and the compose flow both rely on it.
- The Docker daemon running, and your user able to talk to it (`docker ps` should work without `sudo`).
- Claude Code installed and logged in on the host, so you can run `claude setup-token` (see [Authentication](#authentication)).

Check Docker is ready:

```bash
docker --version
docker compose version
docker ps
```

If you don't have Docker yet, install it from [docs.docker.com/get-docker](https://docs.docker.com/get-docker/).

## Setup

Keep these files in a permanent directory (not inside a project repo):

```
~/claude-in-a-box/
  Dockerfile
  docker-compose.yml
  entrypoint.sh
  managed-settings.json   # enforces the rm block + registers the git hook
  git-guard.js            # PreToolUse hook: allows only git pull/log/diff
  run.sh
```

```bash
chmod +x run.sh entrypoint.sh
```

## Updating Claude Code

This is a **rebuild-to-update** image: the in-container auto-updater is disabled on purpose (the container runs as a non-root UID that can't write to the global npm prefix anyway), so Claude Code is pinned to whatever was baked in at build time. Two subcommands manage that:

```bash
./run.sh version            # what's installed vs. what's available
./run.sh update             # rebuild, pulling the latest Claude Code
./run.sh update 2.1.198     # or pin to a specific version / npm tag
```

`version` reports the Claude Code version inside the image, when the image was built, and the latest release on npm:

```
claude-in-a-box: 1.0.0
image:           claude-in-a-box:latest (built 2026-06-27T15:40:23+01:00)
Claude Code:     2.1.195 (Claude Code) (installed in image)
Latest on npm:   2.1.198
```

`update` rebuilds the image, forcing a fresh `npm install -g @anthropic-ai/claude-code` (the `latest` tag by default, or the version/tag you name). Only the npm layer is re-pulled — the apt layer stays cached, so it's quick — and it prints the before → after version. Regular `./run.sh <project>` runs keep using the build cache, so day-to-day launches are unaffected until you explicitly update.

## Authentication

By default the container authenticates with a **long-lived token** from `claude setup-token`, passed in as `CLAUDE_CODE_OAUTH_TOKEN`. It does **not** use your host's `~/.claude/.credentials.json`.

Why not just copy the host login? That file holds a short-lived (~8h) access token plus a **single-use** refresh token. A copy that refreshes inside a container rotates the refresh token, the new one is thrown away with the `--rm` container, and the host's copy is now dead — so the host *and* every later run get bounced to `/login`. A setup-token lasts about a year and never refreshes, so there is no chain to fork and nothing to sync.

`run.sh` resolves the token in this order:

1. `CLAUDE_CODE_OAUTH_TOKEN` in your environment (handy for aliases / CI).
2. `./.oauth-token` — saved by `run.sh` on first use (mode 0600, git-ignored).
3. Otherwise it prompts: offers to run `claude setup-token` for you, captures the token from its terminal output (the browser page never shows it), and saves it. If no token can be found in the output it falls back to asking you to paste one.

Manage the saved token:

```bash
./run.sh token          # set or replace it
./run.sh token clear    # forget it
```

Your host **user config** is still inherited: `settings.json`, `CLAUDE.md` and `.claude.json` are mounted read-only and copied into the per-container home, so the container never writes back to your host files.

If neither a token nor a saved file is present, `ANTHROPIC_API_KEY` is forwarded as a fallback. With no auth at all the container exits with instructions.

### Fresh session (don't inherit the host login)

If you have **multiple Claude Max accounts** and want this box on a different one than your host, pass `--fresh` (alias `--no-inherit`). The host `~/.claude` is then **not** mounted or copied — instead you log in inside the container on first run, and that login is saved per instance under `./.sessions/<instance>/` so it's reused next time.

```bash
./run.sh --fresh ~/code/weave              # interactive; run /login when it starts
./run.sh --fresh ~/code/weave "" work      # same, saved under instance "work"
```

Notes:
- First `--fresh` run **must be interactive** (no task) so you can complete the login; once saved, headless `--fresh` runs reuse it.
- `--fresh` deliberately ignores the host token and `ANTHROPIC_API_KEY` so the new login isn't shadowed by a host credential.
- `.sessions/` holds real credentials and is git-ignored. Delete `./.sessions/<instance>/` to forget that account.
- Unlike the default mode, a `--fresh` login *does* refresh in place — that's fine, because its credential file is bind-mounted from `.sessions/` so the rotated token persists.

### Resume a previous session

By default the container is throwaway: its conversation transcript lives in the ephemeral container home and is gone on exit, so there's nothing to resume next run. Pass `--resume` (alias `--continue`) to persist it and pick up where you left off.

```bash
./run.sh --resume ~/code/weave             # first run seeds; later runs continue
./run.sh --resume ~/code/weave "keep going on the refactor"   # headless resume
```

How it works:
- Transcripts are stored **inside the project** at `<project>/.claude-box/` (Claude writes them there because the project is mounted at `/workspace`). They survive the `--rm` teardown because that directory is the real project on your host.
- On launch, interactive mode always starts Claude with `--resume`, which opens its native session picker. If the project has no recorded transcripts Claude shows "No conversations found" instead of silently starting a fresh session. Headless mode uses `--continue` (most recent session) when a transcript exists, and warns loudly if none does.
- Claude Code normally deletes transcripts older than 30 days from its projects directory, and `.claude-box/` *is* that directory inside the container. The image pins `cleanupPeriodDays` to 3650 in `managed-settings.json` so recorded sessions are never pruned. Rebuild the image (`./run.sh update`) to pick that up.
- `.claude-box/` is automatically added to the project's `.git/info/exclude` — a **local, untracked** git ignore, so your committed `.gitignore` is never modified. Delete `<project>/.claude-box/` to forget the history.
- Note: transcripts can contain code and secrets, the same as the `~/.claude/projects/` files Claude already writes in normal use — this just relocates them into the project.
- Composes with `--fresh` (fresh login *and* persisted history): `./run.sh --fresh --resume ~/code/weave`.

### Safe mode (permission prompting instead of skip-permissions)

By default the box runs Claude with `--dangerously-skip-permissions` for full autonomy. Some models — notably **Fable** — refuse to start under that flag. Pass `--safe` (aliases `--no-skip-permissions`, `--permissions`) to drop the flag so Claude uses normal permission prompting instead.

```bash
./run.sh --safe ~/code/weave               # interactive, with permission prompts
```

- The managed guardrails are **unaffected** — the git allowlist hook and `rm`/`rmdir` deny rules live in `managed-settings.json` and apply whether or not `--dangerously-skip-permissions` is set.
- Best used **interactively**: with prompting on, a headless (`-p`) run can block waiting for an approval it can't receive without a TTY. `entrypoint.sh` prints a warning if you combine `--safe` with a headless task.
- Under the hood `run.sh` passes `CLAUDE_SKIP_PERMISSIONS=0` to the container; `entrypoint.sh` then omits the flag.

## Usage

```bash
./run.sh [--fresh] [--resume] [--safe] <project_path> ["<task>"] [instance_name]
```

### Interactive (default, recommended)

Pass only the project path. You land in the normal Claude Code TUI, with `/workspace` as your project. From here you can enter plan mode (cycle modes with **Shift+Tab**), paste in spec sheets, and iterate — no need to nail it in a single prompt. Type `exit` or press **Ctrl+D** to leave; the container is removed on exit and your edits remain in the project.

```bash
./run.sh ~/code/weave
```

### Headless (one-shot)

Add a task string and Claude works on it autonomously, then exits — the original one-shot behaviour.

```bash
./run.sh ~/code/weave "add rate limiting to the OAuth callback"
```

### Parallel

The instance name is **optional**. Omit it and Docker auto-assigns a unique random container name, so you can launch as many as you like with no naming bookkeeping (separate terminals, or background with `&`):

```bash
./run.sh ~/code/weave "write tests for the auth middleware"
./run.sh ~/code/weave "add input validation to the CRM model"
./run.sh ~/code/weave                # interactive
```

Name them explicitly only when you want a **predictable** container name (e.g. to `docker logs`/`docker stop` a specific one) or a specific `--fresh` login slot. The empty `""` is just a placeholder so the name lands in the 3rd positional slot:

```bash
./run.sh ~/code/weave "write tests for the auth middleware" a
./run.sh ~/code/weave "" c          # interactive, named instance c
```

> Parallel agents **share the same files** (you chose the shared-mount model). Give each non-overlapping work, or simultaneous edits to the same file can clobber each other. For collision-free parallelism, switch to a git-worktree-per-agent setup.

### Via docker compose

`run.sh` is the easiest path, but you can also use compose directly. Use `run` (not `up`) so you attach to a real terminal:

```bash
PROJECT_PATH=~/code/weave docker compose run --rm claude-in-a-box              # interactive
PROJECT_PATH=~/code/weave TASK="fix the flaky test" docker compose run --rm claude-in-a-box  # headless
```

## What's blocked, and how

`rm` and `rmdir` are blocked via `managed-settings.json`, baked into the image at `/etc/claude-code/managed-settings.json`. Managed settings are the highest-precedence config: they **cannot** be overridden by your mounted `~/.claude`, by project settings, or by `--dangerously-skip-permissions`.

**git** is handled differently because we want to allow a few read/sync commands. `git pull`, `git log`, and `git diff` are permitted (so the agent can sync the repo and learn from history); **every other git command is denied** — `push`, `commit`, `add`, `checkout`, `reset`, `merge`, and so on. A plain deny rule can't express this: Claude Code evaluates rules `deny → ask → allow` and *specificity doesn't change the order*, so a broad `deny Bash(git:*)` would block `git pull` too and can't carry an allowlist exception. Instead, a `PreToolUse` hook (`git-guard.js`, registered in `managed-settings.json` and baked in at `/etc/claude-code/git-guard.js`) inspects each Bash command and denies any git invocation outside the allowlist. Because it's a managed hook, it holds even under `--dangerously-skip-permissions`. To allow more git subcommands, edit the `ALLOWED` set in `git-guard.js` and rebuild.

Claude is also told up front (system prompt) which git commands are available, so it won't waste turns retrying denied ones. By default everything else runs without prompts (`--dangerously-skip-permissions`), so the agent is fully autonomous within those guardrails. Pass [`--safe`](#safe-mode-permission-prompting-instead-of-skip-permissions) to drop that flag and get normal permission prompting instead (required for models like Fable) — the guardrails above still hold either way.

To block or allow more non-git commands, edit `managed-settings.json` and rebuild. Pattern form is `Bash(<cmd>:*)`. Note: the git guard catches direct invocations (incl. wrappers, env-assignments, and global flags) but not git smuggled through `bash -c "git ..."` — fine for a cooperative agent; tighten `git-guard.js` if you need airtight enforcement.

## File ownership

The container runs as **your** UID/GID (passed in by `run.sh`), so files Claude creates are owned by you — no root-owned files to `sudo` away, and git sees a matching owner.

## Network

Full network access by default (so Claude can install packages). For full isolation, add `network_mode: none` to the compose service, or `--network none` to the `docker run` in `run.sh`. Only do this if the task needs no package installs.

## Resource limits

By default a container shares the host's full CPU, RAM and process table, so a
runaway agent (fork bomb, memory leak, busy loop) can degrade the **whole
machine**. At startup `run.sh` offers a preset that caps the container via
`docker run`'s `--memory` / `--cpus` / `--pids-limit`:

| Preset | RAM | CPUs | Max procs | When |
| --- | --- | --- | --- | --- |
| `unrestricted` | host | host | host | Trusted heavy work; accept the risk. |
| `low` | 2 GB | 1 | 256 | Light tasks; safe to run several in parallel. |
| `medium` | 4 GB | 2 | 512 | Balanced default for most work. |
| `high` | 8 GB | 4 | 1024 | Heavy builds / large test suites. |

Your last choice is saved to `./.resource-preset` (git-ignored) and used as the
default next time. Skip the prompt with an env var:

```bash
CLAUDE_RESOURCES=medium       ./run.sh ~/code/weave
CLAUDE_RESOURCES=unrestricted ./run.sh ~/code/weave
```

Non-interactive runs (no TTY) reuse the saved preset, or fall back to
`unrestricted` if none is saved — so existing headless/CI usage is unchanged
until you pick a preset.

## Review changes

```bash
cd ~/code/weave
git diff
git add . && git commit -m "..."
```

If a run goes wrong: `git checkout .` resets everything.

## Tips

- Run on a clean branch so `git diff` shows exactly what Claude did.
- For anything non-trivial, prefer interactive mode: enter plan mode (**Shift+Tab**) and let Claude draft a plan before it writes code, and paste spec sheets straight into the prompt rather than cramming everything into one headless task string.
- Headless mode is best for small, well-scoped jobs you can describe in a sentence or two.
- Break large tasks into smaller focused runs (or one interactive session with several planned steps).
