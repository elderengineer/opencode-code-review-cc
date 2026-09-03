---
description: Show what every opencode review attempt in this repository consumed — the per-attempt ledger with per-level totals (tokens, subagents, cost)
disable-model-invocation: true
allowed-tools: Bash(bash:*)
---

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" usage
```

Present the table and the totals verbatim. Point out that `in_tok` is the coordinator's summed
input (cache reads included) and `sub_in_tok` the subagents' — the fan-out at medium and above
is several times the coordinator's own spend, and `?` there means the session store could not be
read for that attempt (unmeasured, not zero). `$0.0000` on a subscription pot means unmetered,
not free.
