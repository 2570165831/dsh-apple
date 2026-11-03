//
//  ResetRunner.swift
//  DSHPortC
//
//  The reset's executor, and the one operation in this step that deletes.
//
//  WHY THE EXECUTOR IS SWIFT AND RUNS BEFORE `node_start`
//  ------------------------------------------------------
//  `sim/reset-plan.mjs` plans; it never moves anything. The move has to happen in
//  this process, at the very start of the next launch, and BEFORE
//  `prepareFilesystem()`: the profile and the sessions directory have to be
//  re-created by that method AFTER the old ones are gone, and the other order
//  would have this code deleting what it just built.
//
//  WHY TWO PHASES
//  --------------
//  `rename` per entry is atomic, but a run of renames is not. `in-progress.json`
//  is written before the first one and updated as they land, so a reset that is
//  killed half way — a force quit, a battery, a crash — is finished by the next
//  launch instead of leaving the app between two states. Both "already moved" and
//  "not moved yet" are recoverable: `rename` is idempotent, and an entry that is
//  nowhere is recorded rather than invented.
//
//  A move that FAILS is treated like a kill half way: `in-progress.json` and the
//  request stay, the launch is reported as failed (see `Outcome`), and the next
//  launch finishes the rest. Only a reset whose every entry is accounted for and
//  whose `complete.json` is on disk removes its records — otherwise the one
//  record that says what is still to move is gone and the app starts on a mix
//  of old and new data.
//
//  THE ONE DELETE
//  --------------
//  `purgeStaging()` empties `reset-staging/`. It is only reachable from the reset
//  panel's own button, after a confirmation that states the size, and nothing
//  calls it automatically. That is the whole difference between this and the
//  "keep it until the user says so" rule the plan states: the staged data
//  contains credentials and conversations, so it cannot be left to grow forever,
//  and it must not be removed by the app on its own.
//

import Foundation

enum ResetRunner {

