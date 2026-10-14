import AppKit
import Carbon.HIToolbox
import CoreGraphics
import OSLog

/// The path every event takes through SameKeys: work out what it triggers,
/// find the rule that applies in the current context, and carry it out.
@MainActor
final class Dispatcher {
    // Carries a CGEvent, which is not Sendable; a disposition never leaves
    // the main thread, where the tap callback runs.
    enum Disposition: @unchecked Sendable {
        /// Let the original event continue to its destination.
        case passThrough
        /// Remove the original event.
        case consume
        /// Send this event on in place of the original.
        case replace(CGEvent)
    }

    /// The effective rules, for every keyboard without settings of its own.
    var rules: [Rule] = [] {
        didSet { matcher = RuleMatcher(rules: rules) }
    }

    private var matcher = RuleMatcher(rules: [])

    /// What a keyboard with a control key or Win and Alt keys of its own runs
    /// with (KB-243), prepared whenever the configuration changes so that a
    /// key press costs a lookup and nothing more.
    struct KeyboardProfile: Equatable {
        var rules: [Rule]
        var ctrlClick: CtrlClick?
    }

    /// Per keyboard; empty for everyone who has not set one, who then pay
    /// nothing for it: no event is asked which keyboard it came from.
    var keyboardProfiles: [Keyboard.ID: KeyboardProfile] = [:] {
        didSet { keyboardMatchers = keyboardProfiles.mapValues { RuleMatcher(rules: $0.rules) } }
    }

    private var keyboardMatchers: [Keyboard.ID: RuleMatcher] = [:]

    /// The keyboard an event came from (`KeyboardSource`); nil when it
    /// cannot be told, and the general rules apply.
    private let keyboard: @MainActor (CGEvent) -> Keyboard?

    /// The keyboard the last modifier was pressed on. Clicks, scrolling and
    /// a modifier tapped alone follow it: a click names the mouse it came
    /// from, never the keyboard the modifier is held on (measured, KB-020).
    private var modifierKeyboard: Keyboard.ID?

    /// Which way mouse wheels scroll.
    var wheelDirection = WheelDirection.system
    private let frontmostBundleID: @MainActor () -> String?
    private let isEditingText: @MainActor () -> Bool
    private let isInFileDialog: @MainActor () -> Bool

    /// Keys whose press was remapped and that are still held. Their repeats
    /// and release are rewritten to match the press, whatever modifiers are
    /// held by then: the user may let go of Ctrl before C.
    private var heldKeys: [KeyCode: HeldKey] = [:]

    private struct HeldKey {
        let ruleID: String
        /// What the press became; nil when the action was not a keystroke, in
        /// which case repeats and the release are swallowed.
        let output: KeyCombo?
    }

    /// Mouse buttons whose press was turned into an action and that are still
    /// held. Their release is swallowed too, so applications never see half
    /// a click.
    private var heldButtons: Set<Int> = []

    private var scrollStepper = ScrollStepper()

    private var modifierTap = ModifierTap()
    /// Nanoseconds, for how long a modifier was held. Replaceable so tests
    /// can hold one for longer than they take.
    private let now: @MainActor () -> UInt64
    /// With Secure Input on, macOS keeps key presses from the tap but not
    /// modifier changes, so ⌘A in a password field would look like ⌘ alone.
    private let isSecureInputOn: @MainActor () -> Bool

    /// Sends events that are not replacements, such as the keystroke a side
    /// button stands for. Replaceable so tests can capture them instead.
    private let post: @MainActor (CGEvent) -> Void

    /// Launches or brings forward an application, for rules that open one.
    /// Replaceable so tests do not start real apps.
    private let openApplication: @MainActor (String) -> Void

    /// The user's shortcuts for system functions. Replaceable so tests do not
    /// depend on this Mac's settings.
    private let systemShortcuts: @MainActor () -> SymbolicHotKeys
    /// Moves the frontmost window. Injected so tests need no real windows.
    private let snap: @MainActor (WindowAction) -> Void
    /// Acts on the open or save dialog in front. Injected for the same reason.
    private let fileDialog: @MainActor (FileDialogAction) -> Void
    /// Whether the clipboard history is on, and showing or hiding it.
    private let isClipboardHistoryOn: @MainActor () -> Bool
    private let toggleClipboardHistory: @MainActor () -> Void
    /// Selects the other input source. Injected so tests leave this Mac's
    /// input source alone.
    private let switchInputSource: @MainActor () -> Void
    /// The general pasteboard's change count, which tells whether Finder's
    /// files were last cut or copied (SK-301). Injected so tests need no
    /// pasteboard.
    private let pasteboardChangeCount: @MainActor () -> Int
    /// The change count when Ctrl+X last marked files to move in Finder.
    private var cutChangeCount: Int?

