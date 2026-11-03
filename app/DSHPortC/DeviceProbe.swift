//
//  DeviceProbe.swift
//  DSHPortC
//
//  Step 4B measurement hook for a physical device. Writes
//  Documents/DSHPortE-probe.json. Nothing here runs unless the app is launched
//  with `-DSHPortEProbe 1` or env DSHPORTE_PROBE=1 (devicectl cannot pass a
//  dash-prefixed launch argument, so the device runs use the environment), so a normal launch is untouched.
//
//  Modes (env DSHPORTE_PROBE_MODE):
//    mem  (default)  T0..T3 memory points, guest boot and command timings, the
//                    guest checks, and two OS-enforcement checks (spawn, dlopen).
//                    Launch with DSHPORTE_GUEST_CHANNEL=0 so the guest is NOT
//                    booted before T0.
//    bg              heartbeat only, every 2 s, for the background test. The
//                    guest comes up the normal way (channel on).
//
//  Memory is `phys_footprint` from TASK_VM_INFO (what jetsam counts), not RSS,
//  plus `os_proc_available_memory()`.
//

import Foundation
import Darwin
import os
import UIKit

/// Step 12's power-test record: one JSON line every 10 s in
/// Documents/DSHPortE-power.jsonl. Nothing runs unless the app is launched with env
/// DSHPORTE_POWER_LOG=1, so a normal launch is untouched.
///
/// A gap in the timestamps is a result, not a fault: it is how long iOS kept the
/// process suspended. `cpu_s` is the whole process (Node and the guest included),
/// and is cumulative, so a scenario's CPU is the difference across its span.
@MainActor
enum PowerLog {
    private static var timer: DispatchSourceTimer?

    static func startIfConfigured() {
        guard ProcessInfo.processInfo.environment["DSHPORTE_POWER_LOG"] == "1", timer == nil else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: 10)
        source.setEventHandler { MainActor.assumeIsolated { appendSample() } }
        source.resume()
        timer = source
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private static func appendSample() {
        let sample: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "app_state": UIApplication.shared.applicationState.rawValue,
            "thermal": ProcessInfo.processInfo.thermalState.rawValue,
            "low_power": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "battery_level": UIDevice.current.batteryLevel,
            "battery_state": UIDevice.current.batteryState.rawValue,
            "cpu_s": cpuSeconds(),
            "footprint_mb": DeviceProbe.footprintMB(),
        ]
        guard var line = try? JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DSHPortE-power.jsonl")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }
}

@MainActor
final class DeviceProbe {
    static let shared = DeviceProbe()
    static var isEnabled: Bool {
        UserDefaults.standard.integer(forKey: "DSHPortEProbe") == 1
            || ProcessInfo.processInfo.environment["DSHPORTE_PROBE"] == "1"
    }

    private var report: [String: Any] = [:]
    private let url: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DSHPortE-probe.json")
    private var started = false

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    static func availableMB() -> Double { Double(os_proc_available_memory()) / 1_048_576 }

    private func point(_ name: String) {
        var points = report["points"] as? [String: Any] ?? [:]
        points[name] = ["footprint_mb": Self.footprintMB(), "available_mb": Self.availableMB(),
                        "at": ISO8601DateFormatter().string(from: Date())]
        report["points"] = points
        write()
    }

