#!/usr/bin/env bash
#
# Tests for run-review.sh: the OS-level sandbox (policy rendering + the seven-verdict probe gate),
# the private-config isolation, the headless slash-command invocation, the spawn allow-set, the
# compiled-cell check, the findings schema gate (both contracts), delta reviews and the working-tree
# guard, the size budget, the route preflight, the usage ledger with subagent columns, and the
# one-run marker.
#
# Everything runs against a FAKE opencode and a FAKE srt (scripts this test writes, handed over as
# OPENCODE_BIN and OPENCODE_REVIEW_SRT), a FAKE plugin file, a FAKE session store, and a THROWAWAY
# git repo in a temp dir. No real opencode is ever invoked, no real provider is ever billed, no real
# sandbox is entered, and this repo's own history is never touched. The fakes are identified to the
# harness by path, never by name, and nothing here kills a process it did not start.
#
# What the fake srt CAN test is the gate's decision: given a probe verdict, does the harness abort or
# proceed. What it cannot test is whether the real policy confines anything — that is measured by
# `run-review.sh setup` through the real `srt`, which is a verification step, not a unit test.
#
#   plugins/opencode/tests/test-run-review.sh
#
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$TEST_DIR/../scripts"
SCRIPT="$SCRIPTS/run-review.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/opencode-review-test.XXXXXX")"
REPO="$TMP/repo"
FAKE="$TMP/bin/opencode"
FAKE_SRT="$TMP/bin/srt-fake"
export FAKE_LOG="$TMP/calls.log"
export FAKE_ARGS="$TMP/last-args.txt"
export FAKE_DB="$TMP/opencode.db"
export HOME="$TMP/home"          # so a real ~/.config/opencode never enters the picture
export XDG_DATA_HOME="$TMP/data" # so db-usage.py reads the FAKE session store
mkdir -p "$TMP/bin" "$HOME" "$XDG_DATA_HOME/opencode"
unset OPENCODE_REVIEW_MODEL OPENCODE_REVIEW_VARIANT OPENCODE_CONFIG OPENCODE_CONFIG_CONTENT OPENCODE_CONFIG_DIR

PASS=0 FAIL=0
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

