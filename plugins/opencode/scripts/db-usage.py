#!/usr/bin/env python3
"""Subagent spend for one review, read from opencode's own session store.

    db-usage.py <parent-sessionID> [--db <path>]

Measurement M2 (2026-09-02, opencode 1.18.27): the `opencode run --format json` stream carries
the PARENT session's events only — a `task` spawn shows up as one tool_use part, and the
subagent's own steps never reach stdout. So a ledger summed from the stream under-reports a
medium+ review by the whole fan-out, which is the one lie the ledger exists to prevent. opencode
persists every subagent as a child session (`session.parent_id`) with cumulative token columns,
and the parent row's tokens_input + tokens_cache_read equals the stream's per-step sum exactly
(12933 = 12933 on the M3 run), so the same arithmetic applied to the children is the fan-out's
spend. Printed as KEY=value lines; any failure prints SUB_MEASURED=0 and exits 0, so the caller
prints UNMEASURED rather than a number it did not read.
"""
import json
import os
import sqlite3
import sys


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: db-usage.py <parent-sessionID> [--db <path>]\n")
        sys.exit(2)
    parent = argv[1]
    db = argv[argv.index("--db") + 1] if "--db" in argv else os.environ.get("OPENCODE_DB") or os.path.join(
        os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"), "opencode", "opencode.db"
    )
    try:
        c = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=5)
        rows = c.execute(
            "select id, agent, model, cost, tokens_input, tokens_output, tokens_cache_read from session where parent_id=?",
            (parent,),
        ).fetchall()
        steps = 0
        for (sid, *_rest) in rows:
            for (data,) in c.execute("select data from message where session_id=?", (sid,)):
                try:
                    if json.loads(data).get("role") == "assistant":
                        steps += 1
                except ValueError:
                    pass
    except Exception as e:  # noqa: BLE001 — any DB trouble means "unmeasured", never a number
        sys.stderr.write(f"db-usage: {e}\n")
        print("SUB_MEASURED=0")
        return
    models, agents = set(), set()
    in_tok = out_tok = 0
    cost = 0.0
    for sid, agent, model, c_, ti, to, tcr in rows:
        agents.add(str(agent or "?"))
        try:
            models.add(json.loads(model or "{}").get("id") or "?")
        except ValueError:
            models.add("?")
        in_tok += int(ti or 0) + int(tcr or 0)
        out_tok += int(to or 0)
        cost += float(c_ or 0)
    print("SUB_MEASURED=1")
    print(f"SUB_SESSIONS={len(rows)}")
    print(f"SUB_STEPS={steps}")
    print(f"SUB_IN_TOK={in_tok}")
    print(f"SUB_OUT_TOK={out_tok}")
    print(f"SUB_COST={cost:.4f}")
    print("SUB_AGENTS=" + ",".join(sorted(agents)))
    print("SUB_MODELS=" + ",".join(sorted(models)))


if __name__ == "__main__":
    main(sys.argv)
