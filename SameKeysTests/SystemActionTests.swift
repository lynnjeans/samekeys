import CoreGraphics
import Foundation
import Testing

@MainActor
@Suite struct SystemActionTests {
    /// An entry as System Settings writes it: [character, key code, flags].
    private static func entry(_ keyCode: Int, _ flags: Int, enabled: Bool = true) -> [String: Any] {
        ["enabled": enabled, "value": ["parameters": [65535, keyCode, flags], "type": "standard"]]
    }

    // MARK: - Reading the user's shortcuts

    @Test func absentEntriesMeanTheShippedShortcut() {
        let keys = SymbolicHotKeys(entries: [:])
        #expect(keys.shortcut(for: .missionControl) == .combo(KeyCombo([.control], .upArrow)))
        #expect(keys.shortcut(for: .showDesktop) == .combo(KeyCombo(.f11)))
        #expect(keys.shortcut(for: .spotlight) == .combo(KeyCombo([.command], .space)))
        #expect(keys.shortcut(for: .apps) == SymbolicHotKeys.Shortcut.none, "Launchpad and Apps ship without one")
    }

    @Test func aChangedShortcutIsFollowed() {
        // Show Desktop moved to ⌥D, and Apps given ⌥Space, as on the maintainer's Mac.
        let keys = SymbolicHotKeys(entries: [
            "36": Self.entry(2, 1 << 19),
            "160": Self.entry(49, 1 << 19),
        ])
        #expect(keys.shortcut(for: .showDesktop) == .combo(KeyCombo([.option], .d)))
        #expect(keys.shortcut(for: .apps) == .combo(KeyCombo([.option], .space)))
    }

    @Test func theFnFlagOfArrowsAndFunctionKeysIsDropped() {
        // The file records fn with every arrow and F-key; pressing them posts it anyway.
        let keys = SymbolicHotKeys(entries: [
            "79": Self.entry(123, (1 << 18) | (1 << 23)),
            "36": Self.entry(103, 1 << 23),
        ])
        #expect(keys.shortcut(for: .spaceLeft) == .combo(KeyCombo([.control], .leftArrow)))
        #expect(keys.shortcut(for: .showDesktop) == .combo(KeyCombo(.f11)))
    }

    @Test func aSwitchedOffShortcutIsReportedAsOff() {
        let keys = SymbolicHotKeys(entries: ["32": Self.entry(126, 1 << 18, enabled: false)])
        #expect(keys.shortcut(for: .missionControl) == .off)
    }

    @Test func anEntryWithoutAKeyHasNoShortcut() {
        let keys = SymbolicHotKeys(entries: ["160": Self.entry(65535, 0)])
        #expect(keys.shortcut(for: .apps) == SymbolicHotKeys.Shortcut.none)
    }

    // MARK: - Triggering

    private func dispatcher(
        _ entries: [String: Any], posted: @escaping @MainActor (CGEvent) -> Void, opened: @escaping @MainActor (String) -> Void
    ) -> Dispatcher {
        let dispatcher = Dispatcher(
            frontmostBundleID: { "com.apple.Safari" }, post: posted, openApplication: opened,
            systemShortcuts: { SymbolicHotKeys(entries: entries) }
        )
        dispatcher.rules = [Rule(id: "test.button", trigger: .mouseButton(number: 4),
                                 action: .systemAction(.showDesktop))]
        return dispatcher
    }

    private func press(_ dispatcher: Dispatcher) async throws {
        let event = try #require(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                                         mouseCursorPosition: .zero, mouseButton: .center))
        event.setIntegerValueField(.mouseEventButtonNumber, value: 3) // button 4, counted from 1
        event.flags = []
        _ = dispatcher.process(event, type: .otherMouseDown)
        // The shortcut is read and posted once the tap callback has returned.
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test func aButtonPostsTheUsersShortcutForTheFunction() async throws {
        var posted: [CGEvent] = []
        let dispatcher = dispatcher(["36": Self.entry(2, 1 << 19)], posted: { posted.append($0) }, opened: { _ in })
        try await press(dispatcher)
        #expect(posted.map(\.type) == [.keyDown, .keyUp])
        #expect(posted.allSatisfy { $0.keyCode == .d && $0.flags.contains(.maskAlternate) })
    }

    @Test func aFunctionWithoutAShortcutOpensItsApp() async throws {
        var posted: [CGEvent] = []
        var opened: [String] = []
        let dispatcher = Dispatcher(
            frontmostBundleID: { nil }, post: { posted.append($0) }, openApplication: { opened.append($0) },
            systemShortcuts: { SymbolicHotKeys(entries: ["32": Self.entry(126, 1 << 18, enabled: false)]) }
        )
        dispatcher.rules = [Rule(id: "test.key", trigger: .key(combo: KeyCombo(.f19)),
                                 action: .systemAction(.missionControl))]
        let down = try #require(CGEvent(keyboardEventSource: nil, virtualKey: KeyCode.f19.rawValue, keyDown: true))
        down.flags = []
        guard case .consume = dispatcher.process(down, type: .keyDown) else {
            Issue.record("The key press is taken")
            return
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(posted.isEmpty)
        #expect(opened == ["com.apple.exposelauncher"])
    }

    @Test func aSwitchedOffFunctionWithNoAppDoesNothing() async throws {
        var posted: [CGEvent] = []
        var opened: [String] = []
        let dispatcher = dispatcher(["36": Self.entry(103, 1 << 23, enabled: false)],
                                    posted: { posted.append($0) }, opened: { opened.append($0) })
        try await press(dispatcher)
        #expect(posted.isEmpty && opened.isEmpty)
    }

    // MARK: - Model

    @Test func aSystemActionSurvivesSaving() throws {
        let rule = Rule(id: "custom.x", trigger: .mouseButton(number: 5), action: .systemAction(.spaceRight))
        let decoded = try JSONDecoder().decode(Rule.self, from: JSONEncoder().encode(rule))
        #expect(decoded == rule)
    }

    @Test func winDShowsTheDesktopWithTheUsersShortcut() throws {
        let rule = try #require(BuiltInRules.all.first { $0.id == "winKey.showDesktop" })
        #expect(rule.action == .systemAction(.showDesktop))
    }
}
