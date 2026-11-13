//
//  ResetSheet.swift
//  DSHPortC
//
//  The reset panel: keep switches, an old-guest opt-in, their move list, the list of
//  what is kept, the size of the data an earlier reset left behind, and the one
//  button that clears that leftover.
//
//  WHY THE PANEL HAS ITS OWN COPY OF THE PATH TABLE
//  ------------------------------------------------
//  The authoritative table is `TIERS` in `sim/reset-plan.mjs`, and the normal
//  path is that Node answers: every launch writes `boot/reset-plan.json` with all
//  four combinations, and this panel reads it. That file does not exist on the
//  launch that matters most — a launch where Node never got as far as writing it —
//  and that is the launch whose failure screen offers "重置运行环境" as the way
//  out. A panel that could not list its own consequences would either have to
//  refuse (wrong: the user needs it) or move paths it could not show (worse).
//
//  So `builtinTiers` below repeats the same container-relative paths, and
//  `scripts/reset-plan-parity.py` compares it against `TIERS` so the two cannot
//  drift. The comparison is a script rather than a Swift test because the Swift
//  test targets do not run in this project's build (see REPORT-19 §…, and the
//  same reasoning as `scripts/check-exif.py`).
//
//  WHAT THIS PANEL NEVER DOES
//  --------------------------
//  It does not delete. A reset MOVES paths into `reset-staging/`, and the data
//  that is already in `reset-staging/` from an earlier reset is only removed when
//  the user presses a button that says so, after being told how much there is.
//  Nothing here runs on its own.
//

import SwiftUI

/// The container-relative path table, and the arithmetic over it.
///
/// Kept as data (not `if` statements) so `reset-plan-parity.py` can compare
/// entries one by one against `TIERS`, and so the sheet shows the same list in
/// the same order as the Node-generated file.
enum ResetTable {

    /// Where the guest image lives, relative to the container.
    ///
    /// Kept out of the four combinations on purpose: re-importing it takes
    /// minutes and loses whatever was installed in it, and it has nothing to do
    /// with "DSH will not start". A separate entrance, not a third switch.
    static let guest = "Library/Application Support/ish-root"
    static let guestBackups = "Library/Application Support/ish-root-previous"

    /// Every planned path, grouped by the tier that decides when it moves.
    ///
    /// `always` moves on every combination; `conversations` and `settings` move
    /// unless their switch is on; `guest` and `guestBackups` only when requested.
    static let tiers: [(tier: String, entries: [(relative: String, reason: String)])] = [
        ("always", [
            ("Library/Application Support/DSH/cache",
             "可重建的缓存"),
            ("Library/Application Support/DSH/storages",
             "DSH 自己的状态（工作区登记、记录下来的路径）；它是从会话日志和 profile 重新生成的投影"),
            ("Library/Application Support/DSH/events.jsonl",
             "客户机通道的事件流"),
            ("Library/Application Support/DSH/.container-root",
             "容器标记；每次启动都会重写"),
            ("Library/Application Support/DSH/DSHPortE-session-migrate.json",
             "上一次迁移的摘要"),
            ("Library/Application Support/DSHPortC/DSHPortC-node.log",
             "启动日志"),
            ("Library/Application Support/DSHPortC/DSHPortC-status.json",
             "启动状态文件"),
            ("Library/Application Support/DSHPortC/DSHPortC-session-url.txt",
             "上一次启动的令牌"),
            ("Library/Application Support/DSHPortC/boot",
             "启动计数的状态、待处理的请求和安全模式的覆盖层"),
            ("Library/Application Support/DSHPortC/diagnostics",
             "之前几次启动留下的诊断包"),
            ("Library/Caches/dsh-compile-cache",
             "编译缓存"),
        ]),
        ("conversations", [
            ("Library/Application Support/DSH/sessions", "对话"),
            ("Library/Application Support/DSH/sessions-quarantine", "被更早的启动隔离出来的对话"),
            ("Library/Application Support/DSH/attachments", "这些对话里的图片和附件"),
        ]),
        ("settings", [
            ("Library/Application Support/DSH/.credentials.yaml", "API 密钥：属于设置，不属于运行环境"),
            ("Library/Application Support/DSH/profiles", "profile：提供商配置和设置页保存的用户层"),
            ("Library/Application Support/DSH/AGENTS.md", "你自己的指令"),
        ]),
        ("guest", [
            ("Library/Application Support/ish-root",
             "Linux 客户机镜像；从 App 内置压缩包重新导入要几分钟，里面装过的东西会全丢"),
        ]),
        ("guestBackups", [
            ("Library/Application Support/ish-root-previous",
             "旧 Linux 客户机副本；移进暂存目录后，再确认清除才会释放空间"),
        ]),
    ]

