import Foundation
import Testing

@Suite struct ControlKeyTests {
    let rules = BuiltInRules.preset.groups.filter(\.isEnabledByDefault).flatMap(\.rules)

    func matcher(_ key: ControlKey) -> RuleMatcher {
        RuleMatcher(rules: key.apply(to: rules))
    }

    func match(_ key: ControlKey, _ combo: KeyCombo, in app: String = "com.apple.TextEdit") -> Action? {
        matcher(key).match(.key(combo: combo), in: MatchContext(frontmostBundleID: app))?.action
    }

    let copy = Action.key(combo: KeyCombo([.command], .c))

    @Test func ctrlIsTheDefault() {
        #expect(Configuration().controlKey == .control)
        #expect(ControlKey.control.apply(to: rules) == rules)
    }

    @Test func fnReplacesCtrl() {
        #expect(match(.function, KeyCombo([.function], .c)) == copy)
        #expect(match(.function, KeyCombo([.control], .c)) == nil, "Ctrl keeps its Mac meaning")
        #expect(match(.function, KeyCombo([.function, .shift], .t)) == .key(combo: KeyCombo([.shift, .command], .t)))
    }

    @Test func bothKeepsCtrlAndAddsFn() {
        #expect(match(.both, KeyCombo([.control], .c)) == copy)
        #expect(match(.both, KeyCombo([.function], .c)) == copy)
    }

    @Test func fnWorksInTerminalsWhereCtrlDoesNot() {
        #expect(match(.both, KeyCombo([.control], .c), in: "com.apple.Terminal") == nil)
        #expect(match(.both, KeyCombo([.function], .c), in: "com.apple.Terminal") == copy)
    }

    @Test func finderRulesStayInFinder() {
        #expect(match(.function, KeyCombo([.function], .v), in: "com.apple.finder")
                == .key(combo: KeyCombo([.option, .command], .v)))
    }

    @Test func keysThatReportFnThemselvesKeepCtrl() {
        // fn+← is Home on a MacBook, and fn+Home reads as Home.
        #expect(match(.function, KeyCombo([.control], .leftArrow)) == .key(combo: KeyCombo([.option], .leftArrow)))
        #expect(match(.function, KeyCombo([.control], .home)) == .key(combo: KeyCombo([.command], .upArrow)))
        #expect(match(.function, KeyCombo(.home)) == .key(combo: KeyCombo([.command], .leftArrow)))
    }

    /// fn+⌫ arrives as ⌦, so an fn+⌫ trigger could never fire (KB-231).
    @Test func deleteWordKeepsCtrl() {
        let deleteWord = Action.key(combo: KeyCombo([.option], .delete))
        for key in ControlKey.allCases {
            #expect(match(key, KeyCombo([.control], .delete)) == deleteWord, "\(key)")
            #expect(match(key, KeyCombo([.function], .delete)) == nil, "\(key)")
        }
        #expect(ControlKey.function.trigger(of: rules.first { $0.id == "nav.deleteWord" }!)
                == .key(combo: KeyCombo([.control], .delete)), "Shown with Ctrl")
    }

    /// Ctrl+Delete deletes the next word (SK-284), on Ctrl in every mode.
    @Test func deleteNextWordKeepsCtrl() {
        let deleteNextWord = Action.key(combo: KeyCombo([.option], .forwardDelete))
        for key in ControlKey.allCases {
            #expect(match(key, KeyCombo([.control], .forwardDelete)) == deleteNextWord, "\(key)")
        }
    }

    @Test func otherRulesAreUntouched() {
        let untouched = rules.filter {
            switch $0.trigger {
            case .key(let combo): !combo.modifiers.contains(.control)
            case .scroll(_, let modifiers): !modifiers.contains(.control)
            default: true
            }
        }
        let applied = ControlKey.function.apply(to: rules)
        for rule in untouched {
            #expect(applied.contains(rule), "\(rule.id)")
        }
    }

    @Test func idsStayUnique() {
        let ids = ControlKey.both.apply(to: rules).map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func theChoiceIsSavedAndOptionalInOlderFiles() throws {
        var configuration = Configuration()
        configuration.controlKey = .function
        let data = try JSONEncoder().encode(configuration)
        #expect(try JSONDecoder().decode(Configuration.self, from: data).controlKey == .function)
        #expect(String(decoding: data, as: UTF8.self).contains(#""controlKey":"fn""#))

        let older = Data(#"{"schemaVersion": 1, "overrides": []}"#.utf8)
        #expect(try JSONDecoder().decode(Configuration.self, from: older).controlKey == .control)
    }

    /// Zooming is Ctrl+wheel on Windows, so it follows the choice like the
    /// Ctrl shortcuts (SK-297).
    @Test func zoomFollowsTheChoice() {
        func zoom(_ key: ControlKey, _ modifiers: Modifiers) -> String? {
            matcher(key).match(.scroll(direction: .up, modifiers: modifiers), in: MatchContext(frontmostBundleID: "com.apple.Safari"))?.id
        }
        #expect(zoom(.control, [.control]) == "scroll.zoomIn")
        #expect(zoom(.control, [.function]) == nil)
        #expect(zoom(.function, [.function]) == "scroll.zoomIn.fn")
        #expect(zoom(.function, [.control]) == nil, "Left to the system's screen zoom")
        #expect(zoom(.both, [.control]) != nil && zoom(.both, [.function]) != nil)
    }

    @Test func aZoomKeyOtherThanCtrlIsTheSameWhateverTheChoice() {
        var zoomIn = rules.first { $0.id == "scroll.zoomIn" }!
        zoomIn.trigger = .scroll(direction: .up, modifiers: [.function])
        #expect(ControlKey.control.apply(to: [zoomIn]) == [zoomIn])
        #expect(ControlKey.both.apply(to: [zoomIn]) == [zoomIn])
    }

    /// A file from before SK-297 that chose Ctrl for zooming kept it as a
    /// change, which is now what the preset has.
    @Test func anOlderCtrlZoomChoiceIsNoLongerAChange() throws {
        var configuration = Configuration()
        for id in ["scroll.zoomIn", "scroll.zoomOut"] {
            configuration.overrides.append(.modified(rule: rules.first { $0.id == id }!))
        }
        var copy = rules.first { $0.id == "edit.copy" }!
        copy.isEnabled = false
        configuration.overrides.append(.modified(rule: copy))
        let read = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(configuration))
        #expect(read.overrides == [.modified(rule: copy)])
    }

    @Test func aCustomizedTriggerFollowsTheChoiceToo() {
        var copy = rules.first { $0.id == "edit.copy" }!
        copy.trigger = .key(combo: KeyCombo([.control, .shift], .c))
        let applied = ControlKey.function.apply(to: [copy])
        #expect(applied.map(\.trigger) == [.key(combo: KeyCombo([.function, .shift], .c))])
    }
}
