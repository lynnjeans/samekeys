import AppKit
import OSLog

/// Tracks the bundle identifier of the frontmost application, which decides
/// whether app-scoped rules apply.
///
/// Updated from workspace notifications rather than queried per event, so the
/// event tap callback only reads a stored value.
@MainActor
final class FrontmostApplication {
    private(set) var bundleID: String?
    /// Its process, for asking it over Accessibility what has focus.
    private(set) var processIdentifier: pid_t?

    /// Told whenever the frontmost application changes, for features that
    /// have to act on the change rather than read the value per event: the
    /// recent folders take in Finder's own as Finder leaves the front.
    var onChange: (@MainActor (String?) -> Void)?

    // Kept for the app's lifetime, so the observer is never removed.
    private var observer: NSObjectProtocol?

    init() {
        bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        processIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            let pid = app?.processIdentifier
            MainActor.assumeIsolated {
                self?.processIdentifier = pid
                self?.update(bundleID)
            }
        }
    }

    private func update(_ bundleID: String?) {
        self.bundleID = bundleID
        onChange?(bundleID)
        #if DEBUG
        Logger.engine.notice("Frontmost application: \(bundleID ?? "none", privacy: .public)")
        #endif
    }
}
