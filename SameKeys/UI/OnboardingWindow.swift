import SwiftUI

/// The first-run guide: why each permission is needed, a button to the pane
/// that grants it, and a closing step once both are in place.
///
/// Nothing here has a Continue button. The step follows the live permission
/// state, so granting a permission in System Settings moves the guide on by
/// itself, usually before the user has switched back.
struct OnboardingWindow: View {
    let onboarding: OnboardingController
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
            ReadyStep()
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

/// The closing step, once both permissions are granted.
private struct ReadyStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("SameKeys is ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title2.bold())
            Text("Both permissions are granted, so SameKeys can be switched on. Your habits should work now:")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Label("Ctrl+C and Ctrl+V copy and paste.", systemImage: "doc.on.doc")
                Label("Home and End jump to the start and end of the line.", systemImage: "arrow.left.to.line")
                Label("The mouse side buttons go back and forward.", systemImage: "computermouse")
                Label("fn or Ctrl with the scroll wheel zooms the page.", systemImage: "plus.magnifyingglass")
            }
            .font(.callout)
            Text("SameKeys lives in the menu bar. Open it from there whenever you want to change what a key does.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