ok()   { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
check() { # <description> <condition-rc>
  if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi
}
have() { grep -qF -- "$2" "$1"; }   # <file> <literal>

# --- the fake plugin --------------------------------------------------------------------------------
# The harness never vendors opencode-code-review; it finds it on the box. Here it is a file with a
# package.json beside it, and the harness is pointed at it by path.
mkdir -p "$TMP/plugin"
printf '// fake opencode-code-review\n' >"$TMP/plugin/plugin.ts"
printf '{ "name": "@elderengineer/opencode-code-review", "version": "9.9.9-fake" }\n' >"$TMP/plugin/package.json"
export OPENCODE_REVIEW_PLUGIN="$TMP/plugin/plugin.ts"

# --- the fake session store ---------------------------------------------------------------------
# opencode persists every subagent as a child session; the harness reads the fan-out's spend from
# there because the event stream carries the parent only (M2). The fake writes what a medium run
# left behind: N children of the parent session, each with cumulative token columns.
export XDG_DATA_HOME
seed_db() { # <parent-session> <children> <in-each> <cache-each> <out-each>
  python3 - "$XDG_DATA_HOME/opencode/opencode.db" "$@" <<'PY'
import sqlite3, sys, json
db, parent, n, tin, tcr, tout = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
c = sqlite3.connect(db)
c.executescript("""
create table if not exists session (id text primary key, parent_id text, agent text, model text, cost real default 0,
  tokens_input integer, tokens_output integer, tokens_cache_read integer);
create table if not exists message (id text primary key, session_id text, data text);
""")
c.execute("delete from session"); c.execute("delete from message")
c.execute("insert into session values (?,?,?,?,?,?,?,?)", (parent, None, "opencode-review-coordinator", json.dumps({"id": "fake"}), 0, 0, 0, 0))
for i in range(n):
    sid = f"ses_child{i:02d}"
    c.execute("insert into session values (?,?,?,?,?,?,?,?)", (sid, parent, "reviewer-medium", json.dumps({"id": "fake-model"}), 0, tin, tout, tcr))
    for j in range(3):
        c.execute("insert into message values (?,?,?)", (f"{sid}-m{j}", sid, json.dumps({"role": "assistant" if j else "user"})))
c.commit()
PY
}
seed_db ses_fakeparent 0 0 0 0

# --- the fake opencode ---------------------------------------------------------------------------
# It answers `debug config` (the PLUGIN probe), the preflight and the real review differently,
# because the harness must be able to fail each one without the others. The real review is
# recognised by `--command code-review`; the level it compiles comes from ITS OWN argv, exactly as
# opencode-code-review's parser reads $ARGUMENTS.
cat >"$FAKE" <<'FAKEEOF'
#!/usr/bin/env bash
model=""; agent=""; prev=""; cmd=""
for a in "$@"; do
  [ "$prev" = "--model" ] && model="$a"
  [ "$prev" = "--agent" ] && agent="$a"
  [ "$prev" = "--command" ] && cmd="$a"
  prev="$a"
done

if [ "${1:-}" = "debug" ] && [ "${2:-}" = "config" ]; then
  printf 'config\t%s\t%s\n' "${XDG_CONFIG_HOME:-unset}" "${OPENCODE_DISABLE_PROJECT_CONFIG:-unset}" >>"$FAKE_LOG"
  # The private config the harness rendered is what a real opencode would load: report exactly its
  # plugin and agents, plus what the plugin injects. FAKE_NO_PLUGIN=1 stands in for a plugin that
  # did not inject.
  python3 - "${XDG_CONFIG_HOME:-/nonexistent}/opencode/opencode.json" <<'PY'
import json, sys, os
try:
    cfg = json.load(open(sys.argv[1]))
except Exception:
    print("{}"); sys.exit(0)
out = {"plugin": cfg.get("plugin", []), "agent": dict(cfg.get("agent", {})), "command": {}}
if os.environ.get("FAKE_NO_PLUGIN") != "1":
    out["command"]["code-review"] = {}
    for l in ("low", "medium", "high", "max"):
        out["agent"]["reviewer-" + l] = {}
print(json.dumps(out))
PY
  exit 0
fi
if [ "${1:-}" = "--version" ]; then echo "0.0.0-fake"; exit 0; fi

printf 'agent\t%s\n' "$agent" >>"$FAKE_LOG"
printf 'env\t%s\t%s\t%s\n' "${XDG_CONFIG_HOME:-unset}" "${XDG_STATE_HOME:-unset}" "${OPENCODE_CONFIG:-unset}" >>"$FAKE_LOG"

if [ "$agent" = "opencode-review-preflight" ]; then
  printf 'probe\t%s\n' "$model" >>"$FAKE_LOG"
  if [ "${FAKE_PROBE_FATAL:-0}" = "1" ]; then
    echo "timestamp=x level=ERROR service=api message=\"stream error\" error.error=\"Weekly usage limit reached. Resets in 3 days\"" >&2
    sleep 30   # a refused route holds the process open; the harness must kill it early
    exit 1
  fi
  echo '{"type":"step_start","part":{"sessionID":"ses_pf"}}'
  echo '{"type":"text","part":{"id":"pp","messageID":"pm","sessionID":"ses_pf","text":"OK"}}'
  echo '{"type":"step_finish","part":{"sessionID":"ses_pf","reason":"stop","cost":"0.0000","tokens":{"input":80,"output":5,"cache":{"read":20}}}}'
  exit 0
fi

printf 'run\t%s\t%s\n' "$model" "$cmd" >>"$FAKE_LOG"
# Everything after `--` is what opencode hands the command as $ARGUMENTS: level first, target next.
args=(); seen=0
for a in "$@"; do
  if [ "$seen" = 1 ]; then args+=("$a"); elif [ "$a" = "--" ]; then seen=1; fi
done
printf '%s\n' "${args[@]}" >"$FAKE_ARGS"
level="${args[0]:-}"
[ -z "${FAKE_CELL_LEVEL:-}" ] || level="$FAKE_CELL_LEVEL"
sid="${FAKE_SESSION:-ses_fakeparent}"

# The reviewer is read-only in reality; this stands in for an edit landing in the tree DURING a run.
[ -z "${FAKE_WRITE_TARGET:-}" ] || printf 'export const z = 0;\n' >"$FAKE_WRITE_TARGET"
[ -z "${FAKE_LENS_TARGET:-}" ] || { mkdir -p "$(dirname "$FAKE_LENS_TARGET")"; printf 'planted lens\n' >"$FAKE_LENS_TARGET"; }

step() { echo "{\"type\":\"step_start\",\"part\":{\"sessionID\":\"$sid\"}}"; }
fin()  { echo "{\"type\":\"step_finish\",\"part\":{\"sessionID\":\"$sid\",\"reason\":\"$1\",\"cost\":\"0.0010\",\"tokens\":{\"input\":$2,\"output\":$3,\"cache\":{\"read\":$4}}}}"; }
tool() { echo "{\"type\":\"tool_use\",\"part\":{\"sessionID\":\"$sid\",\"tool\":\"$1\",\"state\":{\"status\":\"completed\",\"input\":$2,\"output\":$3}}}"; }

# Bill two steps, then exit non-zero with no review — a route killed after it had already been
# charged. The harness must recover the spend from these events, not record zeros.
if [ "${FAKE_DIE_AFTER_STEPS:-0}" = "1" ]; then
  step; fin tool-calls 1000 400 9000; fin tool-calls 2000 800 18000
  exit 3
fi

step
if [ "${FAKE_NO_PROMPT_CALL:-0}" != "1" ]; then
  tag="$level effort → fake cell"
  [ "$level" = low ] && tag="\`low effort → 1 diff pass → no verify → ≤4 findings\`"
  tool code_review_prompt "{\"arguments\":\"${args[*]}\"}" "\"(preamble)\\n\\nReview target: \`${args[1]:-}\`\\n\\n$tag\\n\\n## Phase 0\""
fi
fin tool-calls 1000 40 0
step
tool bash '{"command":"git diff"}' '"diff --git a/a b/a"'
fin tool-calls 500 60 3000
if [ "$level" != low ]; then
  n="${FAKE_SPAWNS:-3}"; name="${FAKE_SPAWN_NAME:-reviewer-$level}"
  for i in $(seq 1 "$n"); do tool task "{\"subagent_type\":\"$name\",\"description\":\"finder $i\"}" '"candidates"'; done
  fin tool-calls 500 80 3500
fi
step
if [ -n "${FAKE_TEXT:-}" ]; then T="$FAKE_TEXT"
elif [ "$level" = low ]; then T='`a.ts:2 — off-by-one: the loop runs once too often`'
else T='Three candidates verified.\n\n```json\n[{\"file\":\"a.ts\",\"line\":2,\"summary\":\"off-by-one\",\"failure_scenario\":\"n=3 yields 4 items\",\"verdict\":\"CONFIRMED\"},{\"file\":\"b.ts\",\"line\":1,\"summary\":\"duplicate helper\",\"failure_scenario\":\"two sums drift\"}]\n```'
fi
printf '{"type":"text","part":{"id":"p1","messageID":"m9","sessionID":"%s","text":"%s"}}\n' "$sid" "$T"
fin "${FAKE_REASON:-stop}" 600 90 4000
exit 0
FAKEEOF
chmod +x "$FAKE"
export OPENCODE_BIN="$FAKE"

# --- the fake srt ---------------------------------------------------------------------------------
# Parses the real invocation shape (`srt -s <policy> -- <cmd…>`), records the policy it was handed,
# and answers the harness's sandbox probe with a VERDICT rather than executing it — the gate's
# decision is what a unit test can exercise. The PLUGIN verdict is the one assertion the probe
# script computes by running opencode itself, so the fake runs the real probe's tail for it.
cat >"$FAKE_SRT" <<'SRTEOF'
#!/usr/bin/env bash
policy=""
while [ $# -gt 0 ]; do
  case "$1" in
    -s) policy="$2"; shift 2 ;;
    --) shift; break ;;
    *)  shift ;;
  esac
done
printf 'srt\t%s\n' "$policy" >>"$FAKE_LOG"
case "${*: -1}" in
  *sandbox-probe.sh)
    if [ "${FAKE_SRT_LEAKY:-0}" = "1" ]; then echo "WRITE=allowed"; else echo "WRITE=blocked"; fi
    echo "CRED=blocked"; echo "READ=ok"; echo "GIT=ok"
    if [ "${FAKE_SRT_NO_EGRESS:-0}" = "1" ]; then echo "NET=fail"; else echo "NET=ok opencode.ai"; fi
    if [ "${FAKE_SRT_UNMASKED:-0}" = "1" ]; then echo "MASK=unmasked"; else echo "MASK=ok"; fi
    # The PLUGIN lines of the real probe script, verbatim: they run `opencode debug config` under
    # the private XDG environment and grep the result.
    sed -n '/^cfg=/,$p' "${*: -1}" | sh
    exit 0 ;;
esac
exec "$@"
SRTEOF
chmod +x "$FAKE_SRT"
export OPENCODE_REVIEW_SRT="$FAKE_SRT"

# --- the throwaway repo ---------------------------------------------------------------------------
git init -q "$REPO"
cd "$REPO" || exit 1
git symbolic-ref HEAD refs/heads/master
git config user.email test@example.invalid
git config user.name "opencode-review test"
printf 'export const a = 1;\n' >a.ts
printf 'export const b = 2;\n' >b.ts
git add -A && git commit -qm "base"
git checkout -q -b feat
printf 'export const a = 1;\nexport const a2 = 2;\nexport const a3 = 3;\n' >a.ts
git commit -qam "round 1: widen a"
R1="$(git rev-parse HEAD)"
mkdir -p src/deep
printf 'export const c = 3;\nexport const c2 = 4;\n' >src/deep/c.ts
git add -A && git commit -qm "round 2: add c"
HEAD_SHA="$(git rev-parse HEAD)"
STATE="$REPO/.opencode-review"

