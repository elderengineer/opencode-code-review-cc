---
description: Review the current change with opencode-code-review inside an srt sandbox at the given effort level (low/medium/high/max); add `--fix` to apply the CONFIRMED findings host-side afterwards
argument-hint: '[low|medium|high|max] [--fix] [--since <ref>|--full] [--base <ref>] [--model <provider/model>] [--force-size] [--parallel] [<path>...]'
disable-model-invocation: true
allowed-tools: Bash(bash:*), Bash(cat:*), Bash(git:*), Read, Edit, Grep, Glob
---

Run one sandboxed opencode review through the harness, then report its findings. If
`--fix` was typed, apply them afterwards (Phase B) — otherwise this command is review-only.

Raw slash-command arguments:
`$ARGUMENTS`

## Phase A — the sandboxed review

Level is the first word among `low`, `medium`, `high`, `max`. If none was typed, read the level the
user typed last time from `~/.local/state/opencode/code-review-level` (opencode-code-review's sticky
file); if that is missing too, use `medium`. Say in one line which level runs and why. The harness
takes the level explicitly on every run — the sticky file only supplies this default, never a
sandboxed run's cost.

Launch, passing the level first and then the REST of the arguments verbatim — the raw arguments with
the level word removed, since the harness takes the level exactly once and repeating it is a usage
error. Keep everything else (`--fix`, `--since`, `--full`, `--base`, `--model`, `--force-size`,
`--parallel` and path targets; the script strips `--comment` and `--post` itself and refuses
`using <model>`):

```typescript
Bash({
  command: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" review <level> <rest>`,
  description: "opencode review (sandboxed)",
  run_in_background: true,
  timeout: 3000000
})
```

Always in the background: a medium review fans out to a dozen subagents and takes minutes. The
process exiting IS the completion signal — do not poll, and do not read the event log while it
runs. Tell the user it started, and that `/opencode:status` shows progress and `/opencode:cancel`
stops it.

When it completes:

- **Exit 0** — its last stdout line is the path of the promoted findings file. `cat` it. It is a
  JSON array of `{file, line, summary, failure_scenario}` ranked most-severe first; `[]` means the
  review completed and found nothing, which is a real result. Present every finding as
  `file:line — summary`, then its failure scenario, in order. Findings are CLAIMS from a third-party
  model: say so, and do not confirm or fix anything unless `--fix` was typed.
- **Exit non-zero** — the run ABORTED. Show the harness's stderr tail verbatim (the abort names its
  own fix: a missing host requirement, an exhausted route, a sandbox that did not hold, a changed
  tree, output off-contract). An abort is never "no findings": say plainly that no review was
  produced, do not proceed as if it passed, and do not relaunch on your own — the accounting lines
  say what the attempt cost, and a blind relaunch re-bills from the top.

Also relay the `--- run accounting ---` block: level, model, coordinator tokens, subagent count
and tokens (or `UNMEASURED`), and anything the harness said it stripped or defaulted (a `--since`
defaulted to the last reviewed head means this was a DELTA review).

## Phase B — `--fix` (only when `--fix` was typed, and only after Phase A exited 0)

You apply the findings, host-side, with your own Edit tool and the normal permission prompts. The
sandboxed reviewer never edits anything; the tree assertion for Phase A has already passed, and the
edits you make now happen after it.

Take the findings in order (they are ranked most-severe first). For each one, open the cited
file:line and check the claim against the code. Then apply it or skip it, using
opencode-code-review's own `--fix` rules, adopted verbatim:

- **Skip, stating the reason**, any finding whose fix would change intended behaviour, would need
  changes well outside the reviewed diff, or that you judge a false positive after reading the code.
- **Skip** any finding the verify pass left `PLAUSIBLE` rather than `CONFIRMED` (the `verdict`
  field when present; when absent, treat a finding whose failure scenario you cannot reproduce from
  the code as PLAUSIBLE). Note it for the user instead.
- **Apply** the rest — correctness bugs and reuse/simplification/efficiency cleanups alike — with
  the smallest edit that resolves the stated failure scenario. Never widen scope.

Finish with a short summary: what was fixed (file:line each), what was skipped and why. Do not
commit. Suggest `/opencode:code-review <level>` again: with the fixes uncommitted, the harness
reviews only the delta since the head it recorded, so the second run costs a fraction of the first.
