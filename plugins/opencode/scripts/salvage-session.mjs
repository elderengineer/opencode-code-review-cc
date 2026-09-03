#!/usr/bin/env node
// Recover a finished review from an opencode session after the harness lost the process.
//
// WHY THIS EXISTS. `run-review.sh` captures the review from opencode's stdout event stream. If the
// process is killed after the model has finished but before the stream is drained — an external
// SIGKILL, a lost terminal, a reaped background task — the work is billed and the review is gone,
// even though opencode has it in local session storage. This turns that into a recovery instead of
// a re-spend.
//
// Usage:  salvage-session.mjs <sessionID> [--out <path>]
// Exit 0  the session's LAST assistant message had text; it is printed to stdout or written to --out.
//         Whether that text is a complete findings list is NOT decided here: run-review.sh hands it
//         to findings.py, whose schema gate is the only judge of completeness.
// Exit 3  the session holds no assistant text at all — it really was killed before the model spoke.
// Exit 1  the export failed.
//
// Only the LAST assistant message is taken, and only ASSISTANT parts are considered: the compiled
// review prompt is a tool result in the same session and is many times longer than the findings,
// so "the longest text part" would hand back the question dressed as the answer.

import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [, , sessionId, ...rest] = process.argv;
if (!sessionId || !/^ses_[A-Za-z0-9]+$/.test(sessionId)) {
  console.error('usage: salvage-session.mjs <sessionID> [--out <path>]');
  process.exit(1);
}
const outIdx = rest.indexOf('--out');
const outPath = outIdx >= 0 ? rest[outIdx + 1] : null;

// Export to a FILE, not a pipe. `execFileSync` with a piped stdout silently truncated a 652 KB
// export to 142 KB — no ENOBUFS, no error, just a short buffer that then failed to parse and read
// as "opencode changed its format". A file has no such ceiling.
const tmp = mkdtempSync(join(tmpdir(), 'oc-salvage-'));
const exportPath = join(tmp, 'session.json');
let raw;
try {
  execFileSync(
    'sh',
    ['-c', '"$0" export "$1" > "$2"', process.env.OPENCODE_BIN || 'opencode', sessionId, exportPath],
    { stdio: ['ignore', 'ignore', 'pipe'] },
  );
  raw = readFileSync(exportPath, 'utf8');
} catch (e) {
  console.error(`salvage: 'opencode export ${sessionId}' failed: ${e.message}`);
  process.exit(1);
} finally {
  rmSync(tmp, { recursive: true, force: true });
}

let doc;
try {
  doc = JSON.parse(raw);
} catch {
  console.error('salvage: export was not JSON — opencode may have changed its export format.');
  process.exit(1);
}

const messages = Array.isArray(doc?.messages) ? doc.messages : [];

/** Text of each assistant message, in order. The role lives on `info` in the export shape; the
 *  message itself is accepted as a fallback so a format change degrades to "found nothing". */
const assistantTexts = [];
for (const m of messages) {
  const role = (m?.info ?? m)?.role;
  if (role !== 'assistant') continue;
  const text = (m?.parts ?? [])
    .filter((p) => p?.type === 'text' && typeof p.text === 'string')
    .map((p) => p.text)
    .join('\n')
    .trim();
  if (text) assistantTexts.push(text);
}

if (assistantTexts.length === 0) {
  console.error(
    `salvage: session ${sessionId} holds NO assistant text — ${messages.length} messages. ` +
      `The run was killed before the model answered; there is nothing to recover and the review must be re-run.`,
  );
  process.exit(3);
}

const body = assistantTexts[assistantTexts.length - 1];
if (outPath) {
  writeFileSync(outPath, body + '\n');
  console.error(`salvage: recovered ${body.length} chars (last assistant message) from ${sessionId} -> ${outPath}`);
} else {
  process.stdout.write(body + '\n');
}
