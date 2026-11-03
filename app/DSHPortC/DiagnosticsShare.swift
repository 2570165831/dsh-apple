//
//  DiagnosticsShare.swift
//  DSHPortC
//
//  The "导出诊断包" button, end to end: ask Node, wait for its answer, share the
//  result — and, when Node is already dead, assemble the minimal package this
//  side can produce without it.
//
//  WHY THE NORMAL PATH ASKS NODE
//  -----------------------------
//  The bundle's contents are a whitelist and the redaction rules are a list of
//  named patterns, both in `sim/diagnostics.mjs`, both tested. Re-implementing
//  either here would mean two answers to "may this file leave the phone", which
//  is the one question in this step that must have exactly one answer.
//
//  WHY THERE IS A FALLBACK AT ALL
//  ------------------------------
//  The failure screen is where the button lives, and a launch can fail so early
//  (or so hard) that Node never reaches the 1-second poller. A button that only
//  works when the app is healthy would be missing exactly when it matters. The
//  fallback shares the same whitelist's already-written artefacts — the boot log
//  this process produced (redacted on the way out), the status file, and the last
//  snapshot Node did write — and says in the package that Node did not take part.
//  It reads no credential, no session, no `storages/`. Because Node's
//  `redactText()` cannot run here, every file goes through `redact(_:)` below,
//  a port of the same rules; keep the two lists in step when either changes.
//
//  WHAT IT NEVER DOES
//  ------------------
//  No `.zip`. What the share sheet gets is one text file holding every file of the
//  bundle: a folder is refused by most share targets, and sharing `SUMMARY.txt`
//  alone would send the list of contents without the contents.
//

import Foundation
import UIKit

enum DiagnosticsShare {

    /// How long the button waits for Node's answer before falling back.
    ///
    /// Node polls its request file once a second, and a bundle of a few hundred
    /// kilobytes takes well under a second to render, so three seconds covers a
    /// normal answer twice over. Longer would leave the button looking dead on
    /// the one screen where the user has already been waiting.
    static let waitTimeout: TimeInterval = 3

    /// Ask Node for a bundle, then share it; fall back to the local package.
    ///
    /// @param anchor the view the iPad popover points at.
    /// @param completion called with a one-line result for the log or the screen.
    static func export(anchor: UIView?, completion: @escaping (String) -> Void) {
        let id = UUID().uuidString
        let requested = request(id: id)
        guard requested else {
            let fallback = shareLocalBundle(anchor: anchor)
            completion(fallback)
            return
        }
        waitForAnswer(id: id, deadline: Date().addingTimeInterval(waitTimeout)) { answer in
            if let answer {
                let presented = ShareSheet.present(items: [singleFile(of: answer)], from: anchor)
                completion(presented
                    ? "诊断包已生成：\(answer.lastPathComponent)"
                    : "诊断包已生成，但分享面板没有打开：\(answer.lastPathComponent)")
                return
            }
            let fallback = shareLocalBundle(anchor: anchor)
            completion("Node 未应答，已导出最小诊断包。\(fallback)")
        }
    }

