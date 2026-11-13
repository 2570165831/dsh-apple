//
//  GuestConsoleView.swift
//  DSHPortC
//
//  The debug entry point for the Linux guest.
//
//  This is not part of the product surface: it exists so the guest can be
//  exercised — booted, run, and deliberately crashed — without going through the
//  DSH web UI. The acceptance numbers in REPORT-1.md come from here, and the
//  host-side measurement script drives it through the accessibility identifiers
//  below.
//
//  It deliberately does not touch the Node side. Opening it does not start,
//  stop, or reload Node; the DSH web mode keeps running behind it.
//

import SwiftUI

struct GuestConsoleView: View {
    @StateObject private var model = GuestConsoleModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                Divider()
                actionRow
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(model.lines.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(line.hasPrefix("[stderr]") ? .red : .primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                        .padding(8)
                    }
                    .background(Color(.secondarySystemBackground))
                    .onChange(of: model.lines.count) { _, _ in
                        if let last = model.lines.indices.last {
                            withAnimation(.linear(duration: 0.1)) {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                    }
                }
                Divider()
                inputBar
            }
            .navigationTitle("Guest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                        .accessibilityIdentifier("guestConsoleClose")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空") { model.clearOutput() }
                        .accessibilityIdentifier("guestConsoleClear")
                }
            }
        }
        .onAppear { model.startObserving() }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.stateColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.stateTitle)
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("guestStateTitle")
                Text(model.stateDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityIdentifier("guestStateDetail")
            }
            Spacer()
            if model.busy {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The acceptance commands, as buttons. Every one of them is a thing the
    /// report claims the guest can do, so every one of them is one tap away.
    /// The acceptance commands, as buttons in a wrapping grid.
    ///
    /// Laid out as a grid rather than a horizontal scroller on purpose: a
    /// scroller put the die() button off-screen at this width, so it could be
    /// neither found nor tapped in a UI test — and a debug screen whose
    /// buttons cannot be reached is not a debug screen. Five short labels fit
    /// two or three per row.
    private var actionRow: some View {
        let columns = [GridItem(.adaptive(minimum: 108), spacing: 8)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            Button("boot guest") { model.boot() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("guestBootButton")
            Button("uname -m") { model.runQuick("uname -m") }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("guestUnameButton")
            Button("cp 覆盖大文件") { model.runQuick(GuestConsoleModel.cpOverwriteScript) }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("guestCpOverwriteButton")
            Button("cp -a 目录") { model.runQuick(GuestConsoleModel.cpArchiveScript) }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("guestCpArchiveButton")
            #if DEBUG
            Button("触发 die()") { model.triggerDie() }
                .buttonStyle(.bordered)
                .tint(.red)
                .accessibilityIdentifier("guestDieButton")
            #endif
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("命令", text: $model.command)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { model.runTypedCommand() }
                .accessibilityIdentifier("guestCommandField")
            Button {
                model.runTypedCommand()
            } label: {
                Image(systemName: "play.fill")
            }
            .disabled(model.busy || model.command.isEmpty)
            .accessibilityIdentifier("guestRunButton")
        }
        .padding(8)
    }
}

/// Mirrors ISHGuest.state into UI copy. The raw enum is not shown: "mounting"
/// means nothing to someone looking at the screen, "挂载 rootfs" does.
final class GuestConsoleModel: ObservableObject {
    @Published var lines: [String] = []
    @Published var command: String = ""
    @Published var busy = false
    @Published var stateTitle = "未启动"
    @Published var stateDetail = "点右上角 → boot guest"

    private let guest = ISHGuest.shared
    private var timer: Timer?
    private var lastLogCount = 0

    /// One big file and one directory tree, written to the guest's own
    /// filesystem rather than a bind mount, because these two commands are the
    /// acceptance test for the O_DIRECTORY_ and st_dev fixes and must exercise
    /// the paths those fixes are on.
    static let cpOverwriteScript = """
    set -e
    cd /root/workspace
    rm -rf cptest && mkdir -p cptest && cd cptest
    head -c 3000000 /dev/urandom > big.bin
    cp big.bin big.copy
    cp big.bin big.copy
    cmp big.bin big.copy && echo "CP-OVERWRITE-OK $(wc -c < big.copy)"
    """

    static let cpArchiveScript = """
    set -e
    cd /root/workspace
    rm -rf src dst && mkdir -p src/sub dst
    echo one > src/a.txt
    echo two > src/sub/b.txt
    ln -s a.txt src/link.txt
    cp -a src dst/
    test -f dst/src/sub/b.txt && echo "CP-ARCHIVE-OK"
    """

    var stateColor: Color {
        switch guest.state {
        case .ready: return .green
        case .failed: return .red
        case .idle: return .gray
        default: return .orange
        }
    }

    func startObserving() {
        // The guest log is the single source of truth for what happened, so the
        // console mirrors it rather than keeping a second copy that can drift.
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        let all = ISHGuestLog.shared.lines()
        if all.count != lastLogCount {
            lastLogCount = all.count
            lines = all
        }
        stateTitle = title(for: guest.state)
        stateDetail = guest.stateDetail
        busy = (guest.state == .booting || guest.state == .mounting || guest.state == .installingRoot)
    }

    private func title(for state: ISHGuestState) -> String {
        switch state {
        case .idle: return "未启动"
        case .installingRoot: return "导入 rootfs"
        case .mounting: return "挂载 fakefs"
        case .booting: return "启动内核"
        case .ready: return String(format: "已就绪（boot %.3f s）", guest.bootSeconds)
        case .failed: return "启动失败"
        @unknown default: return "未知"
        }
    }

    func boot() {
        busy = true
        append("[console] booting…")
        guest.boot { [weak self] error in
            guard let self else { return }
            self.append(error == nil
                        ? "[console] boot ok in \(String(format: "%.3f", self.guest.bootSeconds)) s"
                        : "[console] boot failed: \(error!.localizedDescription)")
            self.busy = false
        }
    }

    func runTypedCommand() {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        command = ""
        run(cmd)
    }

    func runQuick(_ script: String) {
        run(script)
    }

    private func run(_ script: String) {
        busy = true
        let firstLine = script.split(separator: "\n").first.map(String.init) ?? script
        append("$ " + firstLine)
        guest.runCommand(script, timeout: 120, lineBlock: nil) { [weak self] result in
            guard let self else { return }
            if let launchError = result.launchError {
                self.append("[console] could not run: \(launchError)")
            }
            // Everything goes through the shared log, never straight into
            // `lines`. The model re-reads the log on a timer (`refresh`), so a
            // line appended only to `lines` disappears at the next tick -- which
            // is exactly what the first version did: the exit-code line survived
            // (it went through append) while the command's own output vanished.
            // Skip a stream that produced nothing. Splitting "" yields one empty
            // element, which otherwise prints a bare `[stderr]` marker and makes
            // the log look like something went wrong.
            if !result.standardOutput.isEmpty {
                for line in result.standardOutput.split(separator: "\n", omittingEmptySubsequences: false) {
                    self.append(String(line))
                }
            }
            if !result.standardError.isEmpty {
                for line in result.standardError.split(separator: "\n", omittingEmptySubsequences: false) {
                    self.append("[stderr] " + line)
                }
            }
            self.append("[exit code: \(result.exitCode)]  \(String(format: "%.3f", result.duration)) s")
            self.busy = false
        }
    }

    #if DEBUG
    func triggerDie() {
        append("[console] triggering a kernel die() on a guest task")
        _ = guest.triggerKernelDieForTesting()
    }
    #endif

    func clearOutput() {
        ISHGuestLog.shared.clear()
        lines = []
        lastLogCount = 0
    }

    /// Single path for every line the console shows. Records it in the shared
    /// log; the poll timer copies the log into `lines`, so there is exactly one
    /// list and no way for the two to disagree.
    private func append(_ line: String) {
        ISHGuestLog.shared.append(line.isEmpty ? " " : line)
    }
}
