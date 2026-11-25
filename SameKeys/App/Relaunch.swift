import AppKit
import OSLog

enum Relaunch {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SameKeys", category: "ui")

    /// The launch argument that carries the restarting copy's process ID,
    /// right after it, so the new copy knows which process to wait for.
    static let previousCopyArgument = "--previous-pid"

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
        configuration.arguments = [previousCopyArgument, String(ProcessInfo.processInfo.processIdentifier)]
        if reopeningGuide { configuration.arguments.append(OnboardingController.reopenArgument) }
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

    /// Runs `body` as soon as the copy that restarted SameKeys has exited,
    /// or after `timeout` at the latest; right away when this copy was not
    /// started by a restart (SK-309).
    ///
    /// A window brought forward while that copy is still quitting loses the
    /// front again: when the active app quits, macOS gives the front to the
    /// app before it.
    @MainActor
    static func afterPreviousCopyQuits(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        timeout: TimeInterval = 3,
        _ body: @escaping @MainActor () -> Void
    ) {
        guard let pid = previousCopy(in: arguments), kill(pid, 0) == 0 else { return body() }
        let start = Date.now
        let wait = Wait {
            log.notice(
                "Previous copy \(kill(pid, 0) == 0 ? "still running" : "gone", privacy: .public) after \(Date.now.timeIntervalSince(start), format: .fixed(precision: 2), privacy: .public) s"
            )
            body()
        }
        // The kernel says when the process exits; no polling.
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { wait.finish() } }
        wait.source = source
        source.resume()
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { wait.finish() }
    }

    /// The process ID given after `previousCopyArgument`, if any.
    static func previousCopy(in arguments: [String]) -> pid_t? {
        guard let index = arguments.firstIndex(of: previousCopyArgument),
              arguments.indices.contains(index + 1)
        else { return nil }
        return pid_t(arguments[index + 1])
    }

    /// One wait for the previous copy: runs its body once, whichever comes
    /// first, the copy exiting or the timeout.
    @MainActor
    private final class Wait {
        private var body: (@MainActor () -> Void)?
        var source: DispatchSourceProcess?

        init(_ body: @escaping @MainActor () -> Void) {
            self.body = body
        }

        func finish() {
            guard let body else { return }
            self.body = nil
            source?.cancel()
            body()
        }
    }
}
