import AppKit
import ApplicationServices
import OSLog

/// Terminals inside other apps (SK-298): the terminal panel of VS Code,
/// Cursor or the Claude app, where Ctrl+C has to interrupt as it does in
/// Terminal while the rest of the app copies with it.
///
/// They are all xterm.js, which keeps keyboard focus in a hidden text area
/// of the class `xterm-helper-textarea`, and Chromium shows a page's classes
/// to Accessibility as `AXDOMClassList` (measured in VS Code and Claude,
/// 2026-10-12).
@MainActor
final class EmbeddedTerminal {
    nonisolated static let focusClass = "xterm-helper-textarea"

    /// The last answer, so the log notes a change rather than every press.
    private var wasInTerminal = false

    /// Whether keyboard focus in the app `pid` is in such a terminal.
    ///
    /// Called from the event tap, and only for rules that stand aside in
    /// terminals, so it must be quick: each query gives up after 50 ms, and
    /// then the focus counts as not in a terminal.
    func hasFocus(in pid: pid_t, of bundleID: String?) -> Bool {
        let isInTerminal = Self.isTerminal(classList: Self.focusedClassList(in: pid))
        if isInTerminal != wasInTerminal {
            wasInTerminal = isInTerminal
            Logger.engine.notice(
                "\(isInTerminal ? "Focus is in a terminal in" : "Focus left the terminal in", privacy: .public) \(bundleID ?? "?", privacy: .public): Ctrl shortcuts \(isInTerminal ? "left alone" : "translated again", privacy: .public)"
            )
        }
        return isInTerminal
    }

    nonisolated static func isTerminal(classList: [String]) -> Bool {
        classList.contains(focusClass)
    }

    private static func focusedClassList(in pid: pid_t) -> [String] {
        // The app's own element: the system-wide one could not name the
        // focused element in Electron apps (-25204, measured).
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return [] }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.05)
        var classes: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXDOMClassList" as CFString, &classes) == .success else {
            return []
        }
        return classes as? [String] ?? []
    }
}

/// Electron apps show Accessibility nothing of their pages until asked to
/// (`AXManualAccessibility`), and then take a moment to build it, over a
/// second in VS Code (measured). So each is asked as it comes to the front,
/// never at a key press (SK-298). Other apps are left alone.
@MainActor
final class ElectronAccessibility {
    /// Apps already asked, by process.
    private var asked: Set<pid_t> = []
    // Kept for the app's lifetime, so the observers are never removed.
    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { app.map { self?.activated($0) } }
        })
        // A process number comes back for another app once this one quits.
        observers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { app.map { _ = self?.asked.remove($0.processIdentifier) } }
        })
        if let front = NSWorkspace.shared.frontmostApplication { activated(front) }
    }

    private func activated(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard !asked.contains(pid), let url = app.bundleURL, Self.isElectron(url) else { return }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.25)
        let result = AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        // Without the Accessibility permission this fails; it is asked again
        // the next time the app comes to the front.
        guard result == .success else { return }
        asked.insert(pid)
        Logger.engine.notice("Accessibility switched on for \(app.bundleIdentifier ?? "?", privacy: .public), for terminals inside it")
    }

    nonisolated static func isElectron(_ bundleURL: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: bundleURL.appending(path: "Contents/Frameworks/Electron Framework.framework").path
        )
    }
}
