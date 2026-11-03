//
//  DSHPortCApp.swift
//  DSHPortC
//
//  Application entry point. Node is started by `NodeRunner.begin()` from the
//  first view's `onAppear`, not from here, so the window is on screen (and the
//  boot screen is visible) while Node comes up.
//
//  THE LAUNCH SCREEN'S COLOUR IS DECIDED HERE.
//
//  `Info.plist`'s `UILaunchScreen` had an empty `UIColorName`, which means "use
//  the system default" — white, always. On a device in dark mode that is a white
//  flash between the launch screen and the first frame of the boot screen. The
//  fix is not a static colour either, because the app has to launch into the
//  appearance the user has chosen. `UITraitCollection` is not available before
//  the window exists, so the launch screen uses a colour asset with light and
//  dark variants, and the first native view paints the same pair (see
//  `MobileWebTuning.Palette`).
//

import SwiftUI
import UIKit
import UserNotifications

@main
struct DSHPortCApp: App {
    @Environment(\.scenePhase) private var scenePhase

    /// Runs before any view exists, which is what makes it the right place to
    /// stamp the launch time. See `Step15Probe.markLaunch`.
    init() {
        Step15Probe.markLaunch()
        // Step 16: the notification delegate has to be installed before the first
        // view exists. A notification tap that LAUNCHES the app is delivered to
        // whatever object is the delegate at the end of launch, and `onAppear` runs
        // after that point — a delegate installed there would miss exactly the
        // "app was killed" case the task asks to handle. `NotificationTapRelay` holds
        // the tap until `NotificationBridge.start()` adopts it.
        NotificationTapRelay.install()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS suspends a backgrounded app after roughly 30 seconds. Node's
            // server is in-process, so nothing here keeps it alive; this hook
            // only records the transition so the log explains a later failure
            // instead of leaving it mysterious.
            switch phase {
            case .background:
                NSLog("dshportc: scenePhase -> background (iOS will suspend the process)")
                // STEP 19: the marker that makes "the user swiped it away" NOT a
                // boot failure. iOS reclaims memory from backgrounded apps and
                // users close apps from the app switcher, and both of those end
                // the process without writing an outcome. The guard reads this
                // file on the next launch: a launch that left it behind ended in
                // the background, which says nothing about whether it could boot.
                //
                // Not `@MainActor`-isolated work: one atomic one-line write, and
                // the transition is the only moment at which it is true.
                NodeRunner.shared.noteEnteredBackground()
            case .active:
                NSLog("dshportc: scenePhase -> active")
                NodeRunner.shared.noteBecameActive()
            default:
                break
            }
        }
    }
}
