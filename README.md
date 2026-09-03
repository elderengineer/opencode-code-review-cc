# opencode-code-review-cc

Run opencode's `/code-review` from Claude Code inside a bubblewrap sandbox.

```
/opencode:code-review max          # review the current change at max effort
/opencode:code-review high --fix   # review, then apply the findings
/opencode:setup                    # check the machine and the sandbox, no review
/opencode:usage                    # token usage of every run so far
/opencode:status  /opencode:cancel /opencode:fix
```

## How this relates to opencode-code-review

This repository is a Claude Code plugin marketplace with one plugin, `opencode`.

The review itself is done by [opencode-code-review](https://github.com/elderengineer/opencode-code-review),
which is a plugin for opencode. It adds a `/code-review [low|medium|high|max]` command to opencode:
the four effort levels, the finder and verifier subagents, the gap sweep, project lenses, and the
findings format. This plugin does not contain any of that. It runs that command from Claude Code
and takes care of the parts that have to work no matter what the model does:

| | |
|---|---|
| opencode-code-review (opencode plugin) | the review: effort levels, `reviewer-<level>` subagents, project lenses, the findings format |
| opencode-code-review-cc (this repository, Claude Code plugin) | the sandbox, config isolation, cost tracking, error handling, and the Claude Code commands |

The split exists because a plugin running inside opencode cannot put opencode in a sandbox, cannot
check that the sandbox works, and cannot count what it spent from the outside. So those jobs live
here, on the host:

- **Sandbox.** Every run is `srt -s <policy> -- opencode …`, using `@anthropic-ai/sandbox-runtime`
  on top of bubblewrap. The repository is read-only, credential directories cannot be read,
  opencode's `auth.json` is masked, and only the provider endpoints are reachable. Before each run a
  small probe checks all of this inside the sandbox; if any check fails the run does not start.
- **Config isolation.** Each run gets its own `XDG_CONFIG_HOME` and `XDG_STATE_HOME`, so only
  opencode-code-review is loaded. Your other opencode plugins, MCP servers and agents are not part
  of the session, the reviewed repository's `.opencode/opencode.json` is ignored, and the plugin's
  sticky `using <model>` pin cannot take effect.
- **Cost.** A small probe checks the model route before the full run, a second review only covers
  what changed since the previous one, large diffs are warned about or refused, one run at a time
  per repository, and every attempt is written to a ledger that includes the subagents' tokens
  (read from opencode's session database, since they do not appear in the event stream).
- **Errors.** A failed run is reported as a failure, never as "no findings". The harness checks
  that opencode used the right agent, that only `reviewer-*` subagents were spawned, that the
  right effort level was compiled, that the output is a valid findings list, and that the working
  tree did not change during the run.

`--fix` is handled by Claude, not by opencode. Phase A runs the sandboxed review and produces a
JSON list of findings. Phase B is Claude editing the files with its own Edit tool and the usual
permission prompts, using the same skip rules as opencode-code-review's `--fix`. Nothing inside
the sandbox can edit anything.

## Why a sandbox

A code review needs to read the whole repository, so the reviewer has to be a full agent with a
shell and git, not a model that is handed a diff. opencode-code-review runs exactly that way: its
coordinator runs `git diff` itself and starts subagents that read files. The model doing this is a
third-party model, chosen for the fact that it shares nothing with Claude, and it runs on your
machine as your user.

Without a sandbox, that agent can do everything you can do:

- **Write to the repository.** A reviewer that edits the code it is reviewing, runs a build, or
  leaves a file behind is no longer a reviewer. This also breaks the `--fix` design, where the only
  thing that edits files is Claude with your permission prompts.
- **Read your credentials.** `~/.ssh`, `~/.aws`, `~/.config/gh`, `~/.netrc` and opencode's own
  `auth.json` are all readable by any process running as you. Everything the model reads goes to
  its provider.
- **Reach the network.** With `gh`, `curl` and your credentials available, a model can post,
  push, or send data anywhere.
- **Read other repositories.** Nothing limits a shell to the directory it was started in.

opencode's own settings do not close these gaps. Its tool permissions were measured to fail open
in three ways: an unknown agent name falls back to the default agent, which can write; a `write:
false` tool setting did not stop a write made through a subagent; and a custom config merges with
your global config instead of replacing it, so your MCP servers and agents stay available. A
permission setting inside the process being confined is a request, not a boundary.

The sandbox makes the boundary the operating system's, outside opencode. `srt` runs opencode under
bubblewrap with the repository mounted read-only, the credential directories hidden, the network
limited to the provider endpoints, and `auth.json` replaced with placeholders that a proxy on the
host swaps for the real keys only on the way to those endpoints. A subagent's write fails the same
way the coordinator's does, because the kernel does not know the difference. And because the
sandbox is set up from the outside, the harness can check it from the outside: before every run a
probe inside the sandbox tries to write to the repository, read a credential directory and read the
key file, and the run only starts if all of those fail.

## Install

Linux only. Credential masking does not work on macOS. There are four steps; `/opencode:setup`
checks all of them and prints the command for anything that is missing.

**1. Install opencode and log in to a provider.**

```bash
npm i -g --allow-scripts=opencode-ai opencode-ai   # --allow-scripts is needed: the postinstall downloads the binary
opencode auth login
```

**2. Install [opencode-code-review](https://github.com/elderengineer/opencode-code-review#install).**

Follow the instructions on that page. This plugin loads it by path, so it does not need the
registration in `opencode.json`; it looks for the files in
`~/.config/opencode/node_modules/@elderengineer/opencode-code-review/`, then in
`~/.config/opencode/opencode-code-review/`.

**3. Install the sandbox.**

```bash
npm i -g @anthropic-ai/sandbox-runtime     # provides srt
sudo apt install bubblewrap socat          # srt's Linux dependencies
grep -q '^127.0.0.1.*localhost' /etc/hosts || echo '127.0.0.1 localhost' | sudo tee -a /etc/hosts
```

The `/etc/hosts` line is required. srt connects the sandbox to its proxy through `localhost`, and
the proxy listens on `127.0.0.1`. If `localhost` resolves only to `::1`, no request from inside
the sandbox can get out. `python3`, `node` and `flock` are also needed; they are normally already
installed.

**4. Install this plugin in Claude Code**, from the repository you want to review:

```
/plugin marketplace add elderengineer/opencode-code-review-cc
/plugin install opencode@opencode-code-review-cc
/opencode:setup
```

`setup` writes the sandbox policy for that repository, runs the probe inside the real sandbox,
adds `.opencode-review/` to the repository's `.gitignore`, and does not contact any provider. When
it prints `setup OK`, run a review:

```
/opencode:code-review max
```

This runs opencode-code-review at `max` effort inside the sandbox (10 finder lenses with up to 8
candidates each, a verification pass, a gap sweep, and `--variant max`) and reports the findings
as a ranked JSON list, or `[]` if nothing was found. The findings come from a third-party model and
should be checked before acting on them. Add `--fix`, or run `/opencode:fix` afterwards, to have
Claude apply the confirmed ones. A review run after a fix only covers the changes since the
previous review.

## Layout

```
.claude-plugin/marketplace.json
plugins/opencode/
  .claude-plugin/plugin.json
  commands/            code-review, setup, usage, status, cancel, fix
  scripts/
    run-review.sh      the main script: policy, probe, preflight, watchdog, checks, ledger
    coordinator.json   the private opencode config used for each run (one plugin, two agents)
    sandbox-policy.template.json
    stream.py          reads the event stream: tokens, spawned subagents, compiled level, final text
    findings.py        validates the output and converts it to schemas/findings.schema.json
    db-usage.py        reads the subagents' token usage from opencode's session database
    salvage-session.mjs
  skills/opencode-runtime/   SKILL.md (how the commands use the script) and reference/{confinement,recovery}.md
  tests/test-run-review.sh   runs the script against a fake opencode, a fake srt and a fake database
```

Each reviewed repository keeps its state in `<repo>/.opencode-review/` (added to `.gitignore` by
`/opencode:setup`): the ledger, the run marker, and one directory per run with the rendered
policy, the private config, the event log if the run failed, and `findings.json` if it succeeded.

## Tests and measurements

`plugins/opencode/tests/test-run-review.sh` runs the script against fakes and checks its decisions.
It does not contact any provider. `/opencode:setup` checks the real sandbox on the current machine.

`skills/opencode-runtime/reference/confinement.md` records the six measurements the design was
based on, with the opencode and plugin versions they were taken on. Several came out differently
from what the design assumed: `OPENCODE_CONFIG_DIR` adds to the global config instead of replacing
it, `XDG_CONFIG_HOME` is what isolates it, subagent events do not appear in the parent event
stream, and `opencode run` puts quotes around any argument that contains a space.

## License

MIT, see [LICENSE](LICENSE).