    private func write() {
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func runIfConfigured() {
        PowerLog.startIfConfigured()
        guard Self.isEnabled, !started else { return }
        started = true
        let mode = ProcessInfo.processInfo.environment["DSHPORTE_PROBE_MODE"] ?? "mem"
        report["mode"] = mode
        report["pid"] = getpid()
        report["startedAt"] = ISO8601DateFormatter().string(from: Date())
        Task { mode == "bg" ? await heartbeat() : await runMem() }
    }

    private func waitForWeb() async {
        for _ in 0..<300 {
            if NodeRunner.shared.status.phase == BootPhase.webViewReady.rawValue { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func run(_ command: String, timeout: TimeInterval = 120) async -> [String: Any] {
        let started = Date()
        let r: ISHGuestResult = await withCheckedContinuation { c in
            ISHGuest.shared.runCommand(command, timeout: timeout, lineBlock: nil) { c.resume(returning: $0) }
        }
        let out = r.standardOutput
        return ["command": String(command.prefix(80)), "exit": r.exitCode, "wall_s": Date().timeIntervalSince(started),
                "duration_s": r.duration, "timedOut": r.timedOut, "launchError": r.launchError as Any? ?? NSNull(),
                "stdout": String(out.suffix(400)), "stderr": String(r.standardError.suffix(400))]
    }

    private func runMem() async {
        await waitForWeb()
        report["webViewReadySeconds"] = NodeRunner.shared.status.secondsSinceLaunch
        point("T0_node_up_guest_not_booted")

        let t = Date()
        let bootError: Error? = await withCheckedContinuation { c in ISHGuest.shared.boot { c.resume(returning: $0) } }
        report["boot_call_s"] = Date().timeIntervalSince(t)
        report["kernel_boot_s"] = ISHGuest.shared.bootSeconds
        report["rootfs_import_s"] = ISHGuest.shared.rootfsImportSeconds
        report["boot_error"] = bootError?.localizedDescription as Any? ?? NSNull()
        point("T1_guest_booted")
        if bootError != nil { write(); return }

        var cmds: [[String: Any]] = []
        let first = await run("true")
        report["first_cmd_s"] = first["wall_s"]
        cmds.append(first)
        point("T2_after_true")

        cmds.append(await run("uname -m"))
        // Workspace sharing: bind /workspace, write from the guest, read on the host, and the reverse.
        let ws = NodeRunner.shared.workspace
        try? FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let bindError: Error? = await withCheckedContinuation { c in
            ISHGuest.shared.bindMountGuestPath("/workspace", hostPath: ws.path, readWrite: true) { c.resume(returning: $0) }
        }
        report["bind_error"] = bindError?.localizedDescription as Any? ?? NSNull()
        try? FileManager.default.removeItem(at: ws.appendingPathComponent("probe-from-guest.txt"))
        cmds.append(await run("echo guest-wrote-this > /workspace/probe-from-guest.txt"))
        let hostRead = try? String(contentsOf: ws.appendingPathComponent("probe-from-guest.txt"), encoding: .utf8)
        report["workspace_guest_to_host"] = hostRead ?? "UNREADABLE"
        try? "host-wrote-this\n".write(to: ws.appendingPathComponent("probe-from-host.txt"), atomically: true, encoding: .utf8)
        cmds.append(await run("cat /workspace/probe-from-host.txt"))
        cmds.append(await run(GuestSelfTest.cpOverwriteScript))
        cmds.append(await run(GuestSelfTest.cpArchiveScript))
        report["commands"] = cmds
        write()

        // T3: a recursive grep over a medium directory in the guest.
        cmds.append(await run("grep -r -c root /usr 2>/dev/null | wc -l; du -s /usr | cut -f1"))
        report["commands"] = cmds
        point("T3_after_grep_r")
        await Task.yield()

        osChecks()
        report["finishedAt"] = ISO8601DateFormatter().string(from: Date())
        write()
    }

    /// What the OS itself allows, independent of the JS-level blocks in the preload.
    private func osChecks() {
        var checks: [String: Any] = [:]
        // posix_spawn of a system binary.
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "/bin/ls", nil, nil, [strdup("ls"), nil], nil)
        checks["posix_spawn_/bin/ls_rc"] = Int(rc)
        checks["posix_spawn_/bin/ls_strerror"] = rc == 0 ? "spawned (pid \(pid))" : String(cString: strerror(rc))
        if rc == 0 { var st: Int32 = 0; waitpid(pid, &st, 0) }
        // dlopen of a non-system library from the container. Write a copy of a
        // tiny Mach-O-looking file; the OS must reject an unsigned/unknown image.
        let fake = FileManager.default.temporaryDirectory.appendingPathComponent("probe-fake.dylib")
        try? Data(count: 4096).write(to: fake)
        let h = dlopen(fake.path, RTLD_NOW)
        checks["dlopen_unsigned_garbage_handle_null"] = (h == nil)
        checks["dlopen_unsigned_garbage_error"] = h == nil ? (dlerror().map { String(cString: $0) } ?? "nil") : "OPENED"
        // dlopen of a copy of a system dylib placed in the container (unsigned copy of a signed file cannot be copied here, so use the app's own binary as a negative control)
        let own = Bundle.main.executablePath ?? ""
        let h2 = dlopen(own, RTLD_NOW)
        checks["dlopen_app_executable_handle_null"] = (h2 == nil)
        checks["dlopen_app_executable_error"] = h2 == nil ? (dlerror().map { String(cString: $0) } ?? "nil") : "OPENED"
        // Valid arm64 dylibs pushed into Documents/ by the host (one unsigned, one
        // ad-hoc signed). A real native add-on would be the same kind of file.
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for name in ["probe-dl-unsigned.dylib", "probe-dl-adhoc.dylib"] {
            let path = docs.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: path) else { checks[name] = "file not present"; continue }
            let h = dlopen(path, RTLD_NOW)
            checks[name] = h == nil ? "REJECTED: " + (dlerror().map { String(cString: $0) } ?? "nil") : "OPENED"
        }
        checks["node_childProcessBlocked"] = NodeRunner.shared.status.node.childProcessBlocked
        checks["node_addonLoadingBlocked"] = NodeRunner.shared.status.node.addonLoadingBlocked
        report["os_checks"] = checks
    }

    private func heartbeat() async {
        var n = 0
        var lastGuest: [String: Any] = [:]
        while true {
            n += 1
            var hb: [String: Any] = ["n": n, "at": ISO8601DateFormatter().string(from: Date()),
                                     "uptime_s": ProcessInfo.processInfo.systemUptime,
                                     "footprint_mb": Self.footprintMB(), "available_mb": Self.availableMB(),
                                     "pid": getpid(), "phase": NodeRunner.shared.status.phase]
            // Node alive: TCP connect to the loopback web port.
            if let u = NodeRunner.shared.authenticatedURL, let port = u.port { hb["node_port_open"] = Self.portOpen(port) }
            if n % 5 == 1, ISHGuest.shared.state == .ready {
                lastGuest = await run("echo alive-$$", timeout: 20)
            }
            hb["guest_last"] = lastGuest
            report["heartbeat"] = hb
            var all = report["history"] as? [[String: Any]] ?? []
            all.append(["n": n, "at": hb["at"] as Any, "uptime_s": hb["uptime_s"] as Any, "node": hb["node_port_open"] as Any,
                        "guest_exit": lastGuest["exit"] as Any])
            report["history"] = Array(all.suffix(400))
            write()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private static func portOpen(_ port: Int) -> Bool {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        defer { close(s) }
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET); a.sin_port = in_port_t(port).bigEndian
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }
}
