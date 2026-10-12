import AppKit
import CoreGraphics
import Testing

/// The Dispatcher's less travelled paths: stopping mid-keystroke, rules that
/// open an app, the wheel direction and Finder's text fields.
extension DispatcherTests {
    // MARK: - Stopping while keys are held

    @Test func stoppingReleasesEveryRemappedKeyStillHeld() throws {
        var posted: [CGEvent] = []
        let dispatcher = Dispatcher(frontmostBundleID: { "com.apple.TextEdit" }, post: { posted.append($0) })
        dispatcher.rules = BuiltInRules.all
        _ = dispatcher.process(try key(.c, down: true, [.maskControl]), type: .keyDown)
        _ = dispatcher.process(try key(.home, down: true), type: .keyDown)
        #expect(posted.isEmpty, "Key presses are replaced in place, not posted")

        dispatcher.releaseHeldKeys()
        #expect(posted.count == 2)
        #expect(posted.allSatisfy { $0.type == .keyUp && SyntheticEvent.isOurs($0) })
        #expect(Set(posted.map(\.keyCode)) == [.c, .leftArrow])

        // The real releases arriving later are the user's own; there is
        // nothing left to lift.
        #expect(isPassThrough(dispatcher.process(try key(.c, down: false), type: .keyUp)))
        #expect(isPassThrough(dispatcher.process(try key(.home, down: false), type: .keyUp)))
        dispatcher.releaseHeldKeys()
        #expect(posted.count == 2)
    }

    @Test func stoppingForgetsHeldMouseButtons() throws {
        let dispatcher = Dispatcher(frontmostBundleID: { "com.apple.Safari" }, post: { _ in })
        dispatcher.rules = BuiltInRules.all
        _ = dispatcher.process(try button(4, down: true), type: .otherMouseDown)
        dispatcher.releaseHeldKeys()
        #expect(isPassThrough(dispatcher.process(try button(4, down: false), type: .otherMouseUp)))
    }

    // MARK: - Rules that open an application

    @Test func aKeyThatOpensAnAppDoesSoOnceAndSwallowsTheRest() throws {
        var opened: [String] = []
        var posted: [CGEvent] = []
        let dispatcher = Dispatcher(frontmostBundleID: { "com.apple.TextEdit" },
                                    post: { posted.append($0) },
                                    openApplication: { opened.append($0) })
        dispatcher.rules = BuiltInRules.all

        // Ctrl+Shift+Esc, Task Manager on Windows.
        #expect(isConsumed(dispatcher.process(try key(.escape, down: true, [.maskControl, .maskShift]), type: .keyDown)))
        #expect(opened == ["com.apple.ActivityMonitor"])
        #expect(isConsumed(dispatcher.process(try key(.escape, down: true, [.maskControl, .maskShift], repeat: true), type: .keyDown)))
        #expect(isConsumed(dispatcher.process(try key(.escape, down: false), type: .keyUp)))
        #expect(opened.count == 1, "Holding the keys does not open it again")
        #expect(posted.isEmpty)
        // Nothing is left held.
        #expect(isPassThrough(dispatcher.process(try key(.escape, down: true), type: .keyDown)))
    }

    @Test func aMouseButtonCanOpenAnApp() throws {
        var opened: [String] = []
        let dispatcher = Dispatcher(frontmostBundleID: { nil }, post: { _ in }, openApplication: { opened.append($0) })
        dispatcher.rules = [Rule(id: "custom.calculator", trigger: .mouseButton(number: 6),
                                 action: .openApplication(bundleID: "com.apple.calculator"))]
        #expect(isConsumed(dispatcher.process(try button(6, down: true), type: .otherMouseDown)))
        #expect(isConsumed(dispatcher.process(try button(6, down: false), type: .otherMouseUp)))
        #expect(opened == ["com.apple.calculator"])
    }

    // MARK: - Wheel direction

    /// A notched wheel line as macOS delivers it with natural scrolling on.
    func naturalWheel(lines: Int32, _ flags: CGEventFlags = []) throws -> CGEvent {
        let event = try scroll(lines: lines, flags)
        // The field NSEvent reads for isDirectionInvertedFromDevice.
        event.setIntegerValueField(try #require(CGEventField(rawValue: 137)), value: 1)
        return event
    }

    @Test func windowsDirectionTurnsPlainWheelScrollingAround() throws {
        let dispatcher = Dispatcher(frontmostBundleID: { "com.apple.Safari" }, post: { _ in })
        dispatcher.rules = BuiltInRules.all
        dispatcher.wheelDirection = .windows

        let event = try naturalWheel(lines: 3)
        try #require(event.isNaturalScrolling, "The test event reads as natural scrolling")
        #expect(isPassThrough(dispatcher.process(event, type: .scrollWheel)))
        #expect(event.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -3)

        dispatcher.wheelDirection = .system
        let untouched = try naturalWheel(lines: 3)
        _ = dispatcher.process(untouched, type: .scrollWheel)
        #expect(untouched.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 3)
    }

    @Test func zoomFollowsTheWheelWhicheverWayPagesScroll() throws {
        for direction in WheelDirection.allCases {
            var posted: [CGEvent] = []
            let dispatcher = Dispatcher(frontmostBundleID: { "com.apple.Safari" }, post: { posted.append($0) })
            dispatcher.rules = BuiltInRules.all
            dispatcher.wheelDirection = direction
            // Under natural scrolling, rolling the wheel up arrives negated.
            #expect(isConsumed(dispatcher.process(try naturalWheel(lines: -1, [.maskControl]), type: .scrollWheel)))
            #expect(posted.first?.keyCode == .equal, "Wheel up zooms in with \(direction)")
        }
    }

    // MARK: - Finder's text fields

    @Test func finderKeysStepAsideWhileRenaming() throws {
        var editing = false
        let dispatcher = Dispatcher(frontmostBundleID: { "com.apple.finder" }, isEditingText: { editing })
        dispatcher.rules = BuiltInRules.all

        let rename = try #require(replacement(dispatcher.process(try key(.f2, down: true), type: .keyDown)))
        #expect(rename.keyCode == .returnKey)
        _ = dispatcher.process(try key(.f2, down: false), type: .keyUp)

        editing = true
        #expect(isPassThrough(dispatcher.process(try key(.returnKey, down: true), type: .keyDown)),
                "Enter confirms the new name instead of opening the file")
        // Finder's own Ctrl+V (move here) steps aside, so the general one
        // pastes the text.
        let paste = try #require(replacement(dispatcher.process(try key(.v, down: true, [.maskControl]), type: .keyDown)))
        #expect(paste.keyCode == .v)
        #expect(Modifiers(flags: paste.flags) == [.command])
    }
}
