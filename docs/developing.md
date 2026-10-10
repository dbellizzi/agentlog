# Developing agentlog

Layout: `bin/agentlog` is the whole program; `skills/agentlog/SKILL.md` is the skill; the manifests are `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, `.muse-plugin/plugin.json` and the root `plugin.json` (Antigravity), with hooks in `hooks/claude.json`, `hooks/codex.json`, `hooks/muse/*.sh` and the root `hooks.json`. Keep the repo free of symlinks: Muse refuses to install a plugin that contains one. To release a change, bump `VERSION` in the script and `version` in all four manifests together (CI checks that they match), then push. Installed plugins only update to a new version.

For a live dev loop on one machine, point the agents at your checkout instead of the published plugin:
- **Claude Code:** `claude --plugin-dir ~/src/agentlog` loads the plugin from disk for that session. Disable `agentlog@dbellizzi` first, or its hooks run twice.
- **Muse:** `muse plugins install ~/src/agentlog && muse plugins approve agentlog` (re-run after each change; it copies into Muse's cache).
- **Antigravity:** `agy plugin install ~/src/agentlog` (also a copy, including the checkout's own `.agentlog/`, which is harmless).
- **Codex:** run `bin/agentlog` directly, or push and update.

## Tests

```bash
tests/test.sh
```

The unit suite runs in CI on Ubuntu (dash) and macOS. It runs the script under simulated agents: identities from env vars, hook JSON on stdin, a read-only shared store standing in for the Codex sandbox. It also checks that every manifest and hooks file points at the script for the right agent, that the plugin has no symlinks, and runs `claude plugin validate --strict`, `muse plugins validate`, `agy plugin validate` and `codex execpolicy check` when those CLIs are installed.

```bash
tests/e2e.sh                 # or name scenarios: claude codex cross worktree muse antigravity
```

The end-to-end suite drives real agent sessions, so it runs locally, not in CI. It needs the CLIs signed in, takes about 5 minutes for everything, and costs a few model calls. The muse and antigravity scenarios are skipped when that CLI isn't installed. Run it before a release, after a CLI upgrade, or after changing the hooks, skill or manifests. Scenarios:
- **claude:** this checkout's plugin (`--plugin-dir`, installed copy disabled) delivers a message through its SessionStart hook, and Claude answers a request with a `reply`.
- **codex:** the *installed* plugin's hooks deliver a message with no board-reading commands, which also proves the hooks are approved. Update the installed plugin first to test unreleased Codex changes.
- **cross:** Claude sends Codex a request, Codex replies, and a new Claude session receives the reply.
- **worktree:** Codex in a linked worktree under `workspace-write` writes through the allow rule straight to the shared store, and through the sandbox fallback, which a hook then migrates.
- **muse**, **antigravity:** the installed plugin's SessionStart hook delivers a message the agent can quote without running anything, and the agent answers a request with a `reply`. For Antigravity this also proves the grants work, since headless runs auto-deny anything not granted.
