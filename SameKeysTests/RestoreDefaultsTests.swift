import Foundation
import Testing

@MainActor
@Suite struct RestoreDefaultsTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "SameKeysTests-\(UUID().uuidString)")
    var store: ConfigurationStore { ConfigurationStore(fileURL: folder.appending(path: "config.json")) }

    @Test func groupsGoBackToTheirDefaults() {
        let controller = RulesController(store: store)
        #expect(controller.isDefault)
        controller.setGroup("editing", enabled: false)
        controller.setGroup("winKey", enabled: true)
        #expect(!controller.isDefault)

        controller.restoreDefaults()
        #expect(controller.isDefault)
        #expect(controller.isEnabled(group: "editing"))
        #expect(!controller.isEnabled(group: "winKey"), "Off by default")
        #expect(controller.effectiveRules.contains { $0.id == "edit.copy" }, "In effect at once")
        #expect(RulesController(store: store).isDefault, "Saved")
    }

    @Test func changedEntriesGoBackButCustomRulesAndSettingsStay() throws {
        let controller = RulesController(store: store)
        var copy = try #require(controller.original(of: "edit.copy"))
        copy.trigger = .key(combo: KeyCombo([.control, .shift], .c))
        controller.update(copy)
        controller.setZoomModifiers([.function])
        let custom = Rule(id: "custom.1", trigger: .mouseButton(number: 3), action: .key(combo: KeyCombo([.command], .w)))
        controller.saveCustomRule(custom)
        controller.setControlKey(.function)
        controller.setWheelDirection(.windows)

        controller.restoreDefaults()
        #expect(!controller.isCustomized("edit.copy"))
        #expect(controller.zoomModifiers == [.control])
        #expect(controller.customRules == [custom])
        #expect(controller.controlKey == .function)
        #expect(controller.wheelDirection == .windows)
    }

    /// KB-031: a newer preset reaches the entries the user never touched,
    /// while their changes stay on top.
    @Test func untouchedEntriesFollowAnUpdatedPreset() throws {
        var copy = try #require(BuiltInRules.all.first { $0.id == "edit.copy" })
        copy.trigger = .key(combo: KeyCombo([.control, .shift], .c))
        try store.save(Configuration(overrides: [.modified(rule: copy)]))

        // A later release changes the Editing group.
        var updated = BuiltInRules.preset
        let editing = try #require(updated.groups.firstIndex { $0.id == "editing" })
        for index in updated.groups[editing].rules.indices {
            updated.groups[editing].rules[index].scope = .everywhere
        }
        let rules = RulesController(preset: updated, store: store).effectiveRules
        #expect(rules.first { $0.id == "edit.paste" }?.scope == .everywhere, "Untouched: the new value")
        #expect(rules.first { $0.id == "edit.copy" } == copy, "Customized: the user's version")
    }
}
