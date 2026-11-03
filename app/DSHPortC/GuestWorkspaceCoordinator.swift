//
//  GuestWorkspaceCoordinator.swift
//  DSHPortC
//
//  Wires the three things step 3 and step 4 need into one ordered sequence:
//
//    1. boot the guest kernel
//    2. bind-mount the app's Documents/workspace into the guest at /workspace
//    3. start the loopback channel and publish its URL + token to Node
//    4. start Node, which is the first thing that can use the channel
//
//  The order is not negotiable. A bind mount needs a mounted fakefs (the kernel
//  refuses with ENODEV before that), and the channel's `/v1/exec` needs a booted
//  guest. Starting Node first would mean the profile's tool plugins could call a
//  channel that is not listening, and the failure would surface as a tool error
//  rather than as a boot error.
//
//  WHY THIS IS NOW THE DEFAULT (step 5 changed it): the profile's `subprocess`
//  provider is `plugins/dsh-subprocess-ish`, which runs every bash command in
//  this guest. Node cannot start without the channel's URL and token, so the
//  guest is no longer optional — a profile that needs a shell needs this boot.
//  The provider refuses to mount without a channel rather than turning the
//  first tool call into a socket error, so the failure mode of getting this
//  wrong is a loud boot error, not a mystery.
//
//  It can still be turned OFF for measurement: `DSHPORTE_GUEST_CHANNEL=0`
//  suppresses the boot. That is what the step-1 and step-2 regression runs use,
//  because their subject is the web surface and the channel respectively, and a
//  kernel boot inside the cold-start window would confound the number.
//

import Foundation

final class GuestWorkspaceCoordinator {
    static let shared = GuestWorkspaceCoordinator()

    /// Where the app's workspace lives inside the guest.
    static let guestWorkspacePath = "/workspace"

    /// Where the host's per-app temporary directory is mounted inside the guest.
    ///
    /// WHY A SECOND MOUNT EXISTS. `dsh-workspace-changes` builds its snapshot
    /// object store from the HOST's `tmpdir()` and then hands that path to the
    /// GUEST's git as `GIT_OBJECT_DIRECTORY` / `GIT_INDEX_FILE`
    /// (lib/index.js:782 with :1042, used at :283-292). Host and guest do not
    /// share a path namespace, so without a mount the guest cannot see that
    /// directory at all: `git add` fails, no snapshot is taken, and the plugin
    /// appends no `workspace/changes` event — the changed-files card simply never
    /// appears, with nothing in any log to say why.
    ///
    /// Mounting the temp root rather than patching the plugin keeps the "plugins
    /// are the integration point" rule intact: the DSH side stays unmodified and
    /// the routing decision lives where the two worlds meet.
    static let guestTemporaryPath = "/tmp"

    private(set) var started = false
    private(set) var channelURL: String?
    private(set) var workspaceGuestPath: String?
    private(set) var workspaceHostPath: String?
    private(set) var temporaryGuestPath: String?
    private(set) var temporaryHostPath: String?

    /// Whether this launch should bring the guest up before Node.
    ///
    /// ON by default since step 5: the subprocess provider needs the channel,
    /// and a profile whose only shell runs in the guest cannot boot without it.
    /// Turn it off explicitly with `DSHPORTE_GUEST_CHANNEL=0` (the regression
    /// runs do that to keep the measurement honest about what it measured).
    static var isEnabled: Bool {
        let value = (ProcessInfo.processInfo.environment["DSHPORTE_GUEST_CHANNEL"] ?? "").lowercased()
        if value == "0" || value == "false" || value == "no" { return false }
        // A launch argument can still force it on for a UI test that does not
        // control the environment.
        if UserDefaults.standard.integer(forKey: "DSHPortEGuestChannel") == 1 { return true }
        return true
    }

    private let workspace: URL = NodeRunner.shared.workspace

    /// The host's per-app temporary directory, which is what `os.tmpdir()`
    /// reports to Node and therefore what a plugin building a scratch path will
    /// name. Resolved symlinks so the spelling matches what Node sees.
    var hostTemporaryPath: String {
        let raw = NSTemporaryDirectory()
        var directory = URL(fileURLWithPath: raw).standardizedFileURL
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // `realpath(3)`, not `resolvingSymlinksInPath()`: the latter strips the
        // `/private` prefix, so `TMPDIR` would be published to Node in a spelling
        // that Node's own `os.tmpdir()` (and therefore
        // `dsh-workspace-changes`'s scratch path) never produces. See the longer
        // note in NodeRunner.sanitized().
        if let resolved = NodeRunner.realPath(directory.path) {
            directory = URL(fileURLWithPath: resolved, isDirectory: true)
        } else {
            directory = directory.resolvingSymlinksInPath()
        }
        // Node's `os.tmpdir()` keeps the trailing slash that TMPDIR has; the
        // mount point must not, or every path built from it would have a double
        // slash and compare unequal to what the plugin produced.
        return directory.path.hasSuffix("/") ? String(directory.path.dropLast()) : directory.path
    }

