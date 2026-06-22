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

Assuming you already have Docker installed and a `claude login` session on the host:

```bash
# 1. Clone and enter the project
git clone https://github.com/johncarmichael-rgb/claude-in-a-box.git
cd claude-in-a-box

# 2. Make the run script executable
chmod +x run.sh entrypoint.sh

# 3. Launch interactive mode on your project (empty task "", instance name "a")
./run.sh /weave/1-weave-code "" a
```

That drops you into the normal Claude Code interface scoped to your project. See [Usage](#usage) for headless and parallel modes.

## Requirements

This runs Claude Code **inside Docker**, so you need Docker on the host:

- **Docker Engine** (or Docker Desktop) with the **`docker compose`** plugin — `run.sh` and the compose flow both rely on it.
- The Docker daemon running, and your user able to talk to it (`docker ps` should work without `sudo`).
- A working `claude login` session on the host (see [Authentication](#authentication)).

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
  managed-settings.json   # enforces the git/rm block
  run.sh
```

```bash
chmod +x run.sh entrypoint.sh
```

## Authentication

The container inherits your host `claude login` session: `~/.claude` is mounted read-only and **copied into a writable per-container home** at startup, so token refresh works without ever writing back to (or corrupting) your host credentials.

Check you're logged in on the host:

```bash
claude whoami
```

If not: `claude login`.

> **Parallel caveat:** OAuth tokens rotate on refresh. Several containers refreshing the same token concurrently can invalidate each other and even log out the host. For short tasks this is rarely hit. For heavy parallel use, set `ANTHROPIC_API_KEY` instead — `run.sh` forwards it automatically when present.

### Fresh session (don't inherit the host login)

If you have **multiple Claude Max accounts** and want this box on a different one than your host, pass `--fresh` (alias `--no-inherit`). The host `~/.claude` is then **not** mounted or copied — instead you log in inside the container on first run, and that login is saved per instance under `./.sessions/<instance>/` so it's reused next time.

```bash
./run.sh --fresh ~/code/weave              # interactive; run /login when it starts
./run.sh --fresh ~/code/weave "" work      # same, saved under instance "work"
```

Notes:
- First `--fresh` run **must be interactive** (no task) so you can complete the login; once saved, headless `--fresh` runs reuse it.
- `--fresh` deliberately ignores `ANTHROPIC_API_KEY` so the new login isn't shadowed by a host key.
- `.sessions/` holds real credentials and is git-ignored. Delete `./.sessions/<instance>/` to forget that account.

### Resume a previous session

By default the container is throwaway: its conversation transcript lives in the ephemeral container home and is gone on exit, so there's nothing to resume next run. Pass `--resume` (alias `--continue`) to persist it and pick up where you left off.

```bash
./run.sh --resume ~/code/weave             # first run seeds; later runs continue
./run.sh --resume ~/code/weave "keep going on the refactor"   # headless resume
```

How it works:
- Transcripts are stored **inside the project** at `<project>/.claude-box/` (Claude writes them there because the project is mounted at `/workspace`). They survive the `--rm` teardown because that directory is the real project on your host.
- On launch, if a prior transcript exists for the project, Claude is started with `--continue` (most recent session); if none exists, it starts fresh and saves for next time.
- `.claude-box/` is automatically added to the project's `.git/info/exclude` — a **local, untracked** git ignore, so your committed `.gitignore` is never modified. Delete `<project>/.claude-box/` to forget the history.
- Note: transcripts can contain code and secrets, the same as the `~/.claude/projects/` files Claude already writes in normal use — this just relocates them into the project.
- Composes with `--fresh` (fresh login *and* persisted history): `./run.sh --fresh --resume ~/code/weave`.

## Usage

```bash
./run.sh [--fresh] [--resume] <project_path> ["<task>"] [instance_name]
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

Two or three on the same codebase (each needs a **unique instance name**; separate terminals, or background with `&`). Pass an empty task `""` to run an interactive instance with a custom name:

```bash
./run.sh ~/code/weave "write tests for the auth middleware" a
./run.sh ~/code/weave "add input validation to the CRM model" b
./run.sh ~/code/weave "" c          # interactive, instance c
```

> Parallel agents **share the same files** (you chose the shared-mount model). Give each non-overlapping work, or simultaneous edits to the same file can clobber each other. For collision-free parallelism, switch to a git-worktree-per-agent setup.

### Via docker compose

`run.sh` is the easiest path, but you can also use compose directly. Use `run` (not `up`) so you attach to a real terminal:

```bash
PROJECT_PATH=~/code/weave docker compose run --rm claude-in-a-box              # interactive
PROJECT_PATH=~/code/weave TASK="fix the flaky test" docker compose run --rm claude-in-a-box  # headless
```

## What's blocked, and how

`git`, `rm`, and `rmdir` are denied via `managed-settings.json`, baked into the image at `/etc/claude-code/managed-settings.json`. Managed settings are the highest-precedence config: they **cannot** be overridden by your mounted `~/.claude`, by project settings, or by `--dangerously-skip-permissions`. Claude is also told up front (system prompt) that these commands are unavailable, so it won't waste turns retrying.

Everything else runs without prompts (`--dangerously-skip-permissions`), so the agent is fully autonomous within those guardrails.

To block or allow more commands, edit `managed-settings.json` and rebuild. Pattern form is `Bash(<cmd>:*)`. Note: a deny on `git` won't catch `git` smuggled through `bash -c "git ..."` — fine for a cooperative agent, but if you need airtight enforcement add a `PreToolUse` hook.

## File ownership

The container runs as **your** UID/GID (passed in by `run.sh`), so files Claude creates are owned by you — no root-owned files to `sudo` away, and git sees a matching owner.

## Network

Full network access by default (so Claude can install packages). For full isolation, add `network_mode: none` to the compose service, or `--network none` to the `docker run` in `run.sh`. Only do this if the task needs no package installs.

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