run() { # <level> <args…> — returns the script's rc, with stderr in $ERR and stdout in $OUT
  local level="$1"; shift
  ERR="$TMP/stderr.$RANDOM"; OUT="$TMP/stdout.$RANDOM"
  "$SCRIPT" review "$level" --base master "$@" >"$OUT" 2>"$ERR"
  local rc=$?
  [ "${TEST_VERBOSE:-0}" = "1" ] && { echo "--- rc $rc: review $level $* ---"; cat "$ERR"; }
  return $rc
}
promoted() { tail -1 "$OUT"; }   # the last stdout line of a promoted run is the findings path
reset_state() { rm -rf "$STATE"; }

echo "== setup: the seven-verdict probe, no review =="
: >"$FAKE_LOG"
ERR="$TMP/stderr.setup"; "$SCRIPT" setup >/dev/null 2>"$ERR"; rc=$?
check "setup succeeds" $rc
check "  … reports the sandbox as measured, naming all seven verdicts" \
  "$( { have "$ERR" 'sandbox OK' && have "$ERR" 'plugin ok' && have "$ERR" 'credentials ok'; } && echo 0 || echo 1)"
check "  … names the plugin and its version" "$(have "$ERR" '9.9.9-fake' && echo 0 || echo 1)"
check "  … contacted no provider" "$([ "$(grep -cE '^(probe|run)' "$FAKE_LOG")" -eq 0 ] && echo 0 || echo 1)"
check "  … added the state dir to .gitignore" "$(grep -qx '.opencode-review/' "$REPO/.gitignore" && echo 0 || echo 1)"
check "  … and PLUGIN=ok came from opencode run under the PRIVATE config dir" \
  "$(grep -q $'^config\t'".*opencode-review-sbx" "$FAKE_LOG" && ! grep -q $'^config\tunset' "$FAKE_LOG" && echo 0 || echo 1)"
check "  … with project config disabled" "$(grep -qE $'^config\t.*\t1$' "$FAKE_LOG" && echo 0 || echo 1)"
: >"$FAKE_LOG"
FAKE_NO_PLUGIN=1 "$SCRIPT" setup >/dev/null 2>"$ERR"; rc=$?
check "a plugin that did not inject ABORTS setup" "$([ $rc -ne 0 ] && echo 0 || echo 1)"
check "  … naming the missing injection" "$(have "$ERR" 'did not inject' && echo 0 || echo 1)"

echo "== a low review through the sandbox =="
reset_state; : >"$FAKE_LOG"
run low; rc=$?
check "low review succeeds" $rc
F="$(promoted)"
check "findings promoted under .opencode-review/runs/<stamp>-low/" "$([[ "$F" == "$STATE/runs/"*"-low/findings.json" ]] && [ -s "$F" ] && echo 0 || echo 1)"
check "the low one-line contract was normalised into the schema" \
  "$(python3 -c 'import json,sys; f=json.load(open(sys.argv[1])); sys.exit(0 if f[0]["file"]=="a.ts" and f[0]["line"]==2 and "off-by-one" in f[0]["summary"] and f[0]["failure_scenario"] else 1)' "$F" && echo 0 || echo 1)"
check "head recorded, and last/last.head point at this run" \
  "$([ "$(cat "$STATE/last.head")" = "$HEAD_SHA" ] && [ "$(cat "$STATE/last")" = "$F" ] && echo 0 || echo 1)"
check "the harness handed opencode the coordinator agent" "$(grep -qxF $'agent\topencode-review-coordinator' "$FAKE_LOG" && echo 0 || echo 1)"
check "  … and the preflight to the tool-less preflight agent" "$(grep -qxF $'agent\topencode-review-preflight' "$FAKE_LOG" && echo 0 || echo 1)"
check "  … through the sandbox runtime every time" "$([ "$(grep -c '^srt' "$FAKE_LOG")" -ge 3 ] && echo 0 || echo 1)"
check "  … as the headless slash command (--command code-review)" "$(grep -qE $'^run\t.*\tcode-review$' "$FAKE_LOG" && echo 0 || echo 1)"
check "level and target are SEPARATE argv tokens (opencode quotes tokens with spaces)" \
  "$([ "$(sed -n 1p "$FAKE_ARGS")" = "low" ] && [ "$(sed -n 2p "$FAKE_ARGS")" = "$(git rev-parse --short master)...HEAD" ] && echo 0 || echo 1)"
check "every opencode ran under a private XDG_CONFIG_HOME and XDG_STATE_HOME, with OPENCODE_CONFIG unset" \
  "$(grep '^env' "$FAKE_LOG" | grep -qvE $'^env\t/.*\t/.*\tunset$' && echo 1 || echo 0)"
check "with no upstream pin the coordinator gets NO --model (opencode's default)" "$([ "$(grep -m1 '^probe' "$FAKE_LOG")" = $'probe\t' ] && echo 0 || echo 1)"
check "  … and says so" "$(have "$ERR" "opencode's default" && echo 0 || echo 1)"
check "  … and the absent pin file is not announced on stderr" "$(grep -q 'code-review-model' "$ERR" && echo 1 || echo 0)"
check "accounting names the plugin version and the level" "$( { have "$ERR" 'run accounting' && have "$ERR" '9.9.9-fake' && have "$ERR" 'level            low'; } && echo 0 || echo 1)"
check "  … and says subagents: 0 for a low run" "$(grep -q 'subagents        0 ' "$ERR" && echo 0 || echo 1)"

echo "== the rendered sandbox policy and the private config =="
RUN_DIR="$(dirname "$F")"
POL="$RUN_DIR/sandbox.json"
check "policy rendered beside the run" "$([ -s "$POL" ] && echo 0 || echo 1)"
check "the fake srt was handed THAT policy" "$(grep -qxF "$(printf 'srt\t%s' "$POL")" "$FAKE_LOG" && echo 0 || echo 1)"
check "no placeholder survived rendering" "$(grep -q '@[A-Z_]\+@' "$POL" && echo 1 || echo 0)"
check "every placeholder in the template was substituted" \
  "$(python3 - "$SCRIPTS/sandbox-policy.template.json" "$POL" <<'PY' && echo 0 || echo 1
import re, sys
names = set(re.findall(r"@[A-Z_]+@", open(sys.argv[1]).read()))
assert names, "the template carries no placeholders at all"
body = open(sys.argv[2]).read()
sys.exit(1 if any(n in body for n in names) else 0)
PY
)"
check "the repo is NOT in allowWrite, and nothing under it is" \
  "$(python3 -c 'import json,sys; w=json.load(open(sys.argv[1]))["filesystem"]["allowWrite"]; r=sys.argv[2]; sys.exit(1 if any(p==r or p.startswith(r+"/") for p in w) else 0)' "$POL" "$REPO" && echo 0 || echo 1)"
check "allowWrite is opencode's own dirs plus the per-run sandbox tmp, nothing else" \
  "$(python3 -c 'import json,sys; w=json.load(open(sys.argv[1]))["filesystem"]["allowWrite"]; sys.exit(0 if w and all("opencode" in p or "opencode-review-sbx" in p for p in w) else 1)' "$POL" && echo 0 || echo 1)"
