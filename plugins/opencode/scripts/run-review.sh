#!/usr/bin/env bash
#
# Launch opencode-code-review's /code-review inside a bubblewrap sandbox and own everything that
# must hold regardless of what the model does. The review itself is the opencode-native plugin at
# github.com/elderengineer/opencode-code-review; this harness owns the four things a plugin running
# INSIDE the process the gates distrust cannot: confinement, cost, fail-loud, and the Claude-side UX.
#
#   run-review.sh review <low|medium|high|max> [--since <ref>|--full] [--base <ref>] [--model <M>]
#                        [--force-size] [--parallel] [--fix] [--] [<path>...]
#   run-review.sh setup            render the policy, run the probe, report host requirements; no review
#   run-review.sh usage            the ledger as a table, with per-level totals
#   run-review.sh status           the marker, the last ledger rows, what is running
#   run-review.sh cancel           TERM the running review (this repo's marker), release the marker
#   run-review.sh last             path of the last promoted findings file, and the head it reviewed
#   run-review.sh assert-clean     refuse a commit that stages the harness's scratch
#
# Without --model the level's MODEL LADDER runs: best model for the task first, and within a model
# the subscription pot before pay-per-token cash. A model/route-shaped failure (timeout, runaway,
# provider error, empty or truncated stream, output off-contract) advances the ladder by itself; a
# confinement or contract failure aborts. --model pins one entry and disables fallback.
#
# CONFINEMENT. opencode has no sandbox of its own, so this harness supplies one: every invocation
# runs under `srt` (@anthropic-ai/sandbox-runtime), which puts an OS-level boundary around the whole
# process tree — the repo is READ-ONLY, credential paths are unreadable, opencode's own API keys are
# masked, and egress is limited to the provider endpoints the ladders use. The policy is rendered
# from the committed `sandbox-policy.template.json`, and a ~0-token probe MEASURES it before the
# heavy run: if a write into the repo succeeds, the run aborts rather than review from inside a
# sandbox that is not holding. Because the kernel confines the tree rather than a tool allowlist,
# the coordinator HAS a shell (their Phase 0 is `git diff`) and HAS `task` (their Phase 1–3 spawn
# reviewer-<level> subagents); a subagent's write fails with EROFS exactly like the coordinator's.
#
# CONFIG ISOLATION (measured 2026-09-02, opencode 1.18.27 — reference/confinement.md): opencode's
# global config dir is `$XDG_CONFIG_HOME/opencode`, so a per-run XDG_CONFIG_HOME holding a rendered
# copy of coordinator.json is the only config a sandboxed run loads — the user's other plugins, MCP
# servers and agents never enter the session. OPENCODE_DISABLE_PROJECT_CONFIG=1 keeps the reviewed
# repo's `.opencode/opencode.json` out too (a planted `reviewer-high: {tools: {bash: true}}` was
# measured to vanish). XDG_STATE_HOME is per run as well, so opencode-code-review's sticky
# `using <model>` pin cannot bind and the ladder stays the only model authority.
#
# COST. A review is an agentic loop that re-sends its whole context every step, and at medium and
# above the plugin fans out to 8–10 finder subagents plus one verifier per candidate, each its own
# context. The event stream carries the PARENT session only (measured: M2), so the subagent spend is
# read from opencode's session store after the run and printed beside the parent's — never silently
# summed as zero. Delta re-reviews from the recorded head, a diff-size budget, a route preflight, a
# per-attempt TSV ledger and a repo-wide one-run marker carry over from the dealer harness unchanged.
#
# The findings arrive on stdout as the model's last message and THIS script owns the promoted file,
# so a half-written or off-contract run never lands as a review. `[]` is a valid review that found
# nothing; an abort is never that.
#
set -euo pipefail

AGENT='opencode-review-coordinator'
PREFLIGHT_AGENT='opencode-review-preflight'
PLUGIN_PKG='@elderengineer/opencode-code-review'
STATE_DIRNAME='.opencode-review'

# --- the ladders: the harness's model authority until opencode-code-review's own model selection lands ---
# Best model for the task first; within a model, cheapest vendor first (pot before cash).
# deepseek/* direct is pay-per-token at DeepSeek's list price: half price off-peak (peak is
# 01:00-04:00 and 06:00-10:00 UTC Mon-Fri), so schedule direct retries in an off-peak window when
# the clock allows. Level → ladder: low is one pass with no subagents, so a pro model is wasted and
# breadth (flash first) runs it; medium/high need a model that can quote the line in the verify
# pass, so deep (pro first); max is deep as well, with --variant max pinned (§7 of DESIGN.md).
LADDER_DEEP=(
  opencode-go/deepseek-v4-pro
  deepseek/deepseek-v4-pro
  opencode-go/deepseek-v4-flash
  zai-coding-plan/glm-5.3-flash
  opencode-go/glm-5.3-flash
  deepseek/deepseek-v4-flash
)
LADDER_BREADTH=(
  opencode-go/deepseek-v4-flash
  zai-coding-plan/glm-5.3-flash
  opencode-go/glm-5.3-flash
  deepseek/deepseek-v4-flash
  opencode-go/deepseek-v4-pro
  deepseek/deepseek-v4-pro
)
# Documentation, not a gate: a name outside this set runs with a warning (the ladder's billing
# and behaviour notes do not apply to it), and a name opencode cannot resolve dies loudly at the
# CLI — the behaviour we want anyway.
KNOWN_MODELS='opencode-go/deepseek-v4-pro deepseek/deepseek-v4-pro opencode-go/deepseek-v4-flash deepseek/deepseek-v4-flash zai-coding-plan/glm-5.3-flash opencode-go/glm-5.3-flash'

# --- peak-aware reordering ---------------------------------------------------------------------
# DeepSeek peak = 01:00-04:00 and 06:00-10:00 UTC Mon-Fri: cash doubles, while the GLM pot routes
# cost the same regardless of hour. During peak, every deepseek CASH entry demotes below the GLM
# pot entries. It does NOT promote GLM above the DeepSeek pots: agentic review requests are
# cache-dominated and the deepseek pot route is the cheaper one at ALL hours — 2x a cheaper route
# is still cheaper. Tier order dominates throughout.
ds_peak() {
  local h d
  h=$(date -u +%H); d=$(date -u +%u)   # %u: 1=Mon ... 7=Sun
  [ "$d" -le 5 ] || return 1           # weekends are off-peak for DeepSeek entirely
  { [ "$h" -ge 1 ] && [ "$h" -lt 4 ]; } || { [ "$h" -ge 6 ] && [ "$h" -lt 10 ]; }
}
# Applied per attempt to the entries not yet tried, never once at startup: a review runs for
# minutes, and a ladder fixed at 05:58 UTC executes off-peak order straight through the 06:00
# peak boundary (observed 2026-09-02). Demotion is STABLE — entries keep their relative order.
demote_peak_cash() { # <entries…> — during peak every `deepseek/` CASH entry sits below the pots
  local m keep=() demote=()
  ds_peak || { printf '%s\n' "$@"; return; }
  for m in "$@"; do
    case "$m" in
      deepseek/*) demote+=("$m") ;;
      *)          keep+=("$m") ;;
    esac
  done
  printf '%s\n' ${keep[@]+"${keep[@]}"} ${demote[@]+"${demote[@]}"}
}

# Reasoning effort, defaulting to `max`: every model on every ladder accepts it (deepseek/* take
# {high,max}; glm-5.3-flash takes {low,high,max}). Set OPENCODE_REVIEW_VARIANT= (empty) to send no
# variant at all, which is what a model outside KNOWN_MODELS may need. The two FLASH models are
# pinned to `max` regardless of the knob, and so is the `max` level: opencode-code-review pins
# `variant: max` on reviewer-max, and the coordinator should match (M6: the two compose — the
# coordinator's --variant is the session default the subagents inherit unless pinned).
VARIANT="${OPENCODE_REVIEW_VARIANT-max}"
variant_for() { # <model> <level>
  case "$2" in max) echo max; return ;; esac
  case "$1" in
    */deepseek-v4-flash|*/glm-5.3-flash) echo max ;;
    *) echo "$VARIANT" ;;
  esac
}
TIMEOUT_SECS="${OPENCODE_REVIEW_TIMEOUT:-2400}"
MAX_ATTEMPTS="${OPENCODE_REVIEW_MAX_ATTEMPTS:-6}"   # default = the longest ladder, so the advertised tail is reachable
# Liveness watchdog (see the loop): kill a run whose event log never starts, stops growing, or
# grows without bound, long before the timeout would. A healthy run wrote 143KB of events in its
# first 30s; a legit mid-run thinking pause ran 210s flat. With subagents the PARENT stream is
# quiet while a wave of finders runs — a medium wave measured 60–90s between parent events — so
# the flat threshold stays generous.
POLL=10
STALL_START="${OPENCODE_REVIEW_STALL_START:-120}"
STALL_BYTES="${OPENCODE_REVIEW_STALL_BYTES:-600}"
MAX_JSONL=$(( ${OPENCODE_REVIEW_MAX_JSONL_MB:-16} * 1024 * 1024 ))
# Terminal provider errors — the ones no amount of waiting resolves, so the empty-log deadline
# buys nothing on them. Measured 2026-09-02: an exhausted opencode-go weekly pot logged
# `Weekly usage limit reached. Resets in 3 days` 0.2s in, wrote not one event, and held the run
# for the full timeout. Anchored to a `level=ERROR` line so ordinary log prose cannot trip it, and
# consulted ONLY while the event log is still empty.
FATAL_ERR_RE='usage limit|quota (exceeded|exhausted)|rate limit exceeded|insufficient (balance|credit|quota|funds)|no payment method|payment required|invalid api key|unauthorized|forbidden|model not found|\b40[123]\b'

# Whatever the reviewer reads is re-sent on every step after it — and at medium+ every finder
# reads the diff. Measured by a pipe, never by writing a diff to disk.
MAX_DIFF_LINES="${OPENCODE_REVIEW_MAX_DIFF_LINES:-2500}"
PREFLIGHT_SECS=90
SANDBOX_PROBE_SECS=90

# Per-level findings cap, opencode-code-review's contract (compiler/cells.ts FINDINGS_CAP).
cap_for() { case "$1" in low) echo 4 ;; medium) echo 8 ;; high) echo 10 ;; max) echo 15 ;; esac; }

die() { echo "ABORT: $*" >&2; exit 1; }
note() { echo "opencode-review: $*" >&2; }

