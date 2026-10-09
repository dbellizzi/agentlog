#!/bin/sh
# shellcheck disable=SC2034,SC1010,SC2015  # vars are used inside eval strings
# Self-contained tests: each case runs against a fresh store in a temp dir.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
AL=${AGENTLOG_TEST_BIN:-$here/bin/agentlog} # override to test another shell
root=$(mktemp -d "${TMPDIR:-/tmp}/agentlog-test.XXXXXX")
trap 'chmod -R u+w "$root" 2>/dev/null; rm -rf "$root"' EXIT
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
check "json: all fields present" "printf '%s\n' \"\$out\" | head -1 | jq -e 'keys == ([\"agent\",\"body\",\"branch\",\"date\",\"expires\",\"id\",\"kind\",\"paths\",\"re\",\"session\",\"to\"] | sort)' >/dev/null"
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
run codex bbbb2222 write "third note" >/dev/null
check "hook: antigravity PreInvocation delivers new messages" "aj agyc0001 /nonexistent | \"$AL\" hook antigravity PreInvocation | jq -r '.injectSteps[0].ephemeralMessage' | grep -q 'third note'"
agr=$root/agy-repo
git init -q "$agr"
check "hook: relative \$0 still resolves after cd (Antigravity runs ./bin/agentlog)" "(cd \"\$(dirname \"$AL\")/..\" && aj agyc0003 \"$agr\" | ./bin/agentlog hook antigravity SessionStart | jq -r '.injectSteps[0].ephemeralMessage' | grep -q 'Command: /[^ ]*/agentlog ')"
check "hook: antigravity finds the repo from workspacePaths, not its cwd" "(cd \"$root\" && aj agyc0002 \"$agr\" | env -u AGENTLOG_DIR \"$AL\" hook antigravity SessionStart >/dev/null); [ -f \"$agr/.agentlog/sessions/agyc0002\" ]"

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
check "install: rule never allows install/gc/hook/tail" "! grep -E '\"(install|gc|hook|tail)\"' \"$rules\""
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
check "install: antigravity grants cover board subcommands only" "[ \"\$(jq --arg d \"command($dest \" '[.permissions.allow[] | select(startswith(\$d))] | length' \"$ags\")\" -eq 9 ] && ! jq -r '.permissions.allow[]' \"$ags\" | grep -qE ' (install|gc|hook|tail)\)$'"
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

# --- plugin: manifests point at real files; every hook runs this script for its agent
pl=$here
hook_cmds_ok() { # hook_cmds_ok HOOKS-JSON AGENT
  jq -e '.hooks | has("SessionStart") and has("UserPromptSubmit") and has("PostToolUse")' "$1" >/dev/null || return 1
  [ "$(jq '[.. | .command? // empty] | length' "$1")" -ge 3 ] || return 1
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
  [ "$(jq '.capabilities.hooks | length' "$pl/.muse-plugin/plugin.json")" -eq 3 ] || return 1
  jq -r '.capabilities.hooks[] | .command[1]' "$pl/.muse-plugin/plugin.json" | while IFS= read -r w; do
    [ -f "$pl/$w" ] && [ ! -L "$pl/$w" ] && grep -q 'bin/agentlog" hook muse$' "$pl/$w" || exit 1
  done
}
check "plugin: muse hooks run their wrappers for bin/agentlog hook muse" muse_hooks_ok
check "plugin: muse skill path exists" "[ -f \"$pl/\$(jq -r '.capabilities.skills[0].path' \"$pl/.muse-plugin/plugin.json\")\" ]"
check "plugin: antigravity hooks run ./bin/agentlog hook antigravity" "[ \"\$(jq -r '.agentlog | to_entries[] | .value[].command' \"$pl/hooks.json\" | grep -c '^\./bin/agentlog hook antigravity \(SessionStart\|PreInvocation\)$')\" -eq 2 ]"
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
