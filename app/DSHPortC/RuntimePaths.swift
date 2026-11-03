//
//  RuntimePaths.swift
//  DSHPortC
//
//  Where the app's own housekeeping files live, and why they are not in
//  `Documents/`.
//
//  WHY THIS FILE EXISTS
//  --------------------
//  `Info.plist` has had `UIFileSharingEnabled` and
//  `LSSupportsOpeningDocumentsInPlace` on since the first scaffold, so the
//  system Files app shows this container's `Documents/` to the user. That is
//  wanted: it is how the workspace becomes reachable from Files, and how a file
//  the user drops there becomes reachable by the agent and by the guest.
//
//  What was NOT wanted is everything else that used to sit beside it:
//
//    * `DSHPortC-status.json` — boot phase, node paths, diagnostics. Noise in a
//      file browser, and nothing a user should ever have to look at.
//    * `DSHPortC-node.log`   — the whole boot transcript.
//    * `DSHPortC-session-url.txt` — THE ONE THAT MATTERS. It holds DSH's
//      per-launch authenticated URL verbatim, i.e. a live bearer token, in a
//      file the Files app will happily show, copy, AirDrop or hand to another
//      app. Nothing in this app should ever put a credential in a
//      user-browsable directory.
//
//  So the three move to `Library/Application Support/DSHPortC/`. That directory
//  is inside the app container, is not exposed by file sharing, and is not
//  reachable from the Files app at all. `Library/Application Support/DSH` — the
//  DSH home, with the sessions and the profile — is its sibling and stays
//  exactly where it is.
//
//  WHY `Library/Application Support` AND NOT `Library/Caches` OR `tmp`:
//  the log and the status file are how a host-side script observes a run, and
//  the session URL has to survive until the next launch replaces it. Caches and
//  tmp are things the system may purge; neither of those is acceptable for
//  evidence. Application Support is backed up and not purged, which matches
//  "kept for the life of the install, replaced on the next launch".
//
//  WHAT IS DELIBERATELY STILL IN `Documents/`
//  ------------------------------------------
//    * `workspace/` — the agent's working tree. That is the point.
//    * the probe files (`DSHPortE-*.json`, `DSHPortC-uidrive.json`,
//      `DSHPortE-power.jsonl`, …). They exist only in a launch that passed a
//      probe argument, they are read by a host-side script that copies them out
//      of the container, and several acceptance runs deliver their *inputs*
//      through this directory as well. Moving them would churn every probe for
//      no privacy gain: none of them carries a credential, and a normal launch
//      writes none of them at all.
//

import Foundation

enum RuntimePaths {

    /// The name of the app's own support directory, under Application Support.
    static let directoryName = "DSHPortC"

    /// `Library/Application Support/DSHPortC/`, created on demand.
    ///
    /// Not symlink-resolved: this path is only ever used by this process and by
    /// host scripts that read the container through `simctl`, which spells it
    /// `<container>/Library/Application Support/...` exactly like this. (The
    /// `/var` vs `/private/var` question from step 9 does not arise here: no
    /// path in this directory is ever compared against a path Node produced.)
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent(directoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    static var statusFile: URL { supportDirectory.appendingPathComponent("DSHPortC-status.json") }
    static var logFile: URL { supportDirectory.appendingPathComponent("DSHPortC-node.log") }
    static var sessionURLFile: URL { supportDirectory.appendingPathComponent("DSHPortC-session-url.txt") }

    // MARK: - Step 19: the boot guard's directory

    /// `Library/Application Support/DSHPortC/boot/`, created on demand.
    ///
    /// Everything the boot guard and the reset planner exchange lives here, for
    /// the same reason the three files above do: `Documents/` is visible in the
    /// Files app, and none of this is a user document. `boot/` is also one of the
    /// paths a reset moves wholesale, which is why the reset REQUEST is kept
    /// beside it rather than inside it — see `resetRequestFile`.
    static var bootDirectory: URL { directory(supportDirectory, "boot") }

    /// `Library/Application Support/DSHPortC/diagnostics/`.
    static var diagnosticsDirectory: URL { directory(supportDirectory, "diagnostics") }

    /// Where an interrupted reset's moved-aside data waits.
    ///
    /// Inside `supportDirectory` and NOT inside `boot/`: a reset moves `boot/`,
    /// and the record of what it moved cannot be one of the things it moves.
    static var resetStagingDirectory: URL { directory(supportDirectory, "reset-staging") }

    static var bootGuardFile: URL { bootDirectory.appendingPathComponent("boot-guard.json") }
    static var bootOutcomeFile: URL { bootDirectory.appendingPathComponent("boot-outcome.json") }
    static var bootRequestFile: URL { bootDirectory.appendingPathComponent("boot-request.json") }
    static var bootBackgroundFile: URL { bootDirectory.appendingPathComponent("boot-background.txt") }
    static var safeModeOverlayFile: URL { bootDirectory.appendingPathComponent("safe-mode.patch.yml") }
    static var resetPreviewFile: URL { bootDirectory.appendingPathComponent("reset-plan.json") }
    static var exportRequestFile: URL { bootDirectory.appendingPathComponent("export-request.json") }
    static var exportDoneFile: URL { bootDirectory.appendingPathComponent("export-done.json") }

    static var resetRequestFile: URL { supportDirectory.appendingPathComponent("reset-request.json") }
    static var resetResultFile: URL { supportDirectory.appendingPathComponent("reset-result.json") }

    /// The user layer Settings saves, and the two names safe mode uses for it.
    static func userPatchFile(_ profileDirectory: URL) -> URL {
        profileDirectory.appendingPathComponent("cordis.patch.yml")
    }

    static func parkedUserPatchFile(_ profileDirectory: URL) -> URL {
        userPatchFile(profileDirectory).appendingPathExtension("safe-mode-parked")
    }

    /// A child directory, created if it is missing.
    ///
    /// Split out so the eight computed properties above stay one line each and
    /// the "create on demand, ignore failure" behaviour is written once. A
    /// failure to create is not fatal here: the caller that needs the directory
    /// reports the real error when it tries to write (`NodeRunner.emit`), which
    /// names the operation that failed.
    private static func directory(_ parent: URL, _ name: String) -> URL {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// The names as they used to be written, directly into `Documents/`.
    ///
    /// Kept as a list rather than as three string literals at the call site so
    /// the removal below and anything that has to explain itself in a report
    /// use one definition.
    static let legacyDocumentFileNames = [
        "DSHPortC-status.json",
        "DSHPortC-node.log",
        "DSHPortC-session-url.txt",
    ]

    /// Remove the legacy copies from `Documents/`.
    ///
    /// This runs on EVERY launch, not only the first one after an upgrade.
    /// Idempotent and cheap (three `removeItem` calls on paths that normally do
    /// not exist), and it means a container that was written by an older build —
    /// including one that an acceptance script restored from a backup — can
    /// never leave the plaintext-token file behind through a launch path this
    /// code did not anticipate. A file that cannot be removed is reported, not
    /// swallowed: it is the one case where the user-visible directory still
    /// holds a credential, and the caller turns it into a log line.
    ///
    /// @returns the names that were present and could not be removed.
    @discardableResult
    static func removeLegacyDocumentFiles() -> [String] {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var failed: [String] = []
        for name in legacyDocumentFileNames {
            let path = documents.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            do {
                try FileManager.default.removeItem(at: path)
            } catch {
                failed.append("\(name) (\(error.localizedDescription))")
            }
        }
        return failed
    }
}
