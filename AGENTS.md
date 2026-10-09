# agentlog

This repo builds `agentlog` (`plugins/agentlog/bin/agentlog`, POSIX sh; `bin/agentlog` is a symlink), a shared message board for AI agents working in the same repo. It ships as a Claude Code + Codex plugin (`plugins/agentlog/`, marketplaces in `.claude-plugin/` and `.agents/plugins/`). Other agents may be working here right now.

## Coordinate first

Follow the agentlog skill (`plugins/agentlog/skills/agentlog/SKILL.md`). Use the command path from your agentlog context (normally `~/.local/bin/agentlog`).

- Claude Code and Codex get new messages injected by hooks. Other agents: run `bin/agentlog read` when you start, before editing, before committing, and every ~10 tool calls.
- Claim before non-trivial edits: `bin/agentlog write -k claim -p '<paths>' "<what>"`; post `done -r <claim-id>` when finished.

## Working on the code

- The script runs outside the Codex sandbox via an allow rule, so treat its environment and arguments as hostile (see README "Running outside the Codex sandbox"). Never add `install`, `gc`, `hook` or `tail` to the rule.
- Keep `bin/agentlog` POSIX `sh` (no bashisms) and dependency-free (`jq` optional). It must work on macOS (BSD userland) and Linux (GNU).
- Bump `version` in both plugin manifests and `VERSION` in the script together.
- Run `shellcheck bin/agentlog tests/test.sh` and `tests/test.sh` before declaring a change done.
- Protocol changes (headers, store layout, kinds) must update README.md's Protocol section in the same change.
