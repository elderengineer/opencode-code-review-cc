# Recovering a failed run

Read this when a run aborts. The one rule that matters before then: **an abort is never "no
findings"**. `[]` at the findings path is a review that found nothing; nothing at the findings path
is no review.

Two failure classes, and the harness never confuses them:

- **Route/model-shaped → abort after the one attempt.** A failed preflight (the route refused or went
  silent — nothing heavy was sent, and the ledger gets a `probe` row rather than a `run` one); a
  timeout; non-zero exit with nothing to salvage; a provider error event; no assistant text (a
  runaway — the fix is a different model, never a bigger budget); the model never completed a
  `code_review_prompt` call; the compiled cell is not the requested level (the model altered the
  arguments); no finder subagent was spawned at medium+; a stop reason other than `stop`; output
  off-contract (`findings.py` could not extract a schema-valid findings list).
- **Confinement/contract-shaped → abort, loudly, non-zero.** A host requirement is
  missing; the policy will not render; **the sandbox probe measured a writable repo, a readable
  credential path, no egress, an unmasked key, or the plugin not loaded**; opencode fell back to
  the default agent; a `task` spawn named an agent outside `{reviewer-<level>, reviewer-<level>-alt<N>, reviewer-lens-*}`;
  the tree changed while the reviewer ran; another run holds the marker; `using <model>` was
  typed.

Whatever a failed attempt produced is kept in the run directory
(`<repo>/.opencode-review/runs/<stamp>-<level>/`) with a random suffix —
`attempt-N.partial.XXXXXX` (the last assistant text), `.jsonl` (the event stream), `.err`
(stderr), `.wd` (the watchdog's reason) — and **never at `findings.json`**, so a truncated result
can never be mistaken for a finished review.

## Recovering

- **The process died but the model finished.** opencode persists the session, so a kill after the
  model stopped but before the stream drained has already been billed for a review that still
  exists — the harness salvages it automatically (`salvage-session.mjs` returns the LAST assistant
  message; `findings.py` is the only judge of whether it is a complete list). By hand:

  ```bash
  grep -o '"sessionID":"[^"]*"' <kept .jsonl> | head -1 | cut -d'"' -f4
  node scripts/salvage-session.mjs <sessionID> --out /tmp/salvaged.txt
  python3 scripts/findings.py <level> /tmp/salvaged.txt /tmp/findings.json --cap <cap>
  ```

- **The tree changed.** The abort prints the diff and the exact `mv … && git rev-parse HEAD > …`
  that promotes the kept review by hand. If the edits were yours (another window), it is sound; if
  they were not, the sandbox did not hold and neither the tree nor the review can be trusted.
- **The coordinator's model failed.** The harness has no ladder; the abort names the model and its
  source (--model, opencode-code-review's cached ladder head or pin, or opencode's default). Pass
  `--model <provider/model>` to run the coordinator elsewhere. If it died at the preflight, the route is the problem: do not relaunch until it is
  verified — the preflight verifies it for ~100 tokens.
- **Before any re-run, read `run-review.sh usage`** — that is the only place that says what the
  attempt actually consumed, subagents included. Fix the route first; a fresh run re-bills the
  whole fan-out.
- **Another run holds the marker.** `run-review.sh status` shows whether it is alive and how long
  ago its event log grew; `run-review.sh cancel` sends it TERM (it records its spend and releases
  the marker). A marker whose process is gone is cleared automatically by the next run.

## The watchdog

Runs beside every attempt and fires long before the timeout: an event log still empty after
`STALL_START` (120 s) means the provider was never reached; a terminal provider error on stderr
(`usage limit`, `no payment method`, `invalid api key`, `model not found`, …) while the log is
empty short-circuits that deadline; flat for `STALL_BYTES` (600 s — the parent stream is quiet
while a wave of finder subagents runs, measured 60–90 s per wave at medium) means the stream died;
past `MAX_JSONL_MB` (16) means runaway churn. It also kills at once on the agent-fallback warning,
on a compiled cell whose level is not the one requested, and on a `task` spawn outside the
allow-set. Every kill flows through the normal advance path with its reason stamped in the `.wd`
file and the ledger row.

opencode's own logs ride stderr into the kept `.err`: grep them (`level=ERROR`, `agent=`,
`auto-rejecting`), never read them whole — they cost zero model tokens. The Z.AI route rate-limits
subagent waves (`Rate limit reached for requests` on `reviewer-*` sessions); opencode retries, and
a run that completes despite them is sound.

When the harness finally aborts, **stop and report it.** Do not proceed to Phase B as though the
review passed with no findings; that is a silent skip wearing a different hat.
