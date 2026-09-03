---
description: Stop the opencode review running in this repository; the harness records what the attempt consumed and releases the run marker
disable-model-invocation: true
allowed-tools: Bash(bash:*)
---

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" cancel
```

Present the output verbatim. The harness sends TERM to the running harness process, which kills its
sandboxed opencode run, keeps the event log beside the run directory, writes the ledger row for the
spend so far, and releases the marker. If nothing was running, say so.
