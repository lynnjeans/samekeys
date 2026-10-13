import CoreGraphics
import Testing

@Suite struct RuleMatcherTests {
    let matcher = RuleMatcher(rules: CoverageList.preset.rules)

    func match(_ combo: KeyCombo, in bundleID: String? = "com.apple.TextEdit") -> String? {
        matcher.match(.key(combo: combo), in: MatchContext(frontmostBundleID: bundleID))?.id
    }

    @Test func unmatchedInputFindsNoRule() {
        #expect(match(KeyCombo([.control], .q)) == nil)
        #expect(match(KeyCombo(.a)) == nil)
    }

    @Test func modifiersMustMatchExactly() {
        #expect(match(KeyCombo([.control], .t)) == "browser.newTab")
        #expect(match(KeyCombo([.control, .shift], .t)) == "browser.reopenTab")
        #expect(match(KeyCombo([.control, .option], .t)) == nil)
    }

    @Test func narrowerApplicationScopeWins() {
        #expect(match(KeyCombo([.control], .v), in: "com.apple.finder") == "finder.move")
        #expect(match(KeyCombo([.control], .v)) == "edit.paste")
    }

    @Test func narrowerScopeWinsRegardlessOfRuleOrder() {
        let reversed = RuleMatcher(rules: CoverageList.preset.rules.reversed())
        let context = MatchContext(frontmostBundleID: "com.apple.finder")
        #expect(reversed.match(.key(combo: KeyCombo([.control], .v)), in: context)?.id == "finder.move")
    }

    @Test func excludedApplicationKeepsItsShortcut() {
        #expect(match(KeyCombo([.control], .c), in: "com.apple.Terminal") == nil)
        #expect(match(KeyCombo([.control], .c), in: "com.googlecode.iterm2") == nil)
        #expect(match(KeyCombo([.control], .c)) == "edit.copy")
        #expect(match(KeyCombo([.control], .c), in: nil) == "edit.copy")
    }

    @Test func applicationOnlyRuleNeedsAKnownApplication() {
        #expect(match(KeyCombo(.f2), in: nil) == nil)
    }

    @Test func deviceScopedRuleNeedsItsDevice() {
        let win = Trigger.key(combo: KeyCombo([.command], .l))
        let device = DeviceID(vendorID: 0x046D, productID: 0xC31C)
        #expect(matcher.match(win, in: MatchContext()) == nil)
        #expect(matcher.match(win, in: MatchContext(device: DeviceID(vendorID: 0x05AC, productID: 1))) == nil)
        #expect(matcher.match(win, in: MatchContext(device: device))?.id == "win.lock")
    }

    @Test func disabledRuleIsIgnored() {
        var rules = CoverageList.preset.rules
        let index = rules.firstIndex { $0.id == "edit.paste" }!
        rules[index].isEnabled = false
        let matcher = RuleMatcher(rules: rules)
        #expect(matcher.match(.key(combo: KeyCombo([.control], .v)), in: MatchContext()) == nil)
    }

    @Test func mouseAndScrollTriggersMatch() {
        #expect(matcher.match(.mouseButton(number: 4), in: MatchContext())?.id == "browser.back")
        #expect(matcher.match(.scroll(direction: .up, modifiers: [.function]), in: MatchContext())?.id
                == "browser.zoomIn")
        #expect(matcher.match(.scroll(direction: .up, modifiers: []), in: MatchContext()) == nil)
    }
}

@Suite struct EventTriggerTests {
    func keyDown(_ key: KeyCode, _ flags: CGEventFlags = []) throws -> CGEvent {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: key.rawValue, keyDown: true))
        event.flags = flags
        return event
    }

    @Test func keyDownBecomesKeyTrigger() throws {
        let event = try keyDown(.c, [.maskControl, .maskAlphaShift])
        #expect(Trigger(event: event, type: .keyDown) == .key(combo: KeyCombo([.control], .c)))
    }

    @Test func implicitFunctionFlagIsIgnored() throws {
        let event = try keyDown(.home, [.maskSecondaryFn, .maskNumericPad])
        #expect(Trigger(event: event, type: .keyDown) == .key(combo: KeyCombo(.home)))
    }

    @Test func explicitFunctionFlagIsKept() throws {
        let event = try keyDown(.c, [.maskSecondaryFn])
        #expect(Trigger(event: event, type: .keyDown) == .key(combo: KeyCombo([.function], .c)))
    }

    @Test func releasesTriggerNothing() throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: KeyCode.c.rawValue, keyDown: false))
        event.flags = []
        #expect(Trigger(event: event, type: .keyUp) == nil)
    }

    @Test func sideButtonIsNumberedFromOne() throws {
        let event = try #require(CGEvent(
            mouseEventSource: nil, mouseType: .otherMouseDown,
            mouseCursorPosition: .zero, mouseButton: .center
        ))
        event.setIntegerValueField(.mouseEventButtonNumber, value: 3)
        event.flags = []
        #expect(Trigger(event: event, type: .otherMouseDown) == .mouseButton(number: 4))
    }

    @Test func scrollDirectionFollowsTheDominantAxis() throws {
        func scroll(_ vertical: Int32, _ horizontal: Int32) throws -> Trigger? {
            let event = try #require(CGEvent(
                scrollWheelEvent2Source: nil, units: .line,
                wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0
            ))
            event.flags = .maskSecondaryFn
            return Trigger(event: event, type: .scrollWheel)
        }
        #expect(try scroll(1, 0) == .scroll(direction: .up, modifiers: [.function]))
        #expect(try scroll(-3, 1) == .scroll(direction: .down, modifiers: [.function]))
        #expect(try scroll(0, 2) == .scroll(direction: .left, modifiers: [.function]))
        #expect(try scroll(0, 0) == nil)
    }

    func scrollEvent(continuous: Bool, phase: Int64 = 0, momentum: Int64 = 0) throws -> CGEvent {
        let event = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 10, wheel2: 0, wheel3: 0
        ))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        event.flags = []
        return event
    }

    @Test func wheelsAreToldApartFromGestures() throws {
        #expect(try scrollEvent(continuous: false).scrollSource == .notchedWheel)
        #expect(try scrollEvent(continuous: true).scrollSource == .smoothWheel)
        // Phase values as macOS sends them: 1 began, 2 changed, 4 ended, 128 may begin.
        for phase: Int64 in [1, 2, 4, 128] {
            #expect(try scrollEvent(continuous: true, phase: phase).scrollSource == .gesture)
        }
        // Momentum after the fingers lift: phase is 0 then, momentum is not.
        for momentum: Int64 in [1, 2, 3] {
            #expect(try scrollEvent(continuous: true, momentum: momentum).scrollSource == .gesture)
        }
    }

    @Test func gesturesTriggerNothing() throws {
        let gesture = try scrollEvent(continuous: true, phase: 2)
        #expect(Trigger(event: gesture, type: .scrollWheel) == nil)
        let momentum = try scrollEvent(continuous: true, momentum: 2)
        #expect(Trigger(event: momentum, type: .scrollWheel) == nil)
        let smoothWheel = try scrollEvent(continuous: true)
        #expect(Trigger(event: smoothWheel, type: .scrollWheel) == .scroll(direction: .up, modifiers: []))
    }
}