    /// The stamp directory this reset is moving into.
    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: Date())
    }

    /// The container root every relative path is resolved against.
    ///
    /// `Library/Application Support/DSHPortC` is three levels below it
    /// (`Library/Application Support/DSHPortC` → `Library/Application Support` →
    /// `Library` → container), which is why this is `deletingLastPathComponent()`
    /// three times rather than a hard-coded `Documents/..`.
    static var containerRoot: URL {
        RuntimePaths.supportDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    // MARK: - The request

    /// Write the request the next launch executes, then quit.
    ///
    /// The request names the two switches and nothing else: which paths that
    /// means is decided in one place (`reset-plan.mjs`), and re-deriving it here
    /// is how the panel and the executor would come to disagree.
    ///
    /// `exit(0)` rather than an in-process move: DSH's session store and its
    /// storage files are open by the time the panel can be reached, and moving
    /// directories out from under an open store is not something to try. iOS has
    /// no public "restart me" API, so the sequence is: write the request, exit,
    /// the user taps the icon.
    static func requestReset(keepConversations: Bool, keepSettings: Bool) {
        let payload: [String: Any] = [
            "version": 1,
            "keepConversations": keepConversations,
            "keepSettings": keepSettings,
            "requestedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: RuntimePaths.resetRequestFile, options: .atomic)
        } catch {
            NSLog("dshportc: could not write reset-request.json: %@", "\(error)")
            return
        }
        NSLog("dshportc: reset requested (keepConversations=%d keepSettings=%d); exiting",
              keepConversations ? 1 : 0, keepSettings ? 1 : 0)
        // A beat for the log write to reach the disk before the process goes.
        Thread.sleep(forTimeInterval: 0.2)
        exit(0)
    }

    // MARK: - Outcome

    /// What a reset step tells `begin()`.
    ///
    /// `ok == false` means this launch must stop before `prepareFilesystem()`:
    /// either the container is between two states (some entries moved, some
    /// not), or a request was refused. Starting DSH on top of a half reset is how
    /// old and new data end up mixed, and a launch that says "reset applied" when
    /// it was not is how the retry record gets thrown away.
    struct Outcome {
        let ok: Bool
        /// One line for the boot log.
        let note: String
        /// The sentence for the failure screen; empty when `ok`.
        let reason: String
    }

    private static func failure(note: String, reason: String) -> Outcome {
        NSLog("dshportc: %@", note)
        return Outcome(ok: false, note: note, reason: reason)
    }

    private static var inProgressFile: URL {
        RuntimePaths.resetStagingDirectory.appendingPathComponent("in-progress.json")
    }

    private static var completeFile: URL {
        RuntimePaths.resetStagingDirectory.appendingPathComponent("complete.json")
    }

    // MARK: - Path checks

    /// The directories, relative to the container, a reset may take entries out of.
    ///
    /// An entry has to be strictly BELOW one of these. The executor gets its list
    /// from the built-in table or from a file on disk (`in-progress.json`), and
    /// neither is a reason to trust a path that would move DSH_HOME itself, the
    /// app's own support directory (and `reset-staging/` with it), or anything
    /// outside the app's own data — `Documents/workspace` above all.
    private static let allowedParents = [
        "Library/Application Support/DSH",
        "Library/Application Support/DSHPortC",
        "Library/Caches",
    ]

    /// Entries that may be moved as a whole: the guest image's own directory.
    private static let allowedWhole = [ResetTable.guest]

    /// Below an allowed parent, but never something a reset moves: the staging
    /// area is where things go, and the request is the reset's own input.
    private static let forbidden = [
        "Library/Application Support/DSHPortC/reset-staging",
        "Library/Application Support/DSHPortC/reset-request.json",
    ]

    /// Why `relative` cannot be moved, or nil when it can.
    ///
    /// The same rules `computeResetPlan()` in `sim/reset-plan.mjs` applies to its
    /// preview, applied again here because this is the code that actually moves:
    /// a preview that was checked is no guarantee about the list being executed.
    private static func pathProblem(_ relative: String) -> String? {
        if relative.isEmpty || relative.hasPrefix("/") || relative.hasSuffix("/")
            || relative.contains("\\") || relative.contains("\u{0}") {
            return "\(relative): not a container-relative path"
        }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        if parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
            return "\(relative): contains an empty, '.' or '..' component"
        }
        let inside = allowedWhole.contains(relative)
            || allowedParents.contains { relative.hasPrefix($0 + "/") }
        if !inside {
            return "\(relative): not strictly inside DSH_HOME, the app's support directory or Library/Caches"
        }
        if forbidden.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) {
            return "\(relative): the reset's own staging area or request"
        }
        return nil
    }

    /// The first component of `relative`, walking down from `root`, that is a
    /// symbolic link — including the last one — or nil.
    ///
    /// `lstat`, not `fileExists`: the latter follows links, which is exactly what
    /// would let a link inside the container carry a move to somewhere outside
    /// it. The walk stops at the first component that does not exist, because
    /// nothing below it can be followed either.
    private static func symlinkOnPath(root: URL, relative: String) -> String? {
        var current = root.path
        var walked: [String] = []
        for part in relative.split(separator: "/") {
            let name = String(part)
            current += "/" + name
            walked.append(name)
            var info = stat()
            if lstat(current, &info) != 0 { return nil }
            if (info.st_mode & S_IFMT) == S_IFLNK { return walked.joined(separator: "/") }
        }
        return nil
    }

    /// A stamp is one directory name this code wrote. Anything else read back
    /// from `in-progress.json` would steer the destination somewhere else.
    private static func isValidStamp(_ stamp: String) -> Bool {
        !stamp.isEmpty && stamp.count <= 64
            && stamp.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Check every source and destination BEFORE the first move, and refuse the
    /// whole list on the first problem. All-or-nothing on purpose: a list with
    /// one bad path is a list nobody can vouch for, and refusing after some
    /// entries already moved would create the half state this file exists to
    /// avoid.
    ///
    /// Symbolic links are refused rather than skipped (the preview skips them
    /// with a warning): a skipped entry would stay in place while its siblings
    /// move, which is old and new data side by side again.
    ///
    /// @returns nil, or the first problem found.
    private static func checkPlan(root: URL, stampDirectory: URL, entries: [String]) -> String? {
        let rootPath = root.path
        let stampPath = stampDirectory.path
        guard rootPath.count > 1, stampPath.hasPrefix(rootPath + "/") else {
            return "the staging directory \(stampPath) is not inside the container \(rootPath)"
        }
        let stampRelative = String(stampPath.dropFirst(rootPath.count + 1))
        if let link = symlinkOnPath(root: root, relative: stampRelative) {
            return "\(link) is a symbolic link"
        }
        for relative in entries {
            if let problem = pathProblem(relative) { return problem }
            if let link = symlinkOnPath(root: root, relative: relative) {
                return "\(link) is a symbolic link"
            }
            if let link = symlinkOnPath(root: root, relative: stampRelative + "/" + relative) {
                return "\(link) is a symbolic link"
            }
        }
        return nil
    }

    // MARK: - Small helpers

    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static func moveEntry(_ source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: source, to: destination)
    }

    /// What ties an `in-progress.json` to the request that started it.
    ///
    /// The request is only removed once its reset is complete, so the record has
    /// to say WHICH request it came from: by the time an interrupted reset is
    /// finished, the user may have written a newer one from the failure screen,
    /// and that one must survive.
    private static func requestIdentity(_ object: [String: Any]) -> String {
        let keepConversations = object["keepConversations"] as? Bool ?? true
        let keepSettings = object["keepSettings"] as? Bool ?? true
        let requestedAt = object["requestedAt"] as? String ?? ""
        return "\(requestedAt)|\(keepConversations)|\(keepSettings)"
    }

    /// Take a refused request out of the way, without deleting it.
    ///
    /// A refusal is deterministic — the same request would be refused on every
    /// launch — so leaving it in place would fail every launch from here on. It
    /// is renamed, not removed, so the diagnostics bundle can still show it.
    private static func setAsideRequest() {
        let requestFile = RuntimePaths.resetRequestFile
        let refused = requestFile.deletingLastPathComponent().appendingPathComponent("reset-request.refused.json")
        try? FileManager.default.removeItem(at: refused)
        do {
            try FileManager.default.moveItem(at: requestFile, to: refused)
        } catch {
            NSLog("dshportc: could not set the refused reset request aside: %@", "\(error)")
        }
    }

    private static func writeResult(_ result: [String: Any]) {
        var record = result
        record["at"] = ISO8601DateFormatter().string(from: Date())
        try? writeJSON(record, to: RuntimePaths.resetResultFile)
    }

    /// Close a reset whose every entry is accounted for.
    ///
    /// ORDER MATTERS. `complete.json` first: until it is on disk, the only record
    /// of this reset is `in-progress.json`, so that is the last thing to go. The
    /// request goes BEFORE `in-progress.json`: a launch killed between the two
    /// then finds an in-progress record whose entries are all moved (finishing it
    /// again is a no-op), whereas the other order would leave a request with no
    /// record and run the whole reset a second time.
    ///
    /// @returns nil, or what could not be done (`in-progress.json` is then still
    ///          there and the next launch finishes the close).
    private static func finalize(record: [String: Any], complete: [String: Any]) -> String? {
        do {
            try writeJSON(complete, to: completeFile)
        } catch {
            return "could not write complete.json: \(error)"
        }
        if let identity = record["requestIdentity"] as? String {
            let requestFile = RuntimePaths.resetRequestFile
            if let data = try? Data(contentsOf: requestFile),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               requestIdentity(object) == identity {
                do {
                    try FileManager.default.removeItem(at: requestFile)
                } catch {
                    return "could not remove reset-request.json: \(error)"
                }
            }
        }
        do {
            try FileManager.default.removeItem(at: inProgressFile)
        } catch {
            return "could not remove in-progress.json: \(error)"
        }
        return nil
    }

    /// The failure-screen sentence for a reset that stopped part way.
    private static func partialReason(failed: [String], both: [String]) -> String {
        var parts: [String] = []
        if !failed.isEmpty {
            parts.append("有 \(failed.count) 项没能移到暂存目录（\(shortList(failed))）")
        }
        if !both.isEmpty {
            parts.append("有 \(both.count) 项在原位置和暂存目录里同时存在（\(shortList(both))），App 不会替你挑一份删掉")
        }
        return "重置没有做完：" + parts.joined(separator: "；")
            + "。为了不让新旧数据混在一起，这次没有继续启动。已经移走的部分记录在 reset-staging/in-progress.json，"
            + "重新打开 App 会接着做剩下的；也可以先看日志或导出诊断包。"
    }

    private static func shortList(_ items: [String]) -> String {
        let shown = items.prefix(3).joined(separator: "、")
        return items.count > 3 ? shown + " 等" : shown
    }

    // MARK: - Finishing an interrupted reset

    /// Complete a reset that a previous launch started and did not finish.
    ///
    /// Called before anything else in `begin()`, because until it runs the app is
    /// between two states and `prepareFilesystem()` would build on top of both.
    ///
    /// `in-progress.json` is removed only when every entry is accounted for —
    /// moved now, already in staging, or in neither place — AND `complete.json`
    /// is on disk. Any entry that still cannot move, or that is on both sides,
    /// leaves the record in place for the next launch and fails this one.
    ///
    /// @returns nil when there was nothing to do.
    @discardableResult
    static func finishInterruptedIfAny() -> Outcome? {
        let root = containerRoot
        let staging = RuntimePaths.resetStagingDirectory
        let inProgress = inProgressFile
        guard FileManager.default.fileExists(atPath: inProgress.path) else { return nil }
        guard let data = try? Data(contentsOf: inProgress),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stamp = record["stamp"] as? String,
              let entries = record["entries"] as? [String] else {
            // A record that is there but cannot be read is still a reset that did
            // not finish; carrying on as if there were none is the bug.
            return failure(
                note: "reset resume refused: in-progress.json is unreadable",
                reason: "上次重置的进度记录（reset-staging/in-progress.json）无法读取，不知道哪些数据已经移走，"
                    + "这次没有继续启动。可以导出诊断包；在重置面板清除暂存数据会连同这份记录一起删掉。"
            )
        }
        let stampDirectory = staging.appendingPathComponent(stamp)
        let refusal = isValidStamp(stamp)
            ? checkPlan(root: root, stampDirectory: stampDirectory, entries: entries)
            : "stamp \(stamp) is not a plain directory name"
        if let problem = refusal {
            return failure(
                note: "reset resume refused: \(problem)",
                reason: "上次重置的进度记录里有路径没有通过检查（\(problem)），这次什么都没有移动，也没有继续启动。"
                    + "可以导出诊断包查看。"
            )
        }

        var moved = 0
        var done: [String] = []
        var absent: [String] = []
        var both: [String] = []
        var failed: [String] = []
        for relative in entries {
            let source = root.appendingPathComponent(relative)
            let destination = stampDirectory.appendingPathComponent(relative)
            let sourceThere = FileManager.default.fileExists(atPath: source.path)
            let destinationThere = FileManager.default.fileExists(atPath: destination.path)
            if !sourceThere && !destinationThere {
                // Neither place: nothing to do and nothing to guess about. It is
                // recorded by `complete.json` rather than silently forgotten.
                absent.append(relative)
                continue
            }
            if sourceThere && destinationThere {
                // Cannot happen through `rename`, which is atomic. Left alone and
                // reported: the alternative is choosing one to delete.
                both.append(relative)
                continue
            }
            if !sourceThere {
                done.append(relative)
                continue
            }
            do {
                try moveEntry(source, to: destination)
                moved += 1
                done.append(relative)
            } catch {
                failed.append(relative)
                NSLog("dshportc: reset resume could not move %@: %@", relative, "\(error)")
            }
        }

        let now = ISO8601DateFormatter().string(from: Date())
        if !failed.isEmpty || !both.isEmpty {
            var updated = record
            updated["done"] = done
            updated["moved"] = done.count
            updated["failed"] = failed
            updated["bothSides"] = both
            updated["absent"] = absent
            updated["lastAttemptAt"] = now
            try? writeJSON(updated, to: inProgress)
            return failure(
                note: "reset resume incomplete: \(moved) moved now, \(failed.count) failed, "
                    + "\(both.count) present on BOTH sides; in-progress.json kept",
                reason: partialReason(failed: failed, both: both)
            )
        }

        var complete: [String: Any] = [
            "version": 1,
            "stamp": stamp,
            "entries": entries,
            "absent": absent,
            "resumed": true,
            "completedAt": now,
        ]
        complete["moved"] = done.count
        if let problem = finalize(record: record, complete: complete) {
            return failure(
                note: "reset resume could not close: \(problem)",
                reason: "上次重置的数据都已移走，但收尾记录没能写好（\(problem)），这次没有继续启动。重新打开 App 会补上。"
            )
        }
        let note = "reset resumed: \(moved) entr(ies) moved"
        NSLog("dshportc: %@", note)
        return Outcome(ok: true, note: note, reason: "")
    }

    // MARK: - Executing a fresh request

    /// Run the reset the user asked for, if there is one.
    ///
    /// Every entry has to move (or be absent) and `complete.json` has to land
    /// before the request and `in-progress.json` are removed. One failed move
    /// keeps both, records which entries did move, and fails this launch; the
    /// next launch's `finishInterruptedIfAny()` finishes the rest, with the same
    /// stamp, instead of this function starting a second reset on top.
    ///
    /// @returns nil when there was no request.
    @discardableResult
    static func applyPendingIfAny() -> Outcome? {
        let requestFile = RuntimePaths.resetRequestFile
        guard let data = try? Data(contentsOf: requestFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let keepConversations = object["keepConversations"] as? Bool ?? true
        let keepSettings = object["keepSettings"] as? Bool ?? true
        let inProgress = inProgressFile

        // An earlier reset that is not finished holds every new request back:
        // a second reset on a container that is already between two states would
        // move freshly re-created directories next to half-moved old ones.
        if FileManager.default.fileExists(atPath: inProgress.path) {
            return failure(
                note: "reset request held: an earlier reset is still unfinished",
                reason: "上一次重置还没有做完，新的重置请求先不执行，这次也没有继续启动。重新打开 App 会先接着做上一次的。"
            )
        }

        // The list of paths is READ BEFORE ANYTHING MOVES. `boot/reset-plan.json`
        // is one of the paths in the list, so an executor that consulted it entry
        // by entry would move it with the first few entries and then have nothing
        // left to read. That is why `reset-plan.json` and `boot/` are in the move
        // set together: the plan has to be in memory before its own file goes.
        let combos = ResetSheet.builtinCombos()
        let key = "\(keepConversations ? "keep" : "drop")-conversations+"
            + "\(keepSettings ? "keep" : "drop")-settings"
        guard let combo = combos[key] else {
            setAsideRequest()
            writeResult(["ok": false, "refused": "unknown combination \(key)"])
            return failure(
                note: "reset refused: unknown combination \(key)",
                reason: "重置请求无法识别（\(key)），什么都没有移动，这次没有继续启动。重新打开 App 会照常启动。"
            )
        }
        let entries = combo.move

        let root = containerRoot
        let stamp = stamp()
        let staging = RuntimePaths.resetStagingDirectory.appendingPathComponent(stamp)
        if let problem = checkPlan(root: root, stampDirectory: staging, entries: entries) {
            setAsideRequest()
            writeResult(["ok": false, "refused": problem, "stamp": stamp])
            return failure(
                note: "reset refused: \(problem)",
                reason: "重置被拒绝：要移动的路径没有通过检查（\(problem)）。什么都没有移动，这次没有继续启动；"
                    + "重新打开 App 会照常启动。"
            )
        }

        var record: [String: Any] = [
            "version": 1,
            "stamp": stamp,
            "entries": entries,
            "keepConversations": keepConversations,
            "keepSettings": keepSettings,
            "requestIdentity": requestIdentity(object),
            "startedAt": ISO8601DateFormatter().string(from: Date()),
            "moved": 0,
            "done": [String](),
        ]
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try writeJSON(record, to: inProgress)
        } catch {
            // Nothing has moved, so the request stays: the next launch tries again.
            return failure(
                note: "reset could not start: \(error)",
                reason: "重置没能开始（\(error.localizedDescription)），什么都没有移动，这次没有继续启动。重新打开 App 会再试一次。"
            )
        }

        var done: [String] = []
        var missing: [String] = []
        var failed: [String] = []
        for relative in entries {
            let source = root.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: source.path) else {
                missing.append(relative)
                continue
            }
            let destination = staging.appendingPathComponent(relative)
            do {
                try moveEntry(source, to: destination)
                done.append(relative)
                // Best effort: the resume path decides from the filesystem, not
                // from this list, so a lost update costs nothing but the record.
                record["done"] = done
                record["moved"] = done.count
                try? writeJSON(record, to: inProgress)
            } catch {
                failed.append(relative)
                NSLog("dshportc: reset could not move %@: %@", relative, "\(error)")
            }
        }

        let summary: [String: Any] = [
            "stamp": stamp,
            "moved": done.count,
            "missing": missing.count,
            "failed": failed,
            "keepConversations": keepConversations,
            "keepSettings": keepSettings,
        ]

        if !failed.isEmpty {
            record["done"] = done
            record["moved"] = done.count
            record["failed"] = failed
            record["absent"] = missing
            record["lastAttemptAt"] = ISO8601DateFormatter().string(from: Date())
            try? writeJSON(record, to: inProgress)
            var result = summary
            result["ok"] = false
            writeResult(result)
            return failure(
                note: "reset incomplete: \(done.count) moved, \(missing.count) absent, "
                    + "\(failed.count) failed; in-progress.json kept",
                reason: partialReason(failed: failed, both: [])
            )
        }

        let complete: [String: Any] = [
            "version": 1,
            "stamp": stamp,
            "entries": entries,
            "moved": done.count,
            "missing": missing,
            "failed": [String](),
            "completedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let problem = finalize(record: record, complete: complete) {
            var result = summary
            result["ok"] = false
            result["closeError"] = problem
            writeResult(result)
            return failure(
                note: "reset could not close: \(problem)",
                reason: "重置的数据都已移走，但收尾记录没能写好（\(problem)），这次没有继续启动。重新打开 App 会补上。"
            )
        }
        var result = summary
        result["ok"] = true
        writeResult(result)
        let note = "reset applied: \(done.count) moved, \(missing.count) absent, 0 failed"
        NSLog("dshportc: %@", note)
        return Outcome(ok: true, note: note, reason: "")
    }

    // MARK: - The one delete

    /// Total bytes held by everything under `reset-staging/`.
    ///
    /// Shown before the purge button is enabled, because "clear the leftover"
    /// without a size is a button nobody can price. Walks the tree once; the
    /// staged data is a few hundred megabytes at most and the panel is user-
    /// initiated, so there is no need for a cached figure that could be stale.
    static func stagingSize() -> Int64 {
        let root = RuntimePaths.resetStagingDirectory
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
            ), values.isRegularFile == true else { continue }
            let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
            total += Int64(size)
        }
        return total
    }

    /// Delete everything under `reset-staging/`, keeping the directory itself.
    ///
    /// Only ever called from the reset panel's confirmed button.
    ///
    /// @returns the sentence shown under the button.
    static func purgeStaging() -> String {
        let root = RuntimePaths.resetStagingDirectory
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else {
            return "暂存目录不存在，没有需要删除的数据"
        }
        var removed = 0
        var failed: [String] = []
        for name in names {
            do {
                try fileManager.removeItem(at: root.appendingPathComponent(name))
                removed += 1
            } catch {
                failed.append(name)
                NSLog("dshportc: purge staging could not remove %@: %@", name, "\(error)")
            }
        }
        if failed.isEmpty {
            return "已清除上次重置留下的 \(removed) 项数据"
        }
        return "已清除 \(removed) 项，另有 \(failed.count) 项无法删除：\(failed.joined(separator: "、"))"
    }
}