    /// Write `boot/export-request.json`.
    private static func request(id: String) -> Bool {
        let payload: [String: Any] = [
            "action": "export-diagnostics",
            "id": id,
            "at": ISO8601DateFormatter().string(from: Date()),
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: RuntimePaths.exportRequestFile, options: .atomic)
            return true
        } catch {
            NSLog("dshportc: could not write export-request.json: %@", "\(error)")
            return false
        }
    }

    /// Poll `boot/export-done.json` for the answer to `id`.
    ///
    /// Polling rather than a callback because Node is a different runtime in the
    /// same process: it has no way to call back into Swift, and the file is the
    /// one channel both sides already use for every other boot message.
    private static func waitForAnswer(
        id: String,
        deadline: Date,
        then handler: @escaping (URL?) -> Void
    ) {
        if Date() >= deadline {
            handler(nil)
            return
        }
        if let done = readDone(id: id) {
            handler(done)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            waitForAnswer(id: id, deadline: deadline, then: handler)
        }
    }

    private static func readDone(id: String) -> URL? {
        guard let data = try? Data(contentsOf: RuntimePaths.exportDoneFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["id"] as? String == id,
              let dir = object["dir"] as? String, !dir.isEmpty else { return nil }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The package this side can assemble with no Node running.
    ///
    /// Contents, and why each one is safe to hand to another app:
    ///   * `DSHPortC-node.log` — every line already passed through
    ///     `NodeRunner.redact`, which strips the launch token and everything
    ///     `ISHGuestChannel.redact` knows about.
    ///   * `DSHPortC-status.json` — phases, versions, error text. No token: the
    ///     URL is stored redacted.
    ///   * `boot-outcome.json` / `boot-guard.json` — this step's own records.
    ///   * from the newest `diagnostics/*` directory Node wrote, only
    ///     `SUMMARY.txt`, `manifest.json` and `files/NN-*`.
    ///
    /// Every one of them is read through `copyRedacted`: regular files only (a
    /// symbolic link is not followed), at most `maxFileBytes` from the end, and
    /// through `redact`, which mirrors `redactText()` in `sim/diagnostics.mjs`.
    /// The comments above say why each file *should* already be clean; this path
    /// runs exactly when something went wrong, so it does not rely on that.
    ///   * `SUMMARY.txt` — what is in the bundle, and the statement that Node did
    ///     not take part.
    ///
    /// Deliberately absent, and named as absent in the SUMMARY: `.credentials.yaml`,
    /// `storages/`, `sessions/`, `attachments/`, `events.jsonl`, `AGENTS.md`, the
    /// session URL file, and `Documents/workspace`.
    static func shareLocalBundle(anchor: UIView?) -> String {
        let fileManager = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let directory = RuntimePaths.diagnosticsDirectory
            .appendingPathComponent("\(stamp)-minimal", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return "无法创建诊断目录：\(error.localizedDescription)"
        }

        var copied: [String] = []
        var absent: [String] = []
        var budget = maxTotalBytes
        for (source, name) in [
            (RuntimePaths.logFile, "DSHPortC-node.log"),
            (RuntimePaths.statusFile, "DSHPortC-status.json"),
            (RuntimePaths.bootOutcomeFile, "boot-outcome.json"),
            (RuntimePaths.bootGuardFile, "boot-guard.json"),
            (RuntimePaths.safeModeOverlayFile, "safe-mode.patch.yml"),
        ] {
            switch copyRedacted(from: source, to: directory.appendingPathComponent(name), budget: &budget) {
            case .copied(let note):
                copied.append(note.isEmpty ? name : "\(name)（\(note)）")
            case .absent:
                absent.append(name)
            case .skipped(let reason):
                absent.append("\(name)（\(reason)）")
            }
        }

        // The newest full bundle Node produced, if any. Only the files a Node
        // bundle is made of are taken from it, and each goes through the same
        // redaction again: a snapshot written by an older build predates some
        // of the rules, and a directory copied as is would carry whatever else
        // ended up in it.
        var snapshot = "none"
        if let newest = newestSnapshot() {
            let name = "last-node-snapshot"
            let target = directory.appendingPathComponent(name, isDirectory: true)
            var taken = 0
            for relative in snapshotFiles(in: newest) {
                let destination = target.appendingPathComponent(relative)
                try? fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if case .copied = copyRedacted(
                    from: newest.appendingPathComponent(relative),
                    to: destination,
                    budget: &budget
                ) {
                    taken += 1
                }
            }
            snapshot = taken > 0
                ? "\(name), taken \(newest.lastPathComponent), \(taken) files"
                : "could not copy \(newest.lastPathComponent)"
        }

        let summary = """
        DSH 诊断包（最小包）

        生成时间：\(stamp)
        Node 未参与：这一份由 App 直接组装，因为这次启动没有走到 Node 应答那一步。
        每个文件都经过 App 端脱敏（密钥、令牌、URL 账号密码、用户目录和容器编号），单个文件最多保留末尾 \(maxFileBytes / 1024) KB。

        包内文件：
        \(copied.map { "  - \($0)" }.joined(separator: "\n"))
        上一次 Node 快照：\(snapshot)

        没有找到的文件：
        \(absent.map { "  - \($0)" }.joined(separator: "\n"))

        刻意不包含：
          - .credentials.yaml（密钥）
          - storages/（DSH 自己的状态）
          - sessions/、sessions-quarantine/（会话内容）
          - attachments/（会话附件）
          - events.jsonl（客户机通道的事件流）
          - AGENTS.md（用户自己的指令）
          - DSHPortC-session-url.txt（明文令牌）
          - Documents/workspace（用户文件）

        启动计数：
        \(bootGuardSummary())
        """
        let summaryURL = directory.appendingPathComponent("SUMMARY.txt")
        do {
            // The boot-guard reason and the error texts above can quote a path.
            try redact(summary).write(to: summaryURL, atomically: true, encoding: .utf8)
        } catch {
            return "无法写入 SUMMARY.txt：\(error.localizedDescription)"
        }
        let presented = ShareSheet.present(items: [singleFile(of: directory)], from: anchor)
        return presented
            ? "最小诊断包：\(directory.lastPathComponent)"
            : "最小诊断包已生成，但分享面板没有打开：\(directory.lastPathComponent)"
    }

    /// Put every file of a bundle into one text file beside them.
    ///
    /// Everything in a bundle is already redacted text, so this adds no new
    /// exposure. A file that is not UTF-8 is named rather than copied. Falls back
    /// to the folder itself if the file cannot be written.
    private static func singleFile(of directory: URL) -> URL {
        let prefix = "DSH-diagnostics-"
        let output = directory.appendingPathComponent("\(prefix)\(directory.lastPathComponent).txt")
        let base = directory.standardizedFileURL.path + "/"
        var parts: [String] = []
        if let walker = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) {
            let files = walker.compactMap { $0 as? URL }.filter {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                    && !$0.lastPathComponent.hasPrefix(prefix)
            }
            // SUMMARY.txt first: it says what the rest is.
            let ordered = files.sorted {
                let left = $0.lastPathComponent == "SUMMARY.txt" ? "" : $0.path
                let right = $1.lastPathComponent == "SUMMARY.txt" ? "" : $1.path
                return left < right
            }
            for file in ordered {
                let relative = file.standardizedFileURL.path.replacingOccurrences(of: base, with: "")
                let body = (try? String(contentsOf: file, encoding: .utf8)) ?? "（不是 UTF-8 文本，未包含）\n"
                parts.append("===== \(relative) =====\n\(body)")
            }
        }
        do {
            try parts.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
            return output
        } catch {
            NSLog("dshportc: could not write the single-file bundle: %@", "\(error)")
            return directory
        }
    }

    /// The newest `diagnostics/<stamp>-…` directory Node wrote.
    private static func newestSnapshot() -> URL? {
        let directory = RuntimePaths.diagnosticsDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        let candidates = names
            .filter { !$0.hasSuffix("-minimal") }
            .sorted()
        guard let name = candidates.last else { return nil }
        let url = directory.appendingPathComponent(name, isDirectory: true)
        // `attributesOfItem` describes a link itself, so a snapshot directory
        // replaced by a link elsewhere is not followed.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeDirectory else {
            return nil
        }
        return url
    }

    /// The files a Node bundle is made of, relative to its directory: what
    /// `materialize()` writes and nothing else that may have appeared beside it.
    private static func snapshotFiles(in directory: URL) -> [String] {
        var names = ["SUMMARY.txt", "manifest.json"]
        let filesDirectory = directory.appendingPathComponent("files", isDirectory: true)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: filesDirectory.path),
           attributes[.type] as? FileAttributeType == .typeDirectory,
           let entries = try? FileManager.default.contentsOfDirectory(atPath: filesDirectory.path) {
            names += entries.sorted()
                .filter { $0.range(of: #"^[0-9]{2}-[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil }
                .map { "files/\($0)" }
        }
        return names
    }

    // MARK: - The fallback's own redaction

    /// Per-file and whole-package budgets, the numbers `DEFAULT_LIMITS` uses in
    /// `sim/diagnostics.mjs`.
    static let maxFileBytes = 256 * 1024
    static let maxTotalBytes = 2 * 1024 * 1024

    private enum CopyResult {
        case copied(String)
        case absent
        case skipped(String)
    }

    /// Copy one whitelisted file as redacted text.
    ///
    /// Only a regular file is read, and it is opened with `O_NOFOLLOW`, so a link
    /// put where a log belongs cannot make the package read something else. Only
    /// the tail is kept (a log in an error loop grows at the end, and the end is
    /// where the failure is); the first partial line of a cut file is dropped,
    /// as Node does, so a secret split by the cut cannot slip past the patterns.
    private static func copyRedacted(from source: URL, to destination: URL, budget: inout Int) -> CopyResult {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: source.path) else {
            return .absent
        }
        let type = attributes[.type] as? FileAttributeType
        guard type == .typeRegular else {
            return .skipped(type == .typeSymbolicLink ? "符号链接，未跟随" : "不是普通文件")
        }
        guard budget > 0 else { return .skipped("超出整包大小上限，未包含") }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let window = max(0, min(size, maxFileBytes, budget))

        var bytes = Data()
        if window > 0 {
            let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW)
            guard descriptor >= 0 else { return .skipped("无法打开") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                try handle.seek(toOffset: UInt64(size - window))
                bytes = try handle.read(upToCount: window) ?? Data()
            } catch {
                return .skipped("读取失败")
            }
        }
        let truncated = window < size
        if truncated {
            if let newline = bytes.firstIndex(of: 0x0A) {
                bytes = bytes.subdata(in: bytes.index(after: newline)..<bytes.endIndex)
            } else {
                bytes = Data()
            }
        }
        if bytes.prefix(8192).contains(0) { return .skipped("二进制文件，未包含") }
        guard let text = String(data: bytes, encoding: .utf8) else {
            return .skipped("不是 UTF-8 文本，未包含")
        }
        guard let clean = redactOrNil(text) else { return .skipped("脱敏规则不可用，未包含") }
        let body = truncated
            ? "[truncated: kept the last \(bytes.count) of \(size) bytes]\n\(clean)"
            : clean
        do {
            try body.write(to: destination, atomically: true, encoding: .utf8)
        } catch {
            return .skipped("写入失败")
        }
        budget -= body.utf8.count
        return .copied(truncated ? "只保留末尾 \(bytes.count) / \(size) 字节" : "")
    }

    /// `redactOrNil`, or a placeholder when the rules are unavailable.
    static func redact(_ text: String) -> String {
        redactOrNil(text) ?? "（脱敏规则不可用，内容未包含）\n"
    }

    /// Apply `NodeRunner.redact` (launch token, guest token), then the same
    /// named rules as `REDACTIONS` in `sim/diagnostics.mjs`, then the path rules.
    ///
    /// Returns nil when any pattern failed to compile: a rule list with a hole in
    /// it would look like it ran, so the caller leaves the file out instead.
    static func redactOrNil(_ text: String) -> String? {
        guard let rules = redactionRules else { return nil }
        var out = NodeRunner.redact(text)
        for rule in rules { out = rule.apply(out) }
        return out
    }

    private struct RedactionRule {
        let regex: NSRegularExpression
        /// Receives the whole match at index 0 and each group after it ("" for
        /// a group that did not take part).
        let replace: ([String]) -> String

        func apply(_ text: String) -> String {
            let source = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
            guard !matches.isEmpty else { return text }
            let output = NSMutableString(string: text)
            // Back to front, so the ranges of the earlier matches stay valid.
            for match in matches.reversed() {
                var groups: [String] = []
                for index in 0..<match.numberOfRanges {
                    let range = match.range(at: index)
                    groups.append(range.location == NSNotFound ? "" : source.substring(with: range))
                }
                output.replaceCharacters(in: match.range, with: replace(groups))
            }
            return output as String
        }
    }

    /// Expand `$1`…`$9` in `template` from `groups`, once, left to right, so a
    /// group's own text is never expanded again.
    private static func expand(_ template: String, _ groups: [String]) -> String {
        let characters = Array(template)
        var result = ""
        var index = 0
        while index < characters.count {
            if characters[index] == "$", index + 1 < characters.count,
               let digit = characters[index + 1].wholeNumberValue {
                result += digit < groups.count ? groups[digit] : ""
                index += 2
            } else {
                result.append(characters[index])
                index += 1
            }
        }
        return result
    }

    private static func shown(_ value: String) -> String {
        if value.hasPrefix("\"") { return "\"<redacted>\"" }
        if value.hasPrefix("'") { return "'<redacted>'" }
        return "<redacted>"
    }

    /// `redactField` in `sim/diagnostics.mjs`: keep the key and the quotes; a
    /// bare value inside `{...}` or after a quoted key ends at `,`/`}`/`]`, a
    /// bare value on a YAML block line runs to the end of the line.
    private static func redactedField(_ groups: [String]) -> String {
        guard groups.count >= 6 else { return groups.first ?? "" }
        let context = groups[1], quote = groups[2], key = groups[3], separator = groups[4], value = groups[5]
        let quoted = value.hasPrefix("\"") || value.hasPrefix("'")
        var rest = ""
        if !quoted, (!quote.isEmpty || context.contains(where: { "{,[".contains($0) })),
           let cut = value.range(of: #"[ \t]*[,\}\]]"#, options: .regularExpression),
           cut.lowerBound > value.startIndex {
            rest = String(value[cut.lowerBound...])
        }
        return context + quote + key + quote + separator + shown(value) + rest
    }

    // The patterns, one for one with `REDACTIONS` in `sim/diagnostics.mjs`.
    // ICU set syntax differs from JavaScript's: `[`, `{`, `}`, `&` and `-` are
    // escaped inside brackets so none of them is read as a set operator.
    private static let strongKeys = #"(?:api[_\-]?key|api[_\-]?token|access[_\-]?token|refresh[_\-]?token|id[_\-]?token|auth[_\-]?token|session[_\-]?token|bearer[_\-]?token|[_\-]token|access[_\-]?key|secret[_\-]?key|private[_\-]?key|client[_\-]?secret|secret|password|passwd|passphrase|credentials?)"#
    private static let weakKeys = #"(?:token|auth|authorization|bearer|pwd)"#
    private static let fieldValue = #"("(?:[^"\\\n]|\\.)*"|'(?:[^'\n]|'')*'|[^\s"',\}\]][^\n]*?(?=[ \t\r]*$))"#
    private static let notRedacted = #"(?!["']?<redacted)"#
    private static let secretFieldPattern: String =
        #"(^|[^A-Za-z0-9_\-])(["']?)([A-Za-z0-9_\-]*?"# + strongKeys + #")\2([ \t]*:[ \t]*)"# + notRedacted + fieldValue
    private static let tokenFieldPattern: String =
        #"(^[ \t]*(?:-[ \t]+)?|[|>\{,\[][ \t]*)(["']?)("# + weakKeys + #")\2([ \t]*:[ \t]*)"# + notRedacted + fieldValue
    private static let secretAssignmentPattern: String =
        #"(^|[^A-Za-z0-9_\-])([A-Za-z0-9_\-]*?"# + strongKeys + #")="# + notRedacted
        + #"("(?:[^"\\\n]|\\.)*"|'[^'\n]*'|[^\s\&"'#;=][^\s\&"'#;]*)"#

    private static let redactionRules: [RedactionRule]? = {
        let lines: NSRegularExpression.Options = [.caseInsensitive, .anchorsMatchLines]
        let specs: [(String, NSRegularExpression.Options, ([String]) -> String)] = [
            // authorization-header, cookie-header
            (#"(^|[|>\s])authorization[ \t]*:[^\n]*$"#, lines, { expand("$1Authorization: <redacted>", $0) }),
            (#"(^|[|>\s])(?:set-)?cookie[ \t]*:[^\n]*$"#, lines, { expand("$1Cookie: <redacted>", $0) }),
            // bearer-value
            (#"\b(Bearer|Basic)[ \t]+[A-Za-z0-9._~+/=\-]{8,}"#, [.caseInsensitive], { expand("$1 <redacted>", $0) }),
            // url-credentials
            (#"\b([a-z][a-z0-9+.\-]*://)(?:[^\s/?#@:'"<>]*:[^\s/?#@'"<>]*|[^\s/?#@:'"<>]{16,})@"#,
             [.caseInsensitive], { expand("$1<redacted>@", $0) }),
            // token-parameter
            (#"(^|[?\&;\s"'(=])(token|access_token|refresh_token|id_token|auth|password|passwd|secret|api[_\-]?key|apikey|client[_\-]?secret)=([^\&\s"'#]+)"#,
             lines, { expand("$1$2=<redacted>", $0) }),
            // dsh-auth-cookie, sk-key, provider-key, jwt, private-key-block
            (#"\bdsh-auth-[A-Za-z0-9._~+/=\-]{8,}"#, [], { _ in "dsh-auth-<redacted>" }),
            (#"\bsk-[A-Za-z0-9][A-Za-z0-9_\-]{7,}"#, [], { _ in "sk-<redacted>" }),
            (#"\b(gh[pousr]_[A-Za-z0-9]{16,}|xox[abp]-[A-Za-z0-9\-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_\-]{30,})"#,
             [], { _ in "<redacted-key>" }),
            (#"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{4,}"#, [], { _ in "<redacted-jwt>" }),
            (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, [],
             { _ in "<redacted-private-key>" }),
            // secret-field, token-field, secret-assignment
            (secretFieldPattern, lines, redactedField),
            (tokenFieldPattern, lines, redactedField),
            (secretAssignmentPattern, lines, { groups in
                 groups.count >= 4 ? groups[1] + groups[2] + "=" + shown(groups[3]) : (groups.first ?? "")
             }),
            // Paths: container and simulator-device UUIDs, the account name.
            (#"\\?/Containers\\?/(Data|Shared|Bundle)\\?/(Application|AppGroup|PluginKitPlugin)\\?/[0-9A-Fa-f][0-9A-Fa-f\-]{35}"#,
             [], { expand("/Containers/$1/$2/<container>", $0) }),
            (#"\\?/CoreSimulator\\?/Devices\\?/[0-9A-Fa-f][0-9A-Fa-f\-]{35}"#, [], { _ in "/CoreSimulator/Devices/<device>" }),
            (#"(\\?/(?:Users|home)\\?/)(?!<user>|Shared(?![^\\/\s"'<>:]))[^\\/\s"'<>:]+"#, [], { groups in
                (groups.count > 1 ? groups[1].replacingOccurrences(of: "\\", with: "") : "/") + "<user>"
            }),
        ]
        var rules: [RedactionRule] = []
        for (pattern, options, replace) in specs {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
                NSLog("dshportc: diagnostics redaction pattern failed to compile: %@", pattern)
                return nil
            }
            rules.append(RedactionRule(regex: regex, replace: replace))
        }
        return rules
    }()

    private static func bootGuardSummary() -> String {
        let report = BootGuard.report()
        return [
            "  连续失败 \(report.failures) 次，阈值 \(report.threshold)",
            "  安全模式：\(report.safeMode ? "是" : "否")",
            "  计数器状态：\(report.stateStatus)",
            report.previousKind.isEmpty ? nil : "  上一次启动：\(report.previousKind)（\(report.previousReason)）",
        ].compactMap { $0 }.joined(separator: "\n")
    }
}
