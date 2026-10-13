import CoreGraphics
import Foundation
import Testing

/// Win+V opens the clipboard history on every keyboard (KB-245): a rule in
/// the Windows Key group, so it follows each keyboard's Win key, where the
/// history's own shortcut is a system hot key that does not.
@MainActor
@Suite struct ClipboardHistoryRuleTests {
    private typealias Keyboards = PerKeyboardTests
    private let context = MatchContext(frontmostBundleID: "com.apple.TextEdit")
    private let winV = Rule(id: "winKey.clipboard", trigger: .key(combo: KeyCombo([.command], .v)),
                            action: .clipboardHistory)

    final class History {
        var isOn = true
        var toggles = 0
    }
    private let history = History()
    private let keyboards = PerKeyboardTests()

    /// The user's setup: the MacBook on fn with Win by position (⌥), and a PC
    /// keyboard as printed (Ctrl, Win as ⌘), Windows key shortcuts on.
    private func makeEngine() -> (Dispatcher, RulesController) {
        let dispatcher = Dispatcher(
            frontmostBundleID: { "com.apple.TextEdit" },
            isClipboardHistoryOn: { [history] in history.isOn },
            toggleClipboardHistory: { [history] in history.toggles += 1 },
            keyboard: { event in
                switch Int64(bitPattern: event.senderID) {
                case Keyboards.builtInSender: Keyboards.builtIn
                case Keyboards.externalSender: Keyboards.external
                default: nil
                }
            }
        )
        let rules = RulesController(
            store: keyboards.store,
            applyKeyboards: { dispatcher.keyboardProfiles = $0 },
            apply: { dispatcher.rules = $0 }
        )
        rules.setControlKey(.function)
        rules.setModifierLayout(.macPosition)
        rules.setGroup("winKey", enabled: true)
        rules.setConnectedKeyboards([Keyboards.builtIn, Keyboards.external])
        return (dispatcher, rules)
    }

    /// Presses V and lets the history be shown, which happens after the tap
    /// callback returns. Nil when the press went on untouched.
    private func pressV(_ dispatcher: Dispatcher, _ flags: CGEventFlags, from sender: Int64) async throws -> Dispatcher.Disposition {
        let down = try keyboards.key(.v, flags, from: sender)
        let disposition = dispatcher.process(down, type: .keyDown)
        let up = try keyboards.key(.v, flags, from: sender)
        up.type = .keyUp
        _ = dispatcher.process(up, type: .keyUp)
        try await Task.sleep(for: .milliseconds(50))
        return disposition
    }

    private func isConsumed(_ disposition: Dispatcher.Disposition) -> Bool {
        if case .consume = disposition { true } else { false }
    }

    private func isUntouched(_ disposition: Dispatcher.Disposition) -> Bool {
        if case .passThrough = disposition { true } else { false }
    }

    // MARK: - The preset

    @Test func winVIsInTheWindowsKeyGroupWrittenAsCommandV() {
        let group = BuiltInRules.preset.groups.first { $0.id == "winKey" }
        #expect(group?.rules.contains(winV) == true)
        #expect(group?.isEnabledByDefault == false)
    }

    @Test func theActionIsSavedUnderItsName() throws {
        let json = String(decoding: try JSONEncoder().encode(Action.clipboardHistory), as: UTF8.self)
        #expect(json == #"{"clipboardHistory":{}}"#)
        #expect(try JSONDecoder().decode(Action.self, from: Data(json.utf8)) == .clipboardHistory)
    }

    // MARK: - Matching

    /// While the history is off, its keys do what they did before: ⌘V
    /// pastes, and another rule on them gets its turn.
    @Test func matchesOnlyWhileTheHistoryIsOn() {
        let other = Rule(id: "custom.v", trigger: winV.trigger, action: .key(combo: KeyCombo([.command], .c)))
        let matcher = RuleMatcher(rules: [winV, other])
        #expect(matcher.match(winV.trigger, in: context, isClipboardHistoryOn: { true })?.id == winV.id)
        #expect(matcher.match(winV.trigger, in: context, isClipboardHistoryOn: { false })?.id == other.id)
        #expect(RuleMatcher(rules: [winV]).match(winV.trigger, in: context, isClipboardHistoryOn: { false }) == nil)
    }

    @Test func theHistoryIsAskedAboutOnlyForItsRules() {
        var asked = 0
        let copy = Rule(id: "edit.copy", trigger: .key(combo: KeyCombo([.control], .c)),
                        action: .key(combo: KeyCombo([.command], .c)))
        let matcher = RuleMatcher(rules: [winV, copy])
        _ = matcher.match(copy.trigger, in: context, isClipboardHistoryOn: { asked += 1; return true })
        #expect(asked == 0)
    }

    // MARK: - Each keyboard

    @Test func aPCKeyboardsWinVOpensTheHistoryAndCtrlVStillPastes() async throws {
        let (dispatcher, _) = makeEngine()
        #expect(isConsumed(try await pressV(dispatcher, .maskCommand, from: Keyboards.externalSender)))
        #expect(history.toggles == 1)
        let paste = try await pressV(dispatcher, .maskControl, from: Keyboards.externalSender)
        #expect(keyboards.output(paste) == [.command], "Ctrl+V pastes, as on Windows")
        #expect(history.toggles == 1)
    }

    @Test func theMacBooksWinVIsOptionVAndCommandVStillPastes() async throws {
        let (dispatcher, _) = makeEngine()
        #expect(isConsumed(try await pressV(dispatcher, .maskAlternate, from: Keyboards.builtInSender)))
        #expect(history.toggles == 1, "Once, by the rule; the hot key never sees the press")
        #expect(isUntouched(try await pressV(dispatcher, .maskCommand, from: Keyboards.builtInSender)))
        #expect(history.toggles == 1)
    }

    @Test func withTheHistoryOffWinVPastesAgain() async throws {
        let (dispatcher, _) = makeEngine()
        history.isOn = false
        #expect(isUntouched(try await pressV(dispatcher, .maskCommand, from: Keyboards.externalSender)))
        #expect(history.toggles == 0)
    }

    /// Holding Win+V shows the history once, as the hot key does.
    @Test func holdingTheKeysDoesNotRepeat() async throws {
        let (dispatcher, _) = makeEngine()
        _ = dispatcher.process(try keyboards.key(.v, .maskCommand, from: Keyboards.externalSender), type: .keyDown)
        let repeated = try keyboards.key(.v, .maskCommand, from: Keyboards.externalSender)
        repeated.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        #expect(isConsumed(dispatcher.process(repeated, type: .keyDown)))
        try await Task.sleep(for: .milliseconds(50))
        #expect(history.toggles == 1)
    }

    /// The rule editors offer it as a result, so a side button can open it.
    @Test func aMouseButtonCanOpenIt() async throws {
        let dispatcher = Dispatcher(
            frontmostBundleID: { "com.apple.TextEdit" },
            isClipboardHistoryOn: { [history] in history.isOn },
            toggleClipboardHistory: { [history] in history.toggles += 1 }
        )
        dispatcher.rules = [Rule(id: "mouse.back", trigger: .mouseButton(number: 4), action: .clipboardHistory)]
        let press = try #require(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                                         mouseCursorPosition: .zero, mouseButton: .center))
        press.setIntegerValueField(.mouseEventButtonNumber, value: 3)
        press.flags = []
        #expect(isConsumed(dispatcher.process(press, type: .otherMouseDown)))
        try await Task.sleep(for: .milliseconds(50))
        #expect(history.toggles == 1)
    }
}
