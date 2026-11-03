//
//  FilesProbe.swift
//  DSHPortC
//
//  Step 17's file-exchange cases: what the guest and the workspace see of each
//  other, recorded from inside the app.
//
//  WHY A PROBE
//  -----------
//  "A file the Files app put in the workspace can be read and modified by the
//  agent and by iSH" is three claims about three different readers of one
//  directory. The agent side is answered by a real turn's own durable log (see
//  `scripts/step17-files.py`); the iSH side is a guest command, and the only way
//  to run one without a human typing into the debug console is a probe. The
//  guest commands here are ordinary shell, run through the same `ISHGuest`
//  object the subprocess provider uses — not a shortcut around it.
//
//  GATING: `-DSHPortEFilesProbe <case>`. A normal launch never reaches this
//  code, and a probe launch writes one evidence file into `Documents/`
//  (`DSHPortE-files-probe.json`), which is a probe artefact like the others.
//

import Foundation

@MainActor
final class FilesProbe {

    static let shared = FilesProbe()

    static var isEnabled: Bool {
        let value = UserDefaults.standard.string(forKey: "DSHPortEFilesProbe") ?? ""
        return !value.isEmpty
    }

    static var probeCase: String {
        UserDefaults.standard.string(forKey: "DSHPortEFilesProbe") ?? ""
    }

    private var started = false
    private var report: [String: Any] = [:]

    private let reportURL: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("DSHPortE-files-probe.json")
    }()

    /// Run the configured case. Called once the web view is up, which is also
    /// when the guest bind mount has certainly happened (the guest boots before
    /// Node, and Node before the web view).
    func runIfConfigured() {
        guard Self.isEnabled, !started else { return }
        started = true
        report["case"] = Self.probeCase
        report["startedAt"] = ISO8601DateFormatter().string(from: Date())
        report["hostWorkspace"] = NodeRunner.shared.workspace.path
        report["guestWorkspacePath"] = GuestWorkspaceCoordinator.shared.workspaceGuestPath ?? "nil"
        write()
        Task { await run() }
    }

    private func run() async {
        switch Self.probeCase {
        case "paths":
            // Which guest path actually resolves to the shared workspace. The
            // coordinator binds `/workspace`; the console and an earlier
            // acceptance script use `/root/workspace`. Both are asked, so the
            // report states the measured answer instead of repeating a belief.
            await shell("echo home=$HOME; pwd; ls -la /workspace 2>&1 | head -20; echo ---; ls -la /root/workspace 2>&1 | head -20")
            await shell("mount | head -20")
        case "guest-read":
            await shell("cat /workspace/FROM-FILES.txt 2>&1; echo exit=$?")
            await shell("cat /root/workspace/FROM-FILES.txt 2>&1; echo exit=$?")
        case "guest-write":
            await shell("date -u +%FT%TZ > /workspace/FROM-ISH.txt && cat /workspace/FROM-ISH.txt")
        case "guest-edit":
            // Modify a file the Files app put there, in place.
            await shell("printf 'edited by iSH at %s\\n' \"$(date -u +%FT%TZ)\" >> /workspace/FROM-FILES.txt && cat /workspace/FROM-FILES.txt")
        case "guest-dir-ops":
            await shell("cd /workspace && mkdir -p ish-made-dir && echo hi > ish-made-dir/inside.txt && ls -la ish-made-dir")
        default:
            report["error"] = "unknown case \(Self.probeCase)"
            write()
        }
        report["finishedAt"] = ISO8601DateFormatter().string(from: Date())
        write()
    }

    /// Run one shell command in the guest and record its output verbatim.
    private func shell(_ command: String) async {
        let started = Date()
        let result: ISHGuestResult = await withCheckedContinuation { continuation in
            ISHGuest.shared.runCommand(command, timeout: 120, lineBlock: nil) { result in
                continuation.resume(returning: result)
            }
        }
        var entry: [String: Any] = [
            "command": command,
            "seconds": (Date().timeIntervalSince(started) * 1000).rounded() / 1000,
            "exit": result.exitCode,
            "stdout": result.standardOutput,
            "stderr": result.standardError,
            "timedOut": result.timedOut,
        ]
        if let launchError = result.launchError { entry["launchError"] = launchError }
        var steps = report["steps"] as? [[String: Any]] ?? []
        steps.append(entry)
        report["steps"] = steps
        write()
    }

    private func write() {
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: reportURL, options: .atomic)
    }
}
