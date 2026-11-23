import AppKit
import SwiftUI

/// The first page: the master switch, the preset in use, a few counts, the
/// permissions and whatever deserves a word right now.
struct OverviewPage: View {
    let engine: EngineController
    let onboarding: OnboardingController
    let rules: RulesController
    let secureInput: SecureInputMonitor
    let otherRemappers: OtherRemapperMonitor
    let loginItem: LoginItem
    let open: (Page) -> Void

    var body: some View {
        // Keyboards that differ copy with either: "Ctrl or fn".
        ModeCard(engine: engine, controlKey: rules.controlKeysInUse.count > 1 ? .both : rules.controlKey)

        if engine.isActive, let holder = secureInput.holder {
            SecureInputNotice(holder: holder, isLingering: secureInput.isLingering,
                              isInBackground: secureInput.isHeldInBackground)
        }

        if !otherRemappers.running.isEmpty {
            OtherRemapperNotice(tools: otherRemappers.running)
        }

        Card {
            HStack(spacing: 14) {
                IconTile(symbol: "list.bullet.rectangle", tint: .indigo, size: 34)
                AdaptiveRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Preset: \(RuleNames.presetName(rules.preset.id))")
                            .font(.headline)
                        Text(presetDetail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    WrappingControls {
                        Button("Customize…") { open(.shortcuts) }
                        RestoreDefaultsButton(rules: rules)
                    }
                }
            }
        }

        HStack(spacing: 12) {
            StatTile(value: rules.activeRuleCount, label: "Active rules")
            StatTile(value: rules.customizedCount, label: "Customized")
            StatTile(value: rules.exceptionApps.count, label: "App exceptions")
        }

        if engine.permissions.allGranted {
            PermissionsSummary()
        } else {
            PermissionsCard(permissions: engine.permissions, onboarding: onboarding)
        }

        LoginItemCard(loginItem: loginItem)
        MenuBarIconCard()

        ForEach(Array(notices.enumerated()), id: \.offset) { _, notice in
            Label {
                Text(notice).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle.fill").foregroundStyle(Color.accentColor)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
    }

    private var presetDetail: LocalizedStringKey {
        let groupsOn = rules.preset.groups.filter { rules.isEnabled(group: $0.id) }.count
        let changed = rules.customizedCount
        return changed == 0
            ? "\(groupsOn) of \(rules.preset.groups.count) groups on."
            : "\(groupsOn) of \(rules.preset.groups.count) groups on, \(changed) entries customized."
    }

    /// Things worth knowing about the current setup, each only while it
    /// applies.
    private var notices: [LocalizedStringKey] {
        var notices: [LocalizedStringKey] = []
        // One notice for each way a keyboard is set up (KB-076): with a
        // MacBook on fn and a PC keyboard on Ctrl, both are true.
        if rules.exceptionApps.contains(where: BuiltInRules.terminals.contains) {
            let keys = rules.controlKeysInUse
            if keys.contains(.function) {
                notices.append("Home, End and Ctrl+arrow keys are left alone in terminals; fn shortcuts work there too.")
            }
            if keys.contains(.control) || keys.contains(.both) {
                notices.append("Ctrl shortcuts are left alone in terminals, where Ctrl+C stops the running program.")
            }
        }
        if rules.isEnabled(group: "winKey") {
            let layouts = rules.modifierLayoutsInUse
            if layouts.contains(.pcKeyboard) {
                notices.append("Windows key shortcuts are on with Win as ⌘: ⌘Tab opens Mission Control (switch apps with ⌥Tab), ⌘V the clipboard history while it is on, and ⌘Space, ⌘L, ⌘E, ⌘D, ⌘. and ⌘⇧S, and ⌘ tapped on its own, are taken too.")
            }
            if layouts.contains(.macPosition) {
                notices.append("Windows key shortcuts are on with Win as ⌥: ⌥Tab opens Mission Control, ⌥Space, ⌥L, ⌥E, ⌥D, ⌥. and ⌥⇧S no longer type characters, and ⌥ tapped on its own opens Apps.")
            }
        }
        return notices
    }
}

/// One count, large, with what it counts under it.
private struct StatTile: View {
    let value: Int
    let label: LocalizedStringKey

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 2) {
                Text(value, format: .number)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The permissions in one line once everything is granted; the full card,
/// with a row per permission, takes over as soon as one is missing.
private struct PermissionsSummary: View {
    var body: some View {
        Card {
            HStack(spacing: 14) {
                IconTile(symbol: "checkmark", tint: .green, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("System Permissions")
                        .font(.headline)
                    Text("Accessibility and Input Monitoring are both granted.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text("Ready")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(.green.opacity(0.14), in: Capsule())
            }
        }
    }
}

/// Whether SameKeys shows its icon in the menu bar (SK-274). Hidden, it keeps
/// working, and opening it again brings this window back.
private struct MenuBarIconCard: View {
    @AppStorage(MenuBarIcon.showsKey) private var showsIcon = true

    var body: some View {
        Card {
            HStack(spacing: 14) {
                IconTile(symbol: "menubar.rectangle", tint: .indigo, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show in Menu Bar")
                        .font(.headline)
                    Text(showsIcon
                         ? "The ∞ in the menu bar shows whether SameKeys is on and opens its menu."
                         : "Hidden. SameKeys keeps working; to come back here, open SameKeys again from Applications or Spotlight.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("Show in Menu Bar", isOn: $showsIcon)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
    }
}

/// Whether SameKeys opens at login (KB-242). The switch shows what the
/// system has, read again whenever the window comes back into view, so a
/// change made in System Settings is not missed.
private struct LoginItemCard: View {
    let loginItem: LoginItem

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    IconTile(symbol: "power", tint: .teal, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open at Login")
                            .font(.headline)
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("Open at Login", isOn: Binding(
                        get: { loginItem.isEnabled },
                        set: { loginItem.set($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!loginItem.isAvailable)
                }
                if loginItem.hasFailed {
                    Label("macOS did not make the change. It can be made under System Settings › General › Login Items & Extensions.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Login Items Settings") { LoginItem.openSystemSettings() }
                }
            }
        }
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }

    private var detail: LocalizedStringKey {
        loginItem.isAvailable
            ? "SameKeys starts when you log in, so your shortcuts work right after a restart."
            : "Available once SameKeys is in the Applications folder."
    }
}

/// Says why keyboard rules are doing nothing while Secure Input is on.
private struct SecureInputNotice: View {
    let holder: SecureInputMonitor.Holder
    let isLingering: Bool
    var isInBackground = false

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                IconTile(symbol: "lock.fill", tint: .orange, size: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Keyboard shortcuts paused by macOS")
                        .font(.headline)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var detail: String {
        // Whole sentences, so each language can order them its own way.
        var parts = [holder.appName.map {
            String(localized: "\($0) has turned on Secure Input, which hides key presses from apps like SameKeys — a macOS safeguard for passwords, not a fault. Mouse buttons and scrolling still work.")
        } ?? String(localized: "An app has turned on Secure Input, which hides key presses from apps like SameKeys — a macOS safeguard for passwords, not a fault. Mouse buttons and scrolling still work.")]
        if isInBackground, holder.switchOffHint == nil, let name = holder.appName {
            parts.append(String(localized: "\(name) left it on when you switched away. Go back to \(name) and click outside its password field."))
        } else if isLingering {
            parts.append(String(localized: "It has been on for a while, so it is probably not a password field."))
            parts.append(holder.switchOffHint ?? holder.appName.map { String(localized: "Quitting \($0) ends it.") }
                ?? String(localized: "Quitting that app ends it."))
        } else {
            parts.append(String(localized: "It ends when you leave the password field."))
        }
        return parts.joined(separator: " ")
    }

}

/// Names the other remapping tools that are running, since their rules and
/// SameKeys's act on the same keys, buttons and scrolling.
private struct OtherRemapperNotice: View {
    let tools: [String]

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                IconTile(symbol: "exclamationmark.triangle.fill", tint: .orange, size: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(tools.count == 1
                         ? "\(tools[0]) is running"
                         : "Other remapping tools are running")
                        .font(.headline)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var detail: String {
        tools.count == 1
            ? String(localized: "It can change keys, mouse buttons and scrolling before SameKeys sees them, so some shortcuts may do nothing or the wrong thing. Quit it while you use SameKeys, or turn off its settings that overlap.")
            : String(localized: "\(tools.formatted()) can change keys, mouse buttons and scrolling before SameKeys sees them, so some shortcuts may do nothing or the wrong thing. Quit them while you use SameKeys, or turn off their settings that overlap.")
    }
}

/// Puts the preset back as it ships, after asking.
struct RestoreDefaultsButton: View {
    let rules: RulesController
    @State private var confirming = false

    var body: some View {
        Button("Restore Defaults…") { confirming = true }
            .disabled(rules.isDefault)
            .help(rules.isDefault ? "The preset is as it ships" : "Undo every change to the preset")
            .alert("Restore the preset's defaults?", isPresented: $confirming) {
                Button("Restore Defaults", role: .destructive) { rules.restoreDefaults() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All groups and entries go back to the preset. Your custom rules are kept.")
            }
    }
}