    /// The four combinations, as container-relative move lists.
    ///
    /// Same keys, same order and same nesting rule as `relativeCombos()` in
    /// `sim/reset-plan.mjs`: the outermost path covers its children, so a parent
    /// in the list implies nothing below it is listed again.
    static func combos() -> [String: ResetCombo] {
        var out: [String: ResetCombo] = [:]
        for keepConversations in [true, false] {
            for keepSettings in [true, false] {
                let key = "\(keepConversations ? "keep" : "drop")-conversations+"
                    + "\(keepSettings ? "keep" : "drop")-settings"
                var combo = ResetCombo()
                combo.keepConversations = keepConversations
                combo.keepSettings = keepSettings
                var relative: [String] = []
                for (tier, entries) in tiers {
                    if tier == "always" {
                        relative.append(contentsOf: entries.map(\.relative))
                    } else if tier == "conversations", !keepConversations {
                        relative.append(contentsOf: entries.map(\.relative))
                    } else if tier == "settings", !keepSettings {
                        relative.append(contentsOf: entries.map(\.relative))
                    }
                }
                combo.move = outermost(relative)
                combo.keep = keepReasons(keepConversations: keepConversations, keepSettings: keepSettings)
                out[key] = combo
            }
        }
        return out
    }

    /// The paths this combination keeps, with why — the sheet's second list.
    static func keepReasons(keepConversations: Bool, keepSettings: Bool) -> [ResetKeepEntry] {
        var kept: [ResetKeepEntry] = [
            ResetKeepEntry(relative: "Documents/workspace", reason: "你自己的文件，任何情况下都不动"),
        ]
        for (tier, entries) in tiers {
            let isKept = (tier == "conversations" && keepConversations)
                || (tier == "settings" && keepSettings)
                || tier == "guest" || tier == "guestBackups"
            guard isKept else { continue }
            let prefix = tier == "conversations" ? "保留对话："
                : tier == "settings" ? "保留设置：" : "保留："
            for entry in entries {
                kept.append(ResetKeepEntry(relative: entry.relative, reason: prefix + entry.reason))
            }
        }
        return kept
    }

    /// Drop a path whose parent is already in the list.
    ///
    /// String comparison on the container-relative spelling is enough here: these
    /// are all paths this file and `sim/reset-plan.mjs` build, with no symlinked
    /// prefix to normalise (`reset-plan.mjs` does its own, canonical check on the
    /// absolute paths it hands the executor).
    static func outermost(_ paths: [String]) -> [String] {
        let sorted = Array(Set(paths)).sorted()
        var kept: [String] = []
        for path in sorted {
            let covered = kept.contains { parent in
                path == parent || path.hasPrefix(parent + "/")
            }
            if !covered { kept.append(path) }
        }
        return kept
    }

    /// The tier a path belongs to, for the sheet's section headings.
    static func tier(of relative: String) -> String {
        for (tier, entries) in tiers where entries.contains(where: { $0.relative == relative }) {
            return tier
        }
        return "unknown"
    }
}

/// The reset panel.
struct ResetSheet: View {
    /// The container root every relative path is resolved against.
    let containerRoot: URL
    @Environment(\.dismiss) private var dismiss
    @State private var keepConversations = true
    @State private var keepSettings = true
    @State private var discardGuestBackups = false
    @State private var preview = ResetPlanPreview()
    @State private var confirmReset = false
    @State private var confirmPurge = false
    @State private var stagingBytes: Int64 = 0
    @State private var purgeResult: String?

    private var comboKey: String {
        "\(keepConversations ? "keep" : "drop")-conversations+"
            + "\(keepSettings ? "keep" : "drop")-settings"
    }

    private var combo: ResetCombo? {
        guard var combo = preview.combos[comboKey] else { return nil }
        if discardGuestBackups {
            combo.move = ResetTable.outermost(combo.move + [ResetTable.guestBackups])
            combo.keep.removeAll { $0.relative == ResetTable.guestBackups }
        }
        return combo
    }

