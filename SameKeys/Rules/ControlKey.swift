/// The key that plays the part of Windows' Ctrl.
///
/// Many people coming from Windows keep their thumb-side habit on a Mac
/// keyboard by pressing fn (🌐) where Ctrl used to be. With fn, Ctrl keeps its
/// Mac meaning, which also means Ctrl+C still interrupts in a terminal.
enum ControlKey: String, Codable, CaseIterable, Sendable {
    /// Ctrl+C copies, as on Windows.
    case control
    /// fn+C copies; Ctrl is left alone.
    case function = "fn"
    /// Both work.
    case both

    /// Rewrites the Ctrl shortcuts among `rules` for this choice.
    ///
    /// Only triggers that hold Ctrl and not fn change, and never those on
    /// keys fn already has a use for (`keepsControl`). An fn version applies
    /// in terminals too, since fn+C means nothing to a shell. Scrolling with
    /// Ctrl, the zoom (SK-297), changes the same way.
    func apply(to rules: [Rule]) -> [Rule] {
        guard self != .control else { return rules }
        return rules.flatMap { rule -> [Rule] in
            guard let fn = Self.fnVersion(of: rule) else { return [rule] }
            return self == .both ? [rule, fn] : [fn]
        }
    }

    /// The trigger as it is pressed with this choice, for display.
    func trigger(of rule: Rule) -> Trigger {
        guard self == .function, let fn = Self.fnVersion(of: rule) else { return rule.trigger }
        return fn.trigger
    }

    private static func fnVersion(of rule: Rule) -> Rule? {
        var fn = rule
        switch rule.trigger {
        case .key(var combo):
            guard combo.modifiers.contains(.control), !combo.modifiers.contains(.function),
                  !combo.key.keepsControl else { return nil }
            combo.modifiers.remove(.control)
            combo.modifiers.insert(.function)
            fn.trigger = .key(combo: combo)
        case .scroll(let direction, var modifiers):
            guard modifiers.contains(.control), !modifiers.contains(.function) else { return nil }
            modifiers.remove(.control)
            modifiers.insert(.function)
            fn.trigger = .scroll(direction: direction, modifiers: modifiers)
        default:
            return nil
        }
        fn.id = rule.id + ".fn"
        if case .except = fn.scope.applications {
            fn.scope.applications = .all
        }
        return fn
    }
}

extension KeyCode {
    /// Keys whose Ctrl shortcuts stay on Ctrl whatever the choice: on a Mac
    /// keyboard fn turns them into other keys. Arrows, Home, F-keys and the
    /// like report fn by themselves (fn+← is Home, so fn+Home reads as
    /// Home), and fn+⌫ arrives as ⌦, so an fn+⌫ trigger could never fire.
    var keepsControl: Bool {
        carriesImplicitFunctionFlag || self == .delete
    }
}