    init(
        frontmostBundleID: @escaping @MainActor () -> String?,
        isEditingText: @escaping @MainActor () -> Bool = { false },
        isInFileDialog: @escaping @MainActor () -> Bool = { false },
        post: @escaping @MainActor (CGEvent) -> Void = { SyntheticEvent.post($0) },
        openApplication: @escaping @MainActor (String) -> Void = { Dispatcher.launch($0) },
        systemShortcuts: @escaping @MainActor () -> SymbolicHotKeys = { SymbolicHotKeys.current() },
        snap: @escaping @MainActor (WindowAction) -> Void = { WindowElement.perform($0) },
        fileDialog: @escaping @MainActor (FileDialogAction) -> Void = { _ in },
        isClipboardHistoryOn: @escaping @MainActor () -> Bool = { false },
        toggleClipboardHistory: @escaping @MainActor () -> Void = {},
        switchInputSource: @escaping @MainActor () -> Void = {},
        pasteboardChangeCount: @escaping @MainActor () -> Int = { NSPasteboard.general.changeCount },
        now: @escaping @MainActor () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        isSecureInputOn: @escaping @MainActor () -> Bool = { IsSecureEventInputEnabled() },
        keyboard: @escaping @MainActor (CGEvent) -> Keyboard? = { _ in nil }
    ) {
        self.keyboard = keyboard
        self.now = now
        self.isSecureInputOn = isSecureInputOn
        self.frontmostBundleID = frontmostBundleID
        self.isEditingText = isEditingText
        self.isInFileDialog = isInFileDialog
        self.fileDialog = fileDialog
        self.isClipboardHistoryOn = isClipboardHistoryOn
        self.toggleClipboardHistory = toggleClipboardHistory
        self.switchInputSource = switchInputSource
        self.pasteboardChangeCount = pasteboardChangeCount
        self.post = post
        self.openApplication = openApplication
        self.systemShortcuts = systemShortcuts
        self.snap = snap
    }

    /// While set, the rule editor is recording a trigger: key presses and
    /// extra mouse buttons are handed here and swallowed instead of being
    /// matched. Reading them this early catches combinations the system
    /// would take for itself before they reach any window, such as fn+C
    /// opening Control Center.
    var recorder: (@MainActor (Trigger) -> Void)?

    /// While set, a diagnostic recording is running and every press worth
    /// recording is described here (KB-247); nil otherwise, when nothing is
    /// asked about it.
    var trace: (@MainActor (DispatchTrace) -> Void)?

    /// The keyboard of the last modifier change, as recorded: clicks and
    /// modifier taps are told by it.
    private var tracedModifierKeyboard: Keyboard?

    /// Buttons pressed while recording, whose release is swallowed too.
    private var recordedButtons: Set<Int> = []

    /// Sees every left button press and release, as they arrived: clicking
    /// the frontmost app's Dock icon minimizes its window (`DockClick`).
    var leftMouse: (@MainActor (CGEvent, CGEventType) -> Void)?

    /// Ctrl+click as ⌘+click (KB-222); nil while switched off.
    var ctrlClick: CtrlClick?

    /// Whether the left button's current press was made a ⌘+click, so its
    /// release is too.
    private var clickIsCommand = false

    func process(_ event: CGEvent, type: CGEventType) -> Disposition {
        if type == .flagsChanged, !keyboardProfiles.isEmpty, let keyboard = keyboard(event) {
            modifierKeyboard = keyboard.id
        }
        if type == .flagsChanged, trace != nil {
            tracedModifierKeyboard = keyboard(event)
        }
        let tapped = modifierTap(event, type: type)
        if let recorder {
            if let tapped {
                recorder(.key(combo: KeyCombo(tapped)))
            } else if let disposition = record(event, type: type, into: recorder) {
                return disposition
            }
        } else if let tapped {
            modifierTapped(tapped)
        }
        // Recording can end while the recorded button is still down.
        if type == .otherMouseUp, recordedButtons.remove(event.mouseButtonNumber) != nil {
            return .consume
        }
        switch type {
        case .keyDown:
            return keyDown(event)
        case .keyUp:
            return keyUp(event)
        case .otherMouseDown:
            return mouseDown(event)
        case .otherMouseUp:
            return heldButtons.remove(event.mouseButtonNumber) == nil ? .passThrough : .consume
        case .scrollWheel:
            return scroll(event)
        case .leftMouseDown, .leftMouseUp:
            leftMouse?(event, type)
            rewriteClick(event, type: type)
            return .passThrough
        default:
            return .passThrough
        }
    }

