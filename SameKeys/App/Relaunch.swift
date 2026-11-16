import AppKit

enum Relaunch {
    /// Opens a new copy of SameKeys and quits this one: for changes read only
    /// at launch, such as the language and imported settings.
    /// `reopeningGuide` brings the setup guide back in the new copy, for a
    /// language picked in the guide itself (SK-303).
    @MainActor
    static func now(reopeningGuide: Bool = false) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        if reopeningGuide { configuration.arguments = [OnboardingController.reopenArgument] }
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
    }
}