usage() {
  cat >&2 <<'EOF'
usage: run-review.sh review <low|medium|high|max> [--since <ref> | --full] [--base <ref>] [--model <M>]
                            [--force-size] [--parallel] [--fix] [--] [<path>...]
       run-review.sh setup | usage | status | cancel | last | assert-clean

  review     run opencode-code-review's /code-review <level> inside the sandbox and promote its
             findings to <repo>/.opencode-review/runs/<stamp>-<level>/findings.json
  level      low     one diff pass, hunk only, no subagents            ≤4 findings   breadth ladder
             medium  8 finder lenses × 6 candidates, 1-vote verify      ≤8           deep ladder
             high    same fan-out, recall-biased verify                 ≤10          deep ladder
             max     10 lenses × 8, verify, gap sweep, --variant max    ≤15          deep ladder
  --since    review only the DELTA `git diff <ref>...HEAD` plus the working tree. Must be an
             ancestor of HEAD. DEFAULTS to the head the last promoted review recorded when that
             head is an ancestor of HEAD (the `review high --fix` → `review high` loop reviews only
             the uncommitted fixes); pass --full to review the whole change knowingly.
  --full     the whole <base>...HEAD diff plus the working tree, even when a recorded head exists
  --base     the ref the change is measured against (default: @{upstream}, else main, else master)
  --model    opencode's full <provider>/<model>. Pins ONE model — runs exactly that, NO
             auto-fallback. Without it the level's ladder runs (members, cheapest vendor first
             within a model):
               opencode-go/deepseek-v4-pro    deepseek/deepseek-v4-pro
               opencode-go/deepseek-v4-flash  deepseek/deepseek-v4-flash
               zai-coding-plan/glm-5.3-flash  opencode-go/glm-5.3-flash
             During DeepSeek peak hours (01:00-04:00, 06:00-10:00 UTC Mon-Fri) the deepseek CASH
             entries demote below the GLM pot entries automatically.
  --fix      record that Phase B was requested (the bare word `fix` is accepted too). Phase A (this script) is identical with or without
             it; Phase B — applying the findings — is Claude's, host-side, with its own Edit tool
             and the normal permission prompts. Nothing inside the sandbox ever edits.
  <path>     scope the review to these repo paths (passed to opencode as `<range> -- <paths>`)
  --force-size  run even though the diff exceeds OPENCODE_REVIEW_MAX_DIFF_LINES (max dies without it)
  --parallel    run even though another review holds <repo>/.opencode-review/running

  Stripped, and said so in the accounting: --comment and --post (gh/glab, the network and
  ~/.config/gh are all denied). REFUSED: `using <model>` (a sticky pin that would override the
  ladder on every later run — the ladder is the only model authority in sandboxed runs).

env: OPENCODE_BIN OPENCODE_REVIEW_SRT OPENCODE_REVIEW_PLUGIN OPENCODE_REVIEW_MODEL OPENCODE_REVIEW_VARIANT
     OPENCODE_REVIEW_TIMEOUT OPENCODE_REVIEW_MAX_ATTEMPTS OPENCODE_REVIEW_STALL_START OPENCODE_REVIEW_STALL_BYTES
     OPENCODE_REVIEW_MAX_JSONL_MB OPENCODE_REVIEW_MAX_DIFF_LINES OPENCODE_REVIEW_PREFLIGHT
EOF
  exit 2
}

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_TEMPLATE="$SKILL_DIR/coordinator.json"
POLICY_TEMPLATE="$SKILL_DIR/sandbox-policy.template.json"

# Scratch is everything under <repo>/.opencode-review/. Match the path prefix.
assert_clean() {
  local staged
  staged="$(git diff --cached --name-only | grep -E "(^|/)$STATE_DIRNAME/" || true)"
  [ -z "$staged" ] || die $'opencode-review scratch files are staged:\n'"$staged"$'\nunstage them before committing.'
  echo "OK: no opencode-review scratch file staged"
}

add_cost() { # <cost> — accumulate across ladder attempts; ignore empty/non-numeric
  case "${1:-}" in ''|*[!0-9.]*) return ;; esac
  TOTAL_COST="$(awk -v a="$TOTAL_COST" -v b="$1" 'BEGIN{printf "%.4f", a+b}')"
}

# --- the usage ledger ---------------------------------------------------------------------------
# `cost` reads $0.0000 on a subscription pot, so it is not the spend signal on a metered plan —
# TOKENS are. One append-only TSV line per attempt, probe and real, pass or fail. The subagent
# columns are the fan-out's spend read from opencode's session store after the run; `?` there
# means UNMEASURED (the store could not be read), never zero.
LEDGER_COLS=$'when\tlevel\tmodel\tkind\toutcome\tdiff_lines\tdiff_bytes\tjsonl_bytes\tsteps\tin_tok\tout_tok\tcost\tsubagents\tsub_steps\tsub_in_tok\tsub_out_tok'

ledger() { # <kind> <model> <outcome> <jsonl_bytes> <steps> <in_tokens> <out_tokens> <cost> [subagents sub_steps sub_in sub_out]
  [ -n "${LEDGER:-}" ] || return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${LEVEL:-?}" "$2" "$1" "$3" \
    "${DIFF_LINES:-0}" "${DIFF_BYTES:-0}" "${4:-0}" "${5:-0}" "${6:-0}" "${7:-0}" "${8:-0}" \
    "${9:-0}" "${10:-0}" "${11:-0}" "${12:-0}" \
    >>"$LEDGER" 2>/dev/null || true
}

show_ledger() {
  [ -s "$LEDGER" ] || die "no usage ledger at $LEDGER — no run has been recorded in this repo yet."
  { printf '%s\n' "$LEDGER_COLS"; cat "$LEDGER"; } |
    awk -F'\t' '{ printf "%-20s %-7s %-30s %-6s %-40s %7s %9s %9s %5s %10s %7s %8s %4s %5s %10s %7s\n",
                  $1,$2,$3,$4,substr($5,1,40),$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16 }'
  echo "per-level totals (in = parent + subagents; ? = unmeasured, counted as 0):"
  awk -F'\t' '
    { runs[$2]++; in_t[$2]+=$10+$15; out_t[$2]+=$11+$16; c[$2]+=$12; sa[$2]+=$13 }
    END { for (k in runs) printf "  %-7s %3d attempt(s)  in %11d tok  out %8d tok  subagents %4d  $%.4f\n", k, runs[k], in_t[k], out_t[k], sa[k], c[k] }
  ' "$LEDGER" | sort
  awk -F'\t' '
    { n++; gin+=$10+$15; gout+=$11+$16; gc+=$12; gs+=$13 }
    END { printf "  ALL     %3d attempt(s)  in %11d tok  out %8d tok  subagents %4d  $%.4f\n", n, gin, gout, gs, gc }
  ' "$LEDGER"
}

# --- host-side locations --------------------------------------------------------------------------
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$ROOT" ] || die "not inside a git repository."
STATE="$ROOT/$STATE_DIRNAME"
LEDGER="$STATE/ledger.tsv"
RUNNING="$STATE/running"
LAST="$STATE/last"
LAST_HEAD="$STATE/last.head"
LAST_LEVEL="$STATE/last.level"
rank() { case "$1" in low) echo 1 ;; medium) echo 2 ;; high) echo 3 ;; max) echo 4 ;; *) echo 0 ;; esac; }   # unknown ranks below every level
OPENCODE_BIN="${OPENCODE_BIN:-$(command -v opencode || true)}"
OC_DATA="${XDG_DATA_HOME:-$HOME/.local/share}/opencode"
OC_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/opencode"

# opencode-code-review must exist on this box; the harness never vendors it. In order: an explicit
# path, the npm install into opencode's config dir (their README's recommended install), then a
# source copy there (their "from source" install). Its package.json version is stamped on the
# accounting so a re-measurement can name what it measured.
find_plugin() {
  local cands=()
  [ -z "${OPENCODE_REVIEW_PLUGIN:-}" ] || cands+=("$OPENCODE_REVIEW_PLUGIN")
  cands+=("$HOME/.config/opencode/node_modules/$PLUGIN_PKG/plugin.ts" "$HOME/.config/opencode/opencode-code-review/plugin.ts")
  local p
  for p in "${cands[@]}"; do
    [ -f "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}
plugin_version() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("version","?"))' "$(dirname "$1")/package.json" 2>/dev/null || echo '?'; }

# --- subcommands that need no sandbox ---------------------------------------------------------------
[ $# -gt 0 ] || usage
case "$1" in
  assert-clean) assert_clean; exit 0 ;;
  usage) show_ledger; exit 0 ;;
  last)
    [ -f "$LAST" ] && [ -s "$(cat "$LAST")" ] || die "no promoted review in this repo yet (nothing at $LAST)."
    echo "findings: $(cat "$LAST")"
    echo "head:     $(cat "$LAST_HEAD" 2>/dev/null || echo '?')"
    exit 0 ;;
  status)
    echo "repo:    $ROOT"
    if [ -f "$RUNNING" ]; then
      held="$(cat "$RUNNING")"; pid="${held%% *}"
      if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        echo "running: $held (pid alive)"
        latest="$(ls -td "$STATE"/runs/*/ 2>/dev/null | head -1)"
        [ -z "$latest" ] || for f in "$latest"*.jsonl; do
          [ -f "$f" ] && echo "  event log: $f — $(wc -c <"$f") bytes, last written $(( $(date +%s) - $(stat -c %Y "$f") ))s ago"
        done
      else
        echo "running: STALE marker ($held) — the holder is gone; the next run clears it"
      fi
    else
      echo "running: nothing"
    fi
    if [ -f "$LAST" ]; then echo "last:    $(cat "$LAST") (head $(cat "$LAST_HEAD" 2>/dev/null || echo '?'))"; else echo "last:    no promoted review yet"; fi
    if [ -s "$LEDGER" ]; then echo "ledger (last 5 of $(wc -l <"$LEDGER")):"; { printf '%s\n' "$LEDGER_COLS"; tail -5 "$LEDGER"; } | column -t -s $'\t' 2>/dev/null || tail -5 "$LEDGER"; fi
    exit 0 ;;
  cancel)
    [ -f "$RUNNING" ] || die "no review is running in this repo (no $RUNNING)."
    held="$(cat "$RUNNING")"; pid="${held%% *}"
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null ||
      { rm -f "$RUNNING"; die "the marker ($held) named a process that is gone — cleared it; nothing to cancel."; }
    kill -TERM "$pid" && echo "opencode-review: sent TERM to the harness (pid $pid: $held). It kills its opencode run, records the spend, and releases the marker."
    exit 0 ;;
  setup|review) MODE="$1"; shift ;;
  *) usage ;;