    /// Follows modifier keys for lone-modifier triggers, and returns the key
    /// this event completes a tap of. Every other key, click and scroll
    /// cancels one in progress.
    private func modifierTap(_ event: CGEvent, type: CGEventType) -> KeyCode? {
        switch type {
        case .flagsChanged:
            guard let key = modifierTap.flagsChanged(key: event.keyCode, flags: event.flags, now: now()),
                  !isSecureInputOn() else { return nil }
            return key
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            modifierTap.interrupt()
            return nil
        default:
            return nil
        }
    }

    /// A modifier tapped on its own. The key's own events went through; the
    /// action follows once the release has reached the app, so a keystroke
    /// posted for it does not arrive while the modifier still counts as held.
    private func modifierTapped(_ key: KeyCode) {
        let trigger = Trigger.key(combo: KeyCombo(key))
        let rule = matcher(for: modifierKeyboard).match(
            trigger, in: MatchContext(frontmostBundleID: frontmostBundleID()),
            isEditingText: isEditingText, isInFileDialog: isInFileDialog,
            isClipboardHistoryOn: isClipboardHistoryOn
        )
        report(trigger, keyboard: .lastModifier(tracedModifierKeyboard), rule: rule)
        guard let rule else { return }
        record(rule)
        DispatchQueue.main.async { [self] in carryOut(rule.action) }
    }

    private func record(_ event: CGEvent, type: CGEventType, into recorder: @MainActor (Trigger) -> Void) -> Disposition? {
        switch type {
        case .keyDown:
            if !event.isAutorepeat, let trigger = Trigger(event: event, type: type) {
                recorder(trigger)
            }
            return .consume
        case .keyUp:
            // The release of a key remapped before recording began still has
            // to go out, or its replacement would stay pressed.
            return heldKeys[event.keyCode] == nil ? .consume : nil
        case .otherMouseDown:
            if let trigger = Trigger(event: event, type: type) {
                recordedButtons.insert(event.mouseButtonNumber)
                recorder(trigger)
            }
            return .consume
        default:
            return nil
        }
    }

    /// Changes the flags of a left button event in place for Ctrl+click
    /// (KB-222). The press decides; its release follows it, whatever is held
    /// by then.
    private func rewriteClick(_ event: CGEvent, type: CGEventType) {
        if type == .leftMouseDown {
            clickIsCommand = false
            guard let ctrlClick = ctrlClick(for: keyboardID(of: event, type: type)),
                  let flags = ctrlClick.rewrite(event.flags) else { return }
            event.flags = flags
            clickIsCommand = true
        } else if clickIsCommand {
            clickIsCommand = false
            // Whichever keyboard's setting made the press a ⌘+click.
            event.flags = CtrlClick.release(event.flags)
        }
    }

    /// Releases every remapped key still held, so nothing is left pressed
    /// when the tap stops in the middle of a keystroke.
    func releaseHeldKeys() {
        for held in heldKeys.values {
            if let output = held.output, let release = SyntheticEvent.key(output, down: false) {
                post(release)
            }
        }
        heldKeys = [:]
        heldButtons = []
    }

    /// A mouse button press triggers its action once, as a complete
    /// keystroke; holding the button does not repeat it.
    private func mouseDown(_ event: CGEvent) -> Disposition {
        let rule = match(event, type: .otherMouseDown)
        if trace != nil, let trigger = Trigger(event: event, type: .otherMouseDown) {
            report(trigger, keyboard: .lastModifier(tracedModifierKeyboard), rule: rule)
        }
        guard let rule else { return .passThrough }
        record(rule)
        heldButtons.insert(event.mouseButtonNumber)
        carryOut(rule.action)
        return .consume
    }

    /// A matched scroll never reaches the application: while the modifier is
    /// held, the page should zoom, not also scroll. The action fires once per
    /// wheel notch, as the stepper decides.
    private func scroll(_ event: CGEvent) -> Disposition {
        guard let rule = match(event, type: .scrollWheel), let direction = event.scrollDirection else {
            // Not a rule's, so plain scrolling: the wheel's direction applies.
            // The event is changed in place and goes on.
            if wheelDirection.reverses(source: event.scrollSource, isNatural: event.isNaturalScrolling) {
                event.reverseScroll()
            }
            return .passThrough
        }
        record(rule)
        if scrollStepper.step(
            direction: direction, source: event.scrollSource,
            lines: event.scrollLines, timestamp: event.timestamp
        ) {
            carryOut(rule.action)
        }
        return .consume
    }

