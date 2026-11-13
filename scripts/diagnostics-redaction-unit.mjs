// Run the actual Foundation redactor and fallback copier without UIKit.
// Usage: node scripts/diagnostics-redaction-unit.mjs

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { REDACTION_CASES } from '../tests/step19/diagnostics-fixtures.mjs';
import { redactText } from '../sim/diagnostics.mjs';

const source = readFileSync(new URL('../app/DSHPortC/DiagnosticsShare.swift', import.meta.url), 'utf8');
const start = source.indexOf('    static let maxFileBytes =');
const end = source.indexOf('    private static func bootGuardSummary()', start);
assert.ok(start >= 0 && end > start, 'the Foundation fallback section was not found');

const runner = readFileSync(new URL('../app/DSHPortC/NodeRunner.swift', import.meta.url), 'utf8');
const handler = runner.indexOf('    private func handleLine(_ line: String) {');
const logStart = runner.indexOf('\n', handler) + 1;
const logEnd = runner.indexOf('        // The runtime facts line', logStart);
assert.ok(handler >= 0 && logEnd > logStart, 'the bridge log dispatch was not found');

const bridge = readFileSync(new URL('../app/DSHPortC/NotificationBridge.swift', import.meta.url), 'utf8');
const post = bridge.indexOf('    private func post(');
const recordStart = bridge.indexOf('            if !key.isEmpty { deliveredByKey.insert(key) }', post);
const recordEnd = bridge.indexOf('            if dumpEnabled { dumpDelivered(reason: "after-delivery") }', recordStart);
assert.ok(post >= 0 && recordStart > post && recordEnd > recordStart, 'the delivery record was not found');
assert.ok(bridge.includes('"delivered": deliveredForDump,'), 'the test copy must use its separate content list');