    /// `ResetSheet.builtinCombos()` — the entry point `BootGuard.resetPreview()`
    /// calls when Node's file is not there.
    static func builtinCombos() -> [String: ResetCombo] { ResetTable.combos() }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("保留对话", isOn: $keepConversations)
                        .accessibilityIdentifier("resetKeepConversations")
                    Toggle("保留设置", isOn: $keepSettings)
                        .accessibilityIdentifier("resetKeepSettings")
                    Toggle("移走旧客户机副本", isOn: $discardGuestBackups)
                        .accessibilityIdentifier("resetDiscardGuestBackups")
                } header: {
                    Text("重置运行环境")
                } footer: {
                    Text("对话包括会话、被隔离的会话和附件；设置包括 API 密钥、提供商配置和你自己的指令。"
                         + "工作区里的文件永远不动。旧客户机副本默认保留，勾选后移进暂存目录，再确认清除才会释放空间。")
                }

                Section("会移走（移进暂存目录，不删除）") {
                    ForEach(combo?.move ?? [], id: \.self) { relative in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(short(relative)).font(.footnote.monospaced())
                            Text(reason(for: relative))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("会保留") {
                    ForEach(combo?.keep ?? [], id: \.relative) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(short(entry.relative)).font(.footnote.monospaced())
                            Text(keepReason(for: entry)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                if !preview.warnings.isEmpty || preview.source == "builtin" {
                    Section("说明") {
                        if preview.source == "builtin" {
                            Text("这次启动没有走到写清单那一步，上面的清单来自 App 内置的同一份路径表。")
                                .font(.caption)
                        }
                        ForEach(preview.warnings, id: \.self) { warning in
                            Text(warning).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    LabeledContent("上次重置留下的数据", value: byteText(stagingBytes))
                        .accessibilityIdentifier("resetStagingSize")
                    Button(role: .destructive) {
                        confirmPurge = true
                    } label: {
                        Text("彻底清除上次重置留下的数据")
                    }
                    .disabled(stagingBytes == 0)
                    .accessibilityIdentifier("resetPurgeStaging")
                    if let purgeResult {
                        Text(purgeResult).font(.caption).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("上一次重置把数据移进了暂存目录，等着你确认。这里只在你按下按钮时删除，App 自己永远不会动它。")
                }

                Section {
                    Button {
                        confirmReset = true
                    } label: {
                        Text("开始重置").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("resetConfirm")
                } footer: {
                    Text("重置需要退出 App，然后重新打开。")
                }
            }
            .navigationTitle("重置运行环境")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .task {
                preview = BootGuard.resetPreview()
                stagingBytes = ResetRunner.stagingSize()
            }
            .confirmationDialog(
                "确定要重置吗？",
                isPresented: $confirmReset,
                titleVisibility: .visible
            ) {
                Button("重置并退出", role: .destructive) {
                    ResetRunner.requestReset(
                        keepConversations: keepConversations,
                        keepSettings: keepSettings,
                        discardGuestBackups: discardGuestBackups
                    )
                }
                Button("取消", role: .cancel) { }
            } message: {
                Text(resetSummary)
            }
            .confirmationDialog(
                "彻底删除暂存的数据？",
                isPresented: $confirmPurge,
                titleVisibility: .visible
            ) {
                Button("删除 \(byteText(stagingBytes))", role: .destructive) {
                    purgeResult = ResetRunner.purgeStaging()
                    stagingBytes = ResetRunner.stagingSize()
                }
                Button("取消", role: .cancel) { }
            } message: {
                Text("这里的数据是上一次重置移出来的，包括 API 密钥、会话和设置。删除之后无法恢复。")
            }
        }
        .accessibilityIdentifier("resetSheet")
    }

    private var resetSummary: String {
        let moves = combo?.move.count ?? 0
        return "将移走 \(moves) 项运行数据，保留"
            + (keepConversations ? "对话" : "（不含对话）") + "、"
            + (keepSettings ? "设置" : "（不含设置）") + "。"
            + (discardGuestBackups ? "旧客户机副本将移进暂存目录；重新打开 App 后，还需确认清除暂存数据才会释放空间。" : "")
    }

    /// `Library/Application Support/DSH/sessions` reads as `DSH/sessions`.
    private func short(_ relative: String) -> String {
        relative
            .replacingOccurrences(of: "Library/Application Support/", with: "")
            .replacingOccurrences(of: "Library/Caches/", with: "Caches/")
    }

    private func reason(for relative: String) -> String {
        for (_, entries) in ResetTable.tiers {
            if let entry = entries.first(where: { $0.relative == relative }) { return entry.reason }
        }
        return ResetTable.tier(of: relative)
    }

    /// The built-in table's sentence: `boot/reset-plan.json` carries Node's English
    /// one, which is for the log, not for this panel.
    private func keepReason(for entry: ResetKeepEntry) -> String {
        ResetTable.keepReasons(keepConversations: keepConversations, keepSettings: keepSettings)
            .first { $0.relative == entry.relative }?.reason ?? entry.reason
    }

    private func byteText(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "没有" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