check "credential masking cannot silently no-op (onExtractNoMatch is not 'warn')" \
  "$(python3 -c '
import json,sys
c=(json.load(open(sys.argv[1])).get("credentials") or {}).get("files") or []
sys.exit(0 if c and all(f.get("onExtractNoMatch","warn")!="warn" for f in c if f.get("mode")=="mask") else 1)' "$POL" && echo 0 || echo 1)"
check "egress is limited to named provider endpoints" \
  "$(python3 -c '
import json,sys
n=json.load(open(sys.argv[1]))["network"]
sys.exit(0 if n["allowedDomains"] and n.get("allowLocalBinding") is False else 1)' "$POL" && echo 0 || echo 1)"
CFG="$RUN_DIR/opencode.json"
check "the private opencode config is kept with the run" "$([ -s "$CFG" ] && echo 0 || echo 1)"
check "  … registering exactly ONE plugin, ours, by path" \
  "$(python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["plugin"]==[sys.argv[2]] else 1)' "$CFG" "$OPENCODE_REVIEW_PLUGIN" && echo 0 || echo 1)"
check "  … the coordinator has bash, task and code_review_prompt" \
  "$(python3 -c '
import json,sys
t=json.load(open(sys.argv[1]))["agent"]["opencode-review-coordinator"]["tools"]
sys.exit(0 if t["bash"] is True and t["task"] is True and t["code_review_prompt"] is True and t["*"] is False else 1)' "$CFG" && echo 0 || echo 1)"
check "  … and write/edit/patch/webfetch stay false — defence in depth behind the kernel" \
  "$(python3 -c '
import json,sys
t=json.load(open(sys.argv[1]))["agent"]["opencode-review-coordinator"]["tools"]
sys.exit(0 if all(t[k] is False for k in ("write","edit","patch","webfetch")) else 1)' "$CFG" && echo 0 || echo 1)"
check "  … the preflight agent has no tools at all" \
  "$(python3 -c 'import json,sys; t=json.load(open(sys.argv[1]))["agent"]["opencode-review-preflight"]["tools"]; sys.exit(0 if t=={"*": False} else 1)' "$CFG" && echo 0 || echo 1)"

echo "== the usage ledger, with the subagent columns =="
LED="$STATE/ledger.tsv"
check "ledger written" "$([ -s "$LED" ] && echo 0 || echo 1)"
check "ledger has a probe line and a run line" "$(awk -F'\t' '$4=="probe"{p++} $4=="run"{r++} END{exit !(p==1 && r==1)}' "$LED" && echo 0 || echo 1)"
check "the run row carries the level" "$(awk -F'\t' '$4=="run" && $2=="low"' "$LED" | grep -q . && echo 0 || echo 1)"
check "input tokens SUMMED over steps, cache reads included (1000+3500+4600=9100)" \
  "$(awk -F'\t' '$4=="run"{exit !($10==9100)}' "$LED" && echo 0 || echo 1)"
check "output tokens are the per-step MAX (90)" "$(awk -F'\t' '$4=="run"{exit !($11==90)}' "$LED" && echo 0 || echo 1)"
USAGE_OUT="$("$SCRIPT" usage 2>&1)"; urc=$?
check "usage subcommand prints the table with per-level totals" "$([ $urc -eq 0 ] && grep -q 'per-level totals' <<<"$USAGE_OUT" && echo 0 || echo 1)"
check "last subcommand names the findings and the head" "$("$SCRIPT" last 2>/dev/null | grep -q "head:     $HEAD_SHA" && echo 0 || echo 1)"

echo "== a medium review: subagents in the allow-set, spend read from the session store =="
reset_state; : >"$FAKE_LOG"
seed_db ses_fakeparent 12 1000 9000 300
run medium; rc=$?
check "medium review succeeds" $rc
F="$(promoted)"
check "the JSON contract was extracted from inside a fenced block with prose before it" \
  "$(python3 -c 'import json,sys; f=json.load(open(sys.argv[1])); sys.exit(0 if len(f)==2 and f[0]["verdict"]=="CONFIRMED" and "verdict" not in f[1] else 1)' "$F" && echo 0 || echo 1)"
check "accounting names the spawn count and agent" "$(grep -q 'subagents        12 spawned (reviewer-medium)' "$ERR" && echo 0 || echo 1)"
check "  … with the fan-out's tokens read from the session store (12 × 10000)" "$(grep -q '120000 in across 24 steps' "$ERR" && echo 0 || echo 1)"
LED="$STATE/ledger.tsv"
check "the ledger row carries subagents=12 and sub_in_tok=120000" \
  "$(awk -F'\t' '$4=="run"{exit !($13==12 && $15==120000)}' "$LED" && echo 0 || echo 1)"
check "usage totals add coordinator and subagent input" "$("$SCRIPT" usage 2>&1 | grep -E '^  medium' | grep -q 'subagents   12' && echo 0 || echo 1)"

echo "== subagent spend UNMEASURED is printed as such, never as zero =="
reset_state
FAKE_SESSION=ses_unknown run medium; rc=$?
check "the review still promotes" $rc
check "accounting says UNMEASURED" "$(have "$ERR" 'UNMEASURED' && echo 0 || echo 1)"
check "the ledger carries ? in the subagent token columns, and the spawn count" \
  "$(awk -F'\t' '$4=="run"{exit !($13==3 && $15=="?")}' "$STATE/ledger.tsv" && echo 0 || echo 1)"

echo "== a spawn outside the allow-set VOIDS the run =="
reset_state; : >"$FAKE_LOG"
FAKE_SPAWN_NAME=build run medium; rc=$?
check "a task spawn of 'build' aborts" "$([ $rc -ne 0 ] && echo 0 || echo 1)"
check "  … naming the agent and the allow-set" "$( { have "$ERR" "spawned 'build'" && have "$ERR" 'reviewer-medium'; } && echo 0 || echo 1)"
check "  … without advancing the ladder" "$([ "$(grep -c '^run' "$FAKE_LOG")" -eq 1 ] && echo 0 || echo 1)"
check "  … and no findings promoted" "$([ ! -e "$STATE/last" ] && echo 0 || echo 1)"
check "  … but the spend is in the ledger, labelled bad-spawn" "$(awk -F'\t' '$4=="run" && $5=="bad-spawn"' "$STATE/ledger.tsv" | grep -q . && echo 0 || echo 1)"
reset_state
FAKE_SPAWN_NAME=reviewer-lens-security run medium; rc=$?
check "a project-lens specialist (reviewer-lens-*) is in the allow-set" $rc
reset_state
FAKE_SPAWN_NAME=reviewer-high run medium; rc=$?
check "the wrong level's reviewer is NOT (reviewer-high at medium)" "$([ $rc -ne 0 ] && echo 0 || echo 1)"
reset_state
FAKE_SPAWN_NAME=reviewer-medium-alt2 run medium; rc=$?
check "an auto-ladder alternate (reviewer-medium-alt2) is in the allow-set" $rc
reset_state
FAKE_SPAWN_NAME=reviewer-high-alt1 run medium; rc=$?
check "  … but not another level's alternate (reviewer-high-alt1 at medium)" "$([ $rc -ne 0 ] && echo 0 || echo 1)"

