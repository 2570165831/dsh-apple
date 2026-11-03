//
//  DownloadCoordinator.swift
//  DSHPortC
//
//  Makes downloads work at all, and puts the result in the system share sheet.
//
//  WHY THIS EXISTS
//  ---------------
//  A `WKWebView` with no `WKDownloadDelegate` and no download policy does not
//  download anything: the navigation either replaces the page with a blank
//  document or does nothing visible. That is the state this app was in, and it
//  matters because DSH's own UI has real download affordances:
//
//    * `/export` and the session header's download button build an
//      `<a download=…>` and click it (`dsh-session-log-export`), pointing at
//      `/api/session.export`, which answers `Content-Disposition: attachment`.
//    * the document preview panel renders PDF/XLSX/CSV previews and can hand
//      the underlying asset over.
//    * a plugin or a dependency can use a `blob:` or `data:` URL, which WebKit
//      cannot navigate to as a document for anything binary.
//
//  Four entry points have to be covered, and they arrive through two different
//  delegate methods:
//
//    | trigger                                    | seen as              |
//    |--------------------------------------------|----------------------|
//    | `<a download>`, `navigationAction` says so  | shouldPerformDownload |
//    | `blob:` / `data:` handed to a link          | shouldPerformDownload |
//    | `Content-Disposition: attachment`           | navigationResponse   |
//    | a MIME type the web view cannot display     | navigationResponse   |
//
//  `shouldPerformDownload` is read on the NAVIGATION ACTION (before the request
//  goes out); the other two are read on the NAVIGATION RESPONSE (after the
//  headers are in). Both spellings have to return `.download`, and both then
//  arrive in `didBecomeDownload:` where the `WKDownload` gets its delegate.
//
//  WHERE THE BYTES GO, AND WHY THEY DO NOT STAY
//  --------------------------------------------
//  `WKDownload` streams to the destination file URL this class hands it, so a
//  50 MB attachment never becomes a 50 MB `Data` in the app's heap — that is
//  the whole reason to use `WKDownload` rather than fetching in JS and building
//  a blob. The file goes into the app's own temporary directory, the share
//  sheet is presented on the file URL, and the file is deleted when the sheet
//  is dismissed — saved by the user into Files/Photos/WeChat or not, the
//  temporary copy has no further purpose, and leaving downloads in `tmp/`
//  forever is how a phone runs out of space.
//
//  CHINESE FILENAMES
//  -----------------
//  The name comes from `suggestedFilename`, which WebKit derives from
//  `Content-Disposition` (both `filename=` and RFC 5987 `filename*=UTF-8''…`)
//  or from the `download` attribute. It is used as-is apart from characters
//  that cannot appear in a path; nothing transliterates or strips non-ASCII,
//  because a Chinese filename that arrives as `____.zip` is a bug the user sees.
//

import Foundation
import WebKit

/// What one download did, as the acceptance log records it.
struct DownloadRecord {
    var id: String
    var source: String
    var suggestedName: String
    var fileName: String
    var mimeType: String
    var expectedBytes: Int64
    var writtenBytes: Int64
    var seconds: Double
    var error: String?
    var sharePresented: Bool
    var trigger: String
    var cleanedUp: Bool

    var asDictionary: [String: Any] {
        var dictionary: [String: Any] = [
            "id": id,
            "source": source,
            "suggestedName": suggestedName,
            "fileName": fileName,
            "mimeType": mimeType,
            "expectedBytes": expectedBytes,
            "writtenBytes": writtenBytes,
            "seconds": (seconds * 1000).rounded() / 1000,
            "sharePresented": sharePresented,
            "trigger": trigger,
            "cleanedUp": cleanedUp,
        ]
        if let error { dictionary["error"] = error }
        return dictionary
    }
}

@MainActor
final class DownloadCoordinator: NSObject {

    static let shared = DownloadCoordinator()

