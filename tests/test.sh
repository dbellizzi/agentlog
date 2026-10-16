#!/bin/sh
# shellcheck disable=SC2016,SC2034,SC1010,SC2015  # vars are used inside eval strings; check strings expand when eval runs
# Self-contained tests: each case runs against a fresh store in a temp dir.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
AL=${AGENTLOG_TEST_BIN:-$here/bin/agentlog} # override to test another shell
root=$(mktemp -d "${TMPDIR:-/tmp}/agentlog-test.XXXXXX")
trap '[ -z "${DPID:-}" ] || kill "$DPID" 2>/dev/null; chmod -R u+w "$root" 2>/dev/null; rm -rf "$root"' EXIT
# Never touch the real home: hooks auto-install into ~/.local/bin and ~/.codex.
export HOME="$root/home"
mkdir -p "$HOME/.codex"
unset CODEX_HOME AGENTLOG_PREFIX AGENTLOG_NO_INSTALL
fails=0

ok() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

fresh() {
  export AGENTLOG_DIR="$root/$1"
  unset AGENTLOG_SESSION AGENTLOG_AGENT CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID \
    MUSE_SESSION_ID MUSE_THREAD_ID ANTIGRAVITY_CONVERSATION_ID
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

# --- read --from: exact agent name or session prefix, display-only filtering
fresh from
run codex bbbb2222 write 'from first codex' >/dev/null
run codex cccc3333 write 'from second codex' >/dev/null
run codex-extra dddd4444 write 'from other agent' >/dev/null
run codex bbbb2222 write -t elsewhere 'from private message' >/dev/null
run reader aaaa1111 write 'from own message' >/dev/null
out=$(run reader aaaa1111 read --from codex --peek)
check "from: exact agent name selects all its sessions" "printf '%s' \"\$out\" | grep -q 'from first codex' && printf '%s' \"\$out\" | grep -q 'from second codex' && ! printf '%s' \"\$out\" | grep -q 'from other agent'"
check "from: delivery addressing preserved" "! printf '%s' \"\$out\" | grep -q 'from private message'"
out=$(run reader aaaa1111 read --from bbbb --peek)
check "from: session prefix selects only that sender" "printf '%s' \"\$out\" | grep -q 'from first codex' && ! printf '%s' \"\$out\" | grep -q 'from second codex'"
out=$(run reader aaaa1111 read --from codex -n 1)
check "from: peek preserves unread and filter precedes limit" "printf '%s' \"\$out\" | grep -q 'from second codex' && ! printf '%s' \"\$out\" | grep -q 'from first codex'"
check "from: hidden messages also marked read" "[ -z \"\$(run reader aaaa1111 read)\" ]"
out=$(run reader aaaa1111 read --all --from aaaa --json --peek)
check "from: all and json support own sender prefix" "printf '%s' \"\$out\" | jq -e '.body == \"from own message\"' >/dev/null"
check "from: no matches still marks all read" "[ -z \"\$(run reader eeee5555 read --from absent)\" ] && [ -z \"\$(run reader eeee5555 read)\" ]"
check "from: missing or empty value rejected" "! run reader aaaa1111 read --from 2>/dev/null && ! run reader aaaa1111 read --from '' 2>/dev/null"

# --- read --json: one valid object per message, escaping, nulls, -n notice on stderr
fresh json
c=$(run codex bbbb2222 write -k claim -p 'src/**' 'claim "quoted" \ back	tab
second line' 2>/dev/null)
run codex bbbb2222 write -k reply -r "$c" -t aaaa "plain reply" >/dev/null
out=$(run claude-code aaaa1111 read --json --peek)
check "json: one line per message" "[ \$(printf '%s\n' \"\$out\" | wc -l) -eq 2 ]"
check "json: every line parses" "printf '%s\n' \"\$out\" | jq -e . >/dev/null"
check "json: all fields present" "printf '%s\n' \"\$out\" | head -1 | jq -e 'keys == ([\"agent\",\"body\",\"branch\",\"date\",\"expires\",\"host\",\"id\",\"kind\",\"paths\",\"re\",\"session\",\"to\"] | sort)' >/dev/null"
check "json: claim fields and escaped body" "printf '%s\n' \"\$out\" | head -1 | jq -e --arg c \"$c\" '.id == \$c and .kind == \"claim\" and .paths == \"src/**\" and .agent == \"codex\" and .session == \"bbbb2222\" and .re == null and (.expires | type) == \"number\" and .body == \"claim \\\"quoted\\\" \\\\ back\\ttab\\nsecond line\"' >/dev/null"
check "json: reply fields" "printf '%s\n' \"\$out\" | tail -1 | jq -e --arg c \"$c\" '.re == \$c and .to == \"aaaa\" and .paths == null and .expires == null and .body == \"plain reply\"' >/dev/null"
check "json: -n notice goes to stderr" "[ \$(run claude-code aaaa1111 read --json -n 1 2>/dev/null | jq -c . | wc -l) -eq 1 ] && run claude-code aaaa1111 read --all --json -n 1 2>&1 >/dev/null | grep -q 'not shown'"

# --- read --kind: show only listed kinds, still mark everything read
fresh kind
run codex bbbb2222 write "kind note" >/dev/null
run codex bbbb2222 write -k request -t aaaa "kind request" >/dev/null
run codex bbbb2222 write -k claim -p 'x/' "kind claim" 2>/dev/null >/dev/null
out=$(run claude-code aaaa1111 read --peek --kind request,claim)
check "kind: listed kinds shown" "printf '%s' \"\$out\" | grep -q 'kind request' && printf '%s' \"\$out\" | grep -q 'kind claim'"
check "kind: other kinds hidden" "! printf '%s' \"\$out\" | grep -q 'kind note'"
check "kind: unknown kind rejected" "! run claude-code aaaa1111 read --kind bogus 2>/dev/null"
check "kind: filtered read marks all read" "[ \$(run claude-code aaaa1111 read --kind note | grep -c '^\[') -eq 1 ] && [ -z \"\$(run claude-code aaaa1111 read)\" ]"
r=$(run codex bbbb2222 write -k request -t aaaa "need an answer")
run claude-code aaaa1111 write -r "$r" "answer" >/dev/null
run claude-code aaaa1111 write -k note -r "$r" "aside" >/dev/null
out=$(run codex bbbb2222 read --kind reply)
check "kind: -r without -k defaults to reply" "printf '%s' \"\$out\" | grep -q answer"
check "kind: explicit -k wins over -r default" "! printf '%s' \"\$out\" | grep -q aside"

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

# --- claims: closing without Re (by paths, or everything)
fresh claims-close
run a aaaa1111 write -k claim -p 'src/a/** src/b.ts' "a and b" >/dev/null 2>&1
run a aaaa1111 write -k claim -p 'docs/' "docs" >/dev/null 2>&1
run b bbbb2222 write -k claim -p 'src/a/**' "b also on a" >/dev/null 2>&1
run a aaaa1111 write -k done -p 'src/b.ts' "only b finished" >/dev/null
cl=$(run a aaaa1111 claims)
check "claims: done -p leaves a claim it only partly covers" "printf '%s' \"\$cl\" | grep -q 'src/a/\*\* src/b.ts'"
run a aaaa1111 write -k done -p 'src/b.ts,src/a/**' "a and b finished" >/dev/null
cl=$(run a aaaa1111 claims)
check "claims: done -p closes own claims it covers (comma list)" "! printf '%s' \"\$cl\" | grep -q 'src/b.ts'"
check "claims: done -p leaves other claims of the session" "printf '%s' \"\$cl\" | grep -q 'docs/'"
check "claims: done -p never closes another session's claim" "printf '%s' \"\$cl\" | grep -q 'bbbb2222'"
run a aaaa1111 write -k claim -p 'later/' "claimed after" >/dev/null 2>&1
sleep 1
run a aaaa1111 write -k done "all done" >/dev/null
run a aaaa1111 write -k claim -p 'next/' "claimed after done" >/dev/null 2>&1
cl=$(run a aaaa1111 claims)
check "claims: bare done closes the session's earlier claims" "! printf '%s' \"\$cl\" | grep -q -e 'docs/' -e 'later/'"
check "claims: bare done keeps later claims" "printf '%s' \"\$cl\" | grep -q 'next/'"
check "claims: bare done never closes another session's claim" "printf '%s' \"\$cl\" | grep -q 'bbbb2222'"
run b bbbb2222 write -k release -p 'elsewhere/' "not this one" >/dev/null
check "claims: release -p with unrelated paths closes nothing" "run a aaaa1111 claims | grep -q 'bbbb2222'"
: "$c3"

# --- hook: valid JSON, silent when nothing new, identity from stdin
fresh hook
hj() { printf '{"session_id":"%s","hook_event_name":"%s","cwd":"/x"}' "$1" "$2"; }
check "hook: SessionStart silent when no one else is here" "[ -z \"\$(hj aaaa1111 SessionStart | \"$AL\" hook claude-code)\" ]"
check "hook: silent outside a git repo" "[ -z \"\$(cd \"$root\" && hj aaaa1111 SessionStart | env -u AGENTLOG_DIR \"$AL\" hook claude-code)\" ]"
hj cccc3333 SessionStart | "$AL" hook codex >/dev/null
out=$(hj aaaa1111 SessionStart | "$AL" hook claude-code)
check "hook: SessionStart emits JSON once another session is active" "printf '%s' \"\$out\" | jq -e '.hookSpecificOutput.hookEventName == \"SessionStart\"' >/dev/null"
check "hook: SessionStart states identity" "printf '%s' \"\$out\" | jq -r .hookSpecificOutput.additionalContext | grep -q 'claude-code:aaaa1111'"
check "hook: silent PostToolUse with nothing new" "[ -z \"\$(hj aaaa1111 PostToolUse | \"$AL\" hook claude-code)\" ]"
run codex bbbb2222 write -k request -t aaaa 'please "pause" \ now	tab' >/dev/null
out=$(hj aaaa1111 PostToolUse | "$AL" hook claude-code)
check "hook: new message → valid JSON with escaped body" "printf '%s' \"\$out\" | jq -r .hookSpecificOutput.additionalContext | grep -q 'please \"pause\" \\\\ now'"
check "hook: delivered once" "[ -z \"\$(hj aaaa1111 PostToolUse | \"$AL\" hook claude-code)\" ]"
check "hook: registers presence" "[ -f \"$AGENTLOG_DIR/sessions/aaaa1111\" ] && grep -q agent=claude-code \"$AGENTLOG_DIR/sessions/aaaa1111\""

# --- hook: Muse (Claude-style JSON, side threads ignored) and Antigravity
fresh hook2
run codex bbbb2222 write "for muse and antigravity" >/dev/null
mj() { MUSE_SESSION_ID=muse0001 MUSE_THREAD_ID=$1 "$AL" hook muse; }
out=$(hj muse0001 SessionStart | mj muse0001)
check "hook: muse main thread gets Claude-style context" "printf '%s' \"\$out\" | jq -r .hookSpecificOutput.additionalContext | grep -q 'muse:muse0001'"
run codex bbbb2222 write "second note" >/dev/null
check "hook: muse side thread stays silent and unregistered" "[ -z \"\$(hj side0001 PostToolUse | mj side0001)\" ] && [ ! -e \"$AGENTLOG_DIR/sessions/side0001\" ]"
check "hook: muse main thread then receives the message" "hj muse0001 PostToolUse | mj muse0001 | jq -r .hookSpecificOutput.additionalContext | grep -q 'second note'"
aj() { printf '{"conversationId":"%s","workspacePaths":["%s"],"invocationNum":0}' "$1" "$2"; }
out=$(aj agyc0001 /nonexistent | "$AL" hook antigravity SessionStart)
check "hook: antigravity SessionStart injects an ephemeral message" "printf '%s' \"\$out\" | jq -r '.injectSteps[0].ephemeralMessage' | grep -q 'antigravity:agyc0001'"
check "hook: antigravity PreInvocation silent with nothing new" "[ -z \"\$(aj agyc0001 /nonexistent | \"$AL\" hook antigravity PreInvocation)\" ]"
out=$(aj agyc0009 /nonexistent | "$AL" hook antigravity PreInvocation)
check "hook: antigravity 2.0 (no SessionStart): first PreInvocation introduces the board" "printf '%s' \"\$out\" | jq -r '.injectSteps[0].ephemeralMessage' | grep -q 'other agents are working in this repo. You are antigravity:agyc0009'"
check "hook: antigravity 2.0: later PreInvocations stay quiet" "[ -z \"\$(aj agyc0009 /nonexistent | \"$AL\" hook antigravity PreInvocation)\" ]"
run codex bbbb2222 write "third note" >/dev/null
check "hook: antigravity PreInvocation delivers new messages" "aj agyc0001 /nonexistent | \"$AL\" hook antigravity PreInvocation | jq -r '.injectSteps[0].ephemeralMessage' | grep -q 'third note'"
agr=$root/agy-repo
git init -q "$agr"
check "hook: relative \$0 still resolves after cd (Antigravity runs ./bin/agentlog)" "(cd \"\$(dirname \"$AL\")/..\" && aj agyc0003 \"$agr\" | ./bin/agentlog hook antigravity SessionStart | jq -r '.injectSteps[0].ephemeralMessage' | grep -q 'Command: /[^ ]*/agentlog ')"
check "hook: antigravity finds the repo from workspacePaths, not its cwd" "(cd \"$root\" && aj agyc0002 \"$agr\" | env -u AGENTLOG_DIR \"$AL\" hook antigravity SessionStart >/dev/null); [ -f \"$agr/.agentlog/sessions/agyc0002\" ]"

# --- hook: editing a file inside another session's claim warns once per claim
fresh edits
er=$root/edit-repo
git init -q "$er"
mkdir -p "$er/src/auth" "$er/sub"
pj() { # pj SESSION TOOL TOOL_INPUT-JSON
  printf '{"session_id":"%s","hook_event_name":"PostToolUse","cwd":"%s","tool_name":"%s","tool_input":%s,"tool_response":{"file_path":"%s/elsewhere/ignored.ts"}}' "$1" "${PJ_CWD:-$er}" "$2" "$3" "$er"
}
ctx() { jq -r '.hookSpecificOutput.additionalContext // empty'; }
run claude-code bbbb2222 write -k claim -p 'src/auth/** docs/guide.md lib/' "rewriting auth" >/dev/null 2>&1
run claude-code bbbb2222 write -k claim -p 'tools/x.ts:main' "symbol claim" >/dev/null 2>&1
hj aaaa1111 SessionStart | "$AL" hook codex >/dev/null
out=$(pj aaaa1111 Read "{\"file_path\":\"$er/src/auth/token.ts\"}" | "$AL" hook codex | ctx)
check "edits: reading a claimed file stays silent" "! printf '%s' \"\$out\" | grep -q 'you edited'"
out=$(pj aaaa1111 Edit "{\"file_path\":\"$er/README.md\"}" | "$AL" hook codex | ctx)
check "edits: editing an unclaimed file stays silent" "! printf '%s' \"\$out\" | grep -q 'you edited'"
out=$(pj aaaa1111 Edit "{\"file_path\":\"$er/src/auth/token.ts\",\"old_string\":\"a\"}" | "$AL" hook codex | ctx)
check "edits: Edit inside a glob claim warns with owner and file" "printf '%s' \"\$out\" | grep -q 'bbbb2222' && printf '%s' \"\$out\" | grep -q 'you edited: src/auth/token.ts'"
out=$(pj aaaa1111 Write "{\"file_path\":\"$er/src/auth/other.ts\"}" | "$AL" hook codex | ctx)
check "edits: the same claim warns only once per session" "! printf '%s' \"\$out\" | grep -q 'you edited'"
out=$(pj cccc3333 apply_patch '{"input":"*** Begin Patch\n*** Update File: lib/pool.ts\n@@\n-a\n+b\n*** End Patch\n"}' | "$AL" hook codex | ctx)
check "edits: apply_patch Update File inside a directory claim warns" "printf '%s' \"\$out\" | grep -q 'you edited: lib/pool.ts'"
out=$(pj dddd4444 Bash '{"command":["apply_patch","*** Begin Patch\n*** Add File: docs/guide.md\n+hi\n*** End Patch\n"]}' | "$AL" hook codex | ctx)
check "edits: apply_patch Add File via a shell command warns" "printf '%s' \"\$out\" | grep -q 'you edited: docs/guide.md'"
out=$(PJ_CWD=$er/sub pj eeee5555 Edit '{"file_path":"../tools/x.ts"}' | "$AL" hook codex | ctx)
out=$(PJ_CWD=$er/src pj eeee5555 Edit '{"file_path":"auth/z.ts"}' | "$AL" hook codex | ctx)
check "edits: relative path from a subdirectory resolves against the repo root" "printf '%s' \"\$out\" | grep -q 'you edited: src/auth/z.ts'"
out=$(pj ffff6666 NotebookEdit "{\"notebook_path\":\"$er/tools/x.ts\"}" | "$AL" hook codex | ctx)
check "edits: a path:symbol claim still matches the file" "printf '%s' \"\$out\" | grep -q 'you edited: tools/x.ts'"
out=$(pj bbbb2222 Edit "{\"file_path\":\"$er/src/auth/token.ts\"}" | "$AL" hook claude-code | ctx)
check "edits: your own claim never warns you" "! printf '%s' \"\$out\" | grep -q 'you edited'"
out=$(pj gggg7777 Edit "{\"file_path\":\"$er/src/authz.ts\"}" | "$AL" hook codex | ctx)
check "edits: a directory claim does not match a sibling prefix" "! printf '%s' \"\$out\" | grep -q 'you edited'"
check "edits: nudges are tracked per session" "grep -q . \"$AGENTLOG_DIR/nudged/aaaa1111\""

# --- presence: hooked sessions that go quiet stop holding claims; SessionEnd releases
fresh presence
hj aaaa1111 SessionStart | "$AL" hook claude-code >/dev/null
run claude-code aaaa1111 write -k claim -p 'src/' "hooked claim" >/dev/null 2>&1
run human hhhh0000 write -k claim -p 'docs/' "human claim, no hooks" >/dev/null 2>&1
check "presence: hook marks the session via=hook (kept by later CLI writes)" "grep -qx via=hook \"$AGENTLOG_DIR/sessions/aaaa1111\""
check "presence: the CLI alone never marks via=hook" "! grep -qx via=hook \"$AGENTLOG_DIR/sessions/hhhh0000\""
touch -t 202001010000 "$AGENTLOG_DIR/sessions/aaaa1111" "$AGENTLOG_DIR/sessions/hhhh0000"
cl=$(run x xxxx9999 claims)
check "presence: a stale hooked session's claims stop counting" "! printf '%s' \"\$cl\" | grep -q 'src/'"
check "presence: claims of sessions without hooks keep their lease" "printf '%s' \"\$cl\" | grep -q 'docs/'"
hj aaaa1111 PostToolUse | "$AL" hook claude-code >/dev/null
check "presence: a tool call revives the session and its claims" "run x xxxx9999 claims | grep -q 'src/'"
hj aaaa1111 SessionEnd | "$AL" hook claude-code >/dev/null
check "presence: SessionEnd releases the session's claims" "! run x xxxx9999 claims | grep -q 'src/'"
check "presence: SessionEnd marks the presence ended" "grep -q '^ended=' \"$AGENTLOG_DIR/sessions/aaaa1111\" && ! run x xxxx9999 who | grep -q aaaa1111"
n=$(find "$AGENTLOG_DIR/msgs" -type f | wc -l)
hj aaaa1111 SessionEnd | "$AL" hook claude-code >/dev/null
check "presence: SessionEnd with nothing held posts nothing" "[ \"\$(find \"$AGENTLOG_DIR/msgs\" -type f | wc -l)\" -eq $n ]"

# --- sync: two "machines" (own HOME, store and clone) share a board through a remote
fresh sync
rem=$root/remote
for m in m1 m2; do
  mkdir -p "$root/$m/home/.config/agentlog"
  printf 'host=%s\nremote=%s\n' "$m" "$rem" >"$root/$m/home/.config/agentlog/config"
  git init -q "$root/$m/repo"
  git -C "$root/$m/repo" remote add origin "git@GitHub.com:Owner/Repo.git"
done
on() { _m=$1; shift; (cd "$root/$_m/repo" && HOME=$root/$_m/home AGENTLOG_DIR=$root/$_m/store AGENTLOG_NO_INSTALL=1 "$@"); }
check "sync: dir names the remote board from the origin URL" "on m1 run codex aaaa1111 dir | grep -qx 'synced with $rem/github.com/owner/repo'"
for u in https://github.com/owner/repo.git ssh://git@github.com:22/owner/repo git@github.com:owner/repo/; do
  git -C "$root/m2/repo" remote set-url origin "$u"
  check "sync: repo key from $u" "on m2 run codex aaaa1111 dir | grep -q 'github.com/owner/repo\$'"
done
on m1 run claude-code aaaa1111 write -k claim -p 'src/**' "m1 claim" >/dev/null 2>&1
on m1 run claude-code aaaa1111 sync --quiet
on m2 run codex bbbb2222 sync --quiet
check "sync: a claim crosses machines" "on m2 run codex bbbb2222 claims | grep -q 'claude-code:aaaa1111 on m1  src/\*\*'"
check "sync: presence crosses machines" "on m2 run codex bbbb2222 who | grep -q 'aaaa1111 on m1'"
check "sync: messages carry Host" "grep -qx 'Host: m1' \"$rem\"/github.com/owner/repo/msgs/*.msg"
check "sync: read cursors stay local" "[ ! -d \"$rem/github.com/owner/repo/seen\" ]"
on m1 run claude-code aaaa1111 read >/dev/null
on m2 run codex bbbb2222 write -k request -t aaaa1111 "from m2" >/dev/null
f=$(find "$root/m2/store/msgs" -name '*bbbb2222*' | head -1)
touch -t 202001010000 "$f" # an old mtime, as if it reached the remote late
on m2 run codex bbbb2222 sync --quiet
printf '{"session_id":"aaaa1111","hook_event_name":"PostToolUse","cwd":"%s"}' "$root/m1/repo" >"$root/sync-hook.json"
check "sync: hooks don't sync again within 10s when nothing was written here" "on m1 \"$AL\" hook claude-code <\"$root/sync-hook.json\" >/dev/null; sleep 1; [ -z \"\$(find \"$root/m1/store/msgs\" -name '*bbbb2222*')\" ]"
rm -f "$root/m1/store/.sync-at" # as if 10s had passed
on m1 "$AL" hook claude-code <"$root/sync-hook.json" >/dev/null
i=0; while [ $i -lt 50 ] && [ -z "$(find "$root/m1/store/msgs" -name '*bbbb2222*')" ]; do sleep 0.1; i=$((i + 1)); done
check "sync: a hook starts a background sync that pulls new messages" "[ -n \"\$(find \"$root/m1/store/msgs\" -name '*bbbb2222*')\" ]"
i=0; while [ $i -lt 50 ] && [ -d "$root/m1/store/.sync.lock" ]; do sleep 0.1; i=$((i + 1)); done
out=$(on m1 "$AL" hook claude-code <"$root/sync-hook.json")
check "sync: a pulled message gets a fresh mtime, so the next hook delivers it" "printf '%s' \"\$out\" | grep -q 'from m2'"
check "sync: hook shows the sender's machine" "printf '%s' \"\$out\" | grep -q 'codex:bbbb2222 on m2'"
printf '{"session_id":"aaaa1111","hook_event_name":"SessionEnd","cwd":"%s"}' "$root/m1/repo" | on m1 "$AL" hook claude-code
i=0; while [ $i -lt 50 ] && ! grep -qs '^ended=' "$rem/github.com/owner/repo/sessions/aaaa1111"; do sleep 0.1; i=$((i + 1)); done
on m2 run codex bbbb2222 sync --quiet
check "sync: SessionEnd's release and ended presence reach the other machine" "! on m2 run codex bbbb2222 claims | grep -q aaaa1111 && ! on m2 run codex bbbb2222 who | grep -q aaaa1111"
old=$rem/github.com/owner/repo/msgs/20200101T000000.000000Z-old00000-aaaaaa.msg
printf 'Kind: note\n\nold\n' >"$old"; touch -t 202001010000 "$old"
rm -f "$root/m2/store/.sync-pruned"
on m2 run codex bbbb2222 sync --quiet
check "sync: daily prune expires old files on the remote" "[ ! -e \"$old\" ]"
check "sync: a remote with shell characters is refused" "! on m1 run x xxxx0000 install --remote 'ssh://h;rm/x' 2>/dev/null && ! on m1 run x xxxx0000 install --remote 'ssh://-oProxyCommand=x/y' 2>/dev/null"
check "sync: sync_repos keeps other repos off the remote" "on m1 run x xxxx0000 install --sync-repos 'github.com/someone-else/*' >/dev/null && on m1 run x xxxx0000 dir | grep -q 'not in sync_repos' && ! on m1 run x xxxx0000 sync 2>/dev/null"
check "sync: sync_repos globs match the repo key" "on m1 run x xxxx0000 install --sync-repos 'gitlab.com/x github.com/owner/*' >/dev/null && on m1 run x xxxx0000 sync --quiet"
git -C "$root/m2/repo" remote remove origin
check "sync: a repo without origin says why it can't sync" "on m2 run codex bbbb2222 sync 2>&1 | grep -q 'no usable origin'"

# --- identity from agent env vars
fresh ident
check "identity: Claude Code env" "[ \"\$(CLAUDE_CODE_SESSION_ID=abc123456789 \"$AL\" whoami)\" = 'claude-code:abc12345 (session abc123456789)' ]"
check "identity: Codex env" "CODEX_SESSION_ID=01a11f2b-x \"$AL\" whoami | grep -q '^codex:01a11f2b'"
check "identity: Muse env" "MUSE_SESSION_ID=01a122d1-x \"$AL\" whoami | grep -q '^muse:01a122d1'"
check "identity: Antigravity env" "ANTIGRAVITY_CONVERSATION_ID=1d2e1aa7-x \"$AL\" whoami | grep -q '^antigravity:1d2e1aa7'"
check "identity: inner agent beats an inherited Claude Code id" "CLAUDE_CODE_SESSION_ID=outer000 CODEX_THREAD_ID=inner000 \"$AL\" whoami | grep -q '^codex:inner000'"

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
check "gc: --days must be an integer" "! run a aaaa1111 gc --days '1 -delete' 2>/dev/null"
check "read: -n must be an integer" "! run a aaaa1111 read -n x 2>/dev/null"

# --- the allowed subcommands never run repo-controlled git config
fresh gitcfg
unset AGENTLOG_DIR
mkdir -p "$root/gitcfg/r"
git -C "$root/gitcfg/r" init -q
for k in core.fsmonitor core.pager core.hooksPath core.sshCommand alias.rev-parse alias.worktree; do
  git -C "$root/gitcfg/r" config "$k" "!touch $root/gitcfg/RAN"
done
(cd "$root/gitcfg/r" && run codex aaaa1111 write hi && run codex bbbb2222 read && run codex bbbb2222 claims &&
  run codex bbbb2222 who && run codex bbbb2222 dir) >/dev/null 2>&1
check "git config: no repo-controlled command ran" "[ ! -e \"$root/gitcfg/RAN\" ]"

# --- worktrees: one shared store; sandboxed writers fall back to a local store
fresh wt
unset AGENTLOG_DIR
mkdir -p "$root/wt/repo"
repo=$(cd "$root/wt/repo" && pwd -P)
git -C "$repo" init -q -b main && git -C "$repo" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m init
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

# --- install: copy outside the workspace + Codex allow rule, idempotent
fresh install
dest=$HOME/.local/bin/agentlog rules=$HOME/.codex/rules/agentlog.rules
check "install: hook auto-installed on SessionStart" "[ -x \"$dest\" ] && cmp -s \"$AL\" \"$dest\" && [ -f \"$rules\" ]"
check "install: rule allows only the absolute installed path" "grep -q 'pattern = \\[\"$dest\", \\[\"write\"' \"$rules\""
check "install: rule never allows install/gc/hook/tail/dashboard" "! grep -E '\"(install|gc|hook|tail|dashboard)\"' \"$rules\""
check "install: idempotent" "\"$AL\" install | grep -c 'up to date' | grep -qx 2"
if command -v codex >/dev/null 2>&1; then
  check "install: codex accepts the rule (write allowed)" "codex execpolicy check --rules \"$rules\" \"$dest\" write hi 2>/dev/null | grep -q '\"decision\":\"allow\"'"
  check "install: codex does not allow install" "codex execpolicy check --rules \"$rules\" \"$dest\" install 2>/dev/null | grep -q '\"matchedRules\":\\[\\]'"
fi
check "install: AGENTLOG_NO_INSTALL respected" "rm -f \"$dest\"; hj dddd4444 SessionStart | AGENTLOG_NO_INSTALL=1 \"$AL\" hook x >/dev/null; [ ! -e \"$dest\" ]"
check "install: --no-codex-rule removes the rule" "\"$AL\" install >/dev/null; \"$AL\" install --no-codex-rule >/dev/null; [ -x \"$dest\" ] && [ ! -e \"$rules\" ]"
check "install: hook respects --no-codex-rule" "hj eeee5555 SessionStart | \"$AL\" hook x >/dev/null; [ ! -e \"$rules\" ]"
check "install: --codex-rule opts back in" "\"$AL\" install --codex-rule >/dev/null; [ -f \"$rules\" ]"
check "install: uninstall removes both" "\"$AL\" install --uninstall >/dev/null; [ ! -e \"$dest\" ] && [ ! -e \"$rules\" ]"
check "install: hook does not reinstall after uninstall" "hj ffff6666 SessionStart | \"$AL\" hook x >/dev/null; [ ! -e \"$dest\" ] && [ ! -e \"$rules\" ]"
check "install: explicit install re-enables auto-install" "\"$AL\" install >/dev/null; rm -f \"$dest\"; hj gggg7777 SessionStart | \"$AL\" hook x >/dev/null; [ -x \"$dest\" ]"

# --- install: Antigravity permission grants merged into its settings.json
fresh agy-install
ags=$HOME/.gemini/antigravity-cli/settings.json
mkdir -p "$(dirname "$ags")"
printf '{"model":"m","permissions":{"allow":["command(git diff)"]}}\n' >"$ags"
"$AL" install >/dev/null
check "install: antigravity grants cover board subcommands only" "[ \"\$(jq --arg d \"command($dest \" '[.permissions.allow[] | select(startswith(\$d))] | length' \"$ags\")\" -eq 9 ] && ! jq -r '.permissions.allow[]' \"$ags\" | grep -qE ' (install|gc|hook|tail|dashboard)\)$'"
check "install: antigravity settings otherwise untouched" "jq -e '.model == \"m\" and .permissions.allow[0] == \"command(git diff)\"' \"$ags\" >/dev/null"
check "install: antigravity grants idempotent" "\"$AL\" install | grep -q \"up to date: $ags\" && [ \"\$(jq '.permissions.allow | length' \"$ags\")\" -eq 10 ]"
"$AL" install --no-antigravity-rule >/dev/null
check "install: --no-antigravity-rule removes only agentlog's grants" "jq -e '.permissions.allow == [\"command(git diff)\"]' \"$ags\" >/dev/null"
check "install: hook respects --no-antigravity-rule" "hj agy00001 SessionStart | \"$AL\" hook x >/dev/null; jq -e '.permissions.allow == [\"command(git diff)\"]' \"$ags\" >/dev/null"
"$AL" install --antigravity-rule >/dev/null
"$AL" install --uninstall >/dev/null
check "install: uninstall removes the antigravity grants" "jq -e '.permissions.allow == [\"command(git diff)\"]' \"$ags\" >/dev/null"
"$AL" install >/dev/null
printf 'not json\n' >"$ags"
"$AL" install >/dev/null
check "install: unparsable antigravity settings left alone" "[ \"\$(cat \"$ags\")\" = 'not json' ]"
agc=$HOME/.gemini/config/config.json
check "install: antigravity 2.0 config never created" "[ ! -e \"$agc\" ]"
mkdir -p "$(dirname "$agc")"
printf '{"userSettings":{"themeMode":"dark","globalPermissionGrants":{"allow":["command(npm test)"]}}}\n' >"$agc"
"$AL" install >/dev/null
check "install: antigravity 2.0 grants go into config.json" "[ \"\$(jq --arg d \"command($dest \" '[.userSettings.globalPermissionGrants.allow[] | select(startswith(\$d))] | length' \"$agc\")\" -eq 9 ] && jq -e '.userSettings.themeMode == \"dark\" and .userSettings.globalPermissionGrants.allow[0] == \"command(npm test)\"' \"$agc\" >/dev/null"
"$AL" install --no-antigravity-rule >/dev/null
check "install: --no-antigravity-rule cleans antigravity 2.0 config too" "jq -e '.userSettings.globalPermissionGrants.allow == [\"command(npm test)\"]' \"$agc\" >/dev/null"
"$AL" install --antigravity-rule >/dev/null
rm -rf "$HOME/.gemini"

# --- hardening: hostile environment and arguments
fresh harden
mkdir -p "$root/evil"
printf '#!/bin/sh\necho pwned >"%s/pwned"\n' "$root" >"$root/evil/git"
chmod +x "$root/evil/git"
cp "$root/evil/git" "$root/evil/perl"
PATH="$root/evil:$PATH" PERL5OPT=-MNoSuchModule run a aaaa1111 write "hostile env" >/dev/null
check "harden: PATH and PERL5OPT from the caller are ignored" "[ ! -e \"$root/pwned\" ] && run b bbbb2222 read | grep -q 'hostile env'"
check "harden: dot session ids are neutralised" "[ \"\$(AGENTLOG_SESSION=../../x \"$AL\" whoami)\" = 'unknown:x (session x)' ]"
victim=$root/victim
mkdir -p "$victim/tmp" "$victim/msgs" "$victim/sessions"
for f in tmp/keep msgs/notes.txt sessions/config; do echo data >"$victim/$f"; done
touch -t 202001010000 "$victim"/tmp/keep "$victim"/msgs/notes.txt "$victim"/sessions/config
AGENTLOG_DIR=$victim run a aaaa1111 gc --days 1
check "harden: gc only deletes agentlog's own files" "[ -f \"$victim/tmp/keep\" ] && [ -f \"$victim/msgs/notes.txt\" ] && [ -f \"$victim/sessions/config\" ]"

# --- dashboard: a perl server fed by the store; read-only toward the board
fresh dash
dt=$root/dash-t
mkdir -p "$dt"
DPID='' DBASE='' DPORT=''
http_code() { curl -s -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || :; }
dash_get() { # dash_get FILE PATH [HEADER]: read the stream for a second into FILE
  if [ -n "${3:-}" ]; then curl -sN --max-time 1 -H "$3" "$DBASE$2" >"$1" 2>/dev/null || :
  else curl -sN --max-time 1 "$DBASE$2" >"$1" 2>/dev/null || :; fi
}
dash_claims() { # the claims event of a fresh snapshot
  dash_get "$dt/snap" "/events?n=1"
  awk '/^event: claims$/ { getline; print; exit }' "$dt/snap"
}
dash_csp_ok() {
  curl -s -D "$dt/h" -o /dev/null "$DBASE/" &&
    grep -qiF "content-security-policy: default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; connect-src 'self'" "$dt/h"
}
ids_of() { grep '^id: ' "$1" | sed 's/^id: //'; }
# The perl child of dashboard $1 (a shell pid): 0 when its arguments end at the
# log limit, so no opener path was passed (stdout here is not a terminal).
dash_perl_gets_no_opener() {
  for _dpc in $(pgrep -P "$1"); do
    ps -p "$_dpc" -o args= | grep -q '^perl -e' || continue
    ps -p "$_dpc" -o args= | grep -q ' 1000 *$' && return 0
  done
  return 1
}

m1=$(run codex bbbb2222 write "dash first")
ml=$(run codex bbbb2222 write 'dash line one
dash line two')
m2=$(run codex bbbb2222 write "dash second")
c=$(run codex bbbb2222 write -k claim -p 'dash/**' "dash claim" 2>/dev/null)
m3=$(run claude-code aaaa1111 write "dash third")
exp3=$(printf '%s\n%s' "$c" "$m3")
exp4=$(printf '%s\n%s\n%s\n%s' "$ml" "$m2" "$c" "$m3")
# Temp files that atomic_write leaves in sessions/ are not records. One is a
# valid record under a fake session id (must be ignored); one is unreadable (its
# presence must not make any reader print an error).
printf 'agent=codex\nsession=ffff0000-hidden\nbranch=x\nworktree=/x\nhost=h\nseen=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$AGENTLOG_DIR/sessions/.w.test.hidden"
printf 'agent=codex\nsession=ffff0001-locked\n' >"$AGENTLOG_DIR/sessions/.w.test.locked"
chmod 000 "$AGENTLOG_DIR/sessions/.w.test.locked"
# The dashboard runs as codex bbbb2222; its presence and cursor must not move.
run codex bbbb2222 read --peek >/dev/null
touch -t 202001010000 "$AGENTLOG_DIR/seen/bbbb2222" "$AGENTLOG_DIR/sessions/bbbb2222"
touch -t 202001020000 "$dt/ref"
ro_before=$(cat "$AGENTLOG_DIR/seen/bbbb2222" "$AGENTLOG_DIR/sessions/bbbb2222" | cksum)

PERL5OPT=-MNoSuchModule PERL5LIB=$root/nope AGENTLOG_AGENT=codex AGENTLOG_SESSION=bbbb2222 \
  "$AL" dashboard --port 0 >"$dt/log" 2>"$dt/err" &
DPID=$!
i=0; while [ $i -lt 50 ] && ! grep -q 'dashboard at' "$dt/log"; do sleep 0.1; i=$((i + 1)); done
DBASE=$(sed -n 's|^agentlog: dashboard at \(http://127\.0\.0\.1:[0-9]*\)/ .*|\1|p' "$dt/log")
DPORT=${DBASE##*:}
check "dashboard: starts and prints its URL despite PERL5OPT and PERL5LIB" '[ -n "$DBASE" ]'
check "dashboard: outside a terminal perl gets no opener to run" 'dash_perl_gets_no_opener "$DPID"'
run codex bbbb2222 who >/dev/null 2>"$dt/who.err"
check "who: skips hidden temp session files, and prints no errors for them" '! run codex bbbb2222 who 2>/dev/null | grep -q ffff0000 && [ ! -s "$dt/who.err" ]'
dash_get "$dt/hid" "/events?n=1"
check "dashboard: its sessions event skips hidden temp session files" 'grep -q "^event: sessions" "$dt/hid" && ! grep -q ffff0000 "$dt/hid"'
check "dashboard: no store-race noise on stderr after several polls" '[ ! -s "$dt/err" ]'
i=0; while [ $i -lt 60 ] && ! { dash_claims | grep -qF "$c" && grep -qF "$m3" "$dt/snap"; }; do sleep 0.2; i=$((i + 1)); done

check "dashboard: GET / is the page, with the CSP header" 'dash_csp_ok && [ "$(http_code "$DBASE/")" = 200 ]'
check "dashboard: GET /app.js is served" '[ "$(http_code "$DBASE/app.js")" = 200 ]'
check "dashboard: a foreign Host header is refused" '[ "$(http_code -H "Host: evil.example:$DPORT" "$DBASE/")" = 403 ]'
check "dashboard: non-GET methods get 405" '[ "$(http_code -X POST "$DBASE/events")" = 405 ]'
dash_get "$dt/n2" "/events?n=2"
check "dashboard: claims and sessions snapshots, then the 2 newest messages oldest first" 'grep -qx "event: claims" "$dt/n2" && grep -qx "event: sessions" "$dt/n2" && [ "$(ids_of "$dt/n2")" = "$exp3" ]'
dash_get "$dt/resume" "/events" "Last-Event-ID: $m1"
check "dashboard: Last-Event-ID replays only the messages after it" '[ "$(ids_of "$dt/resume")" = "$exp4" ]'
dash_get "$dt/all" "/events"
check "dashboard: a multi-line body is one data line with \\n escapes" '[ "$(grep -c "^data: .*dash line one" "$dt/all")" -eq 1 ] && grep -qF "dash line one\ndash line two" "$dt/all" && ! grep -q "^dash line two" "$dt/all"'
check "dashboard: an open claim is in the claims event" 'dash_claims | grep -qF "$c"'
run claude-code aaaa1111 write -k done -r "$c" "dash done" >/dev/null
i=0; while [ $i -lt 30 ] && dash_claims | grep -qF "$c"; do sleep 0.3; i=$((i + 1)); done
check "dashboard: a closed claim leaves the claims event" '_cl=$(dash_claims); [ -n "$_cl" ] && ! printf "%s" "$_cl" | grep -qF "$c"'
curl -sN --max-time 8 "$DBASE/events?n=1" >"$dt/live" 2>/dev/null &
LP=$!
run claude-code aaaa1111 write "dash live arrival" >/dev/null
i=0; while [ $i -lt 60 ] && ! grep -qF "dash live arrival" "$dt/live"; do sleep 0.1; i=$((i + 1)); done
check "dashboard: a new message reaches an open stream within 6s" 'grep -qF "dash live arrival" "$dt/live"'
kill "$LP" 2>/dev/null || :
wait "$LP" 2>/dev/null || :
check "dashboard: running it leaves seen/ and sessions/ of its identity unchanged" '[ -z "$(find "$AGENTLOG_DIR/seen/bbbb2222" "$AGENTLOG_DIR/sessions/bbbb2222" -newer "$dt/ref")" ] && [ "$(cat "$AGENTLOG_DIR/seen/bbbb2222" "$AGENTLOG_DIR/sessions/bbbb2222" | cksum)" = "$ro_before" ]'
check "dashboard: bad --port or -n, and a port in use, exit non-zero" '! run codex bbbb2222 dashboard --port abc 2>/dev/null && ! run codex bbbb2222 dashboard --port 65536 2>/dev/null && ! run codex bbbb2222 dashboard -n x 2>/dev/null && ! run codex bbbb2222 dashboard -n 0 2>/dev/null && ! run codex bbbb2222 dashboard --port "$DPORT" >"$dt/inuse" 2>&1 && grep -q "cannot listen" "$dt/inuse"'
check "dashboard: --no-open is accepted; --no-open=x and unknown flags are refused" '! run codex bbbb2222 dashboard --no-open=x 2>/dev/null && ! run codex bbbb2222 dashboard --bogus 2>/dev/null && run codex bbbb2222 dashboard --no-open --port abc 2>&1 | grep -q "needs an integer"'
mkdir -p "$root/inuse-tmp"
TMPDIR=$root/inuse-tmp AGENTLOG_AGENT=codex AGENTLOG_SESSION=bbbb2222 "$AL" dashboard --port "$DPORT" >/dev/null 2>&1 || :
check "dashboard: a bind failure leaves no temp dir or FIFO behind" '[ -z "$(find "$root/inuse-tmp" -mindepth 1)" ]'
kill "$DPID" 2>/dev/null || :
wait "$DPID" 2>/dev/null || :
DPID=''

# TERM to the dashboard's shell frees its port at once: the traps kill the server.
# Without that the server lingers until the feed's next poll (up to 2s), so probe
# three fresh dashboards 0.2s after TERM and count any that still answer.
mkdir -p "$root/term-tmp"
tleak=0
for k in 1 2 3; do
  TMPDIR=$root/term-tmp AGENTLOG_AGENT=codex AGENTLOG_SESSION=bbbb2222 "$AL" dashboard --port 0 >"$dt/tlog$k" 2>&1 &
  TPID=$!
  i=0; while [ $i -lt 50 ] && ! grep -q 'dashboard at' "$dt/tlog$k"; do sleep 0.1; i=$((i + 1)); done
  TBASE=$(sed -n 's|^agentlog: dashboard at \(http://127\.0\.0\.1:[0-9]*\)/ .*|\1|p' "$dt/tlog$k")
  sleep 2.5   # let the feed reach its poll sleep: the old traps release only at its next poll
  if [ $k -eq 1 ]; then
    check "dashboard: the FIFO exists while the dashboard runs" '[ -n "$(find "$root/term-tmp" -name feed.fifo)" ]'
  fi
  kill -TERM "$TPID" 2>/dev/null || :
  sleep 0.2
  [ "$(http_code "$TBASE/")" = 000 ] || tleak=$((tleak + 1))
  wait "$TPID" 2>/dev/null || :
done
check "dashboard: TERM frees the port at once (none of 3 answers 0.2s later)" '[ -n "$TBASE" ] && [ "$tleak" -eq 0 ]'
check "dashboard: TERM leaves no FIFO behind" '[ -z "$(find "$root/term-tmp" -name feed.fifo)" ]'
mkdir -p "$root/two-tmp"
TMPDIR=$root/two-tmp AGENTLOG_AGENT=codex AGENTLOG_SESSION=bbbb2222 "$AL" dashboard --port 0 >"$dt/two1" 2>&1 &
T1=$!
TMPDIR=$root/two-tmp AGENTLOG_AGENT=codex AGENTLOG_SESSION=bbbb2222 "$AL" dashboard --port 0 >"$dt/two2" 2>&1 &
T2=$!
i=0; while [ $i -lt 50 ] && ! { grep -q 'dashboard at' "$dt/two1" && grep -q 'dashboard at' "$dt/two2"; }; do sleep 0.1; i=$((i + 1)); done
check "dashboard: two started at once each get their own FIFO" '[ "$(find "$root/two-tmp" -name feed.fifo | wc -l | tr -d " ")" -eq 2 ] && grep -q "dashboard at" "$dt/two1" && grep -q "dashboard at" "$dt/two2"'
kill -TERM "$T1" "$T2" 2>/dev/null || :
wait "$T1" "$T2" 2>/dev/null || :
check "dashboard: TERM to both leaves no FIFO behind" '[ -z "$(find "$root/two-tmp" -name feed.fifo)" ]'

DPID=''

# --- plugin: manifests point at real files; every hook runs this script for its agent
pl=$here
hook_cmds_ok() { # hook_cmds_ok HOOKS-JSON AGENT
  jq -e '.hooks | has("SessionStart") and has("UserPromptSubmit") and has("PostToolUse") and has("SessionEnd")' "$1" >/dev/null || return 1
  [ "$(jq '[.. | .command? // empty] | length' "$1")" -ge 4 ] || return 1
  jq -r '.. | .command? // empty' "$1" | while IFS= read -r c; do
    p=$(printf '%s\n' "$c" | sed -n 's/^"\([^"]*\)".*/\1/p' | sed "s|\${CLAUDE_PLUGIN_ROOT}|$pl|")
    [ "$p" = "$pl/bin/agentlog" ] && [ -x "$p" ] || exit 1
    case $c in *" hook $2") ;; *) exit 1 ;; esac
  done
}
for m in claude:.claude-plugin/plugin.json:claude-code codex:.codex-plugin/plugin.json:codex; do
  n=${m%%:*} f=${m#*:} f=${f%:*} a=${m##*:}
  check "plugin: $n manifest's skills and hooks exist" "[ -f \"$pl/\$(jq -r .skills \"$pl/$f\")/agentlog/SKILL.md\" ] && [ -f \"$pl/\$(jq -r .hooks \"$pl/$f\")\" ]"
  check "plugin: $n hooks run bin/agentlog hook $a" "hook_cmds_ok \"$pl/\$(jq -r .hooks \"$pl/$f\")\" $a"
done
muse_hooks_ok() { # every Muse hook runs its own wrapper, which runs bin/agentlog hook muse
  [ "$(jq '.capabilities.hooks | length' "$pl/.muse-plugin/plugin.json")" -eq 4 ] || return 1
  jq -r '.capabilities.hooks[] | .command[1]' "$pl/.muse-plugin/plugin.json" | while IFS= read -r w; do
    [ -f "$pl/$w" ] && [ ! -L "$pl/$w" ] && grep -q 'bin/agentlog" hook muse$' "$pl/$w" || exit 1
  done
}
check "plugin: muse hooks run their wrappers for bin/agentlog hook muse" muse_hooks_ok
check "plugin: muse skill path exists" "[ -f \"$pl/\$(jq -r '.capabilities.skills[0].path' \"$pl/.muse-plugin/plugin.json\")\" ]"
check "plugin: antigravity hook (PreInvocation only, as 2.0 supports) runs ./bin/agentlog hook antigravity" "[ \"\$(jq -r '.agentlog | to_entries[] | .value[].command' \"$pl/hooks.json\" | grep -c '^\./bin/agentlog hook antigravity PreInvocation$')\" -eq 1 ] && [ \"\$(jq '.agentlog | keys' \"$pl/hooks.json\" | jq -c .)\" = '[\"PreInvocation\"]' ]"
check "plugin: no symlinks in the plugin (Muse refuses them)" "[ -z \"\$(cd \"$pl\" && find . -path ./.git -prune -o -type l -print)\" ]"
for v in muse:'muse plugins validate' agy:'agy plugin validate'; do
  if command -v "${v%%:*}" >/dev/null; then
    check "plugin: ${v#*:}" "${v#*:} \"$pl\" >/dev/null 2>&1"
  else
    echo "skip plugin: ${v#*:} (no ${v%%:*} CLI)"
  fi
done
if command -v claude >/dev/null; then
  check "plugin: claude plugin validate --strict" "claude plugin validate --strict \"$pl\" >/dev/null 2>&1"
else
  echo "skip plugin: claude plugin validate (no claude CLI)"
fi

[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
