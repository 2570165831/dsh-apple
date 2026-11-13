#!/usr/bin/env node
// Exercise the runner's real status and readiness methods without UIKit.
// Run on macOS: node scripts/boot-state-unit.mjs
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const source = readFileSync(new URL('../app/DSHPortC/NodeRunner.swift', import.meta.url), 'utf8');
const lockedValue = readFileSync(new URL('../app/DSHPortC/LockedValue.swift', import.meta.url), 'utf8')
  .replace(/^import Foundation\n/m, '');
function cut(start, end) {
  const first = source.indexOf(start);
  const last = source.indexOf(end, first);
  assert.ok(first >= 0 && last > first, 'extract the real runner section: ' + start);
  return source.slice(first, last);
}
const scratch = mkdtempSync(join(tmpdir(), 'dsh-boot-state-'));
const harness = [
  'import Foundation',
  cut('enum BootPhase', 'struct BackgroundReport: Codable'),
  'struct BackgroundReport: Codable {}',
  'struct NotificationReport: Codable {}',
  'struct SafeModeReport: Codable {}',
  'struct GuardReport: Codable {}',
  lockedValue,
  'enum BootGuard {',
  '  static let pageReadyTimeout: TimeInterval = 60',
  '  static var outcomes: [String] = []',
  '  static func cancelWatchdog() {}',
  '  @discardableResult static func recordOutcome(kind: String, reason: String, phase: String, level: String = "page") -> Bool {',
  '    guard outcomes.isEmpty else { return false }',
  '    outcomes.append(kind + ":" + reason); return true',
  '  }',
  '}',
  'final class NodeRunner {',
  '  private let queue = DispatchQueue(label: "boot-state-test")',
  '  private let launchDate = Date()',
  '  let statusFileURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DSH_TEST_CONTAINER"]!).appendingPathComponent("status.json")',
  '  static func redact(_ text: String) -> String { text }',
  '  func emit(_ line: String) {}',
  cut('    private let statusStore = LockedValue(BootStatus(', '    /// The authenticated loopback URL'),
  cut('    private func writeStatus(', '    // MARK: - Boot'),
  cut('    func noteWebViewLoading()', '    /// Record that the app went to the background'),
  '}',
  String.raw`
func require(_ condition: Bool, _ message: String) { precondition(condition, message) }
extension NodeRunner {
    func expireForTest() { noteReadinessTimeout() }
    func settledForTest() -> BootStatus { queue.sync { statusSnapshot } }
}
func fresh() -> NodeRunner {
    BootGuard.outcomes = []
    return NodeRunner()
}

let ready = fresh()
ready.noteWebViewLoading()
ready.noteDocumentLoaded()
require(ready.settledForTest().phase == "documentLoaded", "HTML completion is not success")
require(BootGuard.outcomes.isEmpty, "no outcome before client readiness")
require(ready.noteWebViewReady(), "accept client readiness")
require(BootGuard.outcomes.first == "success:the DSH interface came up", "record success once")
ready.noteFailure("node stopped", runtimeFatal: true)
ready.noteWebViewLoading()
ready.noteDocumentLoaded()
let stopped = ready.settledForTest()
require(stopped.phase == "failed" && stopped.runtimeFatal == true, "navigation cannot overwrite fatal phase")
require(!ready.noteWebViewReady(), "navigation cannot revive Node")
require(BootGuard.outcomes.count == 1, "runtime exit cannot replace launch success")
let persisted = try JSONDecoder().decode(BootStatus.self, from: Data(contentsOf: ready.statusFileURL))
require(persisted.phase == "failed" && persisted.runtimeFatal == true, "persist the fatal state")

let timeout = fresh()
timeout.noteWebViewLoading()
timeout.noteClientStartupError("first plugin error")
timeout.noteClientStartupError("second error")
timeout.expireForTest()
let failed = timeout.settledForTest()
require(failed.phase == "failed", "watchdog fails an unready client")
require(failed.error?.contains("first plugin error") == true, "watchdog includes startup diagnostic")
require(failed.error?.contains("second error") == false, "keep the first diagnostic")
require(!timeout.noteWebViewReady(), "late readiness cannot replace failure")
timeout.noteFailure("later fatal exit", runtimeFatal: true)
require(timeout.settledForTest().error == failed.error, "retain the first failure reason")
require(timeout.settledForTest().runtimeFatal == true, "retain a later fatal source")
require(BootGuard.outcomes.count == 1, "one launch outcome")

let recovered = fresh()
recovered.noteWebViewLoading()
recovered.noteClientStartupError("optional fetch failed")
require(recovered.noteWebViewReady(), "nonfatal client error does not veto readiness")
require(recovered.settledForTest().clientStartupError == "optional fetch failed", "retain diagnostic after readiness")

let early = fresh()
early.noteFailure("early exit", runtimeFatal: true)
early.noteWebViewLoading()
early.noteDocumentLoaded()
require(early.settledForTest().phase == "failed", "early fatal state is terminal")
require(!early.noteWebViewReady(), "early fatal exit rejects readiness")
print("boot state checks passed")
`,
].join('\n');

try {
  const result = spawnSync('swift', ['-module-cache-path', join(scratch, 'modules'), '-'], {
    input: harness,
    encoding: 'utf8',
    env: { ...process.env, DSH_TEST_CONTAINER: scratch },
    timeout: 120000,
    maxBuffer: 4 * 1024 * 1024,
  });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /boot state checks passed/);
  process.stdout.write(result.stdout);
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
