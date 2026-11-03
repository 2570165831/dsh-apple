//
//  ShareSheet.swift
//  DSHPortC
//
//  One reusable way to put a file in front of the system share sheet.
//
//  WHY THIS IS ITS OWN FILE
//  ------------------------
//  Two callers need it and a third is coming: a finished download (this step),
//  and the diagnostics bundle a later step exports. What those callers must NOT
//  each re-derive is the iPad rule below, because getting it wrong is a crash
//  rather than a cosmetic bug.
//
//  THE iPAD RULE
//  -------------
//  `UIActivityViewController` presents in a popover on iPad. A popover needs an
//  anchor: `popoverPresentationController.sourceView` plus `sourceRect` (or a
//  `barButtonItem`). Without one UIKit raises
//
//      NSGenericException: UIPopoverPresentationController should have a
//      non-nil sourceView or barButtonItem set before the presentation occurs
//
//  and the app dies. On iPhone the same controller is a sheet and does not care,
//  which is exactly why this is easy to ship broken: the phone never fails.
//  So the anchor is set unconditionally — on iPhone it is ignored.
//
//  The anchor is the web view with a zero-size rect at its centre. A finished
//  download has no meaningful "where the user tapped" (the tap may have been
//  several seconds and a network round trip earlier, and WKDownload does not
//  report a source rect), and a centre anchor points the popover arrow at the
//  content the user is looking at instead of at a random corner.
//

import UIKit

enum ShareSheet {

    /// Present `items` in the system share sheet.
    ///
    /// - Parameters:
    ///   - items: what to share. `URL`s (file URLs) are the normal case; the
    ///     type is `Any` so a caller can also pass a `UIImage` or `String`.
    ///   - anchor: the view the popover arrow points at. The web view, in
    ///     practice. A nil anchor falls back to the presenting controller's own
    ///     view, which is still non-nil and therefore still safe on iPad.
    ///   - completion: called once the sheet has been dismissed, whatever the
    ///     user chose — including the cancel path. The download path uses it to
    ///     delete its temporary file, so it must not assume a successful save.
    @discardableResult
    static func present(
        items: [Any],
        from anchor: UIView?,
        completion: (() -> Void)? = nil
    ) -> Bool {
        guard !items.isEmpty else { return false }
        guard let presenter = topViewController() else { return false }

        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // iPhone-compatible: `completionWithItemsHandler` also fires on cancel
        // (with `completed == false`), which is what "clean up either way" needs.
        controller.completionWithItemsHandler = { _, _, _, _ in
            completion?()
        }
        if let popover = controller.popoverPresentationController {
            // `UIViewController.view` is an implicitly unwrapped optional, so a
            // controller whose view has not loaded yet answers nil; falling back
            // to a zero-size rect on a nil source would still be the crash this
            // block exists to prevent, so the view is loaded if needed.
            let source = anchor ?? presenter.view ?? UIView(frame: .zero)
            popover.sourceView = source
            // Zero-size rect at the centre: a point anchor, not a rectangle the
            // arrow has to fit inside. `permittedArrowDirections = 0` would be
            // the "no arrow" spelling, but UIKit still requires the source, so
            // the anchor is set regardless.
            popover.sourceRect = CGRect(
                x: source.bounds.midX,
                y: source.bounds.midY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = .any
        }
        // A share sheet presented from a controller that is already presenting
        // something (a debug `UIAlertController`, say) silently does nothing and
        // logs to nowhere. Dismiss first, then present on the next runloop turn.
        if presenter.presentedViewController != nil {
            presenter.dismiss(animated: false) {
                presenter.present(controller, animated: true)
            }
        } else {
            presenter.present(controller, animated: true)
        }
        return true
    }

    /// The topmost view controller of the key window's scene.
    ///
    /// Walked rather than cached: the sheet can be requested while the debug
    /// menu's `UIAlertController`, the boot-log sheet or the guest console is up,
    /// and presenting on the root controller in that state presents onto nothing.
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let window = scenes
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
            ?? scenes.flatMap { $0.windows }.first
        guard var controller = window?.rootViewController else { return nil }
        while let presented = controller.presentedViewController, !presented.isBeingDismissed {
            controller = presented
        }
        // A navigation controller's visible child is the one that can present
        // over the content the user is looking at.
        if let navigation = controller as? UINavigationController,
           let visible = navigation.visibleViewController {
            controller = visible
        }
        if let tab = controller as? UITabBarController, let selected = tab.selectedViewController {
            controller = selected
        }
        return controller
    }
}