    /// Carries out an action triggered by something other than a key, so
    /// there is no original event to replace: a keystroke is posted as a
    /// complete press and release.
    private func carryOut(_ action: Action) {
        switch action {
        case .key(let combo):
            for down in [true, false] {
                if let keystroke = SyntheticEvent.key(combo, down: down) { post(keystroke) }
            }
        case .openApplication(let bundleID):
            openApplication(bundleID)
        case .systemAction(let function):
            trigger(function)
        case .windowAction(let position):
            move(position)
        case .fileDialog(let action):
            act(on: action)
        case .clipboardHistory:
            showClipboardHistory()
        }
    }

    /// Posts the user's shortcut for a system function, or opens the app that
    /// does the same when it has none; switches the input source directly. Nothing else is posted for a function
    /// switched off with no app to stand in; the rule editor says so.
    ///
    /// The shortcut is read after the tap callback returns, since reading
    /// another app's preferences can take a moment.
    private func trigger(_ function: SystemAction) {
        DispatchQueue.main.async { [self] in
            // Done by SameKeys itself, so the system's switcher stays away.
            if function == .inputSource { return switchInputSource() }
            switch systemShortcuts().shortcut(for: function) {
            case .combo(let combo):
                for down in [true, false] {
                    if let keystroke = SyntheticEvent.key(combo, down: down) { post(keystroke) }
                }
            case .off, .none:
                if let bundleID = function.fallbackApplication {
                    openApplication(bundleID)
                } else {
                    Logger.engine.notice("\(function.rawValue, privacy: .public) has no shortcut in System Settings; nothing posted")
                }
            }
        }
    }

    /// Snaps the frontmost window, after the tap callback returns: the
    /// Accessibility round trip to another app is far too slow to hold up the
    /// event stream, and a held key must not stall the keyboard.
    private func move(_ position: WindowAction) {
        DispatchQueue.main.async { [self] in snap(position) }
    }

    /// Acts on the dialog in front, after the tap callback returns: jumping
    /// takes keystrokes of its own and an Accessibility round trip.
    private func act(on action: FileDialogAction) {
        DispatchQueue.main.async { [self] in fileDialog(action) }
    }

    /// Shows or hides the history panel after the tap callback returns, as
    /// its own shortcut would.
    private func showClipboardHistory() {
        DispatchQueue.main.async { [self] in toggleClipboardHistory() }
    }

    private func keyDown(_ event: CGEvent) -> Disposition {
        let key = event.keyCode

        if let held = heldKeys[key] {
            // Auto-repeat of a key whose press was an action: nothing to
            // repeat, and no need to match again — matching can mean asking
            // the front app, some thirty times a second.
            guard let output = held.output else { return .consume }
            // Auto-repeat of a remapped key. If the modifiers changed mid-hold
            // the combination no longer applies; swallowing the rest of the
            // repeats beats suddenly typing the plain key.
            guard match(event, type: .keyDown)?.id == held.ruleID else { return .consume }
            return replacement(output, down: true, for: event)
        }

        // A repeat that would match only now, because a modifier was pressed
        // while the key was already held, belongs to a press that went out
        // unchanged; it goes out unchanged too, without being matched.
        guard !event.isAutorepeat else { return .passThrough }
        let rule = match(event, type: .keyDown)
        if trace != nil, let trigger = Trigger(event: event, type: .keyDown) {
            let sender = event.senderID
            let attribution: DispatchTrace.KeyboardAttribution = sender == 0
                ? .software : keyboard(event).map { .keyboard($0) } ?? .unknown(sender: sender)
            report(trigger, keyboard: attribution, rule: rule)
        }
        guard let rule else { return .passThrough }
        record(rule)

        switch rule.action {
        case .key(let combo):
            let combo = finderPaste(combo, for: rule)
            heldKeys[key] = HeldKey(ruleID: rule.id, output: combo)
            return replacement(combo, down: true, for: event)
        case .openApplication(let bundleID):
            heldKeys[key] = HeldKey(ruleID: rule.id, output: nil)
            openApplication(bundleID)
            return .consume
        case .systemAction(let function):
            heldKeys[key] = HeldKey(ruleID: rule.id, output: nil)
            trigger(function)
            return .consume
        case .windowAction(let position):
            heldKeys[key] = HeldKey(ruleID: rule.id, output: nil)
            move(position)
            return .consume
        case .fileDialog(let action):
            heldKeys[key] = HeldKey(ruleID: rule.id, output: nil)
            act(on: action)
            return .consume
        case .clipboardHistory:
            heldKeys[key] = HeldKey(ruleID: rule.id, output: nil)
            showClipboardHistory()
            return .consume
        }
    }