    /// The whole sequence. Completion arrives on the main queue.
    ///
    /// Failures are reported but never fatal: the web UI must still come up, and
    /// a guest that could not boot is exactly the sort of thing the app should
    /// say out loud rather than die on. `NodeRunner` records the outcome in the
    /// status JSON either way.
    func startIfEnabled(completion: @escaping (Bool) -> Void) {
        guard Self.isEnabled else { completion(false); return }
        guard !started else { completion(true); return }
        started = true

        NodeRunner.shared.noteGuestPhasing("guest: booting")

        ISHGuest.shared.boot { [weak self] bootError in
            guard let self else { return }
            if let bootError {
                NodeRunner.shared.noteGuestFailure("guest boot failed: \(bootError.localizedDescription)")
                completion(false)
                return
            }

            NodeRunner.shared.noteGuestPhasing(
                "guest: kernel booted in \(String(format: "%.3f", ISHGuest.shared.bootSeconds)) s; binding workspace"
            )

            // The kernel stats() the host path itself and refuses a bind mount
            // whose host path is missing, so the directory has to exist first.
            // NodeRunner creates it in `prepareFilesystem()`, which runs *after*
            // this sequence, so it does not exist yet on a cold container.
            do {
                try FileManager.default.createDirectory(at: self.workspace,
                                                        withIntermediateDirectories: true)
            } catch {
                NodeRunner.shared.noteGuestFailure(
                    "could not create the workspace directory: \(error.localizedDescription)"
                )
                self.startChannel(completion: completion)
                return
            }

            ISHGuest.shared.bindMountGuestPath(
                Self.guestWorkspacePath,
                hostPath: self.workspace.path,
                readWrite: true
            ) { bindError in
                if let bindError {
                    // The channel is still useful without a shared workspace
                    // (a command can run anywhere in the fakefs), so this is
                    // recorded and the sequence continues.
                    NodeRunner.shared.noteGuestFailure(
                        "workspace bind mount failed: \(bindError.localizedDescription)"
                    )
                    self.startChannel(completion: completion)
                    return
                }
                self.workspaceGuestPath = Self.guestWorkspacePath
                self.workspaceHostPath = self.workspace.path

                // The temporary directory, for the reason in `guestTemporaryPath`.
                // Non-fatal: without it the changed-files card cannot work, but
                // bash still does.
                //
                // `DSHPORTE_GUEST_TMP_MOUNT=0` suppresses it, which exists so the
                // mount can be A/B tested against the web UI: this is a mount
                // over a path the emulated kernel also uses for itself, and a
                // change there deserves the ability to be ruled out by
                // measurement rather than by argument.
                if (ProcessInfo.processInfo.environment["DSHPORTE_GUEST_TMP_MOUNT"] == "0") {
                    self.startChannel(completion: completion)
                    return
                }
                ISHGuest.shared.bindMountGuestPath(
                    Self.guestTemporaryPath,
                    hostPath: self.hostTemporaryPath,
                    readWrite: true
                ) { tempError in
                    if let tempError {
                        NodeRunner.shared.noteGuestFailure(
                            "temporary directory bind mount failed: \(tempError.localizedDescription)"
                        )
                    } else {
                        self.temporaryGuestPath = Self.guestTemporaryPath
                        self.temporaryHostPath = self.hostTemporaryPath
                    }
                    self.startChannel(completion: completion)
                }
            }
        }
    }

    /// Start the listener and report whether the whole sequence came up.
    private func startChannel(completion: @escaping (Bool) -> Void) {
        ISHGuestChannel.shared.start { channelError in
            if let channelError {
                NodeRunner.shared.noteGuestFailure(
                    "channel failed to start: \(channelError.localizedDescription)"
                )
                completion(false)
                return
            }

            let channel = ISHGuestChannel.shared
            self.channelURL = "http://127.0.0.1:\(channel.port)"
            NodeRunner.shared.noteGuestPhasing(
                "guest: channel listening on port \(channel.port)"
                + (self.workspaceGuestPath != nil ? ", /workspace is shared" : "")
                + (self.temporaryGuestPath != nil ? ", /tmp is shared" : "")
            )
            completion(true)
        }
    }
}
