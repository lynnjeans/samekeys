import AppKit
import SwiftUI

/// The dropdown shown from the menu bar item: what SameKeys is doing, the
/// master switch, a quick pause, and the way into the main window.
struct MenuBarContent: View {
    let engine: EngineController
    let onboarding: OnboardingController
    let secureInput: SecureInputMonitor
    let updates: UpdateController
    let recorder: DiagnosticRecorder
    @Environment(\.openWindow) private var openWindow

    private var permissions: PermissionMonitor { engine.permissions }

    /// In the accent colour: a menu keeps a non-template image's colours.
    private static var updateIcon: Image {
        let symbol = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(paletteColors: [.white, .controlAccentColor]))!
        symbol.isTemplate = false
        return Image(nsImage: symbol)
    }

    var body: some View {
        // Where a scheduled check leaves a new version, next to the dot on
        // the icon, instead of opening a window on its own (KB-101).
        if let pending = updates.pending {
            // An icon and a "New" badge, since a menu item's text cannot be
            // coloured or made bold.
            Group {
                if pending.isDownloaded {
                    Button { updates.installNow() } label: {
                        Label { Text("Restart to Install SameKeys \(pending.version)") } icon: { Self.updateIcon }
                    }
                } else {
                    Button { updates.checkForUpdates() } label: {
                        Label { Text("SameKeys \(pending.version) Is Available…") } icon: { Self.updateIcon }
                    }
                }
            }
            // Its own key: plain "New" is Finder's New menu, 新建 in Chinese.
            .badge(Text(String(localized: "update.badge", defaultValue: "New",
                               comment: "Badge on the menu item for a new SameKeys version")))
            Divider()
        }

        // A recording runs for minutes, often with the window closed; this
        // says so and ends it (KB-247).
        if recorder.isRecording {
            Button {
                recorder.stop()
            } label: {
                Label("Recording Shortcuts — Stop", systemImage: "record.circle")
            }
        }

        // The master switch, with what is wrong underneath when something
        // is; a status line of its own only repeated the checkmark (KB-249).
        Toggle(isOn: Binding(
            get: { engine.isEnabled && engine.canEnable },
            set: { engine.isEnabled = $0 }
        )) {
            Text("Enable SameKeys")
            if let problem {
                Text(problem)
            }
        }
        .disabled(!engine.canEnable)

        if engine.isPaused {
            Button("Resume Now") { engine.resume() }
        } else {
            Menu("Pause") {
                Button("For 5 Minutes") { engine.pause(for: 5 * 60) }
                Button("For 15 Minutes") { engine.pause(for: 15 * 60) }
                Button("For 1 Hour") { engine.pause(for: 60 * 60) }
            }
            .disabled(!engine.isActive)
        }

        // Only when something is missing; the Overview has the full picture.
        if !permissions.allGranted {
            Section("Permissions") {
                ForEach(Permission.allCases, id: \.self) { permission in
                    let granted = permissions.status(of: permission) == .granted
                    Button {
                        if !granted { NSWorkspace.shared.open(permission.settingsURL) }
                    } label: {
                        Label(
                            granted ? "\(permission.title): Granted" : "\(permission.title): Not granted — Open Settings…",
                            systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                    }
                }
                Button("Set Up Permissions…") { onboarding.open() }
            }
        }

        Divider()

        Button("Open SameKeys…") {
            openWindow(id: WindowID.main)
            WindowID.bringToFront(WindowID.main)
        }
        .keyboardShortcut(",")

        Divider()

        // With Quit, where menu bar apps usually keep it (user's call), and
        // Check for Updates with it, as apps do (KB-249).
        Button("About SameKeys") {
            PageRequest.show(.about)
            openWindow(id: WindowID.main)
            WindowID.bringToFront(WindowID.main)
        }

        Button("Check for Updates…") { updates.checkForUpdates() }
            .disabled(!updates.canCheckForUpdates)

        Button("Quit SameKeys") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// What keeps SameKeys from working right now, under the switch; nil
    /// while it works, or while the user has it off, which the switch shows.
    private var problem: String? {
        if !engine.canEnable { return String(localized: "SameKeys needs permissions") }
        if !engine.isEnabled { return nil }
        if let until = engine.pausedUntil {
            return until == .distantFuture
                ? String(localized: "Paused")
                : String(localized: "Paused until \(until.formatted(date: .omitted, time: .shortened))")
        }
        if !engine.isActive { return String(localized: "SameKeys could not start") }
        if let holder = secureInput.holder {
            if secureInput.isHeldInBackground, let name = holder.appName {
                return String(localized: "Keyboard paused: \(name) left Secure Input on in the background")
            }
            return holder.appName.map { String(localized: "Keyboard paused by Secure Input (\($0))") }
                ?? String(localized: "Keyboard paused by Secure Input")
        }
        return nil
    }

}

extension Permission {
    /// The name System Settings uses for the permission.
    var title: String {
        switch self {
        case .accessibility: String(localized: "Accessibility")
        case .inputMonitoring: String(localized: "Input Monitoring")
        }
    }

    /// Why SameKeys needs it, in the user's terms.
    var purpose: String {
        switch self {
        case .accessibility: String(localized: "Lets SameKeys replace shortcuts, clicks and scrolling with their Mac equivalents.")
        case .inputMonitoring: String(localized: "Lets SameKeys see ordinary key presses, such as the C in Ctrl+C.")
        }
    }

    /// What to expect in System Settings, where the pane may not show
    /// SameKeys at all: once Accessibility is granted, macOS allows Input
    /// Monitoring without storing a decision, so there is no row.
    func settingsHint(granted: Bool) -> String? {
        switch self {
        case .accessibility:
            nil
        case .inputMonitoring:
            granted
                ? String(localized: "macOS grants this together with Accessibility and may not list SameKeys under Input Monitoring.")
                : String(localized: "If SameKeys is not in the Input Monitoring list, click + and choose SameKeys.")
        }
    }
}
