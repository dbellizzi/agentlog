#!/bin/sh
# End-to-end tests against real Claude Code and Codex sessions.
#
# Not run in CI: needs both CLIs signed in, network access, and a handful of
# model calls (about 2-3 minutes). Run before a release, after a CLI upgrade,
# or after changing the hooks, the skill or the manifests.
#
#   tests/e2e.sh                     all scenarios
#   tests/e2e.sh claude cross        just those (claude codex cross worktree)
#
# Claude Code loads this checkout's plugin (--plugin-dir, with the installed
# agentlog@dbellizzi disabled for the run). Codex has no per-run plugin
# directory, so it exercises the INSTALLED agentlog@dbellizzi plugin and its
# hook approvals; update it first when testing an unreleased Codex change.
#
# E2E_TIMEOUT (seconds per agent run, default 180), E2E_KEEP=1 keeps the
# scratch directory even when everything passes.
set -u

here=$(cd "$(dirname "$0")/.." && pwd -P)
plugin=$here/plugins/agentlog
AL=$plugin/bin/agentlog
INSTALLED=$HOME/.local/bin/agentlog
TIMEOUT=${E2E_TIMEOUT:-180}

# Running this from inside an agent session must not leak that session's
# identity or store into the agents and seed writes below.
unset AGENTLOG_DIR AGENTLOG_SESSION AGENTLOG_AGENT CLAUDE_CODE_SESSION_ID \
  CODEX_SESSION_ID CODEX_THREAD_ID OPENCODE_SESSION_ID CURSOR_SESSION_ID

die() { echo "e2e: $*" >&2; exit 2; }
for t in claude codex jq git; do command -v "$t" >/dev/null || die "needs $t on PATH"; done
if command -v timeout >/dev/null; then to=timeout
elif command -v gtimeout >/dev/null; then to=gtimeout
else die "needs timeout (coreutils)"; fi

# Not under $TMPDIR or /tmp: Codex's workspace-write sandbox may write there,
# which would hide the read-only shared store the worktree scenario needs.
cache=${XDG_CACHE_HOME:-$HOME/.cache}
mkdir -p "$cache" || die "cannot create $cache"
work=$(mktemp -d "$cache/agentlog-e2e.XXXXXX") || die "mktemp failed"
pass=0 fail=0

ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; [ $# -lt 2 ] || echo "     see $2"; }
check() { # check NAME LOG CMD...
  name=$1 logf=$2; shift 2
  if "$@"; then ok "$name"; else bad "$name" "$logf"; fi
}

token() { printf 'e2e-%s' "$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"; }

newrepo() { # newrepo NAME -> path of a fresh repo with one commit
  r=$work/$1
  git init -q "$r" || die "git init failed"
  git -C "$r" -c user.name=e2e -c user.email=e2e@example.invalid \
    -c commit.gpgsign=false commit -q --allow-empty -m init || die "git commit failed"
  printf '%s\n' "$r"
}

# seed DIR ARGS... : write as a fixed "human" sender; prints the message id
seed() { (cd "$1" && shift && AGENTLOG_AGENT=human AGENTLOG_SESSION=e2eseed0 "$AL" write "$@"); }

# board DIR : every message, as JSON Lines, without touching any cursor
board() { (cd "$1" && AGENTLOG_AGENT=observer AGENTLOG_SESSION=e2eobsv0 "$AL" read --all --peek --json); }

# has DIR JQ-FILTER / has_n DIR N JQ-FILTER : messages on the board matching the filter
has() { board "$1" | jq -e -s "map(select($2)) | length > 0" >/dev/null; }
has_n() { board "$1" | jq -e -s "map(select($3)) | length == $2" >/dev/null; }

# in_store STORE-PARENT TOKEN : a message file under STORE-PARENT/.agentlog holds TOKEN
in_store() { grep -rqs "$2" "$1/.agentlog/msgs"; }

claude_run() { # claude_run DIR LOG BASH(allow|deny) PROMPT
  dir=$1 logf=$2 bash=$3 prompt=$4
  if [ "$bash" = allow ]; then
    set -- --allowedTools "Bash($AL:*)" "Bash($INSTALLED:*)"
  else
    set -- --disallowedTools Bash
  fi
  (cd "$dir" && AGENTLOG_NO_INSTALL=1 "$to" "$TIMEOUT" claude -p "$prompt" \
    --plugin-dir "$plugin" --settings '{"enabledPlugins":{"agentlog@dbellizzi":false}}' \
    "$@") >"$logf" 2>&1
}

codex_run() { # codex_run DIR LOG SANDBOX PROMPT : JSON Lines events in LOG
  (cd "$1" && "$to" "$TIMEOUT" codex exec --json --sandbox "$3" "$4") >"$2" 2>"$2.err"
}

# codex_said LOG TOKEN : one of codex's messages contains TOKEN
codex_said() {
  jq -r 'select(.item.type? == "agent_message") | .item.text' "$1" | grep -q "$2"
}

# codex_read_board LOG : did codex read the board itself (so hook delivery is unproven)?
codex_read_board() {
  jq -e -s 'map(select(.item.type? == "command_execution")
    | .item.command | select(test("agentlog\\s+(r|read|show|tail)\\b|\\.agentlog/"))) | length > 0' "$1" >/dev/null
}

