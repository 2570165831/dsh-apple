// Does DSH itself list a session that survived a container change?
//
// WHY THIS EXISTS, AND WHY IT IS NOT THE UI TEST.
//
// The requirement is "the old session is still in the list and can be continued".
// Two things have to be true for that, and only one of them can be established
// from the simulator's screen:
//
//   (a) DSH's session store lists the session and can open it — the functional
//       fact, which this module measures by mounting the real profile and asking
//       `sessionPersistence` and `sessionQuery` directly, the same services the
//       sidebar's data comes from;
//   (b) the sidebar renders a row for it — the presentational fact, which needs a
//       viewport wide enough for DSH's 1024 px `SIDEBAR_AUTO_COLLAPSE` threshold.
//       This device presents 402 px, so the sidebar is a 56 px rail and the rows
//       are not in the DOM (measured: twelve presses of the rail toggle left
//       `data-sidebar-collapsed` in place).
//
// Measuring (a) here is not a substitute for (b): the report says so plainly, and
// the person holding the phone is the one who confirms (b). What it does replace
// is guessing — it says whether DSH's own registry sees the migrated log, which is
// the difference between "the file was rewritten correctly" and "the harness can
// use it".
//
// GATED: `sim/ios-app-entry.mjs` imports this INSTEAD of DSH when
// `DSHPORTE_SESSION_LIST_ACCEPTANCE=1`. A normal launch never reaches it.

import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';

const RESULT_NAME = 'DSHPortE-session-list-acceptance.json';

function resultPath() {
  const workspace = process.env.DSH_IOS_WORKSPACE ?? process.cwd();
  return process.env.DSHPORTE_ACCEPTANCE_OUT ?? join(dirname(workspace), RESULT_NAME);
}

const report = { startedAt: new Date().toISOString(), node: process.versions.node, criteria: {} };

function record(id, value) {
  report.criteria[id] = value;
  write();
}

function write() {
  try {
    mkdirSync(dirname(resultPath()), { recursive: true });
    writeFileSync(resultPath(), JSON.stringify(report, null, 2));
  } catch (error) {
    process.stderr.write(`session-list-acceptance: could not write the report: ${error}\n`);
  }
}

// --------------------------------------------------------------- the profile
// Mounted through `runProfile()`, the function `dsh --profile ios-sim` itself
// calls — the same entry `sim/subprocess-acceptance.mjs` uses, and for the same
// reason: `boot()` needs its config path, patch list and environment snapshot
// assembled correctly, and getting that subtly wrong produces a tree that comes up
// with rows missing rather than an error. Measured in step 5: `boot(config, [])`
// yields no task rows at all.
const payload = process.env.IOS_SIM_DSH_INSTALL ?? join(process.env.IOS_SIM_BUNDLE ?? '.', 'payload');
const payloadPath = (name) => join(payload, 'node_modules', '@deepseek-ai', name, 'lib', 'index.js');
// `runProfile` lives in dsh's `profile-boot` export, not the package root.
const { runProfile } = await import(join(payload, 'node_modules/@deepseek-ai/dsh/lib/profile-boot.js'));
const appBoot = await import(payloadPath('dsh-app-boot'));

let ctx;
try {
  const mounted = await runProfile({
    environment: appBoot.loadLayeredEnv('dsh'),
    profile: 'ios-sim',
    patchFiles: [],
    args: [],
  });
  ctx = mounted?.ctx;
  if (ctx === undefined) throw new Error('runProfile returned no context');
} catch (error) {
  record('boot', { ok: false, error: String(error && error.message ? error.message : error) });
  process.stdout.write(`DSHPORTE_SESSION_LIST_ACCEPTANCE ${JSON.stringify(report.criteria)}\n`);
  process.exit(1);
}
record('boot', { ok: true });

// ------------------------------------------------------------------- criteria
try {
  const persistence = ctx.get('sessionPersistence');
  const snapshots = await persistence.list();
  record('session_persistence_lists_sessions', {
    count: snapshots.length,
    sessions: snapshots.map((snapshot) => ({
      id: snapshot.header.id,
      cwd: snapshot.header.cwd,
      formatStatus: snapshot.formatStatus,
      sizeBytes: snapshot.sizeBytes,
    })),
  });

  const query = ctx.get('sessionQuery');
  if (query !== undefined) {
    const listed = await query.listSessions();
    record('session_query_lists_sessions', {
      count: listed.length,
      ids: listed.map((row) => row.header.id),
      allHaveCwd: listed.every((row) => typeof row.header.cwd === 'string'),
    });
  }

  const registry = ctx.get('workspaceRegistry');
  if (registry !== undefined) {
    record('workspace_registry', {
      workspaces: registry.list().map((workspace) => ({
        id: workspace.id,
        path: workspace.path,
        title: workspace.title,
        // A getter, not a field: it filters by the startup header index, so a
        // session whose header DSH could not read does not appear here.
        sessionIds: [...workspace.sessionIds],
      })),
      archivedSessionIds: [...registry.archivedSessionIds],
    });
  }

  // Opening the session is the other half of "it is still usable": DSH loads the
  // log, validates its identity, and returns the events it already has.
  const target = process.env.DSHPORTE_EXPECT_SESSION;
  if (target) {
    // `sessionQuery.readSession` replays and validates the whole log without
    // taking the write lease:
    //   * `sessionPersistence.open` takes a flock, and the flock addon is the one
    //     `@deepseek-ai/node-addon-system` stub `dsh-ios` replaces — measured here
    //     as `flock is not supported on ios-arm64`. That is the write path, and a
    //     listing has no business seeking write access.
    //   * `readSession` is what a session view uses to read a session it is not
    //     driving, and it runs DSH's own replay validation, so a log that parses
    //     here is a log DSH can open.
    if (query === undefined) {
      record('open_session', { id: target, ok: false, error: 'sessionQuery is not mounted' });
    } else {
      try {
        const loaded = await query.readSession(target);
        const events = loaded.events;
        record('open_session', {
          id: target,
          ok: true,
          via: 'sessionQuery.readSession',
          eventCount: events.length,
          types: [...new Set(events.map((event) => event && event.type).filter(Boolean))],
          hasTurnEnd: events.some((event) => event && event.type === 'turn/end'),
          cwd: loaded.session.cwd,
          createdAt: loaded.session.createdAt,
        });
      } catch (error) {
        record('open_session', { id: target, ok: false, error: String(error && error.message ? error.message : error) });
      }
    }
    record('expected_session_present', {
      id: target,
      present: snapshots.some((snapshot) => snapshot.header.id === target),
    });
  }
} catch (error) {
  record('criteria_failed', { error: String(error && error.message ? error.message : error) });
}

write();
process.stdout.write(`DSHPORTE_SESSION_LIST_ACCEPTANCE ${JSON.stringify(report.criteria)}\n`);
// The profile is mounted; stop the process rather than serving a UI nobody asked
// for, exactly like the other acceptance gates.
process.exit(0);