    /// How the download was started, for the log. Set by the navigation
    /// delegate just before it returns `.download`, because by the time the
    /// download object exists the reason is no longer visible.
    enum Trigger: String {
        case navigationActionShouldPerformDownload = "shouldPerformDownload"
        case contentDispositionAttachment = "content-disposition"
        case unshowableMIMEType = "unshowable-mime"
        case responseShouldPerformDownload = "responseDownload"
    }

    /// The view the share popover anchors to. The web view, in practice.
    weak var anchorView: UIView?

    /// Serialises the share sheets: a second download that finishes while the
    /// first sheet is up waits its turn instead of trying to present on a
    /// controller that is already presenting.
    private var pendingShares: [URL] = []
    private var sharing = false

    /// Downloads in flight, keyed by the `WKDownload` object's identity.
    private var inFlight: [ObjectIdentifier: Pending] = [:]

    /// The reason for the next download, consumed when it is created.
    private var nextTrigger: Trigger = .navigationActionShouldPerformDownload

    private struct Pending {
        var record: DownloadRecord
        var destination: URL
        var started: Date
        var bytesAtStart: Int64
    }

    /// Where the temporary files go. One directory under the app's tmp, cleaned
    /// of anything a previous crash left behind when this is first asked for.
    private lazy var downloadsDirectory: URL = {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DSHPortCDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private(set) var records: [DownloadRecord] = []

    // MARK: - Navigation-side decisions

    /// Note why the next download is being started, then return `.download`.
    ///
    /// The caller does the policy decision; this only remembers the reason, so
    /// the record can say which of the four triggers fired rather than only that
    /// something downloaded.
    func noteTrigger(_ trigger: Trigger) {
        nextTrigger = trigger
    }

    /// Attach to a download WebKit just created.
    ///
    /// Both `webView:navigationAction:didBecomeDownload:` and
    /// `webView:navigationResponse:didBecomeDownload:` land here. The delegate
    /// MUST be set here or the download never asks for a destination and never
    /// completes.
    func adopt(_ download: WKDownload) {
        download.delegate = self
    }

    // MARK: - Destination

    func destination(for suggestedFilename: String, response: URLResponse?) -> URL {
        let name = DownloadCoordinator.sanitized(fileName: suggestedFilename)
        var candidate = downloadsDirectory.appendingPathComponent(name)
        // `decideDestinationUsingResponse` requires a path that does NOT exist
        // in a directory that does. Two downloads of the same name in one
        // session is the normal case for "export twice", so the name is
        // deduplicated here rather than the second download failing.
        var counter = 1
        let base = candidate.deletingPathExtension().lastPathComponent
        let extensionPart = candidate.pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            let suffixed = extensionPart.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(extensionPart)"
            candidate = downloadsDirectory.appendingPathComponent(suffixed)
            counter += 1
        }
        return candidate
    }