echo "== models are opencode-code-review's decision =="
UP="$HOME/.local/state/opencode"; mkdir -p "$UP"
reset_state; : >"$FAKE_LOG"
echo auto >"$UP/code-review-model"
printf '{"cachedAt":1,"ladder":[{"route":{"providerID":"opencode-go","modelID":"muse-fake"},"effective":0.1,"pot":false},{"route":{"providerID":"zai","modelID":"glm-fake"},"effective":0.2,"pot":true}]}' >"$UP/code-review-ladder.json"
run medium; rc=$?
check "with the auto pin the coordinator runs the head of upstream's cached ladder" \
  "$([ $rc -eq 0 ] && grep -qxF $'run\topencode-go/muse-fake\tcode-review' "$FAKE_LOG" && have "$ERR" 'favorites ladder' && echo 0 || echo 1)"
check "  … which the sandbox may read but never write" \
  "$(python3 -c 'import json,sys; w=json.load(open(sys.argv[1]))["filesystem"]["allowWrite"]; sys.exit(1 if any(sys.argv[2].startswith(x.rstrip("/")) for x in w) else 0)' "$(dirname "$(promoted)")/sandbox.json" "$UP/code-review-ladder.json" && echo 0 || echo 1)"
reset_state; : >"$FAKE_LOG"
rm -f "$UP/code-review-ladder.json"
run medium; rc=$?
check "auto with no cached ladder runs on opencode's default, says how to build it, writes nothing" \
  "$([ $rc -eq 0 ] && grep -qxF $'run\t\tcode-review' "$FAKE_LOG" && [ ! -e "$UP/code-review-ladder.json" ] && have "$ERR" 'run /code-review once in the opencode TUI' && echo 0 || echo 1)"
reset_state; : >"$FAKE_LOG"
echo zai-coding-plan/glm-fake >"$UP/code-review-model"
run medium; rc=$?
check "a concrete sticky pin is the coordinator's model too" "$([ $rc -eq 0 ] && grep -qxF $'run\tzai-coding-plan/glm-fake\tcode-review' "$FAKE_LOG" && echo 0 || echo 1)"
reset_state; : >"$FAKE_LOG"
run medium --model deepseek/deepseek-fake; rc=$?
check "--model overrides it for the coordinator" "$([ $rc -eq 0 ] && grep -qxF $'run\tdeepseek/deepseek-fake\tcode-review' "$FAKE_LOG" && echo 0 || echo 1)"
rm -f "$UP/code-review-model" "$UP/code-review-ladder.json"
reset_state
run medium --no-triage --lenses correctness,security --include-generated; rc=$?
check "--no-triage, --lenses and --include-generated pass through to /code-review" \
  "$([ $rc -eq 0 ] && grep -qx -- '--no-triage' "$FAKE_ARGS" && grep -qx -- 'correctness,security' "$FAKE_ARGS" && grep -qx -- '--include-generated' "$FAKE_ARGS" && echo 0 || echo 1)"
run medium --lenses 'a b'; rc=$?
check "  … and a --lenses value with a space is refused" "$([ $rc -ne 0 ] && echo 0 || echo 1)"

echo "== the compiled cell must be the level asked for =="
reset_state; : >"$FAKE_LOG"
FAKE_CELL_LEVEL=low run medium; rc=$?
check "a medium run that compiled the low cell does not promote" "$([ $rc -ne 0 ] && echo 0 || echo 1)"
check "  … and says which cell was compiled" "$(grep -qE "compiled cell is 'low', not 'medium'" "$ERR" && echo 0 || echo 1)"
check "  … in one attempt: model fallback is upstream's, not the harness's" "$([ "$(grep -c '^run' "$FAKE_LOG")" -eq 1 ] && echo 0 || echo 1)"
reset_state; : >"$FAKE_LOG"
FAKE_NO_PROMPT_CALL=1 run medium; rc=$?
check "a run that never called code_review_prompt does not promote" "$([ $rc -ne 0 ] && echo 0 || echo 1)"
check "  … saying so" "$(have "$ERR" 'never completed a code_review_prompt call' && echo 0 || echo 1)"
reset_state
FAKE_SPAWNS=0 run medium; rc=$?
check "a medium run that spawned nothing is a single pass, not promoted" "$([ $rc -ne 0 ] && echo 0 || echo 1)"
check "  … named as the inline fallback" "$(have "$ERR" 'inline fallback' && echo 0 || echo 1)"

echo "== the output gate: off-contract output aborts =="
reset_state; : >"$FAKE_LOG"
FAKE_TEXT='I looked and it seems fine.' run medium; rc=$?
check "prose without a JSON array is not a review" "$([ $rc -ne 0 ] && echo 0 || echo 1)"
check "  … reported as off-contract" "$(have "$ERR" 'off-contract' && echo 0 || echo 1)"
reset_state
FAKE_TEXT='[]' run medium; rc=$?
check "[] is a valid, promotable review that found nothing" $rc
check "  … promoted as an empty array" "$([ "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$(promoted)")" = 0 ] && echo 0 || echo 1)"
reset_state
FAKE_TEXT='(none)' run low; rc=$?
check "(none) at low is [] as well" "$([ $rc -eq 0 ] && [ "$(cat "$(promoted)")" = "[]" ] && echo 0 || echo 1)"
reset_state
FAKE_TEXT='[{\"file\":\"a.ts\",\"summary\":\"x\",\"failure_scenario\":\"y\",\"verdict\":\"REFUTED\"}]' run medium; rc=$?
check "a REFUTED finding is dropped, not promoted" "$([ $rc -eq 0 ] && [ "$(cat "$(promoted)")" = "[]" ] && echo 0 || echo 1)"
reset_state
FAKE_REASON=length run medium; rc=$?
check "a 'length' stop is cut short, not finished" "$([ $rc -ne 0 ] && have "$ERR" 'cut short' && echo 0 || echo 1)"

echo "== the sandbox gate is measured, and a leaky sandbox aborts the run =="
reset_state; : >"$FAKE_LOG"
FAKE_SRT_LEAKY=1 run low; rc=$?
check "a sandbox that lets a write into the repo through ABORTS" "$([ $rc -ne 0 ] && echo 0 || echo 1)"
check "  … saying what it measured" "$(have "$ERR" 'WROTE INTO' && echo 0 || echo 1)"
check "  … before anything reached a provider" "$([ "$(grep -cE '^(probe|run)' "$FAKE_LOG")" -eq 0 ] && echo 0 || echo 1)"
: >"$FAKE_LOG"
FAKE_SRT_NO_EGRESS=1 run low; rc=$?
check "a sandbox with no egress ABORTS, naming the localhost/::1 cause" \
  "$([ $rc -ne 0 ] && have "$ERR" '127.0.0.1 localhost' && echo 0 || echo 1)"
