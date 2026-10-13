import Foundation
import Testing

/// The shipped preset against the Windows shortcut coverage list.
@Suite struct WindowsPresetTests {
    let preset = BuiltInRules.preset
    let matcher = RuleMatcher(rules: BuiltInRules.all)

    func match(_ combo: KeyCombo, in bundleID: String = "com.apple.TextEdit", typing: Bool = false) -> String? {
        matcher.match(.key(combo: combo), in: MatchContext(frontmostBundleID: bundleID), isEditingText: { typing })?.id
    }

    /// Ctrl+=, Ctrl+- and Ctrl+0 zoom as on Windows (KB-225), outside
    /// terminals, and follow the fn / Ctrl choice like the rest of the group.
    /// Ctrl+Shift+N: a new folder in Finder, a private window in browsers
    /// (SK-299).
    @Test func ctrlShiftNIsCommandShiftNOutsideTerminals() {
        let trigger = Trigger.key(combo: KeyCombo([.control, .shift], .n))
        for app in ["com.apple.finder", "com.google.Chrome", "com.apple.Safari"] {
            let rule = matcher.match(trigger, in: MatchContext(frontmostBundleID: app))
            #expect(rule?.id == "edit.newFolder", "\(app)")
            #expect(rule?.action == .key(combo: KeyCombo([.shift, .command], .n)))
        }
        #expect(matcher.match(trigger, in: MatchContext(frontmostBundleID: "com.apple.Terminal")) == nil)
        let fn = RuleMatcher(rules: ControlKey.function.apply(to: BuiltInRules.all))
        #expect(fn.match(.key(combo: KeyCombo([.function, .shift], .n)), in: MatchContext(frontmostBundleID: "com.apple.finder"))?.id
                == "edit.newFolder.fn")
    }

    @Test func zoomKeysZoomOutsideTerminals() {
        let zoom: [(String, KeyCode)] = [("browser.zoomIn", .equal), ("browser.zoomOut", .minus), ("browser.zoomReset", .zero)]
        for (id, key) in zoom {
            #expect(match(KeyCombo([.control], key), in: "com.apple.Safari") == id)
            #expect(match(KeyCombo([.control], key), in: "com.apple.Terminal") == nil, "\(id) in a terminal")
            #expect(preset.rules.first { $0.id == id }?.action == .key(combo: KeyCombo([.command], key)))
            let fnMode = RuleMatcher(rules: ControlKey.function.apply(to: BuiltInRules.all))
            #expect(fnMode.match(.key(combo: KeyCombo([.function], key)),
                                 in: MatchContext(frontmostBundleID: "com.apple.Safari"))?.id == id + ".fn")
        }
    }

    @Test func idsAreUnique() {
        let ids = preset.rules.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func groupsAreTheCoverageListsPlusDialogsMouseScrollAndWindow() {
        #expect(preset.groups.map(\.id) == [
            "winKey", "editing", "navigation", "finder", "dialogs", "windows", "browser", "window", "mouse", "scroll",
        ])
    }

    /// The snap shortcuts are ⌥ and an arrow, on by default (KB-201). ⌥ is
    /// where the Windows key sits on a PC keyboard; ⌘ is where Alt does.
    @Test func windowActionpingIsOnOptionAndTheArrowsAndStartsOn() {
        let group = preset.groups.first { $0.id == "window" }
        #expect(group?.isEnabledByDefault == true)
        let snaps: [(String, KeyCode, WindowAction)] = [
            ("window.leftHalf", .leftArrow, .leftHalf),
            ("window.rightHalf", .rightArrow, .rightHalf),
            ("window.maximize", .upArrow, .maximize),
            ("window.minimize", .downArrow, .minimize),
        ]
        for (id, key, snap) in snaps {
            let rule = preset.rules.first { $0.id == id }
            #expect(rule?.trigger == .key(combo: KeyCombo([.option], key)), "\(id) trigger")
            #expect(rule?.action == .windowAction(snap), "\(id) action")
            // Everywhere, terminals included: an arrow with ⌥ means nothing to a shell.
            #expect(rule?.scope == .everywhere, "\(id) scope")
        }
    }

    /// Every "bulk" and "dedicated" entry of the list, as trigger → result.
    @Test func coverageListEntriesAreMapped() {
        let expected: [(KeyCombo, KeyCombo, String)] = [
            (KeyCombo([.control], .c), KeyCombo([.command], .c), "com.apple.TextEdit"),
            (KeyCombo([.control], .x), KeyCombo([.command], .x), "com.apple.TextEdit"),
            (KeyCombo([.control], .v), KeyCombo([.command], .v), "com.apple.TextEdit"),
            (KeyCombo([.control], .z), KeyCombo([.command], .z), "com.apple.TextEdit"),
            (KeyCombo([.control], .y), KeyCombo([.shift, .command], .z), "com.apple.TextEdit"),
            (KeyCombo([.control], .a), KeyCombo([.command], .a), "com.apple.TextEdit"),
            (KeyCombo([.control], .s), KeyCombo([.command], .s), "com.apple.TextEdit"),
            (KeyCombo([.control], .f), KeyCombo([.command], .f), "com.apple.TextEdit"),
            (KeyCombo([.control], .n), KeyCombo([.command], .n), "com.apple.TextEdit"),
            (KeyCombo([.control], .o), KeyCombo([.command], .o), "com.apple.TextEdit"),
            (KeyCombo([.control], .p), KeyCombo([.command], .p), "com.apple.TextEdit"),
            (KeyCombo(.home), KeyCombo([.command], .leftArrow), "com.apple.TextEdit"),
            (KeyCombo(.end), KeyCombo([.command], .rightArrow), "com.apple.TextEdit"),
            (KeyCombo([.control], .home), KeyCombo([.command], .upArrow), "com.apple.TextEdit"),
            (KeyCombo([.control], .end), KeyCombo([.command], .downArrow), "com.apple.TextEdit"),
            (KeyCombo([.control], .leftArrow), KeyCombo([.option], .leftArrow), "com.apple.TextEdit"),
            (KeyCombo([.control], .rightArrow), KeyCombo([.option], .rightArrow), "com.apple.TextEdit"),
            (KeyCombo([.shift], .home), KeyCombo([.shift, .command], .leftArrow), "com.apple.TextEdit"),
            (KeyCombo([.shift], .end), KeyCombo([.shift, .command], .rightArrow), "com.apple.TextEdit"),
            (KeyCombo([.control], .delete), KeyCombo([.option], .delete), "com.apple.TextEdit"),
            (KeyCombo(.forwardDelete), KeyCombo([.command], .delete), "com.apple.finder"),
            (KeyCombo(.f2), KeyCombo(.returnKey), "com.apple.finder"),
            (KeyCombo(.returnKey), KeyCombo([.command], .downArrow), "com.apple.finder"),
            (KeyCombo([.control], .x), KeyCombo([.command], .c), "com.apple.finder"),
            (KeyCombo([.control], .v), KeyCombo([.option, .command], .v), "com.apple.finder"),
            (KeyCombo(.delete), KeyCombo([.command], .upArrow), "com.apple.finder"),
            (KeyCombo([.option], .tab), KeyCombo([.command], .tab), "com.apple.TextEdit"),
            (KeyCombo([.option], .f4), KeyCombo([.command], .q), "com.apple.TextEdit"),
            (KeyCombo(.f13), KeyCombo([.control, .shift, .command], .three), "com.apple.TextEdit"),
            (KeyCombo([.control], .t), KeyCombo([.command], .t), "com.apple.TextEdit"),
            (KeyCombo([.control], .w), KeyCombo([.command], .w), "com.apple.TextEdit"),
            (KeyCombo([.control, .shift], .t), KeyCombo([.shift, .command], .t), "com.apple.TextEdit"),
            (KeyCombo([.control], .l), KeyCombo([.command], .l), "com.apple.TextEdit"),
            (KeyCombo([.control], .r), KeyCombo([.command], .r), "com.apple.TextEdit"),
            (KeyCombo([.command], .l), KeyCombo([.control, .command], .q), "com.apple.TextEdit"),
            (KeyCombo([.command], .period), KeyCombo([.control, .command], .space), "com.apple.TextEdit"),
            (KeyCombo([.shift, .command], .s), KeyCombo([.control, .shift, .command], .four), "com.apple.TextEdit"),
        ]
        for (trigger, result, app) in expected {
            let rule = matcher.match(.key(combo: trigger), in: MatchContext(frontmostBundleID: app))
            #expect(rule?.action == .key(combo: result), "\(trigger.caps(.windows)) in \(app)")
        }
    }

    @Test func theFinderGroupIsScopedToFinderOnly() throws {
        let finder = try #require(preset.groups.first { $0.id == "finder" })
        for rule in finder.rules {
            #expect(rule.scope.applications == .only(bundleIDs: ["com.apple.finder"]), "\(rule.id)")
            #expect(rule.scope.skipsTextInput, "\(rule.id)")
        }
        #expect(match(KeyCombo(.returnKey)) == nil, "Enter is Enter elsewhere")
        #expect(match(KeyCombo(.delete)) == nil, "Backspace is Backspace elsewhere")
        #expect(match(KeyCombo([.control], .v)) == "edit.paste")
    }

    /// Ctrl+D deletes in Explorer too (KB-221): in Finder only, and not while
    /// renaming, where Ctrl+D is the text field's own forward delete.
    @Test func ctrlDMovesToTrashInFinderOnly() {
        #expect(match(KeyCombo([.control], .d), in: "com.apple.finder") == "finder.trashCtrlD")
        #expect(matcher.match(.key(combo: KeyCombo([.control], .d)), in: MatchContext(frontmostBundleID: "com.apple.finder"))?
            .action == .key(combo: KeyCombo([.command], .delete)))
        #expect(match(KeyCombo([.control], .d), in: "com.apple.finder", typing: true) == nil)
        #expect(match(KeyCombo([.control], .d)) == nil, "Ctrl+D is left alone outside Finder")
        let fn = RuleMatcher(rules: ControlKey.function.apply(to: BuiltInRules.all))
        #expect(fn.match(.key(combo: KeyCombo([.function], .d)), in: MatchContext(frontmostBundleID: "com.apple.finder"))?
            .id == "finder.trashCtrlD.fn")
    }

    @Test func finderRulesStandAsideWhileTyping() {
        #expect(match(KeyCombo(.returnKey), in: "com.apple.finder") == "finder.open")
        #expect(match(KeyCombo(.returnKey), in: "com.apple.finder", typing: true) == nil)
        #expect(match(KeyCombo([.control], .v), in: "com.apple.finder", typing: true) == "edit.paste",
                "Pastes into the rename field instead of moving files")
    }

    @Test func focusIsOnlyAskedForWhenARuleNeedsIt() {
        var asked = 0
        _ = matcher.match(.key(combo: KeyCombo([.control], .c)), in: MatchContext(frontmostBundleID: "com.apple.finder"),
                          isEditingText: { asked += 1; return false })
        #expect(asked == 0)
        _ = matcher.match(.key(combo: KeyCombo([.control], .v)), in: MatchContext(frontmostBundleID: "com.apple.finder"),
                          isEditingText: { asked += 1; return true })
        #expect(asked == 1, "Asked once, even with a fallback rule to try")
    }

    @Test func ctrlShortcutsAreLeftAloneInTerminals() {
        for combo in [KeyCombo([.control], .c), KeyCombo([.control], .w), KeyCombo([.control], .a), KeyCombo([.control], .r)] {
            #expect(match(combo, in: "com.apple.Terminal") == nil, "\(combo.caps(.windows))")
        }
        #expect(match(KeyCombo([.option], .tab), in: "com.apple.Terminal") == "win.switchApp")
    }

    @Test func onlyTheWinKeyGroupStartsOff() {
        #expect(preset.groups.filter { !$0.isEnabledByDefault }.map(\.id) == ["winKey"])
        // ⌘ with a key, or ⌘ tapped on its own (Win alone).
        func takesCommand(_ rule: Rule) -> Bool {
            guard case .key(let combo) = rule.trigger else { return false }
            return combo.modifiers.contains(.command) || combo.key == .command
        }
        let winKey = preset.groups.first { $0.id == "winKey" }!
        #expect(winKey.rules.allSatisfy(takesCommand))
        let others = preset.groups.filter { $0.id != "winKey" }.flatMap(\.rules)
        #expect(!others.contains(where: takesCommand), "No other group may take over ⌘ shortcuts")
    }

    @Test func noTwoRulesShareATriggerInTheSameApps() {
        var seen: [String: String] = [:]
        for rule in preset.rules {
            let key = "\(rule.trigger)|\(rule.scope.applications)"
            #expect(seen[key] == nil, "\(rule.id) duplicates \(seen[key] ?? "")")
            seen[key] = rule.id
        }
    }

    @Test func textInputFlagIsOptionalInTheFile() throws {
        let plain = Scope()
        let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!json.contains("skipsTextInput"), "Existing rules encode as before")

        let skipping = Scope(applications: .only(bundleIDs: ["com.apple.finder"]), skipsTextInput: true)
        let decoded = try JSONDecoder().decode(Scope.self, from: JSONEncoder().encode(skipping))
        #expect(decoded == skipping)
    }
}
