//
//  GuestSelfTest.swift
//  DSHPortC
//
//  Runs the guest acceptance commands on launch, when asked to, and writes the
//  results to a JSON file in the app container.
//
//  Why this exists rather than driving the console through XCUITest: the console
//  is a debug screen, and a UI test that types into it measures the keyboard and
//  the accessibility tree as much as the guest. What the acceptance criteria are
//  actually about is "does the kernel boot, run a command, and report an exit
//  code", so the harness asks the guest directly and records what happened.
//
//  GATING: nothing here runs unless the app is launched with
//  `-DSHPortEGuestTest 1`. A normal launch never reaches this code.
//

import Foundation
import Darwin

@MainActor
final class GuestSelfTest {
    static let shared = GuestSelfTest()

    static var isEnabled: Bool {
        UserDefaults.standard.integer(forKey: "DSHPortEGuestTest") == 1
    }

    private var report: [String: Any] = [:]

    /// Time the process has been alive, in seconds.
    ///
    /// Taken from the kernel's own record (`p_starttime` via sysctl) rather than
    /// from the first Swift line that runs: "how long from tapping the icon to a
    /// working command" is the number the report needs, and it has to include
    /// everything the app did before this class was asked to do anything.
    private static func secondsSinceProcessStart() -> Double {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: Int32.self, capacity: 1) { rebound in
                sysctl(&mib, UInt32(mib.count), rebound, &size, nil, 0)
            }
        }
        guard result == 0 else { return 0 }
        let started = info.kp_proc.p_starttime
        var now = timeval()
        gettimeofday(&now, nil)
        let startSeconds = Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
        let nowSeconds = Double(now.tv_sec) + Double(now.tv_usec) / 1_000_000
        return max(0, nowSeconds - startSeconds)
    }
    private let reportURL: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("DSHPortE-guest-test.json")
    }()

    /// Which step to run. Each step is a separate launch so a failure in one
    /// cannot hide another, and so timing is not contaminated by earlier work.
    private var step: String {
        ProcessInfo.processInfo.environment["DSHPORTE_GUEST_STEP"] ?? "uname"
    }

    func runIfConfigured() {
        guard Self.isEnabled else { return }
        Task { await run() }
    }

    private func run() async {
        let guest = ISHGuest.shared
        report["step"] = step
        report["startedAt"] = ISO8601DateFormatter().string(from: Date())
        write()

        // Boot. This is the number the report needs: kernel boot time, measured
        // from the call that starts booting to the call that returns ready.
        let bootStart = Date()
        let bootError: Error? = await withCheckedContinuation { continuation in
            guest.boot { error in continuation.resume(returning: error) }
        }
        let bootSeconds = Date().timeIntervalSince(bootStart)
        report["bootError"] = bootError?.localizedDescription
        // Three different numbers, kept apart on purpose:
        //   bootCallSeconds      the whole boot() call, rootfs import included
        //   kernelBootSeconds    mount + PID 1 + devices + procfs + tty, no import
        //   processToCommandSeconds  icon tap to a finished guest command
        report["bootCallSeconds"] = bootSeconds
        report["kernelBootSeconds"] = guest.bootSeconds
        report["rootfsImportSeconds"] = guest.rootfsImportSeconds
        report["processToBootReadySeconds"] = Self.secondsSinceProcessStart()
        write()

        if bootError != nil { return }

        switch step {
        case "uname":
            await runSimple("uname -m")
        case "cptest":
            await runSimple(GuestSelfTest.cpOverwriteScript)
            await runSimple(GuestSelfTest.cpArchiveScript)
        case "die":
            await runDieTest()
        case "firstCommand":
            // Already past boot; the caller times the whole launch separately.
            await runSimple("true")
        case "fence":
            await runFenceTest()
        default:
            report["error"] = "unknown step \(step)"
        }

        report["finishedAt"] = ISO8601DateFormatter().string(from: Date())
        write()
    }

    private func runSimple(_ command: String) async {
        let guest = ISHGuest.shared
        let started = Date()
        let result: ISHGuestResult = await withCheckedContinuation { continuation in
            guest.runCommand(command, timeout: 120, lineBlock: nil) { result in
                continuation.resume(returning: result)
            }
        }
        var entry: [String: Any] = [
            "command": command.split(separator: "\n").first.map(String.init) ?? command,
            "processSecondsAtFinish": Self.secondsSinceProcessStart(),
            "exitCode": result.exitCode,
            "pid": result.pid,
            "duration": result.duration,
            "wallSeconds": Date().timeIntervalSince(started),
            "stdout": result.standardOutput,
            "stderr": result.standardError,
            "timedOut": result.timedOut,
        ]
        if let launchError = result.launchError { entry["launchError"] = launchError }
        var results = report["results"] as? [[String: Any]] ?? []
        results.append(entry)
        report["results"] = results
        if report["processToFirstCommandSeconds"] == nil {
            report["processToFirstCommandSeconds"] = Self.secondsSinceProcessStart()
        }
        write()
    }

    /// The two guest-side fences: a guest shell must not be able to mount a host
    /// directory (iSH patch 0003), and a command whose working directory cannot
    /// be entered must not run at all (`ISHGuest.m`, `startExecOnQueue`).
    ///
    /// The probe file is a marker written for this test into the app's own
    /// support directory, the directory next to the one that holds the API key.
    /// It is not a secret, and it is removed afterwards.
    private func runFenceTest() async {
        let marker = "FENCE-PROBE-NOT-A-SECRET"
        let probe = RuntimePaths.supportDirectory.appendingPathComponent("guest-fence-probe.txt")
        try? marker.write(to: probe, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: probe) }
        let host = RuntimePaths.supportDirectory.path
        await runSimple("""
        mkdir -p /mnt/fenceprobe /mnt/tmpprobe
        mount -t tmpfs tmpfs /mnt/tmpprobe; echo "tmpfs-exit=$?"
        mount -t real '\(host)' /mnt/fenceprobe; echo "mount-exit=$?"
        cat /mnt/fenceprobe/guest-fence-probe.txt; echo "cat-exit=$?"
        """)
        let output = ((report["results"] as? [[String: Any]])?.last?["stdout"] as? String) ?? ""
        // The tmpfs mount is the control: it must succeed, so a refused realfs
        // mount means the patch refused it, not that the guest user lacks root.
        report["fenceMountBlocked"] = !output.contains(marker) && !output.contains("mount-exit=0")
        report["fenceControlMounted"] = output.contains("tmpfs-exit=0")

        let request = ISHGuestExecRequest()
        request.command = "echo ran-in-$(pwd)"
        request.workingDirectory = "/no/such/directory"
        request.timeout = 30
        let result: ISHGuestExecResult = await withCheckedContinuation { continuation in
            ISHGuest.shared.execRequest(request, chunkBlock: nil, lineBlock: nil) { result in
                continuation.resume(returning: result)
            }
        }
        report["fenceBadCwd"] = [
            "exitCode": result.exitCode,
            "stdout": result.standardOutput,
            "launchError": result.launchError ?? "",
        ] as [String: Any]
        report["fenceBadCwdRefused"] = !result.standardOutput.contains("ran-in-") && result.launchError != nil
        write()
    }

    private func runDieTest() async {
        let guest = ISHGuest.shared

        // Establish that commands work *before* the fault, so a later failure is
        // attributable to the fault and not to the guest never having booted.
        await runSimple("echo before-die")

        // Trip die(). This parks a guest thread inside the replacement handler;
        // the app must keep running, which the command after it proves.
        _ = guest.triggerKernelDieForTesting()
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        // If the handler had returned, log.c's abort() would already have killed
        // the app and nothing below would run.
        await runSimple("echo after-die")
        await runSimple("uname -m")

        report["dieLog"] = ISHGuestLog.shared.lines().filter { $0.contains("die()") }
        write()
    }

    private func write() {
        guard let data = try? JSONSerialization.data(withJSONObject: report,
                                                    options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: reportURL, options: .atomic)
    }

    /// Write to the app container so the host-side script can read the result
    /// without scraping logs.
    var reportPath: String { reportURL.path }

    static let cpOverwriteScript = """
    set -e
    cd /root/workspace
    rm -rf cptest && mkdir -p cptest && cd cptest
    head -c 3000000 /dev/urandom > big.bin
    cp big.bin big.copy
    # The acceptance case: copying onto a file that already exists. Before the
    # O_DIRECTORY_ fix, GNU cp probes the destination with O_PATH|O_DIRECTORY,
    # the probe wrongly succeeded on a regular file, and cp tried to write
    # dst/src instead of dst -- failing with "Not a directory".
    cp big.bin big.copy
    cmp big.bin big.copy
    echo "CP-OVERWRITE-OK bytes=$(wc -c < big.copy)"
    """

    static let cpArchiveScript = """
    set -e
    cd /root/workspace
    rm -rf src dst && mkdir -p src/sub dst
    echo one > src/a.txt
    echo two > src/sub/b.txt
    ln -s a.txt src/link.txt
    # cp -a preserves mode/timestamps and stats the source; before the st_dev
    # fix, stat(path) and fstat(fd) disagreed on the device number and coreutils
    # read that as "replaced while being copied".
    cp -a src dst/
    test -f dst/src/sub/b.txt
    echo "CP-ARCHIVE-OK"
    """
}
