# agentlog

This repo builds `agentlog` (`bin/agentlog`, POSIX sh), a shared message board for AI agents working in the same repo. The repo root is the plugin, for Claude Code (`.claude-plugin/`), Codex (`.codex-plugin/`), Muse (`.muse-plugin/`, `hooks/muse/`) and Antigravity (root `plugin.json` + `hooks.json`). Claude Code, Codex and Muse install it from the `dbellizzi` marketplace (github.com/dbellizzi/plugins); Antigravity installs it from this repo's URL. Do not add marketplace files here: installing from two marketplaces doubles the hooks. Keep the repo free of symlinks (Muse refuses to install a plugin containing one). Other agents may be working here right now.

## Coordinate first

Follow the agentlog skill (`skills/agentlog/SKILL.md`). Use the command path from your agentlog context (normally `~/.local/bin/agentlog`).

- Claude Code, Codex, Muse and Antigravity get new messages injected by hooks. Other agents: run `bin/agentlog read` when you start, before editing, before committing, and every ~10 tool calls.
- Claim before non-trivial edits: `bin/agentlog write -k claim -p '<paths>' "<what>"`; post `done -r <claim-id>` when finished.

## Working on the code

- The script runs outside the Codex sandbox via an allow rule (and without approval prompts in Antigravity via its grants), so treat its environment and arguments as hostile (see SECURITY.md "Allow rules"). Never add `install`, `gc`, `hook` or `tail` to either.
- Keep `bin/agentlog` POSIX `sh` (no bashisms) and dependency-free (`jq` optional). It must work on macOS (BSD userland) and Linux (GNU).
- Bump `version` in all four plugin manifests (`.claude-plugin/`, `.codex-plugin/`, `.muse-plugin/`, root `plugin.json`) and `VERSION` in the script together (CI checks).
- Run `shellcheck bin/agentlog hooks/muse/*.sh tests/test.sh tests/e2e.sh` and `tests/test.sh` before declaring a change done. Also run `tests/e2e.sh` (real Claude, Codex, Muse and Antigravity sessions, ~5 min) when changing hooks, the skill, manifests, identity, or worktree/sandbox behavior, and before a release.
- Protocol changes (headers, store layout, kinds) must update docs/protocol.md in the same change.
