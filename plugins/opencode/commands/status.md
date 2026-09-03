---
description: Show whether an opencode review is running in this repository, the last promoted review, and the last ledger rows
disable-model-invocation: true
allowed-tools: Bash(bash:*)
---

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" status
```

Present the output compactly. If a run is live, say how many bytes its event log holds and how
long ago it was last written — an event log that has not grown for minutes is the watchdog's
concern, not a reason to launch another run. If the marker is stale, say the next run clears it.
