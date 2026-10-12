import Foundation
import Testing

/// Which Mac keys play Win and Alt (KB-226).
@MainActor
@Suite struct ModifierLayoutTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "SameKeysTests-\(UUID().uuidString)")
    var store: ConfigurationStore { ConfigurationStore(fileURL: folder.appending(path: "config.json")) }

    func makeController() -> RulesController {
        let controller = RulesController(store: store)
        controller.setGroup("winKey", enabled: true)
        return controller
    }

    func trigger(_ id: String, in rules: [Rule]) -> Trigger? {
        rules.first { $0.id == id }?.trigger
    }

    func key(_ modifiers: Modifiers, _ key: KeyCode) -> Trigger {
        .key(combo: KeyCombo(modifiers, key))
    }

    // MARK: - The rewrite

    @Test func aPCKeyboardIsThePresetAsWritten() {
        let controller = makeController()
        #expect(controller.modifierLayout == .pcKeyboard)
        #expect(trigger("winKey.lock", in: controller.effectiveRules) == key([.command], .l))
        #expect(trigger("winKey.start", in: controller.effectiveRules) == key([], .command))
        #expect(trigger("winKey.inputSource", in: controller.effectiveRules) == key([.command], .space))
        #expect(controller.effectiveRules.first { $0.id == "winKey.inputSource" }?.action == .systemAction(.inputSource))
        #expect(trigger("win.quit", in: controller.effectiveRules) == key([.option], .f4))
    }

    @Test func byPositionWinIsOptionAndAltIsCommand() {
        let controller = makeController()
        controller.setModifierLayout(.macPosition)
        let rules = controller.effectiveRules
        #expect(trigger("winKey.lock", in: rules) == key([.option], .l))
        #expect(trigger("winKey.screenshotArea", in: rules) == key([.shift, .option], .s))
        #expect(trigger("winKey.inputSource", in: rules) == key([.option], .space), "Win+Space (SK-278)")
        #expect(trigger("winKey.start", in: rules) == key([], .option), "Win alone is ⌥ alone")
        #expect(trigger("win.quit", in: rules) == key([.command], .f4))
        #expect(trigger("sys.forceQuit", in: rules) == key([.control, .command], .forwardDelete))
        // Results are what the Mac gets, whatever the keyboard.
        #expect(rules.first { $0.id == "winKey.lock" }?.action == .key(combo: KeyCombo([.control, .command], .q)))
    }

    @Test func windowSnappingStaysOnOption() {
        let controller = makeController()
        controller.setModifierLayout(.macPosition)
        #expect(trigger("window.leftHalf", in: controller.effectiveRules) == key([.option], .leftArrow))
        #expect(trigger("window.minimize", in: controller.rules(inGroup: "window")) == key([.option], .downArrow))
    }

    @Test func mouseScrollAndCtrlShortcutsAreUntouched() {
        let controller = makeController()
        controller.setModifierLayout(.macPosition)
        let rules = controller.effectiveRules
        #expect(trigger("edit.copy", in: rules) == key([.control], .c))
        #expect(trigger("mouse.back", in: rules) == .mouseButton(number: 4))
        #expect(trigger("scroll.zoomIn", in: rules) == .scroll(direction: .up, modifiers: [.control]))
    }

    @Test func customRulesAreTakenAsRecorded() {
        let controller = makeController()
        let custom = Rule(id: "custom.1", trigger: key([.command], .n), action: .key(combo: KeyCombo([.command], .p)))
        controller.saveCustomRule(custom)
        controller.setModifierLayout(.macPosition)
        #expect(controller.effectiveRules.first == custom)
    }

    @Test func altTabByPositionIsTheMacsOwnAndIsLeftAlone() {
        let controller = makeController()
        controller.setModifierLayout(.macPosition)
        let rules = controller.effectiveRules
        #expect(rules.first { $0.id == "win.switchApp" }?.trigger == key([.command], .tab), "Shown as Alt+Tab → ⌘Tab")
        let matcher = RuleMatcher(rules: rules)
        let context = MatchContext(frontmostBundleID: "com.apple.Safari")
        #expect(matcher.match(key([.command], .tab), in: context) == nil, "Not replaced by a copy of itself")
        #expect(matcher.match(key([.option], .tab), in: context)?.id == "winKey.taskView", "Win+Tab (KB-227)")
        #expect(matcher.match(key([.option], .l), in: context)?.id == "winKey.lock")
    }

    /// Win+Tab opens Mission Control and Alt+Tab still switches apps, with
    /// either choice (KB-227).
    @Test func winTabIsMissionControlAndAltTabStillSwitchesApps() {
        let controller = makeController()
        let context = MatchContext(frontmostBundleID: "com.apple.Safari")

        var matcher = RuleMatcher(rules: controller.effectiveRules)
        #expect(matcher.match(key([.command], .tab), in: context)?.action == .systemAction(.missionControl))
        #expect(matcher.match(key([.option], .tab), in: context)?.id == "win.switchApp")

        controller.setModifierLayout(.macPosition)
        matcher = RuleMatcher(rules: controller.effectiveRules)
        #expect(matcher.match(key([.option], .tab), in: context)?.id == "winKey.taskView")
        #expect(matcher.match(key([.command], .tab), in: context) == nil, "The Mac's own app switcher")
    }

    @Test func worksTogetherWithFn() {
        let controller = makeController()
        controller.setModifierLayout(.macPosition)
        let context = MatchContext(frontmostBundleID: "com.apple.Safari")
        for controlKey in ControlKey.allCases {
            controller.setControlKey(controlKey)
            let matcher = RuleMatcher(rules: controller.effectiveRules)
            #expect(matcher.match(key([.option], .l), in: context)?.id == "winKey.lock", "\(controlKey)")
            #expect(matcher.match(key([.command], .f4), in: context)?.id == "win.quit", "\(controlKey)")
            let copy = controlKey == .control ? key([.control], .c) : key([.function], .c)
            #expect(matcher.match(copy, in: context)?.id.hasPrefix("edit.copy") == true, "\(controlKey)")
        }
    }

    // MARK: - Editing entries

    @Test func theOriginalIsShownInTheChosenLayout() {
        let controller = makeController()
        controller.setModifierLayout(.macPosition)
        #expect(controller.original(of: "winKey.lock")?.trigger == key([.option], .l))
        #expect(controller.original(of: "window.leftHalf")?.trigger == key([.option], .leftArrow))
    }

    @Test func recordingTheShownTriggerIsNoChange() {
        let controller = makeController()
        controller.setModifierLayout(.macPosition)
        var lock = controller.rules(inGroup: "winKey").first { $0.id == "winKey.lock" }!
        lock.trigger = key([.option], .l)
        controller.update(lock)
        #expect(!controller.isCustomized("winKey.lock"))
    }

    @Test func aReRecordedWinShortcutStaysWinWhenTheChoiceChanges() {
        let controller = makeController()
        controller.setModifierLayout(.macPosition)
        var lock = controller.rules(inGroup: "winKey").first { $0.id == "winKey.lock" }!
        lock.trigger = key([.option], .n) // Win+N by position
        controller.update(lock)
        #expect(controller.isCustomized("winKey.lock"))
        #expect(trigger("winKey.lock", in: controller.effectiveRules) == key([.option], .n))

        controller.setModifierLayout(.pcKeyboard)
        #expect(trigger("winKey.lock", in: controller.effectiveRules) == key([.command], .n), "Still Win+N")

        let saved = controller.configuration.overrides.first { $0.id == "winKey.lock" }?.rule.trigger
        #expect(saved == key([.command], .n), "Kept in the preset's terms")
    }

    @Test func aChangedSnapKeyIsNotTraded() {
        let controller = makeController()
        controller.setModifierLayout(.macPosition)
        var left = controller.rules(inGroup: "window").first { $0.id == "window.leftHalf" }!
        left.trigger = key([.command], .leftArrow)
        controller.update(left)
        #expect(trigger("window.leftHalf", in: controller.effectiveRules) == key([.command], .leftArrow))
    }

    @Test func conflictsAreFoundInTheChosenLayout() {
        let controller = makeController()
        controller.setModifierLayout(.macPosition)
        let custom = Rule(id: "custom.1", trigger: key([.option], .l), action: .key(combo: KeyCombo([.command], .p)))
        #expect(controller.conflicts(with: custom).map(\.id) == ["winKey.lock"])
    }

    // MARK: - Settings

    @Test func theChoiceIsSavedAndSurvivesRestoreDefaults() {
        let controller = makeController()
        controller.setModifierLayout(.macPosition)
        #expect(RulesController(store: store).modifierLayout == .macPosition, "Saved")
        controller.restoreDefaults()
        #expect(controller.modifierLayout == .macPosition, "A setting, not part of the preset")
    }

    @Test func olderFilesMeanAPCKeyboardAndTheDefaultIsNotWritten() throws {
        let old = try JSONDecoder().decode(Configuration.self, from: Data(#"{"schemaVersion":1}"#.utf8))
        #expect(old.modifierLayout == .pcKeyboard)
        let written = String(decoding: try JSONEncoder().encode(Configuration()), as: UTF8.self)
        #expect(!written.contains("modifierLayout"))

        var configuration = Configuration()
        configuration.modifierLayout = .macPosition
        let data = try JSONEncoder().encode(configuration)
        #expect(try JSONDecoder().decode(Configuration.self, from: data).modifierLayout == .macPosition)
    }

    // MARK: - Names

    @Test func byPositionOptionIsCalledWinAndCommandAlt() {
        #expect(KeyCombo([.option], .l).caps(.windowsByPosition) == ["Win", "L"])
        #expect(KeyCombo([.command], .f4).caps(.windowsByPosition) == ["Alt", "F4"])
        #expect(KeyCombo(.option).caps(.windowsByPosition) == ["Win"])
        #expect(KeyCombo([.control], .c).caps(.windowsByPosition) == ["Ctrl", "C"])
        #expect(ModifierLayout.pcKeyboard.triggerStyle == .windows)
        #expect(ModifierLayout.macPosition.triggerStyle == .windowsByPosition)
    }
}
