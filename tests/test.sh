#!/bin/sh
# shellcheck disable=SC2034,SC1010,SC2015  # vars are used inside eval strings
# Self-contained tests: each case runs against a fresh store in a temp dir.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
AL=$here/bin/agentlog
root=$(mktemp -d "${TMPDIR:-/tmp}/agentlog-test.XXXXXX")
trap 'rm -rf "$root"' EXIT
fails=0

ok() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

fresh() {
  export AGENTLOG_DIR="$root/$1"
  unset AGENTLOG_SESSION AGENTLOG_AGENT CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID
}
run() { _a=$1 _s=$2; shift 2; AGENTLOG_AGENT=$_a AGENTLOG_SESSION=$_s "$AL" "$@"; }

# --- concurrent writers never lose or tear a message
fresh concurrent
writers=20 per=10
i=0
while [ $i -lt $writers ]; do
  (
    j=0
    while [ $j -lt $per ]; do
      run w "w$i" write "writer $i message $j with some padding to make it longer than a few bytes" >/dev/null
      j=$((j + 1))
    done
  ) &
  i=$((i + 1))
done
wait
n=$(find "$AGENTLOG_DIR/msgs" -name '*.msg' | wc -l | tr -d ' ')
check "concurrent: $((writers * per)) messages written" "[ $n -eq $((writers * per)) ]"
torn=$(for f in "$AGENTLOG_DIR"/msgs/*.msg; do grep -q '^Kind: note$' "$f" && tail -1 "$f" | grep -q 'few bytes$' || echo "$f"; done)
check "concurrent: every message intact" "[ -z \"$torn\" ]"
check "concurrent: no temp files left" "[ -z \"\$(ls -A \"$AGENTLOG_DIR/tmp\")\" ]"
got=$(run r reader read | grep -c '^\[')
check "concurrent: reader sees all $((writers * per))" "[ $got -eq $((writers * per)) ]"

# --- read semantics: own messages hidden, read-once, peek, addressing
fresh read
run claude-code aaaa1111 write "hello everyone" >/dev/null
run codex bbbb2222 write -t aaaa "just for a" >/dev/null
run codex bbbb2222 write -t codex "for codex agents" >/dev/null
out=$(run claude-code aaaa1111 read)
check "read: own message not delivered" "! printf '%s' \"\$out\" | grep -q 'hello everyone'"
check "read: session-prefix addressing" "printf '%s' \"\$out\" | grep -q 'just for a'"
check "read: other agent's broadcast hidden" "! printf '%s' \"\$out\" | grep -q 'for codex agents'"
out=$(run codex cccc3333 read --peek)
check "read: agent-name addressing" "printf '%s' \"\$out\" | grep -q 'for codex agents'"
check "read: direct message not leaked" "! printf '%s' \"\$out\" | grep -q 'just for a'"
check "read: peek leaves unread" "[ -n \"\$(run codex cccc3333 read)\" ]"
check "read: second read empty" "[ -z \"\$(run codex cccc3333 read)\" ]"
check "read: multi-line body kept" "run x dddd4444 write 'line one
line two' >/dev/null && run y eeee5555 read | grep -q '^    line two$'"

# --- read --json: one valid object per message, escaping, nulls, -n notice on stderr
fresh json
c=$(run codex bbbb2222 write -k claim -p 'src/**' 'claim "quoted" \ back	tab
second line' 2>/dev/null)
run codex bbbb2222 write -k reply -r "$c" -t aaaa "plain reply" >/dev/null
out=$(run claude-code aaaa1111 read --json --peek)
check "json: one line per message" "[ \$(printf '%s\n' \"\$out\" | wc -l) -eq 2 ]"
check "json: every line parses" "printf '%s\n' \"\$out\" | jq -e . >/dev/null"
check "json: all fields present" "printf '%s\n' \"\$out\" | head -1 | jq -e 'keys == ([\"agent\",\"body\",\"branch\",\"date\",\"expires\",\"id\",\"kind\",\"paths\",\"re\",\"session\",\"to\"] | sort)' >/dev/null"
check "json: claim fields and escaped body" "printf '%s\n' \"\$out\" | head -1 | jq -e --arg c \"$c\" '.id == \$c and .kind == \"claim\" and .paths == \"src/**\" and .agent == \"codex\" and .session == \"bbbb2222\" and .re == null and (.expires | type) == \"number\" and .body == \"claim \\\"quoted\\\" \\\\ back\\ttab\\nsecond line\"' >/dev/null"
check "json: reply fields" "printf '%s\n' \"\$out\" | tail -1 | jq -e --arg c \"$c\" '.re == \$c and .to == \"aaaa\" and .paths == null and .expires == null and .body == \"plain reply\"' >/dev/null"
check "json: -n notice goes to stderr" "[ \$(run claude-code aaaa1111 read --json -n 1 2>/dev/null | jq -c . | wc -l) -eq 1 ] && run claude-code aaaa1111 read --all --json -n 1 2>&1 >/dev/null | grep -q 'not shown'"

# --- claims: expiry, release by id, bare release
fresh claims
c1=$(run a aaaa1111 write -k claim -p 'src/**' "refactor src")
run a aaaa1111 write -k claim -p 'docs/' --ttl 1s "docs" >/dev/null
c3=$(run b bbbb2222 write -k claim -p 'tests/' "tests" 2>/dev/null)
sleep 2
cl=$(run a aaaa1111 claims)
check "claims: expired claim dropped" "! printf '%s' \"\$cl\" | grep -q docs/"
check "claims: live claims listed" "printf '%s' \"\$cl\" | grep -q 'src/\*\*' && printf '%s' \"\$cl\" | grep -q tests/"
run a aaaa1111 write -k done -r "$c1" "src refactor merged" >/dev/null
check "claims: done -r closes claim" "! run a aaaa1111 claims | grep -q 'src/'"
run b bbbb2222 write -k release "stepping away" >/dev/null
check "claims: bare release closes all of a session" "[ -z \"\$(run a aaaa1111 claims)\" ]"
check "claims: claim requires paths" "! run a aaaa1111 write -k claim nope 2>/dev/null"
check "claims: overlap warning on stderr" "run a aaaa1111 write -k claim -p x 'x' >/dev/null 2>&1; run b bbbb2222 write -k claim -p y 'y' 2>&1 >/dev/null | grep -q 'other active claims'"
: "$c3"

# --- hook: valid JSON, silent when nothing new, identity from stdin
fresh hook
hj() { printf '{"session_id":"%s","hook_event_name":"%s","cwd":"/x"}' "$1" "$2"; }
out=$(hj aaaa1111 SessionStart | "$AL" hook claude-code)
check "hook: SessionStart emits JSON" "printf '%s' \"\$out\" | jq -e '.hookSpecificOutput.hookEventName == \"SessionStart\"' >/dev/null"
check "hook: SessionStart states identity" "printf '%s' \"\$out\" | jq -r .hookSpecificOutput.additionalContext | grep -q 'claude-code:aaaa1111'"
check "hook: silent PostToolUse with nothing new" "[ -z \"\$(hj aaaa1111 PostToolUse | \"$AL\" hook claude-code)\" ]"
run codex bbbb2222 write -k request -t aaaa 'please "pause" \ now	tab' >/dev/null
out=$(hj aaaa1111 PostToolUse | "$AL" hook claude-code)
check "hook: new message → valid JSON with escaped body" "printf '%s' \"\$out\" | jq -r .hookSpecificOutput.additionalContext | grep -q 'please \"pause\" \\\\ now'"
check "hook: delivered once" "[ -z \"\$(hj aaaa1111 PostToolUse | \"$AL\" hook claude-code)\" ]"
check "hook: registers presence" "[ -f \"$AGENTLOG_DIR/sessions/aaaa1111\" ] && grep -q agent=claude-code \"$AGENTLOG_DIR/sessions/aaaa1111\""

# --- identity from agent env vars
fresh ident
check "identity: Claude Code env" "[ \"\$(CLAUDE_CODE_SESSION_ID=abc123456789 \"$AL\" whoami)\" = 'claude-code:abc12345 (session abc123456789)' ]"
check "identity: Codex env" "CODEX_SESSION_ID=01a11f2b-x \"$AL\" whoami | grep -q '^codex:01a11f2b'"

# --- tail: last N across all senders, with no read cursor changes
fresh tail
run a aaaa1111 write 'tail oldest' >/dev/null
run b bbbb2222 write -t elsewhere 'tail directed' >/dev/null
run a aaaa1111 write 'tail own newest' >/dev/null
out=$(run a aaaa1111 tail -n 2)
check "tail: exactly the last N messages in order" "[ \"\$(printf '%s\n' \"\$out\" | grep '^    ')\" = '    tail directed
    tail own newest' ]"
check "tail: leaves read cursor untouched" "[ ! -e \"$AGENTLOG_DIR/seen/aaaa1111\" ]"
check "tail: repeat shows the same messages" "[ \"\$(run a aaaa1111 tail -n 2)\" = \"\$out\" ]"
check "tail: zero messages" "[ -z \"\$(run a aaaa1111 tail -n 0)\" ]"
check "tail: rejects invalid counts" "! run a aaaa1111 tail -n nope 2>/dev/null && ! run a aaaa1111 tail -n -1 2>/dev/null"
check "tail: no temp files left" "[ -z \"\$(ls -A \"$AGENTLOG_DIR/tmp\")\" ]"

# --- gc
fresh gc
run a aaaa1111 write old >/dev/null
run b bbbb2222 read >/dev/null
touch -t 202001010000 "$AGENTLOG_DIR"/msgs/*.msg
run a aaaa1111 write new >/dev/null
run a aaaa1111 gc --days 7
check "gc: old message removed, new kept" "[ \$(ls \"$AGENTLOG_DIR/msgs\" | wc -l) -eq 1 ]"
check "gc: seen list pruned" "[ ! -s \"$AGENTLOG_DIR/seen/bbbb2222\" ]"

# --- worktrees: one shared store; sandboxed writers fall back to a local store
fresh wt
unset AGENTLOG_DIR
mkdir -p "$root/wt/repo"
repo=$(cd "$root/wt/repo" && pwd -P)
git -C "$repo" init -q -b main && git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$repo" worktree add -q -b side "$root/wt/side"
side=$(cd "$root/wt/side" && pwd -P)
shared=$repo/.agentlog
check "worktree: resolves to the main checkout's store" "[ \"\$(cd \"$side\" && \"$AL\" dir)\" = \"$shared\" ]"
(cd "$side" && run codex bbbb2222 write "from side, unsandboxed") >/dev/null
check "worktree: unsandboxed write lands in shared store" "[ \$(ls \"$shared/msgs\" | wc -l) -eq 1 ]"
check "worktree: exclude covers every worktree" "[ -z \"\$(git -C \"$side\" status --porcelain)\" ] && [ -z \"\$(git -C \"$repo\" status --porcelain)\" ]"

chmod -R a-w "$shared" # simulate a sandbox that can only write inside the worktree
sid=$(cd "$side" && run codex bbbb2222 write -k claim -p 'src/' "sandboxed claim")
check "worktree: sandboxed write falls back to local store" "[ -f \"$side/.agentlog/msgs/$sid.msg\" ]"
check "worktree: dir reports the fallback" "(cd \"$side\" && \"$AL\" dir) | grep -q 'writing to $side/.agentlog'"
out=$(cd "$repo" && run claude-code aaaa1111 read --peek)
check "worktree: main checkout reads local-store messages" "printf '%s' \"\$out\" | grep -q 'sandboxed claim'"
check "worktree: read-only reader does not advance cursor" "[ -n \"\$(cd \"$repo\" && run claude-code aaaa1111 read)\" ]"
check "worktree: claims union both stores" "(cd \"$repo\" && run claude-code aaaa1111 claims) | grep -q 'src/'"
(cd "$side" && run codex bbbb2222 read) >/dev/null
chmod -R u+w "$shared"

out=$(cd "$repo" && run claude-code aaaa1111 read)
check "worktree: unsandboxed run migrates local messages" "[ -f \"$shared/msgs/$sid.msg\" ] && [ -z \"\$(ls \"$side/.agentlog/msgs\")\" ]"
check "worktree: migrated message delivered once" "[ \$(printf '%s\n' \"\$out\" | grep -c 'sandboxed claim') -eq 1 ] && [ -z \"\$(cd \"$repo\" && run claude-code aaaa1111 read)\" ]"
check "worktree: local read cursor migrated" "[ -f \"$shared/seen/bbbb2222\" ] && [ ! -f \"$side/.agentlog/seen/bbbb2222\" ]"

[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
