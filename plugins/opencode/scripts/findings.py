#!/usr/bin/env python3
"""The output gate: extract, validate and normalise a review's findings.

    findings.py <level> <text-file> <out-json> [--cap N]

Exit 0  the text holds a findings list that satisfies schemas/findings.schema.json; the
        normalised JSON array is written to <out-json>.
Exit 5  it does not — the reason is on stderr. run-review.sh treats that like a missing
        sentinel used to be: a failed attempt that advances the ladder, never a promotion.

Two contracts, one output shape. At medium and above opencode-code-review asks the model for
a JSON array of {file, line, summary, failure_scenario}, ranked, capped per level, `[]` when
clean. At low it asks for one line per finding — `path/to/file.ext:123 — what's wrong` — or
exactly `(none)`. Both land here as the same array so the Claude-side fix phase and the
`usage`/`status` views read one format. `[]` is a valid, promotable review that found nothing;
an abort is never that, and this script never turns a parse failure into `[]`.
"""
import json
import re
import sys

LEVELS = ("low", "medium", "high", "max")
REQUIRED = ("file", "line", "summary", "failure_scenario")
VERDICTS = ("CONFIRMED", "PLAUSIBLE", "REFUTED")

# `path:123 — text`, tolerant of the backticks, bullets and dash variants models decorate with.
LOW_LINE = re.compile(
    r"^\s*(?:[-*\d.)]+\s*)?`?(?P<file>[^\s`:]+):(?P<line>\d+)`?\s*(?:[—–-]+|:)\s*(?P<text>.+?)\s*`*\s*$"
)
FENCE = re.compile(r"```(?:json)?\s*\n(.*?)\n\s*```", re.S)


def fail(reason):
    sys.stderr.write(f"findings: {reason}\n")
    sys.exit(5)


def note(msg):
    sys.stderr.write(f"findings: NOTE — {msg}\n")


def extract_array(text):
    """The findings array from a model message: bare JSON, a ```json fence, or the last
    bracketed span that parses. Returns None when nothing parses as a list."""
    stripped = text.strip()
    for candidate in (stripped,):
        try:
            v = json.loads(candidate)
            if isinstance(v, list):
                return v
        except ValueError:
            pass
    fences = FENCE.findall(text)
    for block in reversed(fences):
        try:
            v = json.loads(block)
            if isinstance(v, list):
                return v
        except ValueError:
            continue
    # Prose around the array: try every '[' as a start against the last ']' after it. The
    # outermost parse wins, so a nested array inside a finding cannot be mistaken for the list.
    ends = [i for i, c in enumerate(text) if c == "]"]
    if not ends:
        return None
    last_end = ends[-1]
    for i, c in enumerate(text):
        if c != "[" or i > last_end:
            continue
        try:
            v = json.loads(text[i : last_end + 1])
            if isinstance(v, list):
                return v
        except ValueError:
            continue
    return None


def normalise_item(item, idx):
    if not isinstance(item, dict):
        fail(f"finding {idx} is not an object")
    out = dict(item)
    for k in ("file", "summary"):
        v = out.get(k)
        if not isinstance(v, str) or not v.strip():
            fail(f"finding {idx} has no usable '{k}'")
        out[k] = v.strip()
    line = out.get("line", 0)
    if isinstance(line, str) and line.strip().isdigit():
        line = int(line.strip())
    if line is None:
        line = 0
    if not isinstance(line, int) or isinstance(line, bool) or line < 0:
        fail(f"finding {idx} ({out['file']}) has a non-integer 'line': {line!r}")
    out["line"] = line
    fs = out.get("failure_scenario")
    if not isinstance(fs, str) or not fs.strip():
        note(f"finding {idx} ({out['file']}:{line}) has no failure_scenario — copied from summary")
        out["failure_scenario"] = out["summary"]
    else:
        out["failure_scenario"] = fs.strip()
    v = out.get("verdict")
    if v is not None:
        vv = str(v).strip().upper()
        if vv in ("CONFIRMED", "PLAUSIBLE"):
            out["verdict"] = vv
        elif vv == "REFUTED":
            return None
        else:
            del out["verdict"]
    return out


def parse_low(text):
    body = text.replace("```", "")
    findings = []
    saw_none = False
    for raw in body.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.strip("`* ") == "(none)":
            saw_none = True
            continue
        m = LOW_LINE.match(line)
        if m:
            text = m.group("text")
            if text.count("`") % 2:  # the line was wrapped in backticks and the strip ate one
                text += "`"
            findings.append(
                {
                    "file": m.group("file"),
                    "line": int(m.group("line")),
                    "summary": text,
                    "failure_scenario": text,
                }
            )
    if findings:
        return findings
    if saw_none:
        return []
    fail("low-level output has neither a `path:line — finding` line nor `(none)`")


def main(argv):
    if len(argv) < 4 or argv[1] not in LEVELS:
        sys.stderr.write("usage: findings.py <low|medium|high|max> <text-file> <out-json> [--cap N]\n")
        sys.exit(2)
    level, src, dst = argv[1:4]
    cap = None
    if "--cap" in argv:
        cap = int(argv[argv.index("--cap") + 1])
    with open(src, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    if not text.strip():
        fail("the response is empty")

    if level == "low":
        findings = parse_low(text)
    else:
        arr = extract_array(text)
        if arr is None:
            fail("no JSON array of findings in the response (medium+ contract is a JSON array, `[]` when clean)")
        findings = []
        for i, item in enumerate(arr):
            n = normalise_item(item, i)
            if n is None:
                note(f"finding {i} carried verdict REFUTED — dropped")
                continue
            findings.append(n)

    if cap is not None and len(findings) > cap:
        note(f"{len(findings)} findings exceed the {level} cap of {cap} — keeping the first {cap} (they are ranked)")
        findings = findings[:cap]

    with open(dst, "w", encoding="utf-8") as fh:
        json.dump(findings, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    print(len(findings))


if __name__ == "__main__":
    main(sys.argv)
