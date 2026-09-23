#!/usr/bin/env python3
"""Read one `opencode run --format json` event log and print what run-review.sh needs to decide.

    stream.py <events.jsonl> --level <level> [--final <path>] [--errors <path>]

Prints KEY=value lines, one per fact, values restricted to [A-Za-z0-9_.,:/ -] so the shell can
read them without eval. Never exits non-zero for a stream it cannot fully parse: an unparseable
or truncated line costs at most that line (JSONL is line-delimited), and the counters that
survive are the ones a metered plan bills against.

Facts:
  STEPS IN_TOK OUT_TOK COST REASON   the PARENT session: steps counted; input SUMMED with cache
                                     reads (every step re-sends the whole context); output as the
                                     per-step MAX (opencode reports it cumulatively); last stop
                                     reason.
  ERRORS TEXT                        error events seen; whether any assistant text arrived.
  PROMPT_CALLED PROMPT_OK CELL_LEVEL the code_review_prompt tool call: made, completed, and the
                                     effort tag of the cell it compiled (`<level> effort → …`).
  SPAWNS SPAWN_NAMES BAD_SPAWNS      every `task` call, its subagent_type, and those outside the
  SPAWN_ERRORS                       allow-set {reviewer-<level>, reviewer-<level>-alt<N>, reviewer-lens-*}.
  SUB_SESSIONS SUB_STEPS SUB_IN_TOK  step_finish events whose sessionID is not the parent's —
  SUB_OUT_TOK SUB_COST               present only if opencode forwards subagent steps to the
                                     parent stream (measurement M2). Zero with SPAWNS>0 means
                                     the subagent spend is UNMEASURED in this stream.
  SESSION                            the parent sessionID, for the salvager.
"""
import json
import re
import sys

SAFE = re.compile(r"[^A-Za-z0-9_.,:/ -]")


def emit(k, v):
    print(f"{k}={SAFE.sub('', str(v))}")


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        sys.exit(2)
    src = argv[1]
    level = argv[argv.index("--level") + 1] if "--level" in argv else ""
    final = argv[argv.index("--final") + 1] if "--final" in argv else None
    errors_path = argv[argv.index("--errors") + 1] if "--errors" in argv else None
    allow = re.compile(rf"^(reviewer-{re.escape(level)}(-alt[0-9]+)?|reviewer-lens-[A-Za-z0-9_.-]+)$") if level else None

    parent = None
    order, parts = [], {}
    errors = []
    reason = ""
    steps = in_tok = out_tok = 0
    cost = 0.0
    sub = {}  # sessionID -> [steps, in, out_max, cost]
    prompt_called = prompt_ok = 0
    cell_level = ""
    spawns, bad, spawn_errors = [], [], 0

    with open(src, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            kind = ev.get("type")
            part = ev.get("part") or {}
            sid = part.get("sessionID") or ev.get("sessionID")
            if parent is None and sid and kind in ("step_start", "step-start", "step_finish", "step-finish", "text", "tool_use"):
                parent = sid
            if kind == "error":
                err = ev.get("error") or {}
                data = err.get("data") or {}
                errors.append(str(data.get("message") or err.get("name") or err))
            elif kind == "text":
                if sid and parent and sid != parent:
                    continue
                pid = part.get("id")
                if pid is None:
                    continue
                if pid not in parts:
                    order.append(pid)
                parts[pid] = (part.get("messageID"), part.get("text") or "")
            elif kind == "tool_use":
                st = part.get("state") or {}
                inp = st.get("input") or {}
                tool = part.get("tool")
                if tool == "code_review_prompt":
                    prompt_called = 1
                    if st.get("status") == "completed":
                        prompt_ok = 1
                        # The low cell tags itself in backticks, the fleet cells bare (cells.ts);
                        # both sit at a line start: `<level> effort → …`.
                        m = re.search(r"(?m)^`?(low|medium|high|max) effort ", st.get("output") or "")
                        if m:
                            cell_level = m.group(1)
                elif tool == "task":
                    name = str(inp.get("subagent_type") or "?")
                    spawns.append(name)
                    if st.get("status") == "error":
                        spawn_errors += 1
                    if allow and not allow.match(name):
                        bad.append(name)
            elif kind in ("step_finish", "step-finish"):
                tokens = part.get("tokens") or {}
                try:
                    i = int(tokens.get("input") or 0) + int(((tokens.get("cache") or {}).get("read")) or 0)
                    o = int(tokens.get("output") or 0)
                    c = float(part.get("cost") or 0)
                except (TypeError, ValueError):
                    i, o, c = 0, 0, 0.0
                if sid and parent and sid != parent:
                    s = sub.setdefault(sid, [0, 0, 0, 0.0])
                    s[0] += 1
                    s[1] += i
                    s[2] = max(s[2], o)
                    s[3] += c
                    continue
                steps += 1
                reason = part.get("reason") or reason
                in_tok += i
                out_tok = max(out_tok, o)
                cost += c

    text = ""
    if order:
        last_msg = parts[order[-1]][0]
        text = "\n".join(parts[pid][1] for pid in order if parts[pid][0] == last_msg)
    if final is not None:
        with open(final, "w", encoding="utf-8") as fh:
            fh.write(text.rstrip() + "\n")
    if errors_path is not None:
        with open(errors_path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(errors[:5]) + ("\n" if errors else ""))

    emit("SESSION", parent or "")
    emit("STEPS", steps)
    emit("IN_TOK", in_tok)
    emit("OUT_TOK", out_tok)
    emit("COST", f"{cost:.4f}")
    emit("REASON", reason)
    emit("ERRORS", len(errors))
    emit("TEXT", 1 if text.strip() else 0)
    emit("PROMPT_CALLED", prompt_called)
    emit("PROMPT_OK", prompt_ok)
    emit("CELL_LEVEL", cell_level)
    emit("SPAWNS", len(spawns))
    emit("SPAWN_NAMES", ",".join(sorted(set(spawns))))
    emit("BAD_SPAWNS", ",".join(sorted(set(bad))))
    emit("SPAWN_ERRORS", spawn_errors)
    emit("SUB_SESSIONS", len(sub))
    emit("SUB_STEPS", sum(s[0] for s in sub.values()))
    emit("SUB_IN_TOK", sum(s[1] for s in sub.values()))
    emit("SUB_OUT_TOK", sum(s[2] for s in sub.values()))
    emit("SUB_COST", f"{sum(s[3] for s in sub.values()):.4f}")


if __name__ == "__main__":
    main(sys.argv)