    /// Ctrl+V in Finder moves files only when Ctrl+X marked them: its ⌘C
    /// is then the last pasteboard change, or still on its way. After
    /// anything else, Ctrl+X included, it pastes copies, as File Explorer
    /// does, and a copy in the same folder becomes a duplicate (SK-301).
    private func finderPaste(_ combo: KeyCombo, for rule: Rule) -> KeyCombo {
        let id = rule.id.hasSuffix(".fn") ? String(rule.id.dropLast(3)) : rule.id
        switch id {
        case "finder.cut":
            cutChangeCount = pasteboardChangeCount()
        case "finder.move":
            if let cut = cutChangeCount, pasteboardChangeCount() - cut <= 1 { return combo }
            var paste = combo
            paste.modifiers.remove(.option)
            return paste
        default:
            break
        }
        return combo
    }

    private func keyUp(_ event: CGEvent) -> Disposition {
        guard let held = heldKeys.removeValue(forKey: event.keyCode) else { return .passThrough }
        guard let output = held.output else { return .consume }
        return replacement(output, down: false, for: event)
    }

    private func replacement(_ combo: KeyCombo, down: Bool, for original: CGEvent) -> Disposition {
        guard let event = SyntheticEvent.key(combo, down: down, replacing: original) else {
            Logger.engine.error("Could not create a replacement key event")
            return .passThrough
        }
        return .replace(event)
    }

    private func match(_ event: CGEvent, type: CGEventType) -> Rule? {
        guard let trigger = Trigger(event: event, type: type) else { return nil }
        return matcher(for: keyboardID(of: event, type: type)).match(
            trigger, in: MatchContext(frontmostBundleID: frontmostBundleID()),
            isEditingText: isEditingText, isInFileDialog: isInFileDialog,
            isClipboardHistoryOn: isClipboardHistoryOn
        )
    }

    /// The keyboard whose settings apply to `event`: a key's own keyboard,
    /// and for a click or scroll the one the last modifier was pressed on.
    /// Nobody is asked while no keyboard has settings of its own.
    private func keyboardID(of event: CGEvent, type: CGEventType) -> Keyboard.ID? {
        guard !keyboardProfiles.isEmpty else { return nil }
        switch type {
        case .keyDown, .keyUp: return keyboard(event)?.id
        default: return modifierKeyboard
        }
    }

    private func matcher(for keyboard: Keyboard.ID?) -> RuleMatcher {
        keyboard.flatMap { keyboardMatchers[$0] } ?? matcher
    }

    private func ctrlClick(for keyboard: Keyboard.ID?) -> CtrlClick? {
        if let keyboard, let profile = keyboardProfiles[keyboard] { return profile.ctrlClick }
        return ctrlClick
    }

    private static func launch(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            Logger.engine.error("No application with bundle identifier \(bundleID, privacy: .public)")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func report(_ trigger: Trigger, keyboard: DispatchTrace.KeyboardAttribution, rule: Rule?) {
        guard let trace else { return }
        let entry = DispatchTrace(trigger: trigger, keyboard: keyboard,
                                  frontmostBundleID: frontmostBundleID(), rule: rule)
        if entry.isWorthRecording { trace(entry) }
    }

    private func record(_ rule: Rule) {
        #if DEBUG
        matchCounts[rule.id, default: 0] += 1
        #endif
    }

    #if DEBUG
    /// KB_DEBUG_SYSACTION: triggers a system function as a rule would.
    func selfTestTrigger(_ function: SystemAction) {
        trigger(function)
    }

    /// How often each rule matched since the last call. Rule IDs are part of
    /// SameKeys's configuration, not user input, so they are safe to log.
    private var matchCounts: [String: Int] = [:]

    func takeMatchCounts() -> [String: Int] {
        defer { matchCounts = [:] }
        return matchCounts
    }
    #endif
}

extension Logger {
    static let engine = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "SameKeys",
        category: "engine"
    )
}