FAKE_SRT_UNMASKED=1 run low; rc=$?
check "an unmasked credential file ABORTS before anything is sent" \
  "$([ $rc -ne 0 ] && have "$ERR" 'UNMASKED' && have "$ERR" 'Nothing was sent to a provider' && echo 0 || echo 1)"
FAKE_NO_PLUGIN=1 run low; rc=$?
check "a plugin that did not inject ABORTS a review, not just setup" "$([ $rc -ne 0 ] && have "$ERR" 'did not inject' && echo 0 || echo 1)"
check "  … before anything reached a provider" "$([ "$(grep -cE '^(probe|run)' "$FAKE_LOG")" -eq 0 ] && echo 0 || echo 1)"

echo "== no sandbox runtime, no review =="
ERR="$TMP/stderr.nosrt"
OPENCODE_REVIEW_SRT="$TMP/definitely-not-here/srt" "$SCRIPT" review low --base master >/dev/null 2>"$ERR"; rc=$?
check "an OPENCODE_REVIEW_SRT that does not exist is refused" "$([ $rc -ne 0 ] && echo 0 || echo 1)"
mkdir -p "$TMP/stub"
printf '#!/usr/bin/env bash\n[ "$1" = "root" ] && { echo "%s/no-global"; exit 0; }\nexit 0\n' "$TMP" >"$TMP/stub/npm"
chmod +x "$TMP/stub/npm"
NOSRT_PATH="$PATH"
if srt_path="$(command -v srt 2>/dev/null)"; then
  NOSRT_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$(dirname "$srt_path")" | paste -sd: -)"
fi
env -u OPENCODE_REVIEW_SRT PATH="$TMP/stub:$NOSRT_PATH" "$SCRIPT" review low --base master >/dev/null 2>"$ERR"; rc=$?
check "a missing sandbox runtime aborts rather than running unsandboxed" "$([ $rc -ne 0 ] && echo 0 || echo 1)"
check "  … naming the install command" "$(have "$ERR" 'npm i -g @anthropic-ai/sandbox-runtime' && echo 0 || echo 1)"
env -u OPENCODE_REVIEW_PLUGIN "$SCRIPT" review low --base master >/dev/null 2>"$ERR"; rc=$?
check "a missing opencode-code-review aborts, naming the install" "$([ $rc -ne 0 ] && have "$ERR" 'bun add @elderengineer/opencode-code-review' && echo 0 || echo 1)"

echo "== delta reviews: the recorded head is the default, the working tree is in scope =="
reset_state; : >"$FAKE_LOG"
run high; rc=$?
check "first high review succeeds (whole change)" $rc
check "  … its target is base...HEAD" "$([ "$(sed -n 2p "$FAKE_ARGS")" = "$(git rev-parse --short master)...HEAD" ] && echo 0 || echo 1)"
run high; rc=$?
check "a second run with nothing changed is refused: nothing to review" "$([ $rc -ne 0 ] && have "$ERR" 'nothing to review' && echo 0 || echo 1)"
printf 'export const a = 1;\nexport const a2 = 2;\nexport const a3 = 3;\nexport const fix = 4;\n' >a.ts   # an uncommitted fix
run high; rc=$?
check "with an uncommitted fix, the second run reviews the DELTA (empty range + working tree)" $rc
check "  … --since defaulted to the recorded head" "$(have "$ERR" 'since defaulted to' && echo 0 || echo 1)"
check "  … the target is <recorded head>...HEAD" "$([ "$(sed -n 2p "$FAKE_ARGS")" = "$(git rev-parse --short HEAD)...HEAD" ] && echo 0 || echo 1)"
check "  … and the accounting says DELTA and counts the working-tree lines" "$(grep -q 'working tree (DELTA)' "$ERR" && have "$ERR" 'working tree (' && echo 0 || echo 1)"
git checkout -q -- a.ts
run medium; rc=$?
check "a LOWER level after a high review is a delta too (nothing changed → nothing to review)" "$([ $rc -ne 0 ] && have "$ERR" 'nothing to review' && echo 0 || echo 1)"
run max; rc=$?
check "a HIGHER level than the last promotion reviews the whole change, not the delta" \
  "$([ $rc -eq 0 ] && have "$ERR" 'below max' && [ "$(sed -n 2p "$FAKE_ARGS")" = "$(git rev-parse --short master)...HEAD" ] && echo 0 || echo 1)"
printf 'export const a = 1;\nexport const a2 = 2;\nexport const a3 = 3;\nexport const fix = 4;\n' >a.ts
run high --full; rc=$?
check "--full reviews the whole change again" "$([ $rc -eq 0 ] && [ "$(sed -n 2p "$FAKE_ARGS")" = "$(git rev-parse --short master)...HEAD" ] && echo 0 || echo 1)"
run high --since "$R1"; rc=$?
check "--since <ref> ships that delta" "$([ $rc -eq 0 ] && [ "$(sed -n 2p "$FAKE_ARGS")" = "$(git rev-parse --short "$R1")...HEAD" ] && echo 0 || echo 1)"
run high --since "$R1" --full; rc=$?
check "--since and --full contradict" "$([ $rc -ne 0 ] && echo 0 || echo 1)"
git checkout -q -- a.ts
git checkout -q -b other master
run high; rc=$?
check "on a branch where the recorded head is not an ancestor, it falls back to the whole change (HEAD is base → nothing)" \
  "$([ $rc -ne 0 ] && have "$ERR" 'not an ancestor' && echo 0 || echo 1)"
git checkout -q feat

echo "== targets: paths scope, ranges and PR numbers are refused =="
reset_state
run medium src/deep; rc=$?
check "a path target runs" $rc
check "  … passed after -- to opencode" "$([ "$(sed -n 3p "$FAKE_ARGS")" = "--" ] && [ "$(sed -n 4p "$FAKE_ARGS")" = "src/deep" ] && echo 0 || echo 1)"
run medium 123; rc=$?
check "a PR number is refused (gh is denied)" "$([ $rc -ne 0 ] && have "$ERR" 'PR number' && echo 0 || echo 1)"
run medium master..HEAD; rc=$?
check "a literal range is refused in favour of --since/--base" "$([ $rc -ne 0 ] && have "$ERR" -- '--since' && echo 0 || echo 1)"
run medium 'src/with space'; rc=$?
check "a path with whitespace is refused (opencode's argv quoting)" "$([ $rc -ne 0 ] && have "$ERR" 'whitespace' && echo 0 || echo 1)"
run medium using opencode-go/kimi-k3; rc=$?
check "using <model> is refused" "$([ $rc -ne 0 ] && have "$ERR" 'refused' && echo 0 || echo 1)"
reset_state
run medium --comment --post; rc=$?
check "--comment/--post are stripped with a note" "$([ $rc -eq 0 ] && have "$ERR" 'stripped --comment --post' && echo 0 || echo 1)"
check "  … and never reached opencode" "$(grep -qE -- '--comment|--post' "$FAKE_ARGS" && echo 1 || echo 0)"
reset_state
run high --fix; rc=$?
check "--fix runs Phase A unchanged" $rc
check "  … recorded in the accounting as Phase B being Claude's" "$(have "$ERR" '--fix requested' && echo 0 || echo 1)"
check "  … and never reached opencode" "$(grep -qE -- 'fix' "$FAKE_ARGS" && echo 1 || echo 0)"

