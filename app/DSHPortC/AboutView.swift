//
//  AboutView.swift
//  DSHPortC
//
//  What the app is, where its source is, and the licence texts, reachable from the
//  debug menu.
//
//  WHY IT EXISTS
//  -------------
//  The app is GPL-3.0 (it links the iSH core). Handing a build to anyone else, which
//  TestFlight does, means the recipient gets the licence with it (§4), an
//  interactive program shows its legal notices (§5d), and the source is offered
//  from a stated place (§6d). The texts are the same files the repository carries,
//  bundled by gen-xcode-project.rb, so they cannot drift from the source.
//

import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    static let sourceURL = URL(string: "https://github.com/2570165831/dsh-apple")!

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("DSH for iOS").font(.headline)
                        Text("版本 \(version)").font(.subheadline).foregroundStyle(.secondary)
                        Text("DeepSeek Harness 的非官方移植，与 DeepSeek 无关。")
                            .font(.subheadline)
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    Link(destination: Self.sourceURL) {
                        Label("github.com/2570165831/dsh-apple", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .accessibilityIdentifier("aboutSourceLink")
                } header: {
                    Text("源码")
                } footer: {
                    Text("本 App 以 GNU General Public License 第 3 版（GPL-3.0）发布。每个版本对应的完整源码，包括客户机镜像的构建脚本，都在这个仓库里。")
                }
                Section {
                    licenseLink("GPL-3.0 许可证全文", file: "LICENSE")
                    licenseLink("第三方组件许可", file: "THIRD_PARTY_NOTICES.md")
                    licenseLink("客户机镜像软件包", file: "RootfsPackages.md")
                } header: {
                    Text("许可")
                } footer: {
                    Text("Copyright (C) 2026 dsh-apple contributors. This program comes with ABSOLUTELY NO WARRANTY; it is free software, and you are welcome to redistribute it under the terms of the GPL-3.0.")
                }
            }
            .navigationTitle("关于与许可")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func licenseLink(_ title: String, file: String) -> some View {
        NavigationLink(title) { LicenseTextView(title: title, file: file) }
            .accessibilityIdentifier("aboutLicense-" + file)
    }
}

/// One bundled text file, line by line so a long file does not lay out as a single
/// giant `Text`.
private struct LicenseTextView: View {
    let title: String
    let file: String

    private var lines: [String] {
        guard let url = Bundle.main.url(forResource: file, withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ["（没有找到 \(file)。完整文本见源码仓库。）"]
        }
        return text.components(separatedBy: "\n")
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