QUOTE="Do not run any commands or tools. List every token beginning with 'e2e-' that appears anywhere in your context, one per line. If there are none, answer exactly NONE."

# --- claude: hooks from this checkout deliver messages, and Claude answers requests
s_claude() {
  r=$(newrepo claude)
  t1=$(token) t2=$(token)
  seed "$r" "note for whoever starts next: $t1" >/dev/null
  claude_run "$r" "$work/claude-hook.log" deny "$QUOTE"
  check "claude: SessionStart hook delivers a message" "$work/claude-hook.log" \
    grep -q "$t1" "$work/claude-hook.log"

  req=$(seed "$r" -k request -t claude-code "please reply with exactly: $t2")
  claude_run "$r" "$work/claude-reply.log" allow \
    "Handle any agentlog requests addressed to you, then say done."
  check "claude: answers a request with a reply" "$work/claude-reply.log" \
    has "$r" ".kind == \"reply\" and .re == \"$req\" and .agent == \"claude-code\" and (.body | contains(\"$t2\"))"
}

# --- codex: the installed plugin's hooks are loaded and approved
s_codex() {
  r=$(newrepo codex)
  t1=$(token)
  seed "$r" "note for whoever starts next: $t1" >/dev/null
  codex_run "$r" "$work/codex-hook.jsonl" read-only "$QUOTE"
  if codex_read_board "$work/codex-hook.jsonl"; then
    bad "codex: SessionStart hook delivers a message (codex read the board itself, so unproven)" \
      "$work/codex-hook.jsonl"
  else
    check "codex: SessionStart hook delivers a message (are its hooks approved?)" \
      "$work/codex-hook.jsonl" codex_said "$work/codex-hook.jsonl" "$t1"
  fi
}

# --- cross: Claude asks Codex, Codex replies, a new Claude session receives the reply
s_cross() {
  r=$(newrepo cross)
  t=$(token)
  seed "$r" "cross-agent test starting" >/dev/null
  claude_run "$r" "$work/cross-ask.log" allow \
    "Using agentlog, post a request addressed to codex (-t codex) asking it to reply with exactly: $t . Do nothing else, then say done."
  req=$(board "$r" | jq -r -s "map(select(.kind == \"request\" and .agent == \"claude-code\" and .to == \"codex\" and (.body | contains(\"$t\")))) | last | .id // empty")
  if [ -z "$req" ]; then
    bad "cross: claude posts a request to codex" "$work/cross-ask.log"
    return
  fi
  ok "cross: claude posts a request to codex"

  codex_run "$r" "$work/cross-reply.jsonl" workspace-write \
    "Handle any agentlog requests addressed to you, then say done."
  check "cross: codex replies to claude's request" "$work/cross-reply.jsonl" \
    has "$r" ".kind == \"reply\" and .re == \"$req\" and .agent == \"codex\" and (.body | contains(\"$t\"))"

  claude_run "$r" "$work/cross-receive.log" deny "$QUOTE"
  check "cross: a new claude session receives codex's reply" "$work/cross-receive.log" \
    grep -q "$t" "$work/cross-receive.log"
}

# --- worktree: Codex sandboxed in a linked worktree reaches the shared board
s_worktree() {
  r=$(newrepo wt-main)
  wt=$work/wt-side
  git -C "$r" worktree add -q -b e2e-side "$wt" || die "worktree add failed"
  # The main checkout creates the shared store, as an earlier session would have.
  seed "$r" "worktree test starting" >/dev/null
  t1=$(token) t2=$(token)
  codex_run "$wt" "$work/worktree.jsonl" workspace-write \
    "Run exactly these two shell commands, one after the other, then say done:
$INSTALLED write 'via allow rule $t1'
$AL write 'via sandbox fallback $t2'"

  if [ -f "$HOME/.codex/rules/agentlog.rules" ]; then
    check "worktree: allow-rule write lands in the shared store" "$work/worktree.jsonl" \
      in_store "$r" "$t1"
  else
    echo "skip worktree: allow-rule write (no ~/.codex/rules/agentlog.rules)"
  fi
  # The fallback store's message is gone by now: Codex's unsandboxed PostToolUse
  # hook migrates it into the shared store, so check both halves of that trip.
  check "worktree: sandboxed write fell back to a worktree store" "$work/worktree.jsonl" \
    test -f "$wt/.agentlog/.agentlog-store"
  check "worktree: a hook migrated the fallback write to the shared store" "$work/worktree.jsonl" \
    in_store "$r" "$t2"
  check "worktree: main checkout sees both writes, from codex" "$work/worktree.jsonl" \
    has_n "$r" 2 ".agent == \"codex\" and (.body | contains(\"$t1\") or contains(\"$t2\"))"
}

[ $# -gt 0 ] || set -- claude codex cross worktree
for s in "$@"; do
  case $s in
    claude | codex | cross | worktree) "s_$s" ;;
    *) die "unknown scenario '$s' (claude codex cross worktree)" ;;
  esac
done

echo
if [ "$fail" -ne 0 ]; then
  echo "$fail failed, $pass passed; logs in $work"
  exit 1
fi
echo "all $pass passed"
if [ -n "${E2E_KEEP:-}" ]; then echo "logs: $work"; else rm -rf "$work"; fi