echo "== the diff-size budget =="
reset_state
OPENCODE_REVIEW_MAX_DIFF_LINES=3 run medium; rc=$?
check "an oversized change is a WARNING at medium" $rc
check "  … explaining the fan-out" "$(have "$ERR" 'multiplies through the fan-out' && echo 0 || echo 1)"
reset_state
OPENCODE_REVIEW_MAX_DIFF_LINES=3 run max; rc=$?
check "max on an oversized change DIES without --force-size" "$([ $rc -ne 0 ] && have "$ERR" 'scales worst with size' && echo 0 || echo 1)"
OPENCODE_REVIEW_MAX_DIFF_LINES=3 run max --force-size; rc=$?
check "--force-size overrides it" $rc
check "  … and max pins --variant max on the coordinator" "$(grep -q -- 'variant max' "$ERR" && echo 0 || echo 1)"

echo "== route preflight: nothing heavy is sent to a refused route, and it is killed early =="
reset_state; : >"$FAKE_LOG"
T0=$SECONDS
FAKE_PROBE_FATAL=1 run medium; rc=$?
T1=$((SECONDS - T0))
check "a fatal preflight aborts" "$([ $rc -ne 0 ] && echo 0 || echo 1)"
check "  … reporting the preflight as the reason" "$(have "$ERR" 'preflight' && echo 0 || echo 1)"
check "  … having probed once, inside the sandbox" "$([ "$(grep -c '^probe' "$FAKE_LOG")" -eq 1 ] && echo 0 || echo 1)"
check "  … and NEVER launched the real run" "$([ "$(grep -c '^run' "$FAKE_LOG")" -eq 0 ] && echo 0 || echo 1)"
check "  … killing the refused probe early rather than waiting it out (took ${T1}s)" "$([ "$T1" -lt 15 ] && echo 0 || echo 1)"
check "  … logging the probe to the ledger with no run row" \
  "$(awk -F'\t' '$4=="probe" && $5 ~ /^fail/{n++} $4=="run"{r++} END{exit !(n==1 && r==0)}' "$STATE/ledger.tsv" && echo 0 || echo 1)"
: >"$FAKE_LOG"
FAKE_PROBE_FATAL=1 run medium --model opencode-go/deepseek-v4-flash; rc=$?
check "a pinned model dies at the preflight, saying not to relaunch" "$([ $rc -ne 0 ] && have "$ERR" 'Do NOT relaunch' && echo 0 || echo 1)"
: >"$FAKE_LOG"
OPENCODE_REVIEW_PREFLIGHT=0 run medium; rc=$?
check "OPENCODE_REVIEW_PREFLIGHT=0 skips the probe but never the sandbox" \
  "$([ $rc -eq 0 ] && [ "$(grep -c '^probe' "$FAKE_LOG")" -eq 0 ] && [ "$(grep -c '^srt' "$FAKE_LOG")" -ge 2 ] && echo 0 || echo 1)"

echo "== one run at a time =="
reset_state
sleep 60 &
SLEEPER=$!
mkdir -p "$STATE"
echo "$SLEEPER high 2026-09-02T00:00:00Z" >"$STATE/running"
run low; rc=$?
check "a second run refuses while a live marker exists" "$([ $rc -ne 0 ] && have "$ERR" 'another opencode review is running' && echo 0 || echo 1)"
check "  … leaving the other run's marker alone" "$([ -e "$STATE/running" ] && echo 0 || echo 1)"
STATUS_OUT="$("$SCRIPT" status 2>&1)"
check "status shows it as running" "$(grep -q 'pid alive' <<<"$STATUS_OUT" && echo 0 || echo 1)"
run low --parallel; rc=$?
check "--parallel runs anyway, with a warning" "$([ $rc -eq 0 ] && have "$ERR" 'parallel' && echo 0 || echo 1)"
kill "$SLEEPER" 2>/dev/null; wait "$SLEEPER" 2>/dev/null
reset_state; mkdir -p "$STATE"
echo "999999999 low 2026-09-02T00:00:00Z" >"$STATE/running"   # a PID that is long gone
run low; rc=$?
check "a stale marker is cleared, not obeyed" "$([ $rc -eq 0 ] && have "$ERR" 'stale run marker' && echo 0 || echo 1)"
check "the marker is removed when the run finishes" "$([ ! -e "$STATE/running" ] && echo 0 || echo 1)"

echo "== the tree assertion: a changed tree, or a planted lens, is never promoted =="
reset_state
FAKE_WRITE_TARGET="$REPO/b.ts" run medium; rc=$?
check "an edit landing during the run aborts, non-zero" "$([ $rc -ne 0 ] && echo 0 || echo 1)"
check "  … no findings promoted" "$([ ! -e "$STATE/last" ] && echo 0 || echo 1)"
check "  … but the run row IS written, labelled tree-changed" "$(awk -F'\t' '$4=="run" && $5=="tree-changed"' "$STATE/ledger.tsv" | grep -q . && echo 0 || echo 1)"
check "  … and the abort names the promote-by-hand command" "$(have "$ERR" 'git rev-parse HEAD >' && echo 0 || echo 1)"
git checkout -q -- b.ts
reset_state
mkdir -p .opencode && printf '*\n' >.opencode/.gitignore && git add -f .opencode/.gitignore && git commit -qm "opencode dir with a gitignore that hides everything"
FAKE_LENS_TARGET="$REPO/.opencode/code-review/lenses/planted.md" run medium; rc=$?
check "a lens file planted under .opencode/ (hidden from git by its .gitignore) still aborts" "$([ $rc -ne 0 ] && echo 0 || echo 1)"
check "  … named in the diff" "$(have "$ERR" 'lenses/planted.md' && echo 0 || echo 1)"
rm -rf .opencode/code-review

echo "== a killed attempt records what it BURNED, not zeros =="
reset_state
FAKE_DIE_AFTER_STEPS=1 run medium; rc=$?
check "the killed attempt still writes a run row" "$(awk -F'\t' '$4=="run"' "$STATE/ledger.tsv" | grep -q . && echo 0 || echo 1)"
check "  … with the steps it was billed for (2), input summed (30000), output as MAX (800)" \
  "$(awk -F'\t' '$4=="run" && $9==2 && $10==30000 && $11==800' "$STATE/ledger.tsv" | grep -q . && echo 0 || echo 1)"

echo "== the agent-fallback gate =="
reset_state; : >"$FAKE_LOG"
cat >"$TMP/bin/opencode-fallback" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "debug" ] || [ "\${1:-}" = "--version" ]; then exec "$FAKE" "\$@"; fi
for a in "\$@"; do [ "\$a" = "opencode-review-preflight" ] && exec "$FAKE" "\$@"; done
echo '! agent "opencode-review-coordinator" not found. Falling back to default agent' >&2
exec "$FAKE" "\$@"
EOF
chmod +x "$TMP/bin/opencode-fallback"
OPENCODE_BIN="$TMP/bin/opencode-fallback" run medium; rc=$?
check "an agent fallback voids the run" "$([ $rc -ne 0 ] && have "$ERR" 'fell back to the default agent' && echo 0 || echo 1)"
check "  … without advancing the ladder" "$([ "$(grep -c '^run' "$FAKE_LOG")" -eq 1 ] && echo 0 || echo 1)"

