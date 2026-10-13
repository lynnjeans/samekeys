import CoreGraphics
import Testing

/// Lone-modifier triggers (KB-224): Win pressed and released on its own.
@MainActor
@Suite struct ModifierTapTests {
    // Device-dependent flags for each side's key, as a real keyboard sends.
    static let leftCommand = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08)
    static let rightCommand = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
    static let bothCommands = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x18)
    static let leftShift = CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x02)
    static let rightCommandCode = KeyCode(rawValue: 54)
    static let second: UInt64 = 1_000_000_000

    // MARK: - The detector

    @Test func aPressAndReleaseOnItsOwnIsATap() {
        var tap = ModifierTap()
        #expect(tap.flagsChanged(key: .command, flags: Self.leftCommand, now: 0) == nil)
        #expect(tap.flagsChanged(key: .command, flags: [], now: Self.second / 5) == .command)
    }

    @Test func theRightKeyCountsAsTheLeftOne() {
        var tap = ModifierTap()
        _ = tap.flagsChanged(key: Self.rightCommandCode, flags: Self.rightCommand, now: 0)
        #expect(tap.flagsChanged(key: Self.rightCommandCode, flags: [], now: 1) == .command)
    }

    @Test func anythingInBetweenMakesItAShortcut() {
        var tap = ModifierTap()
        _ = tap.flagsChanged(key: .command, flags: Self.leftCommand, now: 0)
        tap.interrupt()
        #expect(tap.flagsChanged(key: .command, flags: [], now: 1) == nil)
    }

    @Test func holdingItTooLongIsNotATap() {
        var tap = ModifierTap()
        _ = tap.flagsChanged(key: .command, flags: Self.leftCommand, now: 0)
        #expect(tap.flagsChanged(key: .command, flags: [], now: ModifierTap.timeout + 1) == nil)
        _ = tap.flagsChanged(key: .command, flags: Self.leftCommand, now: 0)
        #expect(tap.flagsChanged(key: .command, flags: [], now: ModifierTap.timeout) == .command)
    }

    @Test func aSecondModifierMakesItAChord() {
        var tap = ModifierTap()
        // ⌘ then ⇧, let go in either order: neither is alone.
        _ = tap.flagsChanged(key: .command, flags: Self.leftCommand, now: 0)
        _ = tap.flagsChanged(key: .shift, flags: [Self.leftCommand, Self.leftShift], now: 1)
        #expect(tap.flagsChanged(key: .shift, flags: Self.leftCommand, now: 2) == nil)
        #expect(tap.flagsChanged(key: .command, flags: [], now: 3) == nil)

        // ⇧ held first, then ⌘ tapped: ⌘ was not alone either.
        _ = tap.flagsChanged(key: .shift, flags: Self.leftShift, now: 0)
        _ = tap.flagsChanged(key: .command, flags: [Self.leftCommand, Self.leftShift], now: 1)
        #expect(tap.flagsChanged(key: .command, flags: Self.leftShift, now: 2) == nil)
    }

    @Test func lettingGoOfOneOfTwoHeldCommandKeysIsNotATap() {
        var tap = ModifierTap()
        _ = tap.flagsChanged(key: .command, flags: Self.leftCommand, now: 0)
        // The right ⌘ joins; the flags alone still say "⌘".
        _ = tap.flagsChanged(key: Self.rightCommandCode, flags: Self.bothCommands, now: 1)
        #expect(tap.flagsChanged(key: Self.rightCommandCode, flags: Self.leftCommand, now: 2) == nil)
        #expect(tap.flagsChanged(key: .command, flags: [], now: 3) == nil)
    }

    @Test func eventsWithoutDeviceFlagsStillWork() {
        var tap = ModifierTap()
        _ = tap.flagsChanged(key: .option, flags: .maskAlternate, now: 0)
        #expect(tap.flagsChanged(key: .option, flags: [], now: 1) == .option)
        _ = tap.flagsChanged(key: .function, flags: .maskSecondaryFn, now: 0)
        #expect(tap.flagsChanged(key: .function, flags: [], now: 1) == .function)
    }

    @Test func capsLockIsNotAModifierTap() {
        var tap = ModifierTap()
        #expect(tap.flagsChanged(key: KeyCode(rawValue: 57), flags: .maskAlphaShift, now: 0) == nil)
        #expect(tap.flagsChanged(key: KeyCode(rawValue: 57), flags: [], now: 1) == nil)
    }

    // MARK: - In the dispatcher

    func modifier(_ key: KeyCode, _ flags: CGEventFlags) throws -> CGEvent {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: key.rawValue, keyDown: true))
        event.type = .flagsChanged
        event.flags = flags
        return event
    }

    final class Clock {
        var now: UInt64 = 0
    }

    func dispatcher(
        _ clock: Clock, secureInput: Bool = false, opened: @escaping @MainActor (String) -> Void = { _ in },
        posted: @escaping @MainActor (CGEvent) -> Void = { _ in }
    ) -> Dispatcher {
        let dispatcher = Dispatcher(
            frontmostBundleID: { "com.apple.TextEdit" }, post: posted, openApplication: opened,
            systemShortcuts: { SymbolicHotKeys(entries: [:]) },
            now: { clock.now }, isSecureInputOn: { secureInput }
        )
        dispatcher.rules = [Rule(id: "winKey.start", trigger: .key(combo: KeyCombo(.command)),
                                 action: .systemAction(.apps))]
        return dispatcher
    }

    /// Presses and releases left ⌘, leaving the key's own events alone.
    func tapCommand(_ dispatcher: Dispatcher, _ clock: Clock, holding nanoseconds: UInt64 = 100_000_000) throws {
        #expect(DispatcherTests().isPassThrough(dispatcher.process(try modifier(.command, Self.leftCommand), type: .flagsChanged)))
        clock.now += nanoseconds
        #expect(DispatcherTests().isPassThrough(dispatcher.process(try modifier(.command, []), type: .flagsChanged)))
    }

    @Test func winAloneOpensApps() async throws {
        let clock = Clock()
        var opened: [String] = []
        let dispatcher = dispatcher(clock, opened: { opened.append($0) })
        try tapCommand(dispatcher, clock)
        // Apps has no shortcut as shipped, so it is opened; after the release
        // has gone on.
        #expect(opened.isEmpty)
        try await Task.sleep(for: .milliseconds(50))
        #expect(opened == [SystemAction.apps.fallbackApplication])
    }

    @Test func winWithAKeyOrAClickDoesNot() async throws {
        let clock = Clock()
        var opened: [String] = []
        let dispatcher = dispatcher(clock, opened: { opened.append($0) })

        _ = dispatcher.process(try modifier(.command, Self.leftCommand), type: .flagsChanged)
        _ = dispatcher.process(try DispatcherTests().key(.c, down: true, Self.leftCommand), type: .keyDown)
        _ = dispatcher.process(try DispatcherTests().key(.c, down: false, Self.leftCommand), type: .keyUp)
        _ = dispatcher.process(try modifier(.command, []), type: .flagsChanged)

        _ = dispatcher.process(try modifier(.command, Self.leftCommand), type: .flagsChanged)
        let click = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                         mouseCursorPosition: .zero, mouseButton: .left))
        click.flags = Self.leftCommand
        _ = dispatcher.process(click, type: .leftMouseDown)
        _ = dispatcher.process(try modifier(.command, []), type: .flagsChanged)

        _ = dispatcher.process(try modifier(.command, Self.leftCommand), type: .flagsChanged)
        _ = dispatcher.process(try DispatcherTests().scroll(lines: 1, Self.leftCommand), type: .scrollWheel)
        _ = dispatcher.process(try modifier(.command, []), type: .flagsChanged)

        try tapCommand(dispatcher, clock, holding: 2 * Self.second)
        try await Task.sleep(for: .milliseconds(50))
        #expect(opened.isEmpty)
    }

    @Test func secureInputHidesKeysSoNothingCountsAsATap() async throws {
        let clock = Clock()
        var opened: [String] = []
        let dispatcher = dispatcher(clock, secureInput: true, opened: { opened.append($0) })
        try tapCommand(dispatcher, clock)
        try await Task.sleep(for: .milliseconds(50))
        #expect(opened.isEmpty)
    }

    @Test func aLoneModifierCanPostAKey() async throws {
        let clock = Clock()
        var posted: [CGEvent] = []
        let dispatcher = dispatcher(clock, posted: { posted.append($0) })
        dispatcher.rules = [Rule(id: "custom.1", trigger: .key(combo: KeyCombo(.control)),
                                 action: .key(combo: KeyCombo(.escape)))]
        _ = dispatcher.process(try modifier(.control, CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 1)),
                               type: .flagsChanged)
        _ = dispatcher.process(try modifier(.control, []), type: .flagsChanged)
        try await Task.sleep(for: .milliseconds(50))
        #expect(posted.map(\.type) == [.keyDown, .keyUp])
        #expect(posted.allSatisfy { $0.keyCode == .escape && Modifiers(flags: $0.flags).isEmpty })
    }

    @Test func recordingTakesATapAsATrigger() throws {
        let clock = Clock()
        var recorded: [Trigger] = []
        let dispatcher = dispatcher(clock)
        dispatcher.recorder = { recorded.append($0) }
        try tapCommand(dispatcher, clock)
        #expect(recorded == [.key(combo: KeyCombo(.command))])
    }

    // MARK: - Labels

    @Test func winAloneIsCalledWin() {
        #expect(KeyCombo(.command).caps(.windows) == ["Win"])
        #expect(KeyCombo(.command).caps(.mac) == ["⌘"])
        #expect(KeyCombo(.control).caps(.windows) == ["Ctrl"])
        #expect(KeyCombo(.command).isModifierAlone)
        #expect(!KeyCombo([.command], .c).isModifierAlone)
        #expect(!KeyCombo(.home).isModifierAlone)
    }
}
