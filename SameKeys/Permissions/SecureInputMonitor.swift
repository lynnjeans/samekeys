import AppKit
import Carbon
import Observation
import OSLog

/// Watches macOS's Secure Input, which hides key presses from every event
/// tap — SameKeys's included — while it is on. A password field turns it
/// on while it has focus; some apps turn it on for longer, such as Terminal
/// with Secure Keyboard Entry, or leave it on by mistake. Keyboard rules then
/// do nothing, which looks like a SameKeys bug unless the user is told.
///
/// macOS sends no notification for it, so it is polled; the check is a
/// cheap system call.
@MainActor
@Observable
final class SecureInputMonitor {
    /// Who has Secure Input on right now, or nil while it is off.
    private(set) var holder: Holder?

    struct Holder: Equatable {
        /// The app that turned it on, when macOS says which.
        var appName: String?
        var bundleID: String?
        var since: Date
        /// The holder's process, to bring it back to the front.
        var pid: pid_t? = nil
        /// An app with windows and a Dock icon, as opposed to the login
        /// window, the Touch ID prompt and other system agents.
        var isRegularApp = false
    }

    /// How long Secure Input has to stay on before it no longer looks like
    /// a password being typed, and the app holding it is worth naming.
    static let lingering: TimeInterval = 30

    /// How long the holder has to be out of the front before it counts as
    /// left on in the background rather than a quick look elsewhere.
    static let backgroundDelay: TimeInterval = 3

    /// Reads the current state: whether it is on, and the holder's process.
    struct Reading {
        var isOn: Bool
        var pid: pid_t?
    }

    /// An app as the monitor needs it: who it is and what kind of app.
    struct App: Equatable {
        var name: String?
        var bundleID: String?
        var pid: pid_t
        var isRegular: Bool
    }

    @ObservationIgnored private let read: () -> Reading
    @ObservationIgnored private let app: (pid_t) -> App?
    @ObservationIgnored private let frontmost: () -> App?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var leftFrontAt: Date?

    init(read: @escaping () -> Reading = SecureInputMonitor.systemReading,
         app: @escaping (pid_t) -> App? = SecureInputMonitor.runningApp,
         frontmost: @escaping () -> App? = { NSWorkspace.shared.frontmostApplication.map(SecureInputMonitor.app(for:)) }) {
        self.read = read
        self.app = app
        self.frontmost = frontmost
    }

    func start() {
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Whether Secure Input has been on long enough that someone is holding
    /// it rather than typing a password. Updated on each poll.
    private(set) var isLingering = false

    /// Whether the holder is an app that has left the front for a while
    /// with Secure Input still on (SK-307): Chrome does this when the user
    /// switches away from one of its password fields, and every key press
    /// stays hidden from SameKeys until they go back and leave the field.
    private(set) var isHeldInBackground = false

    func refresh(now: Date = .now) {
        let reading = read()
        guard reading.isOn else {
            if holder != nil {
                Logger.permissions.notice("Secure Input off")
                holder = nil
                isLingering = false
                isHeldInBackground = false
                leftFrontAt = nil
            }
            return
        }
        if holder == nil {
            // While Secure Input stays on, macOS reports whichever app is in
            // front as its holder (measured with Chrome and WeChat, SK-307),
            // so the app is taken once, as it turns on: the one whose
            // password field the user has just clicked into.
            let owner = reading.pid.flatMap(app) ?? frontmost()
            holder = Holder(appName: owner?.name, bundleID: owner?.bundleID, since: now,
                            pid: owner?.pid, isRegularApp: owner?.isRegular ?? false)
            Logger.permissions.notice("Secure Input on, held by \(owner?.bundleID ?? "an unknown process", privacy: .public)")
        }
        guard let holder else { return }
        let lingering = now.timeIntervalSince(holder.since) >= Self.lingering
        if lingering != isLingering { isLingering = lingering }

        let front = frontmost()
        let isAway = holder.isRegularApp && holder.pid != nil && front?.pid != holder.pid
        if isAway {
            if leftFrontAt == nil {
                leftFrontAt = now
                Logger.permissions.notice("Secure Input holder \(holder.bundleID ?? "?", privacy: .public) left the front for \(front?.bundleID ?? "?", privacy: .public)")
            }
        } else {
            leftFrontAt = nil
        }
        let background = leftFrontAt.map { now.timeIntervalSince($0) >= Self.backgroundDelay } ?? false
        if background != isHeldInBackground {
            isHeldInBackground = background
            if background { Logger.permissions.notice("Secure Input left on in the background by \(holder.bundleID ?? "?", privacy: .public)") }
        }
    }

    nonisolated static func app(for app: NSRunningApplication) -> App {
        App(name: app.localizedName, bundleID: app.bundleIdentifier, pid: app.processIdentifier,
            isRegular: app.activationPolicy == .regular)
    }

    nonisolated static func runningApp(pid: pid_t) -> App? {
        NSRunningApplication(processIdentifier: pid).map(app(for:))
    }

    nonisolated static func systemReading() -> Reading {
        let isOn = IsSecureEventInputEnabled()
        // The session dictionary names the process holding it.
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let pid = (session?["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value
        return Reading(isOn: isOn, pid: pid)
    }
}

extension SecureInputMonitor.Holder {
    /// Where the user can switch it off, for apps known to offer that.
    var switchOffHint: String? {
        switch bundleID {
        case "com.apple.Terminal": String(localized: "In Terminal, uncheck Terminal › Secure Keyboard Entry.")
        case "com.googlecode.iterm2": String(localized: "In iTerm2, uncheck iTerm2 › Secure Keyboard Entry.")
        default: nil
        }
    }
}