esac

# --- argument parsing (review and setup) -------------------------------------------------------------
LEVEL="" SINCE="" FULL=0 BASE="" FORCE_SIZE=0 PARALLEL=0 FIX=0 STRIPPED=()
MODEL_ARG="${OPENCODE_REVIEW_MODEL:-}"
PATHS=()
while [ $# -gt 0 ]; do
  case "$1" in
    low|medium|high|max) [ -z "$LEVEL" ] || usage; LEVEL="$1"; shift ;;
    fix|--fix)    FIX=1; shift ;;
    --since)      [ $# -ge 2 ] || usage; SINCE="$2";     shift 2 ;;
    --base)       [ $# -ge 2 ] || usage; BASE="$2";      shift 2 ;;
    --model)      [ $# -ge 2 ] || usage; MODEL_ARG="$2"; shift 2 ;;
    --full)       FULL=1;       shift ;;
    --force-size) FORCE_SIZE=1; shift ;;
    --parallel)   PARALLEL=1;   shift ;;
    --comment|--post|--no-post) STRIPPED+=("$1"); shift ;;
    using) die "\`using <model>\` is refused: it writes a sticky pin that binds the reviewer subagents' model at the next plugin load, silently overriding the ladder on every later run. The ladder is the only model authority in sandboxed runs; pass --model <provider/model> to pin ONE run." ;;
    --) shift; PATHS+=("$@"); break ;;
    -*) usage ;;
    *)  PATHS+=("$1"); shift ;;
  esac
done
if [ "$MODE" = "setup" ]; then LEVEL="${LEVEL:-low}"; fi
[ -n "$LEVEL" ] || usage
[ "$FULL" -eq 0 ] || [ -z "$SINCE" ] ||
  die "--since and --full contradict each other: one ships the delta, the other the whole change. Pick one."

# Path targets: a repo-relative path that exists (or existed — a deleted file is a fine scope) and
# carries no whitespace, because `opencode run` wraps any argv token containing a space in double
# quotes and opencode-code-review's argument parser then sees the quote as part of the level
# (measured: `"medium master...HEAD"` compiled the LOW cell from the sticky level). A PR number
# needs gh, which the sandbox denies; a branch name is what --base is for.
for p in ${PATHS[@]+"${PATHS[@]}"}; do
  case "$p" in
    *[[:space:]]*) die "path target '$p' contains whitespace, which opencode's argv quoting would hand the review parser as part of the level. Rename or pass a parent directory." ;;
    *..*) die "target '$p' looks like a git range — use --since <ref> / --base <ref>; the harness composes the range so it can measure and record it." ;;
  esac
  if [[ "$p" =~ ^[0-9]+$ ]]; then die "target '$p' looks like a PR number. Posting/fetching PRs needs gh, which the sandbox denies by construction; check the branch out and pass --base."; fi
  [ -e "$ROOT/$p" ] || git -C "$ROOT" cat-file -e "HEAD:$p" 2>/dev/null || git -C "$ROOT" log -1 --format=%h -- "$p" >/dev/null 2>&1 ||
    die "target '$p' is neither a path in the tree nor one git knows — a branch goes in --base, a range in --since."
done