    /// Keep the name the server or the page asked for, minus what a path cannot
    /// hold. Non-ASCII is preserved deliberately: this app is used in Chinese,
    /// and a Chinese filename has to survive to the share sheet intact.
    nonisolated static func sanitized(fileName: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:\u{0}\n\r\t")
        var name = fileName
            .components(separatedBy: illegal)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "download" }
        if name == "." || name == ".." { name = "download" }
        // A pathological name is not worth a failed write; the filesystem limit
        // is 255 bytes, and a UTF-8 Chinese character is three of those.
        while name.utf8.count > 200 {
            name.removeLast()
        }
        return name
    }

    // MARK: - Share

    private func share(_ file: URL, anchor: UIView?) {
        pendingShares.append(file)
        pumpShares()
    }

    private func pumpShares() {
        guard !sharing, !pendingShares.isEmpty else { return }
        let file = pendingShares.removeFirst()
        sharing = true
        let presented = ShareSheet.present(items: [file], from: anchorView ?? anchorViewFallback()) { [weak self] in
            // Either way. `completed` false (cancel) and true (saved somewhere)
            // both leave this app with nothing to do with its copy.
            Task { @MainActor in
                self?.cleanUp(file)
                self?.sharing = false
                self?.pumpShares()
            }
        }
        if !presented {
            // No controller to present from. Not a crash, and not a silent
            // success either: the download itself happened, and the log says the
            // sheet did not appear.
            sharing = false
            cleanUp(file)
        }
    }

    private func anchorViewFallback() -> UIView? {
        ShareSheet.topViewController()?.view
    }

    /// Delete the temporary copy and record that it is gone.
    private func cleanUp(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
        let name = file.lastPathComponent
        if let index = records.lastIndex(where: { $0.fileName == name }) {
            records[index].cleanedUp = true
        }
        writeProbeLog()
    }

    // MARK: - Evidence

    /// Append the record and, when the probe is on, write the log the acceptance
    /// run reads.
    ///
    /// Gated exactly like the other probes in this app (`-DSHPortEDownloadProbe
    /// 1`): a normal launch writes nothing into `Documents/`. The file is a
    /// probe artefact, not a runtime one, which is why it is allowed to live
    /// there while the boot log and the session URL may not.
    func commit(_ record: DownloadRecord) {
        records.append(record)
        writeProbeLog()
    }

    static var probeEnabled: Bool {
        UserDefaults.standard.integer(forKey: "DSHPortEDownloadProbe") == 1
    }

    private func writeProbeLog() {
        guard DownloadCoordinator.probeEnabled else { return }
        let payload: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "downloads": records.map { $0.asDictionary },
            "pendingShares": pendingShares.count,
            "sharing": sharing,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        else { return }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? data.write(to: documents.appendingPathComponent("DSHPortE-downloads.json"), options: .atomic)
    }
}

// MARK: - WKDownloadDelegate

extension DownloadCoordinator: WKDownloadDelegate {

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor (URL?) -> Void
    ) {
        let destination = destination(for: suggestedFilename, response: response)
        let identifier = ObjectIdentifier(download)
        let record = DownloadRecord(
            id: "\(records.count + inFlight.count + 1)",
            source: NodeRunner.redact(response.url?.absoluteString ?? download.originalRequest?.url?.absoluteString ?? "nil"),
            suggestedName: suggestedFilename,
            fileName: destination.lastPathComponent,
            mimeType: response.mimeType ?? "nil",
            expectedBytes: response.expectedContentLength,
            writtenBytes: 0,
            seconds: 0,
            error: nil,
            sharePresented: false,
            trigger: nextTrigger.rawValue,
            cleanedUp: false
        )
        inFlight[identifier] = Pending(
            record: record,
            destination: destination,
            started: Date(),
            bytesAtStart: 0
        )
        // Consumed: a download that arrives without a fresh trigger (a redirect
        // chain, say) reports the last one rather than a stale guess at a
        // different trigger.
        nextTrigger = .navigationActionShouldPerformDownload
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let identifier = ObjectIdentifier(download)
        guard var pending = inFlight.removeValue(forKey: identifier) else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: pending.destination.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        pending.record.writtenBytes = size
        pending.record.seconds = Date().timeIntervalSince(pending.started)
        pending.record.sharePresented = true
        commit(pending.record)
        share(pending.destination, anchor: anchorView)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let identifier = ObjectIdentifier(download)
        guard var pending = inFlight.removeValue(forKey: identifier) else { return }
        pending.record.error = "\(error)"
        pending.record.seconds = Date().timeIntervalSince(pending.started)
        pending.record.sharePresented = false
        try? FileManager.default.removeItem(at: pending.destination)
        pending.record.cleanedUp = true
        commit(pending.record)
    }

    func download(
        _ download: WKDownload,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        decisionHandler: @escaping @MainActor (WKDownload.RedirectPolicy) -> Void
    ) {
        // A redirect during a download is taken. The alternative — cancelling —
        // would make an `attachment` route that 302s to a signed URL fail, and
        // nothing here needs to police redirect targets: the request is already
        // in flight against a host the page could reach anyway.
        decisionHandler(.allow)
    }
}
