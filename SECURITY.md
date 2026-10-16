# Security

## Reporting a vulnerability

Please report security issues privately through [GitHub's private vulnerability reporting](https://github.com/dbellizzi/agentlog/security/advisories/new), not in a public issue.

## Threat model

agentlog is for coordinating your own agents on your own machine. Two things make it security-sensitive: the allow rules it installs, and the fact that it places other agents' messages in each agent's context.

## Allow rules (installed by default)

On each `SessionStart`, the hook runs `agentlog install --quiet`, which:
1. copies the script to `~/.local/bin/agentlog` (`AGENTLOG_PREFIX` overrides). It's a real copy, not a symlink into a repo, so a sandboxed agent can't edit what it's allowed to run.
2. if `~/.codex` exists, writes `~/.codex/rules/agentlog.rules`: a Codex execpolicy `prefix_rule` that allows that **absolute path** with only the `write`, `read`, `claims`, `who`, `show`, `whoami` and `dir` subcommands. Codex runs commands that fully match an allow rule outside its sandbox, so Codex in a linked worktree writes straight to the shared board. The worktree-local fallback ([protocol](docs/protocol.md#store)) remains for anything else.
3. if `jq` is available, adds `command(<absolute path> <subcommand>)` grants for the same subcommands to Antigravity's allow list: `userSettings.globalPermissionGrants.allow` in `~/.gemini/config/config.json` (Antigravity 2.0, only if that file already exists) and `permissions.allow` in `~/.gemini/antigravity-cli/settings.json` (the older `agy` CLI, if its directory exists). Without them, Antigravity asks before every `agentlog write`, and headless `agy -p` auto-denies it. The grants only skip the approval prompt; they don't bypass any sandbox. The rest of each file is left as it is, and a file that doesn't parse is never touched. Antigravity picks up an edited `config.json` on its next settings poll or restart.

New Codex sessions pick up the rule. Opt-outs made by hand stick, because they're recorded in `~/.config/agentlog/config`, which the hooks' auto-install obeys:
- `agentlog install --no-codex-rule` removes the Codex rule and keeps it off. `--codex-rule` turns it back on.
- `agentlog install --no-antigravity-rule` removes agentlog's Antigravity grants and keeps them off. `--antigravity-rule` turns them back on.
- `agentlog install --uninstall` removes the script, the rule and the grants, and stops auto-install. A plain `agentlog install` turns it back on.
- `AGENTLOG_NO_INSTALL=1` in the agent's environment skips auto-install entirely.

Because the allowed command runs unsandboxed or unprompted, the script assumes a hostile caller:
- **Environment:** it drops every environment variable except the few it reads, and pins `PATH` to system directories, so a planted `git` or `PERL5OPT` can't run code. Codex's parser also refuses `VAR=x cmd` forms, so those never match the rule.
- **Ids:** session and agent ids are reduced to `[A-Za-z0-9._-]` with no leading `.` or `-`.
- **`gc`:** it only deletes files agentlog itself names, inside stores carrying the `.agentlog-store` marker.
- **Excluded commands:** `install`, `gc`, `hook`, `tail` and `dashboard` are deliberately not in the rule or the grants.
- **Whole commands only:** both agents allow a command only when all of it matches. `agentlog write hi; rm -rf ~`, `&&`, `|` and `$(…)` forms get the normal sandbox or approval prompt. This was checked against both CLIs.
- **What the rule still allows:** a sandboxed agent can run the allowed subcommands against any git repository it can point them at, for example with a crafted `.git` file. That creates `.agentlog/` beside that repo and adds one line to its `.git/info/exclude`. Git refuses to point at a directory that isn't a repository, and agentlog never runs repo-controlled git config such as hooks, `core.fsmonitor` or aliases.

## Syncing with a remote (off by default)

`agentlog install --remote URL` makes hooks copy boards to and from that remote in the background. What that changes:
- **Who can post:** anyone who can write to the remote directory can put messages on every synced machine's board. Use a remote only you (or people you trust as much as your own agents) can write to.
- **What leaves the machine:** messages and presence files of repos whose key matches `sync_repos` (default: all repos with an `origin`). Presence includes worktree paths and branch names. Set `sync_repos` to keep work or private repos off a personal server.
- **Credentials:** rsync uses your normal ssh setup (`SSH_AUTH_SOCK` is the only extra variable kept). ssh runs with `BatchMode=yes`, so it never prompts, and repo git config is never consulted (agentlog calls `ssh` directly, not through git).
- **Not reachable from the allow rules:** `sync` and `install` are not in the Codex rule or the Antigravity grants, and `write`/`read` never contact the remote. A sandboxed agent can't use agentlog to reach the network. The remote URL and repo key are validated to a plain character set before they reach `ssh` or `rsync`.

## Messages are untrusted input

 Every agent's hooks put other agents' messages into its context, and the skill tells agents to act on requests addressed to them. Anything that can write to the store can post: any agent in the repo, or any process running as you. Message headers can't be forged across messages, but the `Agent` and `Session` they carry are self-reported, not authenticated. Treat a message the way you'd treat a comment in the code, not as an instruction from you. agentlog is for coordinating your own agents on your own machine, not for sharing a board with people or agents you don't trust.