# The candidate list. A pinned model is a one-entry ladder with fallback disabled: an explicit
# choice must not be second-guessed.
PINNED=0
if [ -n "$MODEL_ARG" ]; then
  PINNED=1
  [[ "$MODEL_ARG" == */* ]] ||
    die "--model takes opencode's full <provider>/<model>, not a short name. Try: $KNOWN_MODELS"
  grep -qw -- "$MODEL_ARG" <<<"$KNOWN_MODELS" ||
    note "NOTE — '$MODEL_ARG' is outside this harness's tested set; the ladder's billing and behaviour assumptions do not apply to it."
  LADDER=("$MODEL_ARG")
else
  case "$LEVEL" in
    low)             LADDER=("${LADDER_BREADTH[@]}") ;;
    medium|high|max) LADDER=("${LADDER_DEEP[@]}") ;;
  esac
fi
N=${#LADDER[@]}
[ "$N" -le "$MAX_ATTEMPTS" ] || N=$MAX_ATTEMPTS

# --- host requirements: each aborts naming its own fix ---------------------------------------------
REQ_FAIL=0
req() { # <ok-rc> <label> <fix>
  if [ "$1" -eq 0 ]; then echo "  ok    $2" >&2; else echo "  MISSING $2 — $3" >&2; REQ_FAIL=1; fi
}
[ "$MODE" = "setup" ] && echo "opencode-review: host requirements" >&2
req "$([ -n "$OPENCODE_BIN" ] && [ -x "$OPENCODE_BIN" ] && echo 0 || echo 1)" "opencode CLI ($OPENCODE_BIN)" "npm i -g --allow-scripts=opencode-ai opencode-ai   (or set OPENCODE_BIN)"
req "$(command -v python3 >/dev/null 2>&1 && echo 0 || echo 1)" "python3" "opencode emits a JSONL event stream; the parsers are python"
req "$(command -v node >/dev/null 2>&1 && echo 0 || echo 1)" "node" "the session salvager is node"
req "$(command -v flock >/dev/null 2>&1 && echo 0 || echo 1)" "flock (util-linux)" "the single-run guard; without it two runs both finish and the second overwrites the first"
req "$(command -v bwrap >/dev/null 2>&1 && echo 0 || echo 1)" "bwrap (bubblewrap)" "sudo apt install bubblewrap   — srt's Linux filesystem/network confinement"
req "$(command -v socat >/dev/null 2>&1 && echo 0 || echo 1)" "socat" "sudo apt install socat   — srt's bridge from the sandbox to its host proxy"
req "$(grep -qE '^[[:space:]]*127\.0\.0\.1[[:space:]]+.*\blocalhost\b' /etc/hosts && echo 0 || echo 1)" "/etc/hosts maps localhost to 127.0.0.1" "add '127.0.0.1 localhost' — srt's socat bridge dials localhost while its proxy binds 127.0.0.1; ::1-only kills every request"
[ -f "$CONFIG_TEMPLATE" ] || die "no $CONFIG_TEMPLATE — it defines the coordinator agent and the private config; without it the reviewer runs as the default agent, which can write and delegate."
[ -f "$POLICY_TEMPLATE" ] || die "no $POLICY_TEMPLATE — that template IS the confinement policy; without it there is nothing to render and nothing to enforce."

# opencode-code-review — theirs, found on this box, never vendored.
PLUGIN="$(find_plugin || true)"
req "$([ -n "$PLUGIN" ] && echo 0 || echo 1)" "opencode-code-review plugin${PLUGIN:+ ($PLUGIN, v$(plugin_version "$PLUGIN"))}" "cd ~/.config/opencode && bun add $PLUGIN_PKG   (or npm i $PLUGIN_PKG; or set OPENCODE_REVIEW_PLUGIN=/path/to/plugin.ts)"

# --- the sandbox: srt, and nothing runs without it --------------------------------------------
# Find the runtime up front and die if it is missing, because the alternative (running unsandboxed
# with a shell-enabled agent) is precisely the state this harness exists to make unreachable.
# Never a silent fallback: `srt` itself fails closed (invalid config or a missing dependency is
# exit 1), and so does finding it.
SRT=()
if [ -n "${OPENCODE_REVIEW_SRT:-}" ]; then
  [ -e "${OPENCODE_REVIEW_SRT}" ] || die "OPENCODE_REVIEW_SRT=${OPENCODE_REVIEW_SRT} does not exist."
  case "$OPENCODE_REVIEW_SRT" in
    *.js|*.mjs) SRT=(node "$OPENCODE_REVIEW_SRT") ;;
    *)          SRT=("$OPENCODE_REVIEW_SRT") ;;
  esac
elif command -v srt >/dev/null 2>&1; then
  SRT=(srt)
else
  SRT_CLI="$(npm root -g 2>/dev/null)/@anthropic-ai/sandbox-runtime/dist/cli.js"
  [ -f "$SRT_CLI" ] && SRT=(node "$SRT_CLI")
fi
req "$([ "${#SRT[@]}" -gt 0 ] && echo 0 || echo 1)" "srt (@anthropic-ai/sandbox-runtime)${SRT[*]:+ (${SRT[*]})}" "npm i -g @anthropic-ai/sandbox-runtime   — or point OPENCODE_REVIEW_SRT at an srt binary or its dist/cli.js"
[ "$REQ_FAIL" -eq 0 ] || die "host requirements missing (above). The reviewer has a shell and must not run outside the sandbox; nothing was sent to a provider."

# --- state dir, gitignore, marker -------------------------------------------------------------------
mkdir -p "$STATE/runs"
# A backstop inside the scratch dir itself, so the tree assertion and `git add -A` never see it
# even on a branch that predates the repo-level line /opencode:setup adds.
[ -f "$STATE/.gitignore" ] || printf '*\n' >"$STATE/.gitignore"
if [ "$MODE" = "setup" ]; then
  if ! grep -qxE "/?$STATE_DIRNAME/?" "$ROOT/.gitignore" 2>/dev/null; then
    printf '%s/\n' "$STATE_DIRNAME" >>"$ROOT/.gitignore"
    note "added '$STATE_DIRNAME/' to $ROOT/.gitignore (the ledger, marker, rendered policy and promoted findings live there)."
  fi
fi

command -v flock >/dev/null 2>&1 || die "flock is required"
# One run at a time, repo-wide. Two concurrent runs would drain a plan's quota twice as fast and
# race on the `last` pointer. `noclobber` makes the create atomic, so the check and the claim
# cannot race; a marker whose PID is gone is stale and is cleared with a note.
# Field 22 of /proc/<pid>/stat is the process's start time in jiffies since boot: unique per process
# on this boot, and NOT reused when the kernel recycles a PID. Stamping it in the marker is what makes
# "is the holder still alive?" answerable.
MARKER_OWNED=0
proc_start() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null || true; }
marker_line() { echo "$$ $(proc_start $$) $LEVEL $(date -u +%Y-%m-%dT%H:%M:%SZ)"; }

claim_marker() {
  local held pid rest started
  if ! (set -o noclobber; marker_line >"$RUNNING") 2>/dev/null; then
    held="$(cat "$RUNNING" 2>/dev/null || true)"
    pid="${held%% *}"
    rest="${held#* }"; started="${rest%% *}"
    # A live PID is not enough — it must be the SAME process that wrote the marker. Unknown must
    # mean "refuse", never "clear it".
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null &&
       { [[ ! "$started" =~ ^[0-9]+$ ]] || [ "$started" = "$(proc_start "$pid")" ]; }; then
      [ "$PARALLEL" -eq 1 ] ||
        die "another opencode review is running ($held). Reviews are sequential by default: each one is an agentic loop that re-sends its context every step, and concurrent runs multiply the burn on a metered plan. Wait for it (run-review.sh status), cancel it (run-review.sh cancel), or pass --parallel if you mean it."
      note "NOTE — --parallel: running alongside $held. On a metered plan this doubles the burn."
      return 0
    fi
    note "clearing a stale run marker ($held — that PID is gone, or was recycled by an unrelated process)."
    # Clear and re-claim under a dedicated lock: two launches can read the SAME stale marker, and
    # the second one's rm would delete the first one's fresh claim.
    exec 8>"$RUNNING.clear.lock"
    flock 8
    if [ "$(cat "$RUNNING" 2>/dev/null || true)" = "$held" ]; then rm -f "$RUNNING"; fi
    (set -o noclobber; marker_line >"$RUNNING") 2>/dev/null || { flock -u 8
      die "could not claim $RUNNING after clearing a stale marker — another run took it in between."; }
    flock -u 8
  fi
  MARKER_OWNED=1
}
# shellcheck disable=SC2329  # invoked by the EXIT trap below
release_marker() { [ "$MARKER_OWNED" -eq 1 ] && rm -f "$RUNNING"; return 0; }
# shellcheck disable=SC2329
drop_sbx_tmp() { [ -z "${SBX_TMP:-}" ] || rm -rf "$SBX_TMP"; return 0; }
CHILD=""
# shellcheck disable=SC2329
on_term() { # `run-review.sh cancel` or a Claude-side stop: kill the run, keep its evidence, release
  note "TERM received — killing the sandboxed run, keeping its event log."
  [ -z "$CHILD" ] || kill_run
  exit 143
}
trap 'release_marker; drop_sbx_tmp' EXIT
trap on_term TERM INT

# --- the change under review: the whole thing, or the delta since the last promoted review ------------
git rev-parse --verify -q HEAD >/dev/null 2>&1 || die "this repository has no commits yet — there is no HEAD to review against."
if [ -z "$BASE" ]; then
  if git rev-parse --verify -q '@{upstream}' >/dev/null 2>&1; then BASE='@{upstream}'
  elif git rev-parse --verify -q main >/dev/null 2>&1; then BASE=main
  elif git rev-parse --verify -q master >/dev/null 2>&1; then BASE=master
  else die "no --base given and none of @{upstream}, main, master exists — pass --base <ref>."; fi
fi
git rev-parse --verify "$BASE" >/dev/null 2>&1 || die "base ref '$BASE' does not exist"
BASE_SHA="$(git rev-parse --short "$BASE")"
HEAD_SHA="$(git rev-parse --short HEAD)"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"

# A re-review that re-ships the whole change pays for what was already reviewed, every step, in
# every finder, again. The previous promotion recorded its head, so the `review high --fix` →
# `review high` loop reviews only the uncommitted fixes with no flag at all.
# A delta is only a delta of a review that COVERED the change: a low pass does not stand in for a
# high one, so a higher level than the last promotion reviews the whole change again.
DELTA=0 DIFF_FROM="$BASE"
if [ -z "$SINCE" ] && [ "$FULL" -eq 0 ] && [ -s "$LAST_HEAD" ]; then
  prev="$(tr -d '[:space:]' <"$LAST_HEAD")"
  prev_level="$(cat "$LAST_LEVEL" 2>/dev/null || echo unknown)"
  if [ "$(rank "$prev_level")" -lt "$(rank "$LEVEL")" ]; then
    note "NOTE — the last promoted review was $prev_level, below $LEVEL: reviewing the whole change against $BASE, not the delta."
  elif git rev-parse --verify -q "$prev^{commit}" >/dev/null 2>&1 && git merge-base --is-ancestor "$prev" HEAD; then
    if [ "$(git rev-parse "$prev")" != "$(git rev-parse "$BASE")" ]; then
      SINCE="$prev"
      note "--since defaulted to $(git rev-parse --short "$prev") — the head the last promoted review recorded. This run is a DELTA (plus the working tree). Pass --full to review the whole change instead."
    fi
  else
    note "NOTE — the last recorded head ($prev) is not an ancestor of HEAD (a different branch?); reviewing the whole change against $BASE."
  fi
fi
if [ -n "$SINCE" ]; then
  git rev-parse --verify "$SINCE^{commit}" >/dev/null 2>&1 || die "--since ref '$SINCE' does not exist"
  git merge-base --is-ancestor "$SINCE" HEAD ||
    die "--since $SINCE is not an ancestor of HEAD — a delta against an unrelated commit is not the change since the last review."
  DELTA=1
  DIFF_FROM="$SINCE"
fi
SINCE_SHA="$(git rev-parse --short "$DIFF_FROM")"

# --- the size of the change, MEASURED, never materialised ---------------------------------------
# opencode-code-review's Phase 0 reviews the commit range PLUS the working tree (`git diff HEAD`),
# so both are measured and the budget sums them. Empty only if BOTH are empty: the fix loop's
# second run has an empty range and a dirty tree, and that is the run it exists for.
read -r RANGE_LINES RANGE_BYTES < <(git diff "$DIFF_FROM...HEAD" -- ${PATHS[@]+"${PATHS[@]}"} | wc -lc)
read -r WT_LINES WT_BYTES < <(git diff HEAD -- ${PATHS[@]+"${PATHS[@]}"} | wc -lc)
DIFF_LINES=$(( RANGE_LINES + WT_LINES )); DIFF_BYTES=$(( RANGE_BYTES + WT_BYTES ))
FILES_CHANGED="$( { git diff --name-only "$DIFF_FROM...HEAD" -- ${PATHS[@]+"${PATHS[@]}"}; git diff --name-only HEAD -- ${PATHS[@]+"${PATHS[@]}"}; } | sort -u | wc -l)"
UNTRACKED="$(git status --porcelain --untracked-files=all -- ${PATHS[@]+"${PATHS[@]}"} | grep '^??' | grep -v " $STATE_DIRNAME/" || true)"
if [ "$MODE" = "review" ]; then
  [ "$DIFF_LINES" -gt 0 ] ||
    die "nothing to review: git diff $SINCE_SHA...HEAD is empty and so is the working tree$([ -n "$UNTRACKED" ] && echo " (untracked files are invisible to every diff — git add them first)")."
  note "reviewing git diff $SINCE_SHA...HEAD ($RANGE_LINES lines) + working tree ($WT_LINES lines) — $FILES_CHANGED file(s), $DIFF_LINES diff lines / $DIFF_BYTES bytes (measured, not written)$([ "$DELTA" -eq 1 ] && echo " — DELTA")"
  [ -z "$UNTRACKED" ] || note "NOTE — untracked files are NOT in scope (opencode-code-review reads git diffs): $(wc -l <<<"$UNTRACKED") file(s), e.g. $(head -1 <<<"$UNTRACKED" | cut -c4-). git add them if they belong to the change."
  if [ "$DIFF_LINES" -gt "$MAX_DIFF_LINES" ] && [ "$FORCE_SIZE" -ne 1 ]; then
    SIZE_MSG="the change is $DIFF_LINES lines (budget $MAX_DIFF_LINES, OPENCODE_REVIEW_MAX_DIFF_LINES). Every finder subagent reads the diff and re-sends it on every step, so size multiplies through the fan-out. Review the DELTA since the last review (--since <ref>), scope to paths, or split the change."
    if [ "$LEVEL" = "max" ]; then
      die "max on an over-budget change: $SIZE_MSG max is the level whose cost scales worst with size (10 lenses × 8 candidates + verify + sweep). Pass --force-size only if you have decided to pay it."
    fi
    if [ "$FULL" -eq 1 ] && [ -s "$LAST_HEAD" ]; then
      die "--full on a re-review: $SIZE_MSG Pass --force-size only if you have decided to pay it."
    fi
    note "WARNING — $SIZE_MSG"
  fi
fi

# --- the run directory -------------------------------------------------------------------------------
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$STATE/runs/$STAMP-$LEVEL"
[ "$MODE" = "setup" ] && RUN_DIR="$STATE/setup"
rm -rf "$RUN_DIR"; mkdir -p "$RUN_DIR"
OUT="$RUN_DIR/findings.json"
HEADFILE="$RUN_DIR/head"
POLICY="$RUN_DIR/sandbox.json"
PROBE_SH="$RUN_DIR/sandbox-probe.sh"
LOCK="$RUN_DIR/lock"
exec 9>"$LOCK"; flock -n 9 || die "another run holds $LOCK"
claim_marker

# --- the confinement policy, rendered then MEASURED ----------------------------------------------
# opencode is a Bun binary and needs a writable temp dir, a writable config dir (it writes a
# .gitignore there at startup) and a writable state dir (`opencode run` dies EROFS without one —
# measured). All three live in ONE per-run directory that dies with the run: the private config
# rendered from coordinator.json, the private state (so the plugin's sticky level/model files are
# per run and cannot pin anything), and the tmp. srt OVERRIDES TMPDIR inside the sandbox, so the
# tmp is chosen with CLAUDE_CODE_TMPDIR, which srt reads on the host.
SBX_TMP="$(mktemp -d "${TMPDIR:-/tmp}/opencode-review-sbx.XXXXXX")"
CFG_HOME="$SBX_TMP/config"; STATE_HOME="$SBX_TMP/state"; OC_TMP="$SBX_TMP/tmp"
mkdir -p "$CFG_HOME/opencode" "$STATE_HOME" "$OC_TMP"
PRIVATE_CFG="$CFG_HOME/opencode/opencode.json"
python3 - "$CONFIG_TEMPLATE" "$PRIVATE_CFG" "$PLUGIN" <<'PY' || die "could not render the private opencode config from $CONFIG_TEMPLATE"
import json, sys
tpl, out, plugin = sys.argv[1:]
cfg = json.load(open(tpl))
cfg.pop("_comment", None)
cfg["plugin"] = [plugin if p == "@PLUGIN@" else p for p in cfg.get("plugin", [])]
assert cfg["plugin"] == [plugin], "coordinator.json must register exactly the @PLUGIN@ placeholder"
json.dump(cfg, open(out, "w"), indent=2)
PY
cp "$PRIVATE_CFG" "$RUN_DIR/opencode.json"   # the record of what this run loaded
# The environment every sandboxed opencode gets. It wraps `srt` on the HOST side, not the command
# inside: srt reads CLAUDE_CODE_TMPDIR itself to choose the sandbox's TMPDIR (set only inside, it is
# ignored and opencode dies EROFS on srt's default /tmp/claude — measured), and it passes the rest
# through to opencode unchanged. OPENCODE_CONFIG* from the caller's environment would MERGE into
# the private config (measured on the old harness), so they are unset explicitly.
OC_ENV=(env -u OPENCODE_CONFIG -u OPENCODE_CONFIG_CONTENT -u OPENCODE_CONFIG_DIR
        XDG_CONFIG_HOME="$CFG_HOME" XDG_STATE_HOME="$STATE_HOME" OPENCODE_DISABLE_PROJECT_CONFIG=1
        OPENCODE_DISABLE_AUTOUPDATE=1 CLAUDE_CODE_TMPDIR="$OC_TMP")

render_policy() {
  sed -e "s|@ROOT@|$ROOT|g" \
      -e "s|@HOME@|$HOME|g" \
      -e "s|@OPENCODE_DATA@|$OC_DATA|g" \
      -e "s|@OPENCODE_CACHE@|$OC_CACHE|g" \
      -e "s|@SANDBOX_TMP@|$SBX_TMP|g" \
      "$POLICY_TEMPLATE" >"$POLICY"
  ! grep -q '@[A-Z_]\+@' "$POLICY" ||
    die "$POLICY still carries an unsubstituted placeholder: $(grep -o '@[A-Z_]\+@' "$POLICY" | sort -u | paste -sd ' ' -). Every placeholder in $POLICY_TEMPLATE needs a substitution in render_policy."
  python3 - "$POLICY" "$ROOT" <<'PY' || die "$POLICY is not a policy this harness will run behind — see the message above."
import json, sys
pol, root = json.load(open(sys.argv[1])), sys.argv[2]
fs = pol.get("filesystem") or {}
missing = [k for k in ("allowRead", "denyRead", "allowWrite", "denyWrite") if k not in fs]
if missing:
    sys.exit(f"filesystem is missing {missing} — srt's schema requires all four keys present.")
for w in fs.get("allowWrite") or []:
    # The repo itself, any ancestor of it, or anything inside it. The read-only tree IS the
    # guarantee this sandbox exists for; since opencode 1.18.27 writes nothing into the reviewed
    # repo (measured), no hole inside it is needed either.
    w = w.rstrip("/")
    if root == w or root.startswith(w + "/") or w.startswith(root + "/"):
        sys.exit(f"allowWrite lists {w}, which covers or enters the repo at {root}. A writable repo makes the run void.")
for c in (pol.get("credentials") or {}).get("files") or []:
    if c.get("mode") == "mask" and c.get("onExtractNoMatch", "warn") == "warn":
        sys.exit(f"credentials entry for {c.get('path')} masks with onExtractNoMatch='warn', which leaves the file readable as-is when the pattern misses. Use 'deny' or 'error'.")
PY
}
render_policy

# The sandbox gate: MEASURED before the heavy run, once per run rather than per ladder attempt.
# This is confinement, so it aborts and never advances the ladder. The probe is a script rather
# than an inline -c string so the shell quoting cannot become the thing under test, and it prints
# one parseable verdict per assertion. Seven verdicts:
#   WRITE   a touch into the repo root                       (allowed → ABORT)
#   CRED    a denyRead path that really holds a readable file on this box
#   READ    the plugin's entry file is readable — the reviewer would be confined out of its own review otherwise
#   GIT     git runs against the range inside the sandbox
#   NET     curl reaches ANY ONE allowed domain; all failing is the bridge, not a provider
#   MASK    auth.json reads back as sentinels inside                (unmasked → ABORT)
#   PLUGIN  opencode's resolved config INSIDE the sandbox, under the private XDG dirs, carries the
#           /code-review command, the coordinator and reviewer-<level> — i.e. opencode-code-review
#           loaded and injected. A run where it did not would review with the default prompt.
NET_HOSTS="$(python3 -c 'import json,sys;print(" ".join(json.load(open(sys.argv[1]))["network"]["allowedDomains"]))' "$POLICY")"
MASK_TARGET="$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1])).get("credentials",{}).get("files",[])
print(d[0]["path"] if d else "")' "$POLICY")"
CRED_TARGET=""
for p in $(python3 -c 'import json,sys;print(" ".join(json.load(open(sys.argv[1]))["filesystem"]["denyRead"]))' "$POLICY"); do
  [ -n "$(find "$p" -type f -readable -print -quit 2>/dev/null)" ] || continue
  CRED_TARGET="$p"; break
done
cat >"$PROBE_SH" <<PROBE
set -u
root="$ROOT"
cred="$CRED_TARGET"
tmp="\$root/.opencode-sandbox-probe.tmp"
if touch "\$tmp" 2>/dev/null; then rm -f "\$tmp" 2>/dev/null; echo "WRITE=allowed"; else echo "WRITE=blocked"; fi
if [ -z "\$cred" ]; then echo "CRED=absent"
elif [ -n "\$(find "\$cred" -type f -readable -print -quit 2>/dev/null)" ]; then echo "CRED=readable"
else echo "CRED=blocked"; fi
if [ -s "$PLUGIN" ]; then echo "READ=ok"; else echo "READ=fail"; fi
mask="$MASK_TARGET"
if [ -z "\$mask" ] || [ ! -f "\$mask" ]; then echo "MASK=absent"
elif grep -q 'fake_value_' "\$mask" 2>/dev/null; then echo "MASK=ok"
else echo "MASK=unmasked"; fi
if git -C "\$root" diff --stat "$DIFF_FROM...HEAD" >/dev/null 2>&1; then echo "GIT=ok"; else echo "GIT=fail"; fi
if ! command -v curl >/dev/null 2>&1; then echo "NET=skip"
else
  net_reached=""
  for h in $NET_HOSTS; do
    if curl -s -o /dev/null --max-time 12 "https://\$h/" 2>/dev/null; then net_reached="\$h"; break; fi
  done
  if [ -n "\$net_reached" ]; then echo "NET=ok \$net_reached"; else echo "NET=fail"; fi
fi
cfg="\$(cd "\$root" && ${OC_ENV[*]} "$OPENCODE_BIN" debug config 2>/dev/null)" || cfg=""
if [ -z "\$cfg" ]; then echo "PLUGIN=fail"
elif printf '%s' "\$cfg" | python3 -c 'import json,sys
c=json.load(sys.stdin); cmd=c.get("command") or {}; ag=c.get("agent") or {}
sys.exit(0 if "code-review" in cmd and "$AGENT" in ag and "reviewer-$LEVEL" in ag and "$PREFLIGHT_AGENT" in ag else 1)' 2>/dev/null; then echo "PLUGIN=ok"
else echo "PLUGIN=missing"; fi
PROBE

sandbox_gate() {
  local out rc
  set +e
  out="$(timeout "$SANDBOX_PROBE_SECS" "${OC_ENV[@]}" "${SRT[@]}" -s "$POLICY" -- /bin/sh "$PROBE_SH" 2>&1)"
  rc=$?
  set -e
  local write cred read_ok git_ok net_ok mask_ok plugin_ok
  write="$(grep -m1 '^WRITE=' <<<"$out" || true)"
  cred="$(grep -m1 '^CRED=' <<<"$out" || true)"
  read_ok="$(grep -m1 '^READ=' <<<"$out" || true)"
  git_ok="$(grep -m1 '^GIT=' <<<"$out" || true)"
  net_ok="$(grep -m1 '^NET=' <<<"$out" || true)"
  mask_ok="$(grep -m1 '^MASK=' <<<"$out" || true)"
  plugin_ok="$(grep -m1 '^PLUGIN=' <<<"$out" || true)"
  if [ -z "$write" ]; then
    echo "--- sandbox probe output ---" >&2; echo "$out" >&2
    die "the sandbox probe produced no verdict (${SRT[*]} exited $rc). srt fails closed on an invalid config or a missing dependency (bwrap, socat) — fix that before any review runs; the reviewer has a shell and must not run outside the sandbox."
  fi
  [ "$write" = "WRITE=blocked" ] ||
    die "the sandbox probe WROTE INTO $ROOT. The policy at $POLICY is not holding, and a reviewer with a shell would be able to edit the tree it is reviewing. Nothing was sent to a provider."
  [ "$read_ok" = "READ=ok" ] ||
    die "the sandbox probe could not read $PLUGIN — opencode-code-review would not load inside the sandbox. Check filesystem.denyRead in $POLICY."
  [ "$git_ok" = "GIT=ok" ] ||
    die "the sandbox probe could not run 'git diff --stat $DIFF_FROM...HEAD' inside the sandbox — Phase 0 fetches the diff with git, so a review from in there would have nothing to read."
  case "$net_ok" in
    NET=ok*)  ;;
    NET=skip) note "NOTE — no curl inside the sandbox, so egress was not measured; a route failure below may be the sandbox rather than the provider." ;;
    *)        die "the sandbox reached NONE of the allowed domains (${NET_HOSTS:-the providers}), so this is the bridge and not one provider being down — NO route can answer. On Linux srt bridges to its host proxy through \`socat … TCP:localhost:<port>\` while that proxy binds 127.0.0.1: if this box's /etc/hosts maps \`localhost\` to ::1 only, add \`127.0.0.1 localhost\` to it and re-run. Nothing was sent to a provider." ;;
  esac
  case "$mask_ok" in
    MASK=ok)     ;;
    MASK=absent) note "NOTE — the policy masks no credential file, so that assertion had nothing to measure." ;;
    *)           die "the sandbox read $MASK_TARGET UNMASKED — the reviewer has a shell and would see the API key it is running on. Credential masking is configured in $POLICY but is not taking effect (ASRT degrades mask to deny on macOS; on Linux check that network.tlsTerminate is present). Nothing was sent to a provider." ;;
  esac
  case "$cred" in
    CRED=blocked) ;;
    CRED=absent)  note "NOTE — none of the policy's denyRead paths exist on this box, so that assertion had nothing to measure." ;;
    *)            die "the sandbox probe READ a credential path the policy denies. $POLICY is not holding; a reviewer with a shell would see it too." ;;
  esac
  case "$plugin_ok" in
    PLUGIN=ok) ;;
    PLUGIN=missing) die "opencode loaded inside the sandbox but its resolved config lacks the /code-review command, the '$AGENT' agent or 'reviewer-$LEVEL' — opencode-code-review did not inject. Check $PLUGIN loads (cd ~/.config/opencode && opencode debug config) and that its dependencies (@opencode-ai/plugin, zod) resolve beside it. A run from here would review with the default prompt, so it does not run." ;;
    *) die "opencode could not print its resolved config inside the sandbox (PLUGIN=$plugin_ok) — the private config at $PRIVATE_CFG did not load. Nothing was sent to a provider." ;;
  esac
  note "sandbox OK — repo read-only, credential paths unreadable, plugin and git readable, egress ${net_ok#NET=}, credentials ${mask_ok#MASK=}, plugin ${plugin_ok#PLUGIN=} (${SRT[*]} -s $POLICY)"
}
sandbox_gate

if [ "$MODE" = "setup" ]; then
  note "setup OK — opencode $("$OPENCODE_BIN" --version 2>/dev/null | tail -1), opencode-code-review v$(plugin_version "$PLUGIN") at $PLUGIN, srt ${SRT[*]}. No review was run. Policy rendered at $POLICY."
  exit 0
fi

# What the tree looks like before an independent reviewer touches it — any difference afterwards
# means the reviewer wrote something, which is the one thing the sandbox exists to prevent. The
# harness's OWN scratch lives under $STATE and is filtered explicitly rather than trusted to a
# .gitignore. `.opencode/` gets a FILESYSTEM listing as well: a lens file written there would shape
# the next run's fleet, and a `.opencode/.gitignore` would hide it from git status.
tree_snapshot() { git status --porcelain --untracked-files=all | grep -vE "^..[[:space:]]+\"?$STATE_DIRNAME/" || true; }
opencode_dir_snapshot() { [ -d "$ROOT/.opencode" ] && find "$ROOT/.opencode" -type f -printf '%P %s %T@\n' 2>/dev/null | sort || true; }
TREE_BEFORE="$(tree_snapshot)"
OCDIR_BEFORE="$(opencode_dir_snapshot)"
HEAD_BEFORE="$(git rev-parse HEAD)"

# --- the message: their slash command, not a composed brief ---------------------------------------
# `opencode run --command code-review -- <level> <target>` is opencode's headless slash-command
# path (measured, M3): the plugin's template calls code_review_prompt with these arguments and the
# coordinator executes the compiled cell. Level and target are SEPARATE argv tokens: opencode wraps
# any token containing a space in double quotes, and the plugin's parser then reads `"medium` as a
# non-level and falls back to the sticky level (measured — it compiled the low cell).
TARGET="$SINCE_SHA...HEAD"
CMD_ARGS=("$LEVEL" "$TARGET")
[ "${#PATHS[@]}" -eq 0 ] || CMD_ARGS+=(-- "${PATHS[@]}")
[ "${#STRIPPED[@]}" -eq 0 ] || note "NOTE — stripped ${STRIPPED[*]}: posting needs gh/glab, the network and ~/.config/gh, all denied in the sandbox. Post host-side afterwards if wanted."

# --- the ladder ---------------------------------------------------------------------------------
# `setsid --wait` puts opencode in its OWN session and process group (still propagating the exit
# code), so a supervising harness reaping background shells by process group, a terminal hangup, or
# a CI teardown cannot kill a review that is minutes from finishing and already billed.
SETSID=()
if command -v setsid >/dev/null 2>&1 && setsid --help 2>&1 | grep -q -- '--wait'; then
  SETSID=(setsid --wait)
fi

# An unknown agent is opencode's fail-OPEN case: it warns and falls back to the default agent —
# which has write, edit and task — and exits 0. Kept even though srt makes the tree read-only: the
# default agent reviews with a DIFFERENT tool set and a different system prompt, so a fallback is
# still a void review. Checked on EVERY attempt, before anything else: confinement, aborts.
FALLBACK_RE='falling back to default agent|agent .* not found|is a subagent, not a primary agent'
agent_gate() {
  if grep -qiE "$FALLBACK_RE" "$PARTIAL_ERR" "$RAW" 2>/dev/null; then
    echo "--- opencode stderr ---" >&2; tail -20 "$PARTIAL_ERR" >&2
    ledger run "$M" "agent-fallback" "$(wc -c <"$RAW" 2>/dev/null || echo 0)" "$RUN_STEPS" "$RUN_IN" "$RUN_OUT" 0
    print_accounting "$M" "void — agent fell back to the default" 0
    die "opencode did not resolve '$AGENT' and fell back to the default agent, which is NOT the reviewed one. The review is void. Event log: $RAW"
  fi
}

tree_gate() { # <candidate-file> — rc 0 = tree untouched. A BACKSTOP behind the kernel: sandbox_gate
  # measured the read-only tree before the run; this checks the claim still held after it. It
  # cannot tell a sandbox escape from the operator editing in another window, so it promotes
  # nothing on its own.
  if [ "$(tree_snapshot)" = "$TREE_BEFORE" ] && [ "$(git rev-parse HEAD)" = "$HEAD_BEFORE" ] &&
     [ "$(opencode_dir_snapshot)" = "$OCDIR_BEFORE" ]; then return 0; fi
  echo "--- tree changed while the reviewer ran ---" >&2
  diff <(echo "$TREE_BEFORE") <(tree_snapshot) >&2 || true
  diff <(echo "$OCDIR_BEFORE") <(opencode_dir_snapshot) >&2 || true
  echo "The review itself completed and is kept at:" >&2
  echo "  $1" >&2
  echo "If those edits are yours, it is sound — promote it with:" >&2
  echo "  mv '$1' '$OUT' && git rev-parse HEAD > '$HEADFILE' && echo '$OUT' > '$LAST' && cp '$HEADFILE' '$LAST_HEAD'" >&2
  return 1
}

record_head() { git rev-parse HEAD >"$HEADFILE"; echo "$OUT" >"$LAST"; cp "$HEADFILE" "$LAST_HEAD"; echo "$LEVEL" >"$LAST_LEVEL"; }

# What a killed attempt consumed, recovered from the event log it already wrote. The main parser
# runs only AFTER the return-code checks, so the timeout and non-zero-exit paths would otherwise
# reach the ledger with the counters still at 0 — the ledger lying in the DANGEROUS direction, on
# exactly the paths that precede a relaunch.
RUN_STEPS=0 RUN_IN=0 RUN_OUT=0 RUN_LAUNCHED=0 RUN_SESSION=""
SUB_N=0 SUB_STEPS=0 SUB_IN=0 SUB_OUT=0 SUB_MEASURED=0 SUB_AGENTS="" SPAWNS=0
read_stream() { # sets the RUN_*/SPAWN facts from $RAW; never fatal
  [ -s "$RAW" ] || return 0
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      SESSION) RUN_SESSION="$v" ;;
      STEPS) RUN_STEPS="${v:-0}" ;; IN_TOK) RUN_IN="${v:-0}" ;; OUT_TOK) RUN_OUT="${v:-0}" ;;
      COST) EV_COST="${v:-0}" ;; REASON) EV_REASON="$v" ;; ERRORS) EV_ERRORS="${v:-0}" ;; TEXT) EV_TEXT="${v:-0}" ;;
      PROMPT_CALLED) EV_PROMPT_CALLED="${v:-0}" ;; PROMPT_OK) EV_PROMPT_OK="${v:-0}" ;; CELL_LEVEL) EV_CELL="$v" ;;
      SPAWNS) SPAWNS="${v:-0}" ;; SPAWN_NAMES) EV_SPAWN_NAMES="$v" ;; BAD_SPAWNS) EV_BAD_SPAWNS="$v" ;; SPAWN_ERRORS) EV_SPAWN_ERRORS="${v:-0}" ;;
    esac
  done < <(python3 "$SKILL_DIR/stream.py" "$RAW" --level "$LEVEL" --final "$PARTIAL" --errors "$PARTIAL.errors" 2>/dev/null || true)
  return 0
}
# The fan-out's spend, from opencode's session store (M2: the stream carries the parent only).
read_subagents() {
  SUB_N=0 SUB_STEPS=0 SUB_IN=0 SUB_OUT=0 SUB_MEASURED=0 SUB_AGENTS=""
  [ -n "$RUN_SESSION" ] || return 0
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      SUB_MEASURED) SUB_MEASURED="${v:-0}" ;; SUB_SESSIONS) SUB_N="${v:-0}" ;; SUB_STEPS) SUB_STEPS="${v:-0}" ;;
      SUB_IN_TOK) SUB_IN="${v:-0}" ;; SUB_OUT_TOK) SUB_OUT="${v:-0}" ;; SUB_AGENTS) SUB_AGENTS="$v" ;;
    esac
  done < <(python3 "$SKILL_DIR/db-usage.py" "$RUN_SESSION" 2>/dev/null || true)
  # A store that answers but holds no children for a run whose stream showed spawns is not a
  # measurement of zero — it is the wrong store (OPENCODE_DB elsewhere) or a session id mismatch.
  if [ "$SUB_MEASURED" = "1" ] && [ "${SUB_N:-0}" -eq 0 ] && [ "${SPAWNS:-0}" -gt 0 ]; then SUB_MEASURED=0; fi
  return 0
}
sub_cols() { # the four ledger columns, `?` when unmeasured
  if [ "$SUB_MEASURED" = "1" ]; then echo "$SUB_N $SUB_STEPS $SUB_IN $SUB_OUT"; else echo "$SPAWNS ? ? ?"; fi
}

