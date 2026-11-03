// `dsh-busy-ios`: tell the app shell whether a turn is in progress, and how far
// into it we are.
//
// WHY THE SHELL NEEDS THIS
// ------------------------
// Step 13 asks the app to keep a running turn alive after the user backgrounds
// it. Requesting that from iOS (`BGContinuedProcessingTask`) has to happen when
// the turn starts, while the app is in the foreground, and ONLY when there is work
// in flight: asking with nothing running burns a system resource for no reason and
// shows the user a system task they did not ask for.
//
// The question "is a turn running" therefore has to be answerable from the
// native side, at any moment. The shell cannot ask the web view: a backgrounded
// WKWebView may already have been throttled, and reading the DOM answers "did the
// UI last paint something that looks busy", not "is the agent working". It cannot
// read the session log either — that is a zstd frame being appended to, and
// reading it after every event would cost more than the whole feature.
//
// So this plugin observes the durable session event stream, which is the same
// source the UI is rendered from, and writes ONE line per state change to stdout:
//
//     DSHPORTC_BUSY {"busy":true,"sessions":[{"id":"…","turn":1,"step":2,"tools":1}]}
//
// The app already owns stdout (it dup2s a pipe over fd 1 so it can read the
// launch URL), and `NodeRunner.handleLine` already dispatches the lines it does
// not recognise, so a prefixed line needs no new plumbing and no polling.
//
// WHY A PLUGIN AND NOT A PAYLOAD PATCH
// ------------------------------------
// `session/event` is a published cordis event, not an internal: `dsh-agent-loop`,
// `dsh-agent-instructions` and `dsh-compaction-basic` all subscribe to it from
// their own packages. Observing it costs zero lines of DSH source, exactly like
// `dsh-subprocess-ish` and `dsh-attachment-ios` (PATCHES.md P-6, P-10). Nothing
// here changes what DSH does; it only reports.
//
// WHAT IT DELIBERATELY DOES NOT DO
// --------------------------------
// * No token streaming. Token deltas are not durable events and would produce a
//   line per token; the state only changes at turn/step/tool boundaries, which
//   is also the granularity the system's progress indicator can show.
// * No timers that decide state. A stale "busy" on a crashed session would be
//   worse than a late one: `turn/end` always fires in the agent loop's `finally`,
//   and a process that dies takes the whole app with it. The one timer here only
//   adds `beat` to a turn already in flight: the system expires a continued-
//   processing task that looks stalled, and a long generation or a silent command
//   produces no events. A beat proves Node is alive, nothing more.
// * No content. Session ids, turn and step numbers, and a count of tool calls.
//   No prompt text, no tool arguments, no result text — those are the user's.

export const name = 'busy-ios';

/** The stdout prefix the app's line dispatcher looks for. */
const PREFIX = 'DSHPORTC_BUSY ';

const BEAT_MS = 10_000;

export function apply(ctx) {
  /** sessionId -> { turn, step, tools } */
  const sessions = new Map();
  /** The last emitted line, so an unchanged state is not written twice. */
  let lastLine = null;
  let beat = 0;
  let beatTimer;

  const publish = () => {
    const view = {
      busy: sessions.size > 0,
      beat,
      sessions: [...sessions.entries()].map(([id, state]) => ({
        id,
        turn: state.turn,
        step: state.step,
        tools: state.tools,
      })),
    };
    const line = PREFIX + JSON.stringify(view);
    if (line === lastLine) return;
    lastLine = line;
    // One write, one line: the reader splits on '\n' and nothing else in this
    // package interleaves on fd 1 during a turn.
    process.stdout.write(line + '\n');
  };

  ctx.on('session/event', (session, event) => {
    const id = session?.id;
    if (typeof id !== 'string' || id === '') return;
    const data = event?.data ?? {};
    let changed = false;

    switch (event.type) {
      case 'turn/start': {
        sessions.set(id, { turn: Number(data.turn) || 1, step: 0, tools: 0 });
        changed = true;
        break;
      }
      case 'step/start': {
        const state = sessions.get(id);
        if (state !== undefined) {
          state.step = Number(data.step) || state.step;
          changed = true;
        }
        break;
      }
      case 'tool/call': {
        const state = sessions.get(id);
        if (state !== undefined) {
          state.tools += 1;
          changed = true;
        }
        break;
      }
      case 'turn/end': {
        changed = sessions.delete(id);
        break;
      }
      default:
        break;
    }

    if (changed) publish();

    if (sessions.size > 0 && beatTimer === undefined) {
      beatTimer = setInterval(() => {
        beat += 1;
        publish();
      }, BEAT_MS);
      beatTimer.unref?.();
    } else if (sessions.size === 0 && beatTimer !== undefined) {
      clearInterval(beatTimer);
      beatTimer = undefined;
    }
  });

  // Announce the initial (idle) state, so the app can tell "the bridge is
  // mounted and says idle" apart from "the bridge never mounted". Without this
  // the two look identical from the shell: no line either way.
  publish();
  process.stdout.write('busy-ios: installed\n');
}

export default { name, apply };
