---
name: opencode-runtime
description: Internal contract for the opencode review harness — how /opencode:code-review, /opencode:setup, /opencode:usage, /opencode:status, /opencode:cancel and /opencode:fix call scripts/run-review.sh, what a promoted review looks like, and what an abort means. Read reference/ only on failure.
user-invocable: false
---

# opencode review runtime

The plugin runs [opencode-code-review](https://github.com/elderengineer/opencode-code-review)'s
`/code-review` inside a bubblewrap sandbox (`srt`, `@anthropic-ai/sandbox-runtime`) from Claude
Code. Their plugin owns review quality — the level cells, the finder/verifier fleet, project lenses.
This plugin owns the four things a plugin inside the reviewed process cannot: **confinement**
(measured before every run), **cost** (preflight, budget, ledger, marker), **fail-loud**
(an abort is never "no findings"), and the Claude-side UX (Phase B, the `--fix` hand).

## The one entry point

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" review <level> [args…]   # /opencode:code-review
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" setup                    # /opencode:setup
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" usage | status | cancel | last
```

`review` runs in the background (`run_in_background: true`); the process exiting is the completion
signal. There is no daemon, no polling, no id scraping: the response file either exists (promoted)
or does not (aborted, evidence kept beside it).

## What a promoted review is

`<repo>/.opencode-review/runs/<stamp>-<level>/findings.json` — a JSON array of
`{file, line, summary, failure_scenario}` (optionally `verdict`), ranked most-severe first, capped
per level (4/8/10/15), `[]` when the review completed and found nothing. Validated against
`scripts/schemas/findings.schema.json` before promotion; the low level's one-line contract is
normalised into the same shape. `.opencode-review/last` points at the newest promotion and
`last.head` at the commit it reviewed — the next run defaults to the delta since it.

## What an abort is

Non-zero exit, `ABORT:` on stderr naming the cause and its fix, nothing at the findings path. Two
classes, never confused:

- **route/model-shaped → aborted after one attempt** (preflight refused, timeout, runaway,
  provider error, wrong cell compiled, no subagent spawned at medium+, output off-contract). Model
  fallback is opencode-code-review's (its `reviewer-<level>-alt<N>` alternates under
  `--model auto`), not the harness's; the abort names the coordinator's model and where it came from.
- **confinement/contract-shaped → aborted at once, no fallback** (a host requirement missing, the
  probe measured a writable repo / readable credential / no egress / unmasked key / plugin not
  loaded, the agent fell back to the default, a `task` spawn outside the allow-set, the tree
  changed while the reviewer ran, another run holds the marker).

Report an abort as an abort. Do not relaunch on your own; `usage` says what the attempts cost.
Make recovery the default rather than something the user must think to request: the script salvage-promotes a finished review from a dead process on its own, and before reporting an abort, check what else survived — a re-run is the last resort, never the first move.

## Levels and what they buy

| level | their cell | cap |
|---|---|---|
| low | one diff pass, hunk only, no subagents | 4 |
| medium | up to 8 triaged finder lenses × 6 candidates, 1-vote precision verify | 8 |
| high | same fan-out, recall-biased verify | 10 |
| max | 10 lenses × 8, verify, gap sweep; `--variant max` | 15 |

Models are opencode-code-review's decision: the reviewers run its pin (`--model auto` = your ★
favorites, cheapest first), and the coordinator runs the head of its cached ladder, its concrete
pin, or opencode's default — `--model` overrides the coordinator for one run.

Medium and above spawn `reviewer-<level>` (or, on fallback, `reviewer-<level>-alt<N>`) subagents; every subagent is its own context re-sent per
step. The accounting prints the coordinator's tokens and the subagents' separately (the latter read
from opencode's session store — the event stream carries the parent only).

## Phase B — `--fix`

`--fix` never reaches the sandbox. Phase A is identical with or without it; Phase B is Claude,
host-side, with its own Edit tool and the normal permission prompts, applying findings in order and
skipping — with a stated reason — any that would change intended behaviour, need changes well
outside the diff, or that verification left PLAUSIBLE. Those are opencode-code-review's `--fix`
rules verbatim; only the hand that edits changes. A third-party model with a shell and edit rights
running as the user is the thing this plugin exists to prevent.

## Stripped and refused

`--comment` / `--post` are stripped (gh/glab, the network and `~/.config/gh` are all denied) and
said so in the accounting. `using <model>` is refused: it writes opencode-code-review's sticky pin, which
is read-only in the sandbox — set it in opencode, where it then applies to sandboxed runs too.
`--no-triage`, `--lenses a,b,c` and `--include-generated` pass through unchanged.

## On failure, read

- `reference/confinement.md` — what holds the reviewer, the six measurements (M1–M6) with versions
- `reference/recovery.md` — salvage, partials, the watchdog, what to do after an abort
