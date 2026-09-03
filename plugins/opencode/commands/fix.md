---
description: Apply the findings of the LAST promoted opencode review host-side (Phase B alone, for a review that ran without `--fix`)
disable-model-invocation: true
allowed-tools: Bash(bash:*), Bash(cat:*), Bash(git:*), Read, Edit, Grep, Glob
---

Locate the last promoted review:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" last
```

If it aborts (no promoted review in this repo), say so and stop. Otherwise `cat` the findings file
it names and check that the recorded head is still `HEAD` (`git rev-parse HEAD`); if the head has
moved, warn that the findings were made against an older commit and confirm with the user before
continuing.

Then apply Phase B exactly as `/opencode:code-review … --fix` does — you edit, host-side, with the
normal permission prompts; nothing sandboxed edits anything:

- Take the findings in order (ranked most-severe first). Open each cited file:line and check the
  claim against the code.
- **Skip, stating the reason**, any finding whose fix would change intended behaviour, would need
  changes well outside the reviewed diff, or that you judge a false positive after reading the code;
  and any finding the verify pass left `PLAUSIBLE` rather than `CONFIRMED` (the `verdict` field
  when present; otherwise a failure scenario you cannot reproduce from the code).
- **Apply** the rest with the smallest edit that resolves the stated failure scenario.

Finish with what was fixed (file:line each) and what was skipped and why. Do not commit. Suggest
`/opencode:code-review <level>` to review the uncommitted fixes as a delta.