const harness = [
  'import Foundation',
  'import Darwin',
  'enum NodeRunner { static func redact(_ text: String) -> String { text } }',
  'enum DiagnosticsShare {', source.slice(start, end),
  String.raw`
    static func checkCopies(in directory: URL) throws {
        func copy(_ name: String, _ text: String, _ available: Int) throws -> String {
            let input = directory.appendingPathComponent(name)
            let output = directory.appendingPathComponent("out-" + name)
            try text.write(to: input, atomically: true, encoding: .utf8)
            var budget = available
            guard case .copied = copyRedacted(from: input, to: output, budget: &budget) else {
                preconditionFailure("fallback did not copy " + name)
            }
            let body = try String(contentsOf: output, encoding: .utf8)
            precondition(body.utf8.count <= min(available, maxFileBytes))
            precondition(budget == available - body.utf8.count)
            return body
        }
        let large = String(repeating: "node| boot continues\n", count: readWindowBytes / 10)
            + "node| TAIL-LARGE\n"
        let log = try copy("DSHPortC-node.log", large, maxTotalBytes)
        precondition(log.contains("TAIL-LARGE") && log.contains("[truncated:"))
        let snapshotLog = try copy("00-appSupport_DSHPortC-node.log", large, maxTotalBytes)
        precondition(snapshotLog.contains("TAIL-LARGE"))
        let limited = try copy("DSHPortC-node.log", String(repeating: "node| 中文\n", count: 1000)
            + "node| TAIL-BUDGET\n", 1024)
        precondition(limited.contains("TAIL-BUDGET") && !limited.contains("\u{FFFD}"))
        let status = try copy("DSHPortC-status.json",
            "{\"title\":\"PRIVATE-TITLE\",\"padding\":\"" + String(repeating: "x", count: maxFileBytes + 100)
                + "\",\"body\":\"PRIVATE-BODY\",\"phase\":\"TAIL-STATUS\"}", maxTotalBytes)
        precondition(status.contains("TAIL-STATUS"))
        precondition(!status.contains("PRIVATE-TITLE") && !status.contains("PRIVATE-BODY"))
        let old = "dshportc: notify delivered question title=PRIVATE\n"
            + String(repeating: "PRIVATE-CONTINUATION\n", count: readWindowBytes / 10)
            + "dshportc: TAIL-RECOVERED\n"
        let recovered = try copy("DSHPortC-node.log", old, maxTotalBytes)
        precondition(recovered.contains("TAIL-RECOVERED") && !recovered.contains("PRIVATE"))
        let summary = try copy("SUMMARY.txt",
            "old snapshot\ncredentials:\r\n  provider: PRIVATE-KEY\r\n", maxTotalBytes)
        precondition(summary == "[omitted: multiline sensitive field]\n")
        for name in ["safe-mode.patch.yml", "10-dshHome_profiles_ios-sim_cordis.patch.yml", "SUMMARY.txt"] {
            let input = directory.appendingPathComponent(name)
            let output = directory.appendingPathComponent("omitted-" + name)
            try String(repeating: "  PRIVATE-KEY\n", count: readWindowBytes / 5)
                .write(to: input, atomically: true, encoding: .utf8)
            var budget = 1024
            guard case .skipped = copyRedacted(from: input, to: output, budget: &budget) else {
                preconditionFailure("context-free structured tail was copied")
            }
            precondition(budget == 1024 && !FileManager.default.fileExists(atPath: output.path))
        }
    }
}
func loggedLine(_ line: String) -> String {
    var output = ""
    func emit(_ line: String) { output = line }
    func handleLine(_ line: String) {
`,
  runner.slice(logStart, logEnd),
  '    }', '    handleLine(line)', '    return output', '}',
  String.raw`
struct Report { var delivered: [[String: String]] = [] }
func checkDelivery(_ dumpEnabled: Bool) {
    var report = Report()
    var deliveredByKey: Set<String> = []
    var deliveredForDump: [[String: String]] = []
    var output = ""
    func emit(_ line: String) { output = line }
    let kind = "question", key = "question:1", sessionId = "session-1"
    let content = (title: "PRIVATE-TITLE", body: "PRIVATE-BODY", threadIdentifier: sessionId)
`,
  bridge.slice(recordStart, recordEnd),
  String.raw`
    precondition(report.delivered.count == 1 && report.delivered[0]["key"] == key)
    precondition(report.delivered[0]["title"] == nil && report.delivered[0]["body"] == nil)
    precondition(!output.contains("PRIVATE"))
    precondition(deliveredForDump.count == (dumpEnabled ? 1 : 0))
    if dumpEnabled {
        precondition(deliveredForDump[0]["title"] == content.title && deliveredForDump[0]["body"] == content.body)
    }
}
checkDelivery(false)
checkDelivery(true)
for prefix in ["DSHPORTC_NOTIFY", "DSHPORTC_BUSY"] {
    precondition(loggedLine(prefix + " {\"title\":\"PRIVATE\",\"body\":\"PRIVATE\"}")
        == "node| " + prefix + " <payload omitted>")
    precondition(loggedLine(prefix + " malformed PRIVATE")
        == "node| " + prefix + " <payload omitted>")
}
// current_session_id in step16-acceptance.py requires this exact compact field order.
for input in [
    #"DSHPORTC_NOTIFY {"kind":"turn-start","sessionId":"session-current"}"#,
    #"DSHPORTC_NOTIFY {"sessionId":"session-current","title":"PRIVATE-TITLE","kind":"turn-start","body":"PRIVATE-BODY"}"#,
] {
    precondition(loggedLine(input)
        == #"node| DSHPORTC_NOTIFY {"kind":"turn-start","sessionId":"session-current"}"#)
}
for input in [
    #"DSHPORTC_NOTIFY {"kind":"turn-start"}"#,
    #"DSHPORTC_NOTIFY {"kind":"turn-start","sessionId":null}"#,
    #"DSHPORTC_NOTIFY {"kind":"turn-start","sessionId":""}"#,
    #"DSHPORTC_NOTIFY {"kind":"turn-start","sessionId":123}"#,
] {
    precondition(loggedLine(input) == "node| DSHPORTC_NOTIFY <payload omitted>")
}
precondition(loggedLine("ordinary boot line") == "node| ordinary boot line")
try DiagnosticsShare.checkCopies(in: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
let input = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [String]
let output = input.map { DiagnosticsShare.redactOrNil($0) ?? "<rules-unavailable>" }
let data = try JSONSerialization.data(withJSONObject: output)
print(String(data: data, encoding: .utf8)!)
`,
].join('\n');

const directory = mkdtempSync(join(tmpdir(), 'dsh-diagnostics-swift-'));
try {
  const file = join(directory, 'main.swift');
  const binary = join(directory, 'redact');
  writeFileSync(file, harness);
  const built = spawnSync('swiftc', [file, '-o', binary], { encoding: 'utf8' });
  assert.equal(built.status, 0, built.error?.message ?? built.stderr);
  const run = spawnSync(binary, [directory], {
    encoding: 'utf8',
    input: JSON.stringify(REDACTION_CASES.map((entry) => entry.text)),
  });
  assert.equal(run.status, 0, run.error?.message ?? run.stderr);
  const outputs = JSON.parse(run.stdout);
  assert.equal(outputs.length, REDACTION_CASES.length);
  REDACTION_CASES.forEach((entry, index) => {
    assert.equal(outputs[index], redactText(entry.text).text, entry.name + ': Swift/Node drift');
    for (const secret of entry.secrets) assert.equal(outputs[index].includes(secret), false, entry.name);
    for (const kept of entry.kept ?? []) assert.ok(outputs[index].includes(kept), entry.name);
  });
  console.log(REDACTION_CASES.length + ' Foundation redaction cases, fallback copies and bridge checks passed');
} finally {
  rmSync(directory, { recursive: true, force: true });
}