print_accounting() { # <model> <outcome> <cost>
  echo "--- run accounting ---" >&2
  echo "  level            $LEVEL$([ "$FIX" -eq 1 ] && echo ' (--fix requested — Phase B is Claude'"'"'s, host-side)')" >&2
  echo "  model            $1" >&2
  echo "  outcome          $2" >&2
  echo "  reviewed         git diff $SINCE_SHA...HEAD + working tree$([ "$DELTA" -eq 1 ] && echo " (DELTA)"): $FILES_CHANGED file(s), ${DIFF_LINES:-?} diff lines / ${DIFF_BYTES:-?} bytes" >&2
  echo "  event log        $(wc -c <"$RAW" 2>/dev/null || echo 0) bytes" >&2
  echo "  coordinator      ${RUN_IN:-0} in (summed across ${RUN_STEPS:-0} steps, cache reads included) / ${RUN_OUT:-0} out" >&2
  if [ "$SUB_MEASURED" = "1" ]; then
    echo "  subagents        $SUB_N spawned (${SUB_AGENTS:-none}) — $SUB_IN in across $SUB_STEPS steps / $SUB_OUT out, read from opencode's session store" >&2
  else
    echo "  subagents        $SPAWNS task spawn(s) seen in the stream; subagent spend: UNMEASURED (session store unreadable — the true total is higher than the coordinator line)" >&2
  fi
  echo "  cost             \$${3:-0.0000}  — \$0.0000 on a subscription pot means unmetered, not free; the tokens above are the spend" >&2
  echo "  plugin           opencode-code-review v$(plugin_version "$PLUGIN")" >&2
  echo "  ledger           $LEDGER" >&2
}

