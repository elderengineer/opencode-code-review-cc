# Confinement — what actually holds the reviewer

Read this before changing `scripts/sandbox-policy.template.json`, `scripts/coordinator.json`, or
anything in `run-review.sh` that renders the policy or runs the sandbox gate. The happy path does
not need it: every requirement here aborts at runtime naming its own fix.

**The boundary is the OS, not the tool allowlist.** Every invocation — preflight and review — runs
as `srt -s <rendered policy> -- env … opencode …`, where `srt` is
[`@anthropic-ai/sandbox-runtime`](https://www.npmjs.com/package/@anthropic-ai/sandbox-runtime)
over bubblewrap. The repo is read-only, credential paths unreadable, opencode's own API keys
masked, egress limited to the provider endpoints in the policy (a ★ favorite on any other provider fails there, and opencode-code-review's fallback moves to its next alternate). `srt` fails closed — a bad config or
missing dependency is exit 1, never a silent unsandboxed run. Because the kernel confines the whole
process tree, the coordinator HAS a shell (their Phase 0 is `git diff`) and HAS `task` (their
Phase 1–3 spawn subagents): a subagent's write fails with `EROFS` exactly like the coordinator's.

The tools blocks in `coordinator.json` are the second layer: a tool the model cannot call is a step
it does not waste, and opencode's own controls were measured to fail open three ways on the old
harness (an unknown `--agent` warns and runs the default agent at exit 0; `tools:{write:false}` +
`permission:{bash:deny}` did not stop a write through `task`; `OPENCODE_CONFIG` merges rather than
replaces). Their `reviewer-*` subagents are `tools: {"*": false, read, grep, glob, list}` with
`edit/bash/webfetch: deny`; merge is user-wins, so nothing here can loosen them.

## Requirements

Each aborts at runtime naming its own fix; `/opencode:setup` runs them all without a review.

| Requirement | Install | Why |
| --- | --- | --- |
| `opencode` | `npm i -g --allow-scripts=opencode-ai opencode-ai` | the reviewer CLI (`--allow-scripts`: its postinstall fetches the platform binary) |
| opencode-code-review | `"plugin": ["@elderengineer/opencode-code-review"]` in `~/.config/opencode/opencode.json` — opencode installs it into `~/.cache/opencode/packages/`, and `find_plugin` loads that same copy | the review; `OPENCODE_REVIEW_PLUGIN=/path/to/plugin.ts` for a local checkout |
| `srt` | `npm i -g @anthropic-ai/sandbox-runtime` | the sandbox; or `OPENCODE_REVIEW_SRT=<binary or dist/cli.js>` |
| `bwrap`, `socat` | `sudo apt install bubblewrap socat` | srt's Linux confinement and its host-proxy bridge |
| `python3`, `node`, `flock` | distro packages | the parsers, the salvager, the single-run guard |
| `/etc/hosts`: `127.0.0.1 localhost` | one line | srt's socat bridge dials `localhost` while its proxy binds 127.0.0.1; `::1`-only kills every request as an empty reply |

## The measurements (M1–M6) — 2026-09-02, opencode 1.18.27, opencode-code-review 0.1.1 (installed copy 0.1.0), srt 1.0.0 / ASRT 0.0.75, bwrap 0.6.1, socat 1.7.4.1, Bun 1.3.14

Re-measure on a version bump. Each changed the design where noted.

**M1 — config isolation: `OPENCODE_CONFIG_DIR` does NOT isolate; `XDG_CONFIG_HOME` does.**
opencode's `ConfigPaths.directories` is `[Path.config, …project .opencode dirs…, ~/.opencode,
OPENCODE_CONFIG_DIR]` — the env var is *additive*, and `Path.config/opencode.json` is always
loaded. `Path.config` is `$XDG_CONFIG_HOME/opencode`, so a per-run `XDG_CONFIG_HOME` holding a
rendered `coordinator.json` is the only global config the run sees: `opencode debug config` under
it showed `plugin: [<ours>]`, agents `[coordinator, preflight, reviewer-low/medium/high/max]`,
commands `[code-review, code-review:create-lens]`, `mcp: {}` — none of the user's twelve
`~/.config/opencode/agents/*.md`, MCP servers or other plugins. `auth.json` stays found (data dir,
`XDG_DATA_HOME`, untouched). `OPENCODE_DISABLE_PROJECT_CONFIG=1` additionally drops the reviewed
repo's `.opencode/opencode.json`: a planted `reviewer-high: {tools: {bash: true}}` there vanished
from the resolved config. Project lenses (`.opencode/code-review/lenses/*.md`) still load — the
plugin reads that directory itself, not through config (`reviewer-lens-money` was injected with
a lens present). `~/.opencode/opencode.json` is still probed (none exists on this box); the
harness also unsets `OPENCODE_CONFIG*` from the caller's environment. `XDG_STATE_HOME` redirects
opencode's own state dir the same way, so the user's TUI defaults are never touched. It does NOT
redirect opencode-code-review's: the plugin resolves `homedir()/.local/state/opencode/` directly
(re-measured 2026-09-23, v0.5.0), so its sticky `code-review-model` pin and its favorites
`code-review-ladder.json` bind the reviewers inside the sandbox too — the harness relies on that,
read-only. The ladder cache is refreshed only by `/code-review` in the opencode TUI: upstream fetches
its session's `serverUrl`, which srt's egress policy refuses from inside the sandbox.
*Consequence:* the private config dir must be **writable** (opencode writes a `.gitignore` and
attempts a background `@opencode-ai/plugin` install there — under the sandbox that install fails
with a harmless `level=WARN background dependency install failed`, the plugin having resolved its
deps from its own `node_modules`), and `opencode run` dies `EROFS` if the state dir is not
writable (`debug config` only warns). Config, state and tmp all live in the per-run `SBX_TMP`,
which is in `allowWrite` and dies with the run.

**M2 — subagent `step_finish` events do NOT reach the parent stream.** A medium run's stream
held one sessionID across 8 `step_finish` events (68,148 input tokens) while opencode's session
store held 12 child sessions (`session.parent_id`), 50 assistant messages, 184,229 input tokens —
the ledger summed from the stream alone would under-report by 3.7×. `scripts/db-usage.py` sums the
children's `tokens_input + tokens_cache_read` (the parent row's same sum equals the stream's
per-step sum exactly: 12,933 = 12,933 on the low run), and the ledger's `sub_*` columns carry it;
`?` there means the store could not be read — printed as `UNMEASURED`, never as zero.

**M3 — headless slash command: `opencode run --command code-review --agent <coordinator> -- <level> <target>`.**
The `--command` flag is opencode's headless command path (`session.command({command, arguments})`);
the message tokens become `$ARGUMENTS`. The coordinator stayed the executor (`agent=opencode-review-coordinator`
on every parent step), its first tool call was `code_review_prompt`, and the compiled cell's level
tag (`<level> effort → …`, backticked at low, bare at medium+) is in that tool's output.
*Trap, measured:* `opencode run` wraps any argv token containing a space in double quotes, so a
single `"medium master...HEAD"` argument reached the parser as `"medium` — not a level — and the
plugin compiled the **low** cell from its sticky level. Level and target are separate argv tokens,
path targets with whitespace are refused, and the watchdog kills a run whose compiled cell is not
the requested level.

**M4 — their plugin loads under srt.** Registered by absolute path (opencode records it as
`file:///…/plugin.ts`), `Bun.Glob`, `import.meta.dir` and the `node_modules` beside the plugin all
resolve with `allowRead: []` (everything readable); a fresh private config dir loads it in ~1 s.
Nothing was added to the policy.

**M5 — an unknown `subagent_type` is a tool ERROR, not a fallback.** The task tool fails the call
with `Unknown agent type: <x> is not a valid agent type`; the model then follows their
`SPAWN_FALLBACK_NOTE` (retry once, then run the lens inline). The harness reads every `task`
spawn's `subagent_type` from the stream — live, in the watchdog, and after the run — and aborts on
any name outside `{reviewer-<level>, reviewer-<level>-alt<N>, reviewer-lens-*}`; a medium+ run that
spawned nothing aborts as "a single pass wearing a fan-out's label". A medium run on the M3 diff
spawned 12 × `reviewer-medium`, all inheriting the coordinator's `--model`.

**M6 — `--variant max` on the coordinator composes with the plugin's `variant: max` pin on
`reviewer-max`.** A max run through the harness (`--variant max` on the `opencode run` line)
recorded `variant: "max"` on the coordinator's session row AND on every one of its six
`reviewer-max` child sessions — no conflict, no error. The harness passes both, as designed. (The
coordinator spawned 6 tasks for 10 lenses + sweep, batching lenses per subagent; that is their
prompt's business, and the harness's spawn gate asks only that the names be in the allow-set.)

Also measured on the way: `opencode run` **auto-rejects** any permission that would "ask"
(`permission requested: <p> (…); auto-rejecting` on stderr), so a headless run cannot wedge on a
prompt — the harness reports such a line as a NOTE. Seen for real: a medium coordinator asked to read
the reviewed repo's PARENT directory (`external_directory (/…/m3/*)`) and was rejected. The default permission ruleset allows
everything except `doom_loop: ask`, `external_directory: ask`, `question/plan_*: deny` and reading
`*.env` (`ask` → rejected). opencode 1.18.27 wrote **nothing** into the reviewed repo's `.opencode/`
(the old harness's claim that it dies without `.opencode/.gitignore` no longer holds), so the repo
is entirely read-only — `.opencode` is no longer in `allowWrite`, which closes the "a review writes
a lens for the next run" residual at the kernel; a filesystem listing of `.opencode/` before and
after remains in the tree assertion as a backstop.

## The policy

`sandbox-policy.template.json` is committed; `run-review.sh` renders it per run into
`<repo>/.opencode-review/runs/<stamp>-<level>/sandbox.json`. The renderer refuses a policy whose
`allowWrite` covers, is under, or is an ancestor of the repo, and one that leaves credential
masking on its silently-no-op default.

| key | what it says |
| --- | --- |
| `filesystem.allowWrite` | opencode's data and cache dirs, and the per-run `SBX_TMP` (private config, private state, tmp) — nothing else |
| `filesystem.denyWrite` | the repo — a no-op on Linux (below), kept as documentation |
| `filesystem.denyRead` | `~/.ssh`, `~/.aws`, `~/.config/gh`, `~/.netrc`, `~/.gnupg`, `~/.grok`, `~/.npmrc`, `~/.docker/config.json`, `~/.kube` |
| `credentials.files` | opencode's `auth.json`, masked to per-session sentinels; the host proxy substitutes the real bytes on egress |
| `network` | `opencode.ai`, `models.opencode.ai`, `api.deepseek.com`, `api.z.ai`; `allowLocalBinding: false`; `tlsTerminate` on, which masking requires |

**How the write rules compose on Linux.** ASRT binds every `allowWrite` path read-write up front
and emits a `denyWrite` entry as a later read-only bind **only when that path lies inside an
allow-listed one**; everything else is read-only from the initial `--ro-bind / /`. So the repo's
`denyWrite` entry does nothing here — the repo is read-only because nothing allow-lists it — and a
`denyWrite` placed *inside* an allowed path behaves the opposite way. Credential masking is
Linux-only: ASRT degrades `mask` to `deny` on macOS.

## The sandbox gate — measured, not assumed

Once per run, before anything is spent, a probe runs through `srt` under the **same rendered
policy** and the same private XDG environment:

```
WRITE=blocked    a touch into the repo root                  (allowed → ABORT)
CRED=blocked     a denyRead path that really holds a readable file on this box
READ=ok          the plugin's entry file is readable
GIT=ok           git diff --stat <range> runs
NET=ok <host>    curl reaches ANY ONE allowed domain; all of them failing is the bridge
MASK=ok          auth.json reads back as sentinels inside          (unmasked → ABORT)
PLUGIN=ok        opencode's resolved config inside carries /code-review, the coordinator,
                 the preflight agent and reviewer-<level>       (missing → ABORT)
```

Any failure aborts non-zero before a provider is contacted. The same script **outside** the
sandbox reports `WRITE=allowed CRED=readable`, which is what makes the inside result evidence.

**Measured on every run:** the seven verdicts; the agent-fallback wording on stderr; every `task`
spawn's name; the compiled cell's level; `git status --porcelain --untracked-files=all` + `HEAD` +
a file listing of `.opencode/` unchanged after the run. **Inferred:** the stderr wording of the
agent-fallback warning, which no doc pins (`agent "x" not found. Falling back to default agent`,
and `is a subagent, not a primary agent. Falling back to default agent`, both read from the 1.18.27
bundle).

**Residual risk:** `read` runs as you, and the reviewer is a hosted third-party model — whatever it
reads, its provider sees. Already true of the code under review; keep it in mind before pointing
this at a tree holding something the code does not.
