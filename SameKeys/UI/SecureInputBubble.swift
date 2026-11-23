import AppKit
import SwiftUI

/// A small bubble under the menu bar icon when an app in the background has
/// left Secure Input on (SK-307). Every key press is hidden from SameKeys
/// then, in every app, and nothing on screen says why: Chrome leaves it on
/// when the user switches away from one of its password fields, until they
/// go back and leave the field.
///
/// No notification, so no permission to ask for. Shown once each time
/// Secure Input turns on; closed by hand, it stays closed until it ends.
@MainActor
final class SecureInputBubbleController {
    private let monitor: SecureInputMonitor
    private var panel: NSPanel?
    /// The holder the user closed the bubble for, by when it turned on.
    private var closedFor: Date?

    init(monitor: SecureInputMonitor) {
        self.monitor = monitor
    }

    func start() {
        observe()
    }

    /// Follows the monitor; the observation fires once, so it is set again.
    private func observe() {
        withObservationTracking {
            update(holder: monitor.holder, inBackground: monitor.isHeldInBackground)
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observe() }
        }
    }

    private func update(holder: SecureInputMonitor.Holder?, inBackground: Bool) {
        guard let holder else {
            closedFor = nil
            hide()
            return
        }
        guard inBackground, closedFor != holder.since else {
            hide()
            return
        }
        show(holder)
    }

    private func show(_ holder: SecureInputMonitor.Holder) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let view = SecureInputBubbleView(
            appName: holder.appName,
            switchOffHint: holder.switchOffHint,
            goBack: { [weak self] in
                if let pid = holder.pid { Self.bringToFront(pid) }
                self?.hide()
            },
            close: { [weak self] in
                self?.closedFor = holder.since
                self?.hide()
            }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize
        panel.setContentSize(hosting.fittingSize)
        panel.contentView = hosting
        position(panel)
        guard !panel.isVisible else { return }
        panel.orderFrontRegardless()
    }

    /// Brings the holder back. `activate()` is refused for a click in this
    /// panel, which never makes SameKeys the active app, so the app is
    /// opened through Launch Services as the Dock would.
    private static func bringToFront(_ pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        guard let url = app.bundleURL else {
            app.activate()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: SecureInputBubbleView.width, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .sameKeysPanel
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        return panel
    }

    /// Under the menu bar icon when its window can be found on a screen,
    /// otherwise in the top right corner of the screen with the menu bar.
    private func position(_ panel: NSPanel) {
        let size = panel.frame.size
        if let icon = Self.iconFrame(),
           let screen = NSScreen.screens.first(where: { $0.frame.intersects(icon) }),
           Self.isInView(icon, on: screen) {
            let visible = screen.visibleFrame
            let x = min(max(icon.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
            panel.setFrameOrigin(NSPoint(x: x, y: min(icon.minY, visible.maxY) - size.height - 6))
            return
        }
        guard let visible = NSScreen.screens.first?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 8, y: visible.maxY - size.height - 6))
    }

    /// The menu bar icon's frame on screen, read from the window SwiftUI put
    /// it in (as `MenuBarIcon.setItemVisible` finds it); nil when hidden.
    private static func iconFrame() -> NSRect? {
        for window in NSApp.windows where String(describing: type(of: window)) == "NSStatusBarWindow" {
            guard window.isVisible, window.frame.width > 0 else { continue }
            return window.frame
        }
        return nil
    }

    /// Whether the icon can be seen: on a screen with a camera housing, a
    /// full menu bar pushes it behind the notch, where a bubble pointing at
    /// it would point at nothing.
    private static func isInView(_ icon: NSRect, on screen: NSScreen) -> Bool {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return true }
        return left.minX <= icon.midX && icon.midX <= left.maxX || right.minX <= icon.midX && icon.midX <= right.maxX
    }
}

/// The bubble's content: what happened, and how to end it.
private struct SecureInputBubbleView: View {
    static let width: CGFloat = 320

    let appName: String?
    let switchOffHint: String?
    let goBack: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                IconTile(symbol: "lock.fill", tint: .orange, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Keyboard shortcuts paused")
                        .font(.callout.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            if let appName {
                HStack {
                    Spacer()
                    Button(String(localized: "Go to \(appName)"), action: goBack)
                        .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(width: Self.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }

    private var detail: String {
        // Terminal's Secure Keyboard Entry stays on by design: say where
        // to switch it off instead.
        if let switchOffHint, let appName {
            return String(localized: "\(appName) has Secure Input on in the background, so macOS hides every key press from SameKeys.") + " " + switchOffHint
        }
        return appName.map {
            String(localized: "\($0) left Secure Input on in the background, so macOS hides every key press from SameKeys. Go back to \($0) and click outside its password field.")
        } ?? String(localized: "An app in the background left Secure Input on, so macOS hides every key press from SameKeys. Go back to it and click outside its password field.")
    }
}