kill_run() {
  local leader pg
  leader="$CHILD"
  if [ "${#SETSID[@]}" -gt 0 ]; then leader="$(pgrep -P "$CHILD" 2>/dev/null | head -1)"; fi
  [ -n "$leader" ] || { kill -TERM "$CHILD" 2>/dev/null; return; }
  pg="$(ps -o pgid= -p "$leader" 2>/dev/null | tr -d ' ')"
  if [ -n "$pg" ]; then kill -TERM -- "-$pg" 2>/dev/null; else kill -TERM "$leader" "$CHILD" 2>/dev/null; fi
}

# --- route preflight ----------------------------------------------------------------------------
# A ~100-token probe before the heavy run, through the tool-less preflight agent so the coordinator's
# prompt (which would call code_review_prompt and pull a 5 KB compiled prompt into context) is not
# what gets probed. Its verdict flows through the same advance() as any other route failure.
PF_REASON=""
preflight() { # <model> — rc 0 = the route answered; rc 1 = advance, with PF_REASON set
  PF_REASON=""
  [ "${OPENCODE_REVIEW_PREFLIGHT:-1}" != "0" ] || return 0
  local raw err rc status text steps in_tok out_tok cost
  raw="$PARTIAL.preflight.jsonl"; err="$PARTIAL.preflight.err"
  # A refused route logs its `level=ERROR … usage limit` line in the first second and then holds
  # the process open until the timeout (measured: 90s on an exhausted opencode-go pot), so the
  # probe is watched and killed the moment a terminal error appears rather than waited out.
  set +e
  ${SETSID[@]+"${SETSID[@]}"} timeout "$PREFLIGHT_SECS" "${OC_ENV[@]}" "${SRT[@]}" -s "$POLICY" -- \
    "$OPENCODE_BIN" run --dir "$ROOT" --agent "$PREFLIGHT_AGENT" --print-logs --log-level ERROR \
      --model "$1" --format json -- "Reply with exactly: OK" >"$raw" 2>"$err" </dev/null &
  CHILD=$!
  while kill -0 "$CHILD" 2>/dev/null; do
    sleep 2
    if [ ! -s "$raw" ] && grep -qiE "level=ERROR.*($FATAL_ERR_RE)" "$err" 2>/dev/null; then kill_run; break; fi
  done
  wait "$CHILD"; rc=$?
  CHILD=""
  set -e
  status="$(python3 - "$raw" <<'PY' 2>/dev/null || true
import json, sys
text = steps = in_tok = out_tok = 0
cost = 0.0
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except ValueError:
        continue
    kind, part = ev.get("type"), ev.get("part") or {}
    if kind == "text" and (part.get("text") or "").strip():
        text = 1
    elif kind in ("step_finish", "step-finish"):
        steps += 1
        tok = part.get("tokens") or {}
        try:
            in_tok += int(tok.get("input") or 0) + int(((tok.get("cache") or {}).get("read")) or 0)
            out_tok += int(tok.get("output") or 0)
            cost += float(part.get("cost") or 0)
        except (TypeError, ValueError):
            pass
print(f"{text}\t{steps}\t{in_tok}\t{out_tok}\t{cost:.4f}")
PY
)"
  text=0 steps=0 in_tok=0 out_tok=0 cost=0
  [ -z "$status" ] || IFS=$'\t' read -r text steps in_tok out_tok cost <<<"$status"
  local fatal=""
  fatal="$(cat "$err" "$raw" 2>/dev/null | grep -oiE "$FATAL_ERR_RE" | head -1 || true)"
  if grep -qiE "$FALLBACK_RE" "$err" 2>/dev/null; then
    die "the preflight fell back to the default agent — '$PREFLIGHT_AGENT' did not load from the private config. Nothing heavy was sent. stderr: $err"
  elif [ -n "$fatal" ]; then
    PF_REASON="the route refused before any review was sent — $fatal"
  elif [ "$rc" -eq 124 ]; then
    PF_REASON="no reply in ${PREFLIGHT_SECS}s — the route is unreachable or wedged"
  elif [ "${text:-0}" != "1" ]; then
    PF_REASON="the route produced no assistant text (opencode exited $rc)"
  fi
  if [ -n "$PF_REASON" ]; then
    ledger probe "$1" "fail: $PF_REASON" "$(wc -c <"$raw" 2>/dev/null || echo 0)" "${steps:-0}" "${in_tok:-0}" "${out_tok:-0}" "${cost:-0}"
    note "[$i/$N] preflight FAILED on $1 — $PF_REASON (nothing was sent: no diff, no review)"
    return 1
  fi
  ledger probe "$1" ok "$(wc -c <"$raw" 2>/dev/null || echo 0)" "${steps:-0}" "${in_tok:-0}" "${out_tok:-0}" "${cost:-0}"
  add_cost "$cost"
  note "[$i/$N] preflight OK on $1 (${in_tok:-0} in / ${out_tok:-0} out tokens)"
  rm -f "$raw" "$err"
  return 0
}

