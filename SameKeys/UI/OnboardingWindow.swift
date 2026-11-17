import FinderSync
import SwiftUI

/// The first-run guide: why each permission is needed, a button to the pane
/// that grants it, and a closing step once both are in place.
///
/// Nothing here has a Continue button. The step follows the live permission
/// state, so granting a permission in System Settings moves the guide on by
/// itself, usually before the user has switched back.
struct OnboardingWindow: View {
    let onboarding: OnboardingController
    let rules: RulesController
    let clipboard: ClipboardController
    @Environment(\.dismiss) private var dismiss

    private var step: OnboardingController.Step {
        #if DEBUG
        if let step = LayoutCheck.onboardingStep { return step }
        #endif
        return onboarding.step
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepIndicator(current: step)
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
            Divider()
            content
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
                .padding(.horizontal, 32)
                .padding(.vertical, 16)
        }
        .frame(width: 560, height: 480)
        .background(WindowReader(window: $window))
        // The user is in System Settings when a step completes, so the guide
        // is behind it. Bring it forward so the next step is in view without
        // a trip to the menu bar. `activate()` would be refused while another
        // app is frontmost; ordering the window front is not.
        .onChange(of: step) {
            window?.orderFrontRegardless()
            onboarding.requestInputMonitoringIfNeeded()
        }
        .onAppear { onboarding.requestInputMonitoringIfNeeded() }
        .showsInDock()
        // Likewise when the guide first appears: at launch the app is not
        // frontmost — even when started from Finder — so the activation that
        // follows `openWindow` is refused and the guide would open behind.
        .onChange(of: window) { window?.orderFrontRegardless() }
    }

    @State private var window: NSWindow?

    @ViewBuilder private var content: some View {
        switch step {
        case .accessibility, .inputMonitoring:
            PermissionStep(step: step, onboarding: onboarding)
        case .ready:
            ReadyStep(rules: rules, clipboard: clipboard)
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            if step == .ready {
                // Next to the button that applies it (KB-242).
                if onboarding.loginItem.isAvailable {
                    Toggle("Open SameKeys at login", isOn: Binding(
                        get: { onboarding.opensAtLogin }, set: { onboarding.opensAtLogin = $0 }
                    ))
                    .toggleStyle(.checkbox)
                }
                // The globe alone: the checkbox and the button already
                // fill the row in French and Portuguese.
                GuideLanguagePicker(iconOnly: true)
                Spacer()
                Button("Start Using SameKeys") {
                    onboarding.finish()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .fixedSize()
            } else {
                // Closing without granting leaves the guide unfinished, so it
                // returns on the next launch. Until then the Overview and the
                // menu bar still say what is missing and lead back here.
                Button("Set Up Later") { dismiss() }
                GuideLanguagePicker()
                Spacer()
                Button("Open System Settings") { onboarding.openSettings() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// The language menu in the guide's footer, for someone who cannot read the
/// language their Mac is set to (SK-303). Unlike the sidebar's, it restarts
/// at once: the guide is all there is to see yet, and it comes back in the
/// new language where it left off.
private struct GuideLanguagePicker: View {
    var iconOnly = false
    private let current = AppLanguage.current

    var body: some View {
        // A menu rather than a picker, so it is as wide as the current
        // language's name and not the longest one's: the footer is narrow in
        // German already.
        Menu {
            ForEach(AppLanguage.allCases) { language in
                Toggle(language.name, isOn: Binding(get: { language == current }, set: { _ in
                    guard language != current else { return }
                    language.apply()
                    Relaunch.now(reopeningGuide: true)
                }))
            }
        } label: {
            if iconOnly {
                Image(systemName: "globe")
            } else {
                Label(current.name, systemImage: "globe")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Language")
    }
}

/// Hands a SwiftUI view the `NSWindow` it is shown in.
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The view has no window until it is inserted into the hierarchy.
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The three steps across the top, with the ones already done ticked off.
private struct StepIndicator: View {
    let current: OnboardingController.Step

    var body: some View {
        HStack(spacing: 12) {
            ForEach(OnboardingController.Step.allCases, id: \.self) { step in
                let state = progress(of: step)
                HStack(spacing: 6) {
                    Image(systemName: state == .done ? "checkmark.circle.fill" : "\(step.number).circle.fill")
                        .foregroundStyle(state == .upcoming ? Color.secondary : Color.accentColor)
                    Text(step.indicatorTitle)
                        .foregroundStyle(state == .upcoming ? Color.secondary : Color.primary)
                }
                .font(.subheadline.weight(state == .current ? .semibold : .regular))
                if step != .ready { Spacer(minLength: 8) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(current.number) of \(OnboardingController.stepCount): \(current.indicatorTitle)")
    }

    private enum Progress { case done, current, upcoming }

    private func progress(of step: OnboardingController.Step) -> Progress {
        if step.rawValue < current.rawValue { return .done }
        return step == current ? .current : .upcoming
    }
}

/// A step that asks for one permission.
private struct PermissionStep: View {
    let step: OnboardingController.Step
    let onboarding: OnboardingController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(step.headline)
                .font(.title2.bold())
            Text(step.explanation)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Open System Settings below — SameKeys takes you to the right pane.", systemImage: "1.circle")
                    // Once Accessibility is granted, macOS usually allows
                    // Input Monitoring without listing SameKeys; when this
                    // step does show, the row may be missing and + is the
                    // only way in.
                    if step.permission == .inputMonitoring {
                        Label("Switch **SameKeys** on. If it is not in the list, click **+** and choose it.", systemImage: "2.circle")
                    } else {
                        Label("Find **SameKeys** in the list and switch it on.", systemImage: "2.circle")
                    }
                    Label("Come back here. This window moves on by itself.", systemImage: "3.circle")
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for \(step.permission?.title ?? "")…")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            if step.permission == .accessibility {
                Text("macOS may ask for your password, and it locks these grants to SameKeys's signature: a rebuild from source asks again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The closing step, once both permissions are granted: what works already,
/// then the features that start off, each with its switch (SK-305). After
/// setup few people open the main window to look for them.
private struct ReadyStep: View {
    let rules: RulesController
    let clipboard: ClipboardController
    @State private var confirmingWinKey = false
    @State private var finderMenuIsOn = FIFinderSyncController.isExtensionEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("SameKeys is ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title2.bold())
            Text("Ctrl+C and Ctrl+V, Home and End, the mouse side buttons and zooming with the wheel work now. These start off; turn on the ones you want:")
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) {
                FeatureRow(symbol: "command", tint: .pink, title: RuleNames.name(ofGroup: "winKey"),
                           note: RuleNames.note(ofGroup: "winKey", style: rules.modifierLayout.triggerStyle).map { Text($0) }) {
                    Toggle(RuleNames.name(ofGroup: "winKey"), isOn: Binding(
                        get: { rules.isEnabled(group: "winKey") },
                        set: { isOn in
                            if isOn { confirmingWinKey = true } else { rules.setGroup("winKey", enabled: false) }
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                FeatureRow(symbol: "arrow.up.arrow.down", tint: .teal, title: String(localized: "Windows scroll direction"),
                           note: Text(WheelSettings.directionNote)) {
                    Toggle("Windows scroll direction", isOn: Binding(
                        get: { rules.wheelDirection == .windows },
                        set: { rules.setWheelDirection($0 ? .windows : .system) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                FeatureRow(symbol: "doc.on.clipboard.fill", tint: .purple, title: String(localized: "Clipboard history"),
                           note: Text(clipboard.isEnabled
                                      ? "Keeps what you copy — text, images and files — on this Mac only."
                                      : "Off. Turn it on to keep what you copy, like Win+V on Windows.")) {
                    Toggle("Clipboard history", isOn: Binding(
                        get: { clipboard.isEnabled }, set: { clipboard.isEnabled = $0 }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                // macOS switches Finder extensions on only in System Settings.
                FeatureRow(symbol: "contextualmenu.and.cursorarrow", tint: .blue, title: String(localized: "Finder right-click menu"),
                           note: Text("New documents and Open in Terminal on empty space in a folder.")) {
                    if finderMenuIsOn {
                        Label("On", systemImage: "checkmark")
                            .foregroundStyle(.green)
                    } else {
                        Button("Turn On…") { FIFinderSyncController.showExtensionManagementInterface() }
                    }
                }
            }
            Text("SameKeys lives in the menu bar. Open it from there whenever you want to change what a key does.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .winKeyConfirmation(isPresented: $confirmingWinKey, rules: rules)
        // Coming back from System Settings makes SameKeys active again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            finderMenuIsOn = FIFinderSyncController.isExtensionEnabled
        }
    }
}

/// One feature in the closing step: icon, name, one line, and its control.
private struct FeatureRow<Control: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let note: Text?
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: symbol, tint: tint, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.semibold))
                note?
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            control()
                .controlSize(.small)
        }
    }
}

private extension OnboardingController.Step {
    /// The short name in the step indicator.
    var indicatorTitle: String {
        switch self {
        case .accessibility: String(localized: "Accessibility")
        case .inputMonitoring: String(localized: "Input Monitoring")
        case .ready: String(localized: "Ready")
        }
    }

    var headline: String {
        switch self {
        case .accessibility: String(localized: "Let SameKeys change what your keys do")
        case .inputMonitoring: String(localized: "Let SameKeys see your key presses")
        case .ready: String(localized: "SameKeys is ready")
        }
    }

    /// Why macOS asks for this one, in the user's terms.
    var explanation: String {
        switch self {
        case .accessibility:
            String(localized: "Accessibility is what lets SameKeys turn a Windows shortcut into its Mac equivalent — pressing Ctrl+C and getting ⌘C. Without it macOS will not let any app rewrite input, and SameKeys can do nothing at all.")
        case .inputMonitoring:
            String(localized: "Input Monitoring is what lets SameKeys see ordinary keys, such as the C in Ctrl+C. Without it macOS delivers only modifiers, clicks and scrolling, so mouse buttons would work while keyboard shortcuts silently did not.")
        case .ready:
            String(localized: "Both permissions are granted.")
        }
    }
}

