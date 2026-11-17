import OSLog
import SwiftUI

/// The entry point. Opened from its disk image, SameKeys installs itself in
/// Applications and hands over to that copy before anything else runs
/// (KB-235): the app object's first property, the permission monitor, already
/// asks macOS about Input Monitoring, and asking from the disk image left it
/// "denied" with no row in System Settings for the installed copy.
@main
enum Launcher {
    @MainActor static func main() {
        // SameKeys asking itself about permissions from a fresh process
        // (PermissionService.statusesFromFreshProcess).
        if CommandLine.arguments.contains(PermissionService.reportArgument) {
            print(PermissionService.report())
            exit(0)
        }
        if MoveToApplications.installFromDiskImageBeforeLaunch() { exit(0) }
        SameKeysApp.main()
    }
}

struct SameKeysApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // With LSUIElement set there is no Dock icon, so the menu bar item is
        // the app's only permanent presence and the way into everything else.
        MenuBarExtra {
            MenuBarContent(engine: appDelegate.engine, onboarding: appDelegate.onboarding, secureInput: appDelegate.secureInput,
                           updates: appDelegate.updates, recorder: appDelegate.recorder)
        } label: {
            MenuBarIcon(isActive: appDelegate.engine.isActive && appDelegate.secureInput.holder == nil,
                        hasUpdate: appDelegate.updates.needsAttention, onboarding: appDelegate.onboarding)
        }

        Window("SameKeys", id: WindowID.main) {
            MainWindow(
                engine: appDelegate.engine,
                onboarding: appDelegate.onboarding,
                rules: appDelegate.rules,
                secureInput: appDelegate.secureInput,
                otherRemappers: appDelegate.otherRemappers,
                clipboard: appDelegate.clipboard,
                quickSwitch: appDelegate.quickSwitch,
                updates: appDelegate.updates,
                loginItem: appDelegate.loginItem,
                keyboards: appDelegate.keyboards,
                recorder: appDelegate.recorder,
                logArchive: appDelegate.logArchive
            )
        }
        .defaultSize(width: 880, height: 600)
        .windowResizability(.contentMinSize)
        // A samekeys:// URL from the Finder extension would otherwise open
        // this window; AppDelegate handles those URLs itself.
        .handlesExternalEvents(matching: [])

        // The first-run guide, sized by its content.
        Window("Set Up SameKeys", id: WindowID.onboarding) {
            OnboardingWindow(onboarding: appDelegate.onboarding, rules: appDelegate.rules, clipboard: appDelegate.clipboard)
        }
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: [])
    }
}

/// Identifiers for the app's windows, for use with `openWindow(id:)`.
enum WindowID {
    static let main = "main"
    static let onboarding = "onboarding"

    /// Brings a window that was just opened in front of the app the user is
    /// working in.
    ///
    /// `activate()` alone is only a request since macOS 14, and it is often
    /// refused when the click came through the menu bar item, which macOS 26
    /// hosts in Control Center rather than in SameKeys: the window then
    /// opened behind the frontmost app's. Ordering the window itself to the
    /// front is not refused, but leaves SameKeys inactive — the window in
    /// front, drawn grey, with the keyboard still in the other app.
    ///
    /// When that happens, SameKeys asks Launch Services to open it, as
    /// Finder or Spotlight would; that activation is honoured.
    @MainActor
    static func bringToFront(_ id: String) {
        NSApplication.shared.activate()
        // On a first open, SwiftUI creates the window after this returns.
        DispatchQueue.main.async {
            for window in NSApplication.shared.windows where window.identifier?.rawValue.hasPrefix(id) == true {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
            if !NSApplication.shared.isActive { activateThroughLaunchServices() }
        }
    }

    /// Makes SameKeys the active app for a window it did not open through
    /// SwiftUI, such as Sparkle's update window, the same way.
    @MainActor
    static func activateSameKeys() {
        NSApplication.shared.activate()
        DispatchQueue.main.async {
            if !NSApplication.shared.isActive { activateThroughLaunchServices() }
        }
    }

    /// Set while SameKeys is opening itself, so the reopen event this sends
    /// does not open the main window as well (`AppDelegate`).
    @MainActor static private(set) var isActivatingItself = false

    @MainActor
    private static func activateThroughLaunchServices() {
        guard !isActivatingItself else { return }
        isActivatingItself = true
        Logger.ui.notice("Activation refused; asking Launch Services")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error {
                Logger.ui.error("Could not activate through Launch Services: \(error.localizedDescription, privacy: .public)")
            }
            // The reopen event may still be on its way; give it a moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { isActivatingItself = false }
        }
    }
}

extension Logger {
    static let ui = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SameKeys", category: "ui")
}
