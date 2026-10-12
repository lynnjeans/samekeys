import CoreGraphics
import Foundation
import Testing

/// Settings kept per keyboard (KB-243): the MacBook's own keyboard next to an
/// external PC keyboard, as on the user's Mac.
@MainActor
@Suite struct PerKeyboardTests {
    static let builtIn = Keyboard(vendorID: 0, productID: 0, name: "Apple Internal Keyboard / Trackpad", isBuiltIn: true)
    static let external = Keyboard(vendorID: 0x000E, productID: 0x3412, name: "RK-KB5.0", isBuiltIn: false)
    /// The registry IDs their events carry in field 87.
    static let builtInSender: Int64 = 0x1_0000_0B4E
    static let externalSender: Int64 = 0x1_0000_F33B
    static let leftCommand = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08)
    static let leftOption = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20)

    let folder = FileManager.default.temporaryDirectory.appending(path: "SameKeysTests-\(UUID().uuidString)")
    var store: ConfigurationStore { ConfigurationStore(fileURL: folder.appending(path: "config.json")) }

    final class Record {
        var lookups = 0
        var opened: [String] = []
    }
    let record = Record()

    /// A dispatcher fed by a rules controller, as the app wires them, whose
    /// events name their keyboard by sender.
    func makeEngine(_ configure: (RulesController) -> Void = { _ in }) -> (Dispatcher, RulesController) {
        let dispatcher = Dispatcher(
            frontmostBundleID: { "com.apple.TextEdit" },
            openApplication: { [record] in record.opened.append($0) },
            systemShortcuts: { SymbolicHotKeys(entries: [:]) },
            keyboard: { [record] event in
                record.lookups += 1
                switch Int64(bitPattern: event.senderID) {
                case Self.builtInSender: return Self.builtIn
                case Self.externalSender: return Self.external
                default: return nil
                }
            }
        )
        let rules = RulesController(
            store: store,
            applyCtrlClick: { dispatcher.ctrlClick = $0 },
            applyKeyboards: { dispatcher.keyboardProfiles = $0 },
            apply: { dispatcher.rules = $0 }
        )
        configure(rules)
        return (dispatcher, rules)
    }

    func stamp(_ event: CGEvent, _ sender: Int64?) throws -> CGEvent {
        if let sender { event.setIntegerValueField(try #require(CGEventField(rawValue: 87)), value: sender) }
        return event
    }

    func key(_ key: KeyCode, _ flags: CGEventFlags, from sender: Int64?) throws -> CGEvent {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: key.rawValue, keyDown: true))
        event.flags = flags
        return try stamp(event, sender)
    }

    func modifier(_ key: KeyCode, _ flags: CGEventFlags, from sender: Int64?) throws -> CGEvent {
        let event = try self.key(key, flags, from: sender)
        event.type = .flagsChanged
        return event
    }

    func click(_ flags: CGEventFlags) throws -> CGEvent {
        let event = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                         mouseCursorPosition: .zero, mouseButton: .left))
        event.flags = flags
        // A click names the mouse, never a keyboard (measured, KB-020).
        return try stamp(event, 0x1_0000_F38D)
    }

    /// What the key press goes out as: its modifiers, or nil when untouched.
    func output(_ disposition: Dispatcher.Disposition) -> Modifiers? {
        if case .replace(let event) = disposition { Modifiers(flags: event.flags) } else { nil }
    }

    /// Presses and releases a key, and says what the press went out as.
    func press(_ dispatcher: Dispatcher, _ key: KeyCode, _ flags: CGEventFlags, from sender: Int64?) throws -> Modifiers? {
        let result = output(dispatcher.process(try self.key(key, flags, from: sender), type: .keyDown))
        let up = try self.key(key, flags, from: sender)
        up.type = .keyUp
        _ = dispatcher.process(up, type: .keyUp)
        return result
    }

    /// Scrolls the wheel one line up and says whether the page zoomed in.
    func zooms(_ dispatcher: Dispatcher, _ flags: CGEventFlags) throws -> Bool {
        let event = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0
        ))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
        event.flags = flags
        // Scrolling names the mouse, never a keyboard, like a click.
        if case .consume = dispatcher.process(try stamp(event, 0x1_0000_F38D), type: .scrollWheel) { return true }
        return false
    }

    // MARK: - Configuration

    @Test func anOlderFileHasNoKeyboardsAndNoneAreWritten() throws {
        let old = Data(#"{"schemaVersion": 1, "overrides": [], "controlKey": "fn"}"#.utf8)
        let configuration = try JSONDecoder().decode(Configuration.self, from: old)
        #expect(configuration.keyboards.isEmpty)
        let written = String(decoding: try JSONEncoder().encode(configuration), as: UTF8.self)
        #expect(!written.contains("keyboards"), "The file only changes for those who use it")
    }

    @Test func aKeyboardIsWrittenFlatAndReadBack() throws {
        var configuration = Configuration()
        configuration.setControlKey(.function, for: Self.builtIn)
        configuration.setModifierLayout(.macPosition, for: Self.builtIn)
        configuration.setControlKey(.control, for: Self.external)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(configuration.keyboards), as: UTF8.self)
        #expect(json == """
            [{"controlKey":"fn","isBuiltIn":true,"modifierLayout":"mac","name":"Apple Internal Keyboard \\/ Trackpad","productID":0,"vendorID":0},\
            {"controlKey":"control","name":"RK-KB5.0","productID":13330,"vendorID":14}]
            """)
        let read = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(configuration))
        #expect(read.keyboards == configuration.keyboards)

        // As someone would type it, with only what matters.
        let typed = Data(#"{"keyboards": [{"vendorID": 14, "productID": 13330, "controlKey": "fn"}]}"#.utf8)
        let hand = try JSONDecoder().decode(Configuration.self, from: typed)
        #expect(hand.controlKey(for: Self.external.id) == .function)
    }

    static let magicKeyboard = Keyboard(vendorID: 0x004C, productID: 0x0267, name: "Magic Keyboard", isBuiltIn: false)

    @Test func aMacKeyboardWithNothingOfItsOwnFollowsTheGeneralSettings() {
        var configuration = Configuration()
        configuration.controlKey = .both
        configuration.modifierLayout = .macPosition
        configuration.setControlKey(.function, for: Self.builtIn)
        #expect(configuration.controlKey(for: Self.builtIn.id) == .function)
        #expect(configuration.modifierLayout(for: Self.builtIn.id) == .macPosition, "Not set for it, so the general one")
        #expect(configuration.controlKey(for: Self.magicKeyboard.id) == .both)
        #expect(configuration.controlKey(for: nil) == .both, "A key from no known keyboard")

        configuration.setControlKey(nil, for: Self.builtIn)
        #expect(configuration.keyboards.isEmpty, "Nothing of its own left, so it is forgotten")
    }

    @Test func aKeyboardKeepsTheNameItLastGave() {
        var configuration = Configuration()
        configuration.setControlKey(.function, for: Self.external)
        let renamed = Keyboard(vendorID: 0x000E, productID: 0x3412, name: "RK Keyboard", isBuiltIn: false)
        configuration.setModifierLayout(.macPosition, for: renamed)
        #expect(configuration.keyboards.count == 1)
        #expect(configuration.keyboards.first?.name == "RK Keyboard")
        #expect(configuration.keyboards.first?.controlKey == .function)
    }

    @Test func aPCKeyboardDefaultsToCtrlAndItsPrintedKeys() {
        var configuration = Configuration()
        configuration.controlKey = .function
        configuration.modifierLayout = .macPosition
        // No fn key reaches the Mac from it, and its Win key sends ⌘.
        #expect(configuration.controlKey(for: Self.external.id) == .control)
        #expect(configuration.modifierLayout(for: Self.external.id) == .pcKeyboard)
        configuration.setModifierLayout(.macPosition, for: Self.external)
        #expect(configuration.modifierLayout(for: Self.external.id) == .macPosition, "Its own setting wins")
    }

    // MARK: - Keys

    @Test func aPCKeyboardPluggedInNextToAMacBookOnFnWorksAtOnce() async throws {
        let (dispatcher, rules) = makeEngine { rules in
            rules.setControlKey(.function)
            rules.setModifierLayout(.macPosition)
            rules.setGroup("winKey", enabled: true)
        }
        rules.setConnectedKeyboards([Self.builtIn, Self.external])
        #expect(rules.keyboardSettings.isEmpty, "Nothing written to the file")
        #expect(try press(dispatcher, .c, .maskControl, from: Self.externalSender) == [.command])
        #expect(try press(dispatcher, .c, .maskSecondaryFn, from: Self.builtInSender) == [.command])
        #expect(try press(dispatcher, .c, .maskControl, from: Self.builtInSender) == nil)
        // Its Win key, which sends ⌘, alone opens Apps.
        _ = dispatcher.process(try modifier(.command, Self.leftCommand, from: Self.externalSender), type: .flagsChanged)
        _ = dispatcher.process(try modifier(.command, [], from: Self.externalSender), type: .flagsChanged)
        try await Task.sleep(for: .milliseconds(50))
        #expect(record.opened.count == 1)
        #expect(rules.controlKeysInUse == [.function, .control])
    }

    @Test func choosingAKeyboardsDefaultKeepsNothingOfItsOwn() {
        let (_, rules) = makeEngine { $0.setControlKey(.function) }
        rules.chooseControlKey(.control, for: Self.external)
        #expect(rules.keyboardSettings.isEmpty, "Ctrl is already a PC keyboard's default")
        rules.chooseModifierLayout(.macPosition, for: Self.external)
        #expect(rules.configuration.settings(for: Self.external.id)?.modifierLayout == .macPosition)
        rules.chooseControlKey(.control, for: Self.builtIn)
        #expect(rules.configuration.settings(for: Self.builtIn.id)?.controlKey == .control)
        rules.chooseControlKey(.function, for: Self.builtIn)
        #expect(rules.configuration.settings(for: Self.builtIn.id) == nil, "Back to the general fn")
    }

    @Test func eachKeyboardPressesCtrlShortcutsItsOwnWay() throws {
        let (dispatcher, _) = makeEngine { rules in
            rules.setControlKey(.control)
            rules.setControlKey(.function, for: Self.builtIn)
        }
        // The MacBook's keyboard: fn+C copies, Ctrl+C keeps its Mac meaning.
        #expect(try press(dispatcher, .c, .maskSecondaryFn, from: Self.builtInSender) == [.command])
        #expect(try press(dispatcher, .c, .maskControl, from: Self.builtInSender) == nil)
        // The PC keyboard: Ctrl+C copies, and has no fn to press.
        #expect(try press(dispatcher, .c, .maskControl, from: Self.externalSender) == [.command])
    }

    @Test func eachKeyboardHasItsOwnWinAndAlt() throws {
        let (dispatcher, _) = makeEngine { rules in
            rules.setModifierLayout(.pcKeyboard)
            rules.setModifierLayout(.macPosition, for: Self.builtIn)
        }
        // Alt+Tab switches apps: ⌘Tab out, whichever Mac key Alt is.
        #expect(try press(dispatcher, .tab, .maskAlternate, from: Self.externalSender) == [.command], "Alt is ⌥ on the PC keyboard")
        #expect(try press(dispatcher, .tab, .maskCommand, from: Self.builtInSender) == nil,
                "Alt is ⌘ on the MacBook's: ⌘Tab is already the Mac's app switcher")
    }

    @Test func anEventFromNoKnownKeyboardGetsTheGeneralSettings() throws {
        let (dispatcher, _) = makeEngine { rules in
            rules.setControlKey(.control)
            rules.setControlKey(.function, for: Self.builtIn)
        }
        // Posted by software, or the field not saying.
        #expect(try press(dispatcher, .c, .maskControl, from: nil) == [.command])
        #expect(try press(dispatcher, .c, .maskSecondaryFn, from: nil) == nil)
    }

    @Test func nobodyIsAskedWhileNoKeyboardHasSettings() throws {
        let (dispatcher, _) = makeEngine()
        _ = dispatcher.process(try modifier(.control, .maskControl, from: Self.builtInSender), type: .flagsChanged)
        _ = dispatcher.process(try key(.c, .maskControl, from: Self.builtInSender), type: .keyDown)
        _ = dispatcher.process(try click(.maskControl), type: .leftMouseDown)
        #expect(record.lookups == 0)
    }

    // MARK: - Mouse

    @Test func aClickFollowsTheKeyboardTheModifierIsHeldOn() throws {
        let (dispatcher, rules) = makeEngine { rules in
            rules.setControlKey(.control)
            rules.setControlKey(.function, for: Self.builtIn)
        }
        rules.setCtrlClickSelects(true)

        // Ctrl held on the MacBook's keyboard, where fn plays Ctrl: the
        // shortcut menu's Ctrl+click is left alone.
        _ = dispatcher.process(try modifier(.control, .maskControl, from: Self.builtInSender), type: .flagsChanged)
        let macCtrl = try click(.maskControl)
        _ = dispatcher.process(macCtrl, type: .leftMouseDown)
        #expect(Modifiers(flags: macCtrl.flags) == [.control])

        // Ctrl held on the PC keyboard: ⌘+click.
        _ = dispatcher.process(try modifier(.control, .maskControl, from: Self.externalSender), type: .flagsChanged)
        let pcCtrl = try click(.maskControl)
        _ = dispatcher.process(pcCtrl, type: .leftMouseDown)
        #expect(Modifiers(flags: pcCtrl.flags) == [.command])
    }

    /// The user's Mac (SK-297): the MacBook on fn next to a PC keyboard,
    /// which has no fn key. Each zooms with the key it presses Ctrl+C with.
    @Test func eachKeyboardZoomsWithItsOwnCtrl() throws {
        let (dispatcher, rules) = makeEngine { $0.setControlKey(.function) }
        rules.setConnectedKeyboards([Self.builtIn, Self.external])

        _ = dispatcher.process(try modifier(.function, .maskSecondaryFn, from: Self.builtInSender), type: .flagsChanged)
        #expect(try zooms(dispatcher, .maskSecondaryFn), "fn+scroll on the MacBook")
        _ = dispatcher.process(try modifier(.control, .maskControl, from: Self.builtInSender), type: .flagsChanged)
        #expect(try !zooms(dispatcher, .maskControl), "Ctrl+scroll on the MacBook stays the system's")

        _ = dispatcher.process(try modifier(.control, .maskControl, from: Self.externalSender), type: .flagsChanged)
        #expect(try zooms(dispatcher, .maskControl), "Ctrl+scroll on the PC keyboard")
    }

    @Test func aChosenZoomKeyIsTheSameOnEveryKeyboard() throws {
        let (dispatcher, rules) = makeEngine { rules in
            rules.setControlKey(.function)
            rules.setZoomModifiers([.option])
        }
        rules.setConnectedKeyboards([Self.builtIn, Self.external])
        for sender in [Self.builtInSender, Self.externalSender] {
            _ = dispatcher.process(try modifier(.option, .maskAlternate, from: sender), type: .flagsChanged)
            #expect(try zooms(dispatcher, .maskAlternate))
        }
    }

    @Test func winAloneFollowsItsKeyboard() async throws {
        let (dispatcher, _) = makeEngine { rules in
            rules.setGroup("winKey", enabled: true)
            rules.setModifierLayout(.pcKeyboard)
            rules.setModifierLayout(.macPosition, for: Self.builtIn)
        }
        func tap(_ key: KeyCode, _ flags: CGEventFlags, from sender: Int64) throws {
            _ = dispatcher.process(try modifier(key, flags, from: sender), type: .flagsChanged)
            _ = dispatcher.process(try modifier(key, [], from: sender), type: .flagsChanged)
        }
        // ⌘ alone on the MacBook's keyboard is ⌘, not Win there.
        try tap(.command, Self.leftCommand, from: Self.builtInSender)
        try await Task.sleep(for: .milliseconds(50))
        #expect(record.opened.isEmpty)
        // ⌥ alone there is Win, and so is ⌘ alone on the PC keyboard.
        try tap(.option, Self.leftOption, from: Self.builtInSender)
        try tap(.command, Self.leftCommand, from: Self.externalSender)
        try await Task.sleep(for: .milliseconds(50))
        #expect(record.opened.count == 2)
    }
}
