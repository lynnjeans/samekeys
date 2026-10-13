/// What is known about an event's surroundings when it is matched.
struct MatchContext: Sendable {
    /// Bundle identifier of the frontmost application, if there is one.
    var frontmostBundleID: String?
    /// The device the event came from. Nil until device identification
    /// exists, which means device-scoped rules never match yet.
    var device: DeviceID?
}

/// Finds the rule an input triggers.
///
/// Runs inside the event tap callback for every event, so lookups are a single
/// dictionary access plus a scan of the few rules that share a trigger.
struct RuleMatcher: Sendable {
    /// Enabled rules by trigger, most specific scope first.
    private let candidates: [Trigger: [Rule]]

    init(rules: [Rule]) {
        var byTrigger: [Trigger: [(offset: Int, rule: Rule)]] = [:]
        for (offset, rule) in rules.enumerated() where rule.isEnabled && !rule.changesNothing {
            byTrigger[rule.trigger, default: []].append((offset, rule))
        }
        // When several rules share a trigger, the narrower scope wins: Ctrl+V
        // moves files in Finder and pastes everywhere else. Ties keep the
        // order the rules were given in.
        candidates = byTrigger.mapValues { entries in
            entries.sorted {
                ($0.rule.scope.specificity, -$0.offset) > ($1.rule.scope.specificity, -$1.offset)
            }.map(\.rule)
        }
    }

    /// - Parameters:
    ///   - isEditingText: asked only when a candidate rule skips text input,
    ///     since finding out means asking the frontmost application.
    ///   - isInFileDialog: asked only when a candidate rule acts on an open
    ///     or save dialog, for the same reason.
    ///   - isClipboardHistoryOn: asked only when a candidate rule opens the
    ///     clipboard history. While it is off, its key does what it did
    ///     before: Win+V as ⌘V pastes (KB-245).
    ///   - isInTerminal: asked only when a candidate rule stands aside in
    ///     terminals, whether focus is in a terminal inside another app, such
    ///     as VS Code's (SK-298). There the rule stands aside too.
    func match(
        _ trigger: Trigger,
        in context: MatchContext,
        isEditingText: () -> Bool = { false },
        isInFileDialog: () -> Bool = { false },
        isClipboardHistoryOn: () -> Bool = { false },
        isInTerminal: () -> Bool = { false }
    ) -> Rule? {
        var editing: Bool?
        var inDialog: Bool?
        var inTerminal: Bool?
        return candidates[trigger]?.first { rule in
            guard rule.scope.admits(context) else { return false }
            if rule.scope.applications.standsAsideInTerminals {
                if inTerminal == nil { inTerminal = isInTerminal() }
                guard inTerminal == false else { return false }
            }
            if rule.action == .clipboardHistory, !isClipboardHistoryOn() { return false }
            if let dialogAction = rule.action.fileDialogAction,
               !(dialogAction.worksInFinder && context.frontmostBundleID == BuiltInRules.finderID) {
                if inDialog == nil { inDialog = isInFileDialog() }
                guard inDialog == true else { return false }
            }
            guard rule.scope.skipsTextInput else { return true }
            if editing == nil { editing = isEditingText() }
            return editing == false
        }
    }
}

extension Scope {
    func admits(_ context: MatchContext) -> Bool {
        applications.admits(context.frontmostBundleID) && devices.admits(context.device)
    }

    /// Higher is narrower. An application list outranks a device list.
    fileprivate var specificity: Int {
        var score = 0
        if case .only = applications { score += 2 }
        if case .only = devices { score += 1 }
        return score
    }
}

extension ApplicationFilter {
    /// Leaves terminals out, as the Ctrl shortcuts do: then terminals inside
    /// other apps are left out too.
    var standsAsideInTerminals: Bool {
        if case .except(let bundleIDs) = self { bundleIDs.contains(where: BuiltInRules.terminals.contains) } else { false }
    }

    func admits(_ bundleID: String?) -> Bool {
        switch self {
        case .all:
            return true
        case .only(let bundleIDs):
            return bundleID.map(bundleIDs.contains) ?? false
        case .except(let bundleIDs):
            return !(bundleID.map(bundleIDs.contains) ?? false)
        }
    }
}

extension DeviceFilter {
    func admits(_ device: DeviceID?) -> Bool {
        switch self {
        case .all:
            return true
        case .only(let devices):
            return device.map(devices.contains) ?? false
        }
    }
}

private extension Rule {
    /// A key turned into the same key, such as Alt+Tab → ⌘Tab when Alt is ⌘
    /// (KB-226). Matching it would only swap the keystroke for a copy.
    var changesNothing: Bool {
        if case .key(let trigger) = trigger, case .key(let result) = action { trigger == result } else { false }
    }
}
