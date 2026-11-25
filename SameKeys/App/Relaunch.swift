import AppKit

enum Relaunch {
    /// Opens a new copy of SameKeys and quits this one: for changes read only
    /// at launch, such as the language and imported settings.
    /// `reopeningGuide` brings the setup guide back in the new copy, for a
    /// language picked in the guide itself (SK-303).
    ///
    /// This copy is the active app, so it hands the front to the new one
    /// before quitting (SK-309). Otherwise macOS gives the front back to the
    /// app before SameKeys, and the new copy's window opens behind it.
    @MainActor
    static func now(reopeningGuide: Bool = false) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        if reopeningGuide { configuration.arguments = [OnboardingController.reopenArgument] }
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { app, _ in
            DispatchQueue.main.async {
                if let app {
                    NSApplication.shared.yieldActivation(to: app)
                    app.activate(from: .current)
                }
                NSApplication.shared.terminate(nil)
            }
        }
    }

    /// Runs `body` once no other copy of SameKeys is running, or after
    /// `timeout` at the latest (SK-309): a window brought forward while the
    /// copy that restarted is still quitting can lose the front to it.
    @MainActor
    static func afterPreviousCopyQuits(timeout: TimeInterval = 5, _ body: @escaping @MainActor () -> Void) {
        let deadline = Date.now.addingTimeInterval(timeout)
        func check() {
            guard otherCopyIsRunning, Date.now < deadline else { return body() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { check() }
        }
        check()
    }

    /// Asks the system rather than `NSRunningApplication`, whose list is
    /// updated through the run loop and can still hold a copy that is gone.
    @MainActor
    private static var otherCopyIsRunning: Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).contains {
            $0.processIdentifier != me && kill($0.processIdentifier, 0) == 0
        }
    }
}
