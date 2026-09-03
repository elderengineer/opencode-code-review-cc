---
description: Check this box for the opencode review harness (opencode, srt, bwrap, socat, the plugin, /etc/hosts), render the sandbox policy and run the measured probe — no review is run
disable-model-invocation: true
allowed-tools: Bash(bash:*)
---

Run the harness's setup mode, which checks every host requirement, renders the srt policy for this
repository, runs the sandbox probe under it (seven verdicts: WRITE, CRED, READ, GIT, NET, MASK,
PLUGIN), and adds `.opencode-review/` to the repo's `.gitignore`. It contacts no provider and
spends no tokens.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" setup $ARGUMENTS
```

Present the output verbatim. Every missing requirement is printed with the exact command that
fixes it — relay those commands; do not run installs yourself. If the last line reads
`setup OK`, say the harness is ready and that `/opencode:code-review low` is the cheapest first run.
If it aborted, say which verdict failed and that no review can run until it passes.