TOTAL_COST="0.0000"
ATTEMPTS=()
REMAINING=("${LADDER[@]:0:$N}")
i=0
while [ "${#REMAINING[@]}" -gt 0 ]; do
  mapfile -t REMAINING < <(demote_peak_cash "${REMAINING[@]}")
  M="${REMAINING[0]}"
  REMAINING=("${REMAINING[@]:1}")
  i=$((i + 1))
  PARTIAL="$(mktemp "$RUN_DIR/attempt-$i.partial.XXXXXX")"
  RAW="$PARTIAL.jsonl"
  PARTIAL_ERR="$PARTIAL.err"
  WD_REASON="$PARTIAL.wd"
  RUN_STEPS=0 RUN_IN=0 RUN_OUT=0 RUN_LAUNCHED=0 RUN_SESSION="" SPAWNS=0 SUB_MEASURED=0
  EV_COST=0 EV_REASON="" EV_ERRORS=0 EV_TEXT=0 EV_PROMPT_CALLED=0 EV_PROMPT_OK=0 EV_CELL="" EV_SPAWN_NAMES="" EV_BAD_SPAWNS="" EV_SPAWN_ERRORS=0

  # advance: give up on THIS entry, fall to the next — unless the model was pinned.
  advance() { # <cost> <reason>
    add_cost "$1"
    local wd; wd="$(cat "$WD_REASON" 2>/dev/null || true)"
    if [ "$RUN_LAUNCHED" -eq 1 ]; then
      read_subagents
      # shellcheck disable=SC2046
      ledger run "$M" "${wd:-$2}" "$(wc -c <"$RAW" 2>/dev/null || echo 0)" "$RUN_STEPS" "$RUN_IN" "$RUN_OUT" "${1:-0}" $(sub_cols)
      print_accounting "$M" "failed — ${wd:-$2}" "${1:-0}"
    fi
    if [ "$PINNED" -eq 1 ]; then
      local hint=""
      case "${wd:-$2}" in
        *"event log still empty"*|*"provider refused before producing"*|*"preflight"*)
          hint=$'\nDo NOT relaunch until the route is verified: a refused or unreachable route bills a full context load per attempt and returns nothing. Read the ledger first:  run-review.sh usage' ;;
      esac
      die "--model $M was pinned: NO auto-fallback. Reason: ${wd:+watchdog — }${wd:-$2}. Event log: $RAW  stderr: $PARTIAL_ERR$hint"
    fi
    note "[$i/$N] $M failed — $2${wd:+ — watchdog: $wd} — falling back"
    ATTEMPTS+=("$M: $2${wd:+ — watchdog: $wd}  [kept: $PARTIAL, $RAW, $PARTIAL_ERR]")
    return 0
  }

  if ! preflight "$M"; then
    advance "" "preflight: $PF_REASON"
    continue
  fi

  V="$(variant_for "$M" "$LEVEL")"
  note "[$i/$N] model $M${V:+, variant $V}, level $LEVEL, target $TARGET (timeout ${TIMEOUT_SECS}s)"
  ARGS=(run --command code-review --dir "$ROOT" --agent "$AGENT" --model "$M" --print-logs --log-level INFO)
  [ -z "$V" ] || ARGS+=(--variant "$V")
  ARGS+=(--format json -- "${CMD_ARGS[@]}")

  set +e
  RUN_LAUNCHED=1
  ${SETSID[@]+"${SETSID[@]}"} timeout "$TIMEOUT_SECS" \
    "${OC_ENV[@]}" "${SRT[@]}" -s "$POLICY" -- "$OPENCODE_BIN" "${ARGS[@]}" >"$RAW" 2>"$PARTIAL_ERR" </dev/null &
  CHILD=$!

  # Liveness watchdog: the failure signatures live in files this script owns, so watch them and kill
  # early — the resulting non-zero rc flows through the normal advance path with the reason attached.
  # Each poll also checks the three things that make the rest of the run a waste: the agent-fallback
  # warning (confinement), a compiled cell whose level is not the one asked for (the run would be a
  # different, cheaper review than the ledger records), and a task spawn outside the allow-set.
  (
    last=0; flat=0
    empty_deadline=$(( SECONDS + STALL_START ))
    while :; do
      sleep "$POLL"
      kill -0 "$PPID" 2>/dev/null || exit 0
      if grep -qiE "$FALLBACK_RE" "$PARTIAL_ERR" "$RAW" 2>/dev/null; then
        echo "agent fell back to the default (confinement)" >"$WD_REASON"; kill_run; exit 0
      fi
      cur=$(wc -c <"$RAW" 2>/dev/null || echo 0)
      if [ "$cur" -eq 0 ]; then
        if grep -qiE "level=ERROR.*($FATAL_ERR_RE)" "$PARTIAL_ERR" 2>/dev/null; then
          echo "provider refused before producing anything: $(grep -oiE "$FATAL_ERR_RE" "$PARTIAL_ERR" | head -1) — terminal, not a slow start" >"$WD_REASON"; kill_run; exit 0
        fi
        if [ "$SECONDS" -ge "$empty_deadline" ]; then
          echo "event log still empty after ${STALL_START}s — the provider was never reached (route problem)" >"$WD_REASON"; kill_run; exit 0
        fi
        continue
      fi
      if [ "$cur" -gt "$MAX_JSONL" ]; then
        echo "event log reached ${cur} bytes with no review — runaway to the output ceiling" >"$WD_REASON"; kill_run; exit 0
      fi
      if [ "$cur" -ne "$last" ]; then
        flat=0; last=$cur
        cell="$(python3 "$SKILL_DIR/stream.py" "$RAW" --level "$LEVEL" 2>/dev/null || true)"
        got="$(grep -m1 '^CELL_LEVEL=' <<<"$cell" | cut -d= -f2)"
        if [ -n "$got" ] && [ "$got" != "$LEVEL" ]; then
          echo "the compiled cell is '$got', not '$LEVEL' — the model passed code_review_prompt different arguments than it was given; killed before the wrong review was paid for" >"$WD_REASON"; kill_run; exit 0
        fi
        bad="$(grep -m1 '^BAD_SPAWNS=' <<<"$cell" | cut -d= -f2)"
        if [ -n "$bad" ]; then
          echo "task spawned an agent outside the allow-set: $bad (confinement)" >"$WD_REASON"; kill_run; exit 0
        fi
      else
        flat=$((flat + POLL))
        if [ "$flat" -ge "$STALL_BYTES" ]; then
          echo "event log flat for ${STALL_BYTES}s — the stream died mid-run" >"$WD_REASON"; kill_run; exit 0
        fi
      fi
    done
  ) &
  WD_PID=$!

  wait "$CHILD"
  rc=$?
  set -e
  CHILD=""
  kill "$WD_PID" 2>/dev/null || true
  wait "$WD_PID" 2>/dev/null || true

  read_stream
  agent_gate
  if [ -n "$EV_BAD_SPAWNS" ] || grep -q 'outside the allow-set' "$WD_REASON" 2>/dev/null; then
    read_subagents
    # shellcheck disable=SC2046
    ledger run "$M" "bad-spawn" "$(wc -c <"$RAW" 2>/dev/null || echo 0)" "$RUN_STEPS" "$RUN_IN" "$RUN_OUT" "$EV_COST" $(sub_cols)
    print_accounting "$M" "void — task spawned an agent outside the allow-set: ${EV_BAD_SPAWNS:-see watchdog}" "$EV_COST"
    die "the coordinator spawned '${EV_BAD_SPAWNS:-?}' through task; only reviewer-$LEVEL and reviewer-lens-* are permitted. The review is void. Event log: $RAW"
  fi
  grep -qE 'permission requested:.*auto-rejecting' "$PARTIAL_ERR" 2>/dev/null &&
    note "NOTE — opencode auto-rejected a permission request during the run ($(grep -m1 -oE 'permission requested: [^;]*' "$PARTIAL_ERR")); the model asked for something the private config denies. Not fatal."

  if [ "$rc" -eq 124 ]; then
    advance "$EV_COST" "timed out after ${TIMEOUT_SECS}s (event log $RAW: $(wc -c < "$RAW") bytes — empty means it never started)"
    continue
  fi

  if [ "$rc" -ne 0 ]; then
    echo "--- opencode stderr (tail) ---" >&2; tail -5 "$PARTIAL_ERR" >&2 || true
    if grep -q 'No payment method' "$RAW" 2>/dev/null; then
      echo "HINT: $M's provider wants a payment method on that workspace." >&2
    fi
    # SALVAGE. The review may be FINISHED and merely lost: opencode persists the session locally, so
    # a process killed after the model stopped but before the stream drained has already been billed
    # for a review that still exists. The salvager returns the last assistant message; findings.py
    # is the only judge of whether that is a complete review.
    if [ -n "$RUN_SESSION" ]; then
      note "run died with a session on disk ($RUN_SESSION) — attempting salvage."
      if OPENCODE_BIN="$OPENCODE_BIN" node "$SKILL_DIR/salvage-session.mjs" "$RUN_SESSION" --out "$PARTIAL.salvaged" >/dev/null &&
         python3 "$SKILL_DIR/findings.py" "$LEVEL" "$PARTIAL.salvaged" "$PARTIAL.salvaged.json" --cap "$(cap_for "$LEVEL")" >/dev/null; then
        read_subagents
        tree_gate "$PARTIAL.salvaged.json" || {
          # shellcheck disable=SC2046
          ledger run "$M" "tree-changed-salvage" "$(wc -c <"$RAW" 2>/dev/null || echo 0)" "$RUN_STEPS" "$RUN_IN" "$RUN_OUT" "$EV_COST" $(sub_cols)
          die "salvage not promoted automatically: if the edits are NOT yours, the sandbox did not hold."
        }
        # shellcheck disable=SC2046
        ledger run "$M" "ok-salvaged" "$(wc -c <"$RAW" 2>/dev/null || echo 0)" "$RUN_STEPS" "$RUN_IN" "$RUN_OUT" "$EV_COST" $(sub_cols)
        mv "$PARTIAL.salvaged.json" "$OUT"
        record_head
        print_accounting "$M" "ok — SALVAGED from $RUN_SESSION after the process died (rc $rc)" "$EV_COST"
        echo "$OUT"
        exit 0
      fi
      echo "HINT: nothing to salvage — the model had not finished a schema-valid findings list." >&2
    fi
    advance "$EV_COST" "opencode exited $rc with nothing to salvage"
    continue
  fi

  # --- the contract gates: their prompt was executed, their fleet ran, their output validates ------
  if [ "${EV_ERRORS:-0}" != "0" ]; then
    advance "$EV_COST" "the provider returned an error instead of a review ($(head -1 "$PARTIAL.errors" 2>/dev/null || echo 'unknown'))"; continue
  fi
  if [ "${EV_TEXT:-0}" != "1" ]; then
    advance "$EV_COST" "runaway: no assistant text (stop reason ${EV_REASON:-?}) — the ladder's next model gets a fresh shot"; continue
  fi
  if [ "${EV_PROMPT_OK:-0}" != "1" ]; then
    advance "$EV_COST" "the model never completed a code_review_prompt call (called: ${EV_PROMPT_CALLED:-0}) — it reviewed without the compiled prompt, which is not the review that was asked for"; continue
  fi
  if [ "$EV_CELL" != "$LEVEL" ]; then
    advance "$EV_COST" "the compiled cell is '${EV_CELL:-?}', not '$LEVEL' — the model altered the arguments it passed to code_review_prompt"; continue
  fi
  if [ "$LEVEL" != "low" ] && [ "${SPAWNS:-0}" -eq 0 ]; then
    advance "$EV_COST" "no finder subagent was spawned at $LEVEL: the model took the inline fallback although task was available, which is a single pass wearing a fan-out's label"; continue
  fi
  if [ "$EV_REASON" != "stop" ]; then
    advance "$EV_COST" "stopped with '$EV_REASON', not 'stop' — cut short, not finished ($(wc -c <"$PARTIAL" 2>/dev/null || echo 0) bytes recovered)"; continue
  fi
  if ! python3 "$SKILL_DIR/findings.py" "$LEVEL" "$PARTIAL" "$PARTIAL.json" --cap "$(cap_for "$LEVEL")" >"$PARTIAL.count" 2>"$PARTIAL.gate"; then
    advance "$EV_COST" "output off-contract: $(head -1 "$PARTIAL.gate" 2>/dev/null || echo 'not a findings list')"; continue
  fi
  grep -i 'NOTE' "$PARTIAL.gate" >&2 2>/dev/null || true
  COUNT="$(cat "$PARTIAL.count")"

  # The read-only claim, measured rather than assumed. The ledger row is written BEFORE the gate
  # decides: this is the most expensive attempt the harness makes, its counters are in hand, and
  # the abort below is the one an operator is most likely to hit (an edit in another window).
  read_subagents
  TREE_OK=1; tree_gate "$PARTIAL.json" || TREE_OK=0
  # shellcheck disable=SC2046
  ledger run "$M" "$([ "$TREE_OK" -eq 1 ] && echo ok || echo tree-changed)" \
    "$(wc -c <"$RAW" 2>/dev/null || echo 0)" "$RUN_STEPS" "$RUN_IN" "$RUN_OUT" "$EV_COST" $(sub_cols)
  [ "$TREE_OK" -eq 1 ] ||
    die "not promoting automatically: if the edits are NOT yours, the sandbox did not hold and neither the tree nor the review can be trusted."

  SPAWN_ERR_NOTE=""; [ "${EV_SPAWN_ERRORS:-0}" -eq 0 ] || SPAWN_ERR_NOTE=", $EV_SPAWN_ERRORS spawn error(s)"
  print_accounting "$M" "ok — $COUNT finding(s) promoted (${EV_SPAWN_NAMES:-no subagents}$SPAWN_ERR_NOTE)" "$EV_COST"
  add_cost "$EV_COST"
  chmod 0644 "$PARTIAL.json"
  mv "$PARTIAL.json" "$OUT"
  record_head
  rm -f "$PARTIAL" "$PARTIAL.count" "$PARTIAL.gate" "$PARTIAL.errors" "$RAW" "$PARTIAL_ERR" "$WD_REASON"
  note "$OUT  ($COUNT finding(s), \$$TOTAL_COST across $i attempt(s)) via $M"
  note "findings are CLAIMS — confirm each against the code before editing."
  echo "$OUT"
  exit 0
done

{
  echo "ABORT: every model on the $LEVEL ladder failed ($i attempt(s)):"
  for a in "${ATTEMPTS[@]}"; do echo "  - $a"; done
  echo "Total spend: \$$TOTAL_COST. Fix the route, raise OPENCODE_REVIEW_MAX_ATTEMPTS, or pin a known-good --model."
  echo "Read what these attempts consumed BEFORE relaunching — a blind re-run re-bills from the top:"
  echo "  $SKILL_DIR/run-review.sh usage"
} >&2
exit 1
