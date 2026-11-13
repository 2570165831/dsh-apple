#!/usr/bin/env node
// Exercise the Foundation-only reset and guard code in scratch containers.
// Run on macOS: node scripts/boot-runtime-unit.mjs
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const source = (name) => readFileSync(new URL('../app/DSHPortC/' + name, import.meta.url), 'utf8');
const lookup = 'let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]';
const paths = source('RuntimePaths.swift');
assert.equal(paths.split(lookup).length, 2, 'redirect the support root exactly once');
const table = source('ResetSheet.swift').split('enum ResetTable {')[1].split('/// The reset panel.')[0];
assert.ok(table.endsWith('}\n\n'), 'the complete Foundation-only table was extracted');
const scratch = mkdtempSync(join(tmpdir(), 'dsh-boot-runtime-'));
const harness = [
  paths.replace(lookup, 'let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DSH_TEST_CONTAINER"]!).appendingPathComponent("Library/Application Support")'),
  source('BootGuard.swift'),
  'enum ResetTable {' + table,
  'enum ResetSheet { static func builtinCombos() -> [String: ResetCombo] { ResetTable.combos() } }',
  source('ResetRunner.swift'),
  String.raw`
let fm = FileManager.default
let root = ResetRunner.containerRoot
let support = RuntimePaths.supportDirectory
let staging = RuntimePaths.resetStagingDirectory
let progress = staging.appendingPathComponent("in-progress.json")
func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
func put(_ text: String, _ url: URL) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}
func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
func record(_ stamp: String, _ entries: [String]) throws {
    let data = try JSONSerialization.data(withJSONObject: ["stamp": stamp, "entries": entries])
    try data.write(to: progress)
}
func require(_ condition: Bool, _ message: String) { precondition(condition, message) }

let mode = ProcessInfo.processInfo.environment["DSH_TEST_CASE"]!
if mode != "recovery" {
    let marker = support.appendingPathComponent("boot/boot-background.txt")
    try put("previous-launch\n", marker)
    BootGuard.noteBecameActive()
    if mode != "active" { BootGuard.noteEnteredBackground() }
    if mode == "returned" { BootGuard.noteBecameActive() }
    require(try read(marker) == "previous-launch\n", "early lifecycle preserves previous evidence")
    require(try fm.contentsOfDirectory(atPath: staging.path).isEmpty, "early lifecycle creates no launch directory")
    RuntimePaths.finishReset(success: true)
    BootGuard.flushBackgroundMarker()
    let expected = mode == "background" ? BootGuard.launchId + "\n" : "previous-launch\n"
    require(try read(marker) == expected, "pending background uses the final path")
    require(try fm.contentsOfDirectory(atPath: staging.path).isEmpty, "normal launch leaves no staging entries")
    BootGuard.noteBecameActive()
    require(exists(marker) == (mode != "background"), "active clears only this launch's marker")
} else {
    BootGuard.noteEnteredBackground()
    require(try fm.contentsOfDirectory(atPath: staging.path).isEmpty, "early background does not create staging evidence")
    RuntimePaths.finishReset(success: false)
    BootGuard.flushBackgroundMarker()
    require(try read(RuntimePaths.bootBackgroundFile) == BootGuard.launchId + "\n", "failed reset keeps deferred marker in staging")
    BootGuard.noteBecameActive()
    try put("failure log", RuntimePaths.logFile)
    try put("failure status", RuntimePaths.statusFile)
    _ = BootGuard.report()
    _ = BootGuard.resetPreview()
    _ = RuntimePaths.diagnosticsDirectory
    require(BootGuard.recordOutcome(kind: "failure", reason: "reset", phase: "failed"), "write failure evidence")
    for name in ["boot", "diagnostics", "DSHPortC-node.log", "DSHPortC-status.json"] {
        require(!exists(support.appendingPathComponent(name)), "failure diagnostics do not recreate originals")
    }

    let runtime = [
        "DSHPortC-node.log", "DSHPortC-status.json", "DSHPortC-session-url.txt",
        "boot/evidence", "diagnostics/evidence",
    ]
    let entries = runtime.map {
        "Library/Application Support/DSHPortC/" + String($0.split(separator: "/").first!)
    }
    let sessions = "Library/Application Support/DSH/sessions"
    let credentials = "Library/Application Support/DSH/.credentials.yaml"
    let stamp = "interrupted"
    let saved = staging.appendingPathComponent(stamp)
    for relative in runtime {
        try put("original", support.appendingPathComponent(relative))
        try put("staged", saved.appendingPathComponent("Library/Application Support/DSHPortC/" + relative))
    }
    for relative in [sessions, credentials] {
        try put("user original", root.appendingPathComponent(relative))
        try put("user staged", saved.appendingPathComponent(relative))
    }
    try record(stamp, entries + [sessions, credentials])
    require(ResetRunner.finishInterruptedIfAny()?.ok == false, "user conflicts still stop recovery")
    require(exists(progress), "retain recovery record")
    for relative in runtime {
        require(!exists(support.appendingPathComponent(relative)), "regenerated original moved")
        let destination = saved.appendingPathComponent("Library/Application Support/DSHPortC/" + relative)
        require(try read(destination) == "staged", "old runtime evidence is unchanged")
        let entry = String(relative.split(separator: "/").first!)
        let parent = saved.appendingPathComponent("Library/Application Support/DSHPortC")
        let extras = try fm.contentsOfDirectory(atPath: parent.path).filter { $0.hasPrefix(entry + ".relaunch-") }
        require(extras.count == 1, "preserve regenerated runtime evidence once")
        let extra = parent.appendingPathComponent(extras[0])
        require(try read(relative.contains("/") ? extra.appendingPathComponent("evidence") : extra) == "original",
                "preserved copy retains its contents")
    }
    for relative in [sessions, credentials] {
        require(try read(root.appendingPathComponent(relative)) == "user original", "preserve original user data")
        require(try read(saved.appendingPathComponent(relative)) == "user staged", "preserve staged user data")
        try fm.removeItem(at: root.appendingPathComponent(relative))
    }
    require(ResetRunner.finishInterruptedIfAny()?.ok == true, "retry completes without purging staging")
    require(!exists(progress), "completed reset removes its record")

    let retryStamp = "retry"
    let blocked = staging.appendingPathComponent(retryStamp).appendingPathComponent("Library/Application Support/DSH")
    try put("block parent", blocked)
    try put("session", root.appendingPathComponent(sessions))
    try record(retryStamp, [sessions])
    require(ResetRunner.finishInterruptedIfAny()?.ok == false, "blocked destination fails")
    try put("more evidence", RuntimePaths.logFile)
    try put("{}", RuntimePaths.statusFile)
    _ = BootGuard.report()
    require(!exists(support.appendingPathComponent("boot")), "failed retry does not rebuild boot")
    try fm.removeItem(at: blocked)
    require(ResetRunner.finishInterruptedIfAny()?.ok == true, "unblocking permits recovery")
    RuntimePaths.finishReset(success: true)
}

require(RuntimePaths.logFile.deletingLastPathComponent() == support, "successful recovery uses normal paths")
let marker = RuntimePaths.bootBackgroundFile
try put("previous-launch\n", marker)
BootGuard.noteBecameActive()
require(try read(marker) == "previous-launch\n", "first active preserves previous-launch evidence")
BootGuard.noteEnteredBackground()
BootGuard.noteBecameActive()
require(!exists(marker), "returning active clears this launch's marker")
BootGuard.noteEnteredBackground()
require(try read(marker) == BootGuard.launchId + "\n", "a second background transition writes again")
try put(" \n" + BootGuard.launchId + "\n ", marker)
BootGuard.noteBecameActive()
require(!exists(marker), "comparison trims whitespace")
BootGuard.noteBecameActive()
print("boot runtime checks passed: " + mode)
`,
].join('\n');

try {
  for (const mode of ['active', 'background', 'returned', 'recovery']) {
    const result = spawnSync('swift', ['-module-cache-path', join(scratch, 'modules'), '-'], {
      input: harness,
      encoding: 'utf8',
      env: { ...process.env, DSH_TEST_CONTAINER: join(scratch, mode), DSH_TEST_CASE: mode },
      timeout: 120000,
      maxBuffer: 4 * 1024 * 1024,
    });
    assert.ifError(result.error);
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.match(result.stdout, /boot runtime checks passed/);
    process.stdout.write(result.stdout);
  }
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
