#!/usr/bin/env python3
r"""Stop a frozen process from counting as time spent on a tool call.

WHY THIS IS NEEDED
------------------
iOS suspends the whole app, and Node with it. The clock Node's timers read keeps
moving meanwhile, so on thaw every armed timer fires at once. A bash command that
had used 5 of its 60 seconds comes back as "[timed out after 60000ms]", the guest
command is killed, and the model starts debugging a failure that never happened
(REPORT-12, the 10 x 30 s runs).

WHY A PATCH AND NOT A PLUGIN
----------------------------
`deadline` and `idleWatchdog` are plain exports of `@deepseek-ai/dsh-timeout` and
their callers import them directly (`dsh-bash-local`,
`dsh-tool-call-timeout-policy`, the persistent shells). There is no service seam
to replace, and wrapping the global `setTimeout` would change every timer in the
process, including the ones that should notice the clock jump.

WHAT IT CHANGES, EXACTLY
------------------------
Only how those two helpers wait. When the timer fires it subtracts the time the
event loop was not running and, if budget is left, waits for the rest. The reason,
the codes and the abort behaviour are untouched. A one-second unref'd heartbeat
measures the gaps, and it runs only while one of these timers is armed. A gap
under 3 s is ordinary load and still counts as spent time; a longer synchronous
block is treated like a freeze, which can only make a timeout later, never earlier.

BACKUP AND IDEMPOTENCE: the original file is copied to
work/frozen-timeout-patch-backup/ before the first rewrite, and re-running with the
patch already applied reports `already_patched`.
"""

from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TARGET = ROOT / "payload/node_modules/@deepseek-ai/dsh-timeout/lib/index.js"
BACKUP = ROOT / "work/frozen-timeout-patch-backup/index.js"
MARKER = "dsh-ios: frozen time is not spent time"

HELPER = """const MAX_TIMER_DELAY_MS = 2147483647;
// dsh-ios: frozen time is not spent time. See scripts/patch-payload-frozen-timeout.py.
const FROZEN_BEAT_MS = 1e3;
const FROZEN_GAP_MS = 3e3;
let frozenTotalMs = 0;
let frozenLastBeat = 0;
let frozenBeat;
let frozenWatchers = 0;
function frozenSoFar() {
	const gap = performance.now() - frozenLastBeat;
	return gap > FROZEN_GAP_MS ? frozenTotalMs + gap : frozenTotalMs;
}
function runningTimeout(fire, timeoutMs) {
	if (frozenWatchers++ === 0) {
		frozenLastBeat = performance.now();
		frozenBeat = setInterval(() => {
			frozenTotalMs = frozenSoFar();
			frozenLastBeat = performance.now();
		}, FROZEN_BEAT_MS);
		frozenBeat.unref?.();
	}
	const startedAt = performance.now();
	const frozenAtStart = frozenSoFar();
	let id;
	let armed = true;
	const stop = () => {
		if (!armed) return;
		armed = false;
		clearTimeout(id);
		if (--frozenWatchers === 0) clearInterval(frozenBeat);
	};
	const check = () => {
		const spent = performance.now() - startedAt - (frozenSoFar() - frozenAtStart);
		const left = timeoutMs - spent;
		if (left >= 1) {
			id = setTimeout(check, left);
			return;
		}
		stop();
		fire();
	};
	id = setTimeout(check, timeoutMs);
	return stop;
}
"""

REPLACEMENTS = [
    ("const MAX_TIMER_DELAY_MS = 2147483647;\n", HELPER),
    (
        """	const id = setTimeout(() => {
		timer.abort(new TimeoutReason(code, timeoutMs));
	}, timeoutMs);
""",
        """	const stopTimer = runningTimeout(() => {
		timer.abort(new TimeoutReason(code, timeoutMs));
	}, timeoutMs);
""",
    ),
    (
        """		[Symbol.dispose]() {
			clearTimeout(id);
		}
""",
        """		[Symbol.dispose]() {
			stopTimer();
		}
""",
    ),
    (
        """		if (timer !== void 0) clearTimeout(timer);
		timer = setTimeout(() => {
			timeout.abort(reason);
		}, timeoutMs);
""",
        """		timer?.();
		timer = runningTimeout(() => {
			timeout.abort(reason);
		}, timeoutMs);
""",
    ),
    (
        """			} finally {
				clearTimeout(timer);
				timer = void 0;
""",
        """			} finally {
				timer?.();
				timer = void 0;
""",
    ),
    (
        """			disposed = true;
			if (timer !== void 0) clearTimeout(timer);
			timer = void 0;
""",
        """			disposed = true;
			timer?.();
			timer = void 0;
""",
    ),
]


def main() -> int:
    source = TARGET.read_text(encoding="utf-8")
    if MARKER in source:
        print(json.dumps({"already_patched": str(TARGET.relative_to(ROOT))}))
        return 0
    patched = source
    for old, new in REPLACEMENTS:
        if patched.count(old) != 1:
            print(f"expected exactly one match, found {patched.count(old)}:\n{old}", file=sys.stderr)
            return 1
        patched = patched.replace(old, new)
    BACKUP.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(TARGET, BACKUP)
    TARGET.write_text(patched, encoding="utf-8")
    print(json.dumps({"patched": str(TARGET.relative_to(ROOT)), "replacements": len(REPLACEMENTS)}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
