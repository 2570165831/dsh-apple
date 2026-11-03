//
//  NotificationSettingsView.swift
//  DSHPortC
//
//  The four switches, reachable from the debug menu, plus a way to the system
//  notification setting when iOS has been told no.
//
//  WHERE THESE SWITCHES LIVE, AND WHY HERE
//  ---------------------------------------
//  The task's first choice was DSH's own settings page. That was checked and is not
//  available: `dsh-client-ui-settings-plugins` is a SHELL — it owns the navigation
//  entry and the tab row, and every tab in it is contributed by a feature-owned
//  client package that registers into `settings.plugins.tab`. The one tab that ships
//  (the inventory) is read-only. Configuring a plugin happens on the sidebar's
//  Plugins page, where each official plugin's own companion package registers a
//  page. So "the plugins section renders a plugin's configuration items
//  automatically" is false, and using it would have meant writing and shipping a new
//  browser plugin: a bundle under `payload/`, which this task's rules put last.
//
//  So the switches ride on iOS's own settings: `Settings.bundle/Root.plist` declares
//  four `PSToggleSwitchSpecifier` rows whose `Key` values are exactly
//  `NotifyKind.defaultsKey`. That is not a second copy of the settings — the Settings
//  app writes those keys into this app's `UserDefaults` domain, so both places edit
//  the same four values, and a change made in either is what the bridge reads. This
//  sheet exists because the Settings app is several taps away and a phone user stuck
//  behind a Debug menu should not have to leave the app to find out why nothing
//  arrives.
//
//  The two places differ in one deliberate way: this sheet can also say that the
//  SYSTEM permission is off and take the user to the place that fixes it. A
//  `Settings.bundle` row cannot open another settings page.
//

import SwiftUI
import UIKit

struct NotificationSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    /// Local mirror, so a switch moves the instant it is touched instead of waiting
    /// for the next notification event to re-read `UserDefaults`.
    @State private var switches: [NotifyKind: Bool] = [:]
    @State private var authorization = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(NotifyKind.allCases, id: \.self) { kind in
                        Toggle(isOn: binding(for: kind)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.label)
                                Text(kind.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("notifySwitch-" + kind.rawValue)
                    }
                } header: {
                    Text("通知我什么")
                } footer: {
                    Text("只在 App 不在前台时发。四种各自独立开关，重启后保留。")
                }

                Section {
                    HStack {
                        Text("系统授权")
                        Spacer()
                        Text(authorization.isEmpty ? "未知" : authorization)
                            .foregroundStyle(.secondary)
                    }
                    // Shown as its own row rather than as a footnote to the switches,
                    // because the two facts are unrelated: a user can have all four
                    // switches on and still get nothing, and the reason is here.
                    if authorization == "系统通知已关闭" {
                        Button("去系统设置打开通知") {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            UIApplication.shared.open(url)
                        }
                        .accessibilityIdentifier("notifyOpenSystemSettings")
                    }
                } header: {
                    Text("系统通知")
                } footer: {
                    Text(authorizationNote)
                }
            }
            .navigationTitle("通知")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("notifySettingsDone")
                }
            }
            .onAppear(perform: load)
        }
    }

    /// The sentence under the authorization row.
    ///
    /// It says the thing a person actually needs to know when nothing arrives: with
    /// the system permission off, the switches have nothing to act on.
    private var authorizationNote: String {
        switch authorization {
        case "系统通知已关闭":
            return "iOS 已关掉这个 App 的通知，四个开关都不会生效。到系统设置里打开「通知」即可。"
        case "还没有请求过系统通知授权（第一轮开始时才会请求）":
            return "第一次有回合开始时才会问一次系统授权。"
        default:
            return "通知只在 App 不在前台、且进程还活着的时候发得出去。"
        }
    }

    private func load() {
        for kind in NotifyKind.allCases {
            switches[kind] = NotifySettings.isEnabled(kind)
        }
        authorization = NotificationBridge.shared.authorizationExplanation
    }

    private func binding(for kind: NotifyKind) -> Binding<Bool> {
        Binding(
            get: { switches[kind] ?? NotifySettings.isEnabled(kind) },
            set: { newValue in
                switches[kind] = newValue
                NotifySettings.set(kind, enabled: newValue)
                NotificationBridge.shared.refreshSwitchSnapshot(reason: kind.rawValue)
                authorization = NotificationBridge.shared.authorizationExplanation
            }
        )
    }
}