echo "== cancel: TERM kills the run, records the spend, releases the marker =="
reset_state; : >"$FAKE_LOG"
cat >"$TMP/bin/opencode-slow" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in opencode-review-preflight|debug|--version) exec "$FAKE" "\$@" ;; esac; done
echo '{"type":"step_start","part":{"sessionID":"ses_slow"}}'
echo '{"type":"step_finish","part":{"sessionID":"ses_slow","reason":"tool-calls","cost":"0","tokens":{"input":700,"output":10,"cache":{"read":0}}}}'
sleep 120
EOF
chmod +x "$TMP/bin/opencode-slow"
ERR="$TMP/stderr.cancel"
OPENCODE_BIN="$TMP/bin/opencode-slow" "$SCRIPT" review low --base master >/dev/null 2>"$ERR" &
HARNESS=$!
for _ in $(seq 1 40); do [ -e "$STATE/running" ] && grep -q '^run' "$FAKE_LOG" && break; sleep 0.5; done
sleep 1
CANCEL_OUT="$("$SCRIPT" cancel 2>&1)"; crc=$?
wait "$HARNESS"; hrc=$?
check "cancel finds the marker and signals the harness" "$([ $crc -eq 0 ] && grep -q 'sent TERM' <<<"$CANCEL_OUT" && echo 0 || echo 1)"
check "  … the harness exits non-zero" "$([ $hrc -ne 0 ] && echo 0 || echo 1)"
check "  … and releases the marker" "$([ ! -e "$STATE/running" ] && echo 0 || echo 1)"
check "  … and nothing from the slow run was promoted" "$([ ! -e "$STATE/last" ] && echo 0 || echo 1)"

echo "== assert-clean =="
reset_state
mkdir -p "$STATE" && echo x >"$STATE/ledger.tsv" && git add -f "$STATE/ledger.tsv"
"$SCRIPT" assert-clean >/dev/null 2>&1; rc=$?
check "a staged scratch file is refused" "$([ $rc -ne 0 ] && echo 0 || echo 1)"
git reset -q "$STATE/ledger.tsv"
"$SCRIPT" assert-clean >/dev/null 2>&1; rc=$?
check "a clean index passes" $rc

echo "== findings.py on its own =="
FT="$TMP/findings-tests"; mkdir -p "$FT"
printf 'Findings:\n\n`ledger.py:19 — off-by-one: `entries[-n - 1:]` returns n+1 entries`\n- src/x.ts:7: missing await\n' >"$FT/low.txt"
python3 "$SCRIPTS/findings.py" low "$FT/low.txt" "$FT/low.json" >/dev/null 2>&1; rc=$?
check "low lines with backticks, bullets and colon separators parse" "$([ $rc -eq 0 ] && [ "$(python3 -c 'import json,sys; f=json.load(open(sys.argv[1])); print(len(f), f[0]["line"], f[1]["file"])' "$FT/low.json")" = "2 19 src/x.ts" ] && echo 0 || echo 1)"
printf 'Nothing found.\n' >"$FT/low2.txt"
python3 "$SCRIPTS/findings.py" low "$FT/low2.txt" "$FT/low2.json" >/dev/null 2>&1; rc=$?
check "low prose without (none) is off-contract" "$([ $rc -eq 5 ] && echo 0 || echo 1)"
printf '[{"file":"a","line":"12","summary":"s"}]\n' >"$FT/m.txt"
python3 "$SCRIPTS/findings.py" medium "$FT/m.txt" "$FT/m.json" >/dev/null 2>&1; rc=$?
check "a string line is coerced and a missing failure_scenario is filled from summary (with a NOTE)" \
  "$([ $rc -eq 0 ] && [ "$(python3 -c 'import json,sys; f=json.load(open(sys.argv[1])); print(f[0]["line"], f[0]["failure_scenario"])' "$FT/m.json")" = "12 s" ] && echo 0 || echo 1)"
printf '[{"file":"","line":1,"summary":"s","failure_scenario":"f"}]\n' >"$FT/m2.txt"
python3 "$SCRIPTS/findings.py" medium "$FT/m2.txt" "$FT/m2.json" >/dev/null 2>&1; rc=$?
check "an empty file field is off-contract" "$([ $rc -eq 5 ] && echo 0 || echo 1)"
python3 - <<'PY' >"$FT/cap.txt"
import json; print(json.dumps([{"file":"f","line":i,"summary":"s","failure_scenario":"f"} for i in range(20)]))
PY
python3 "$SCRIPTS/findings.py" high "$FT/cap.txt" "$FT/cap.json" --cap 10 >/dev/null 2>&1; rc=$?
check "over-cap output is truncated to the cap, not refused" "$([ $rc -eq 0 ] && [ "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$FT/cap.json")" = 10 ] && echo 0 || echo 1)"
python3 - "$SCRIPTS/schemas/findings.schema.json" "$FT/m.json" "$FT/low.json" "$FT/cap.json" <<'PY' && rc=0 || rc=1
import json, sys
schema = json.load(open(sys.argv[1]))
req = schema["items"]["required"]
for p in sys.argv[2:]:
    for f in json.load(open(p)):
        assert all(k in f for k in req), (p, f)
        assert isinstance(f["line"], int) and f["line"] >= 0
PY
check "every normalised output satisfies the committed schema's required keys" $rc

echo
echo "== syntax =="
bash -n "$SCRIPT"; check "bash -n run-review.sh" $?
bash -n "$TEST_DIR/test-run-review.sh"; check "bash -n test-run-review.sh" $?
python3 -m py_compile "$SCRIPTS/findings.py" "$SCRIPTS/stream.py" "$SCRIPTS/db-usage.py"; check "python scripts compile" $?
node --check "$SCRIPTS/salvage-session.mjs"; check "salvage-session.mjs parses" $?
for j in "$SCRIPTS/coordinator.json" "$SCRIPTS/sandbox-policy.template.json" "$SCRIPTS/schemas/findings.schema.json" \
         "$TEST_DIR/../.claude-plugin/plugin.json" "$TEST_DIR/../../../.claude-plugin/marketplace.json"; do
  python3 -m json.tool "$j" >/dev/null; check "$(basename "$j") parses" $?
done
check "coordinator.json registers exactly the @PLUGIN@ placeholder" \
  "$(python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["plugin"]==["@PLUGIN@"] else 1)' "$SCRIPTS/coordinator.json" && echo 0 || echo 1)"
for c in code-review setup usage status cancel fix; do
  check "commands/$c.md has frontmatter with disable-model-invocation" \
    "$(head -8 "$TEST_DIR/../commands/$c.md" | grep -q 'disable-model-invocation: true' && echo 0 || echo 1)"
done

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
