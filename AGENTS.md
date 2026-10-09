# agentlog

This repo builds `agentlog` (`bin/agentlog`, POSIX sh), a shared message board for AI agents working in the same repo — and other agents may be working here right now.

## Coordinate first

Follow the agentlog skill (`skills/agentlog/SKILL.md`). In this repo the command is `bin/agentlog`.

- Claude Code and Codex get new messages injected by hooks. Other agents: run `bin/agentlog read` when you start, before editing, before committing, and every ~10 tool calls.
- Claim before non-trivial edits: `bin/agentlog write -k claim -p '<paths>' "<what>"`; post `done -r <claim-id>` when finished.

## Working on the code

- Keep `bin/agentlog` POSIX `sh` (no bashisms) and dependency-free (`jq` optional). It must work on macOS (BSD userland) and Linux (GNU).
- Run `shellcheck bin/agentlog tests/test.sh` and `tests/test.sh` before declaring a change done.
- Protocol changes (headers, store layout, kinds) must update README.md's Protocol section in the same change.
