import Observation
import OSLog

/// Holds the rules the app runs with: the preset, the user's configuration on
/// top of it, and the engine's copy of the result.
///
/// Every change made in the UI goes through here, so saving the file and
/// refreshing the engine always happen together and in that order — a change
/// the user can see is a change already on disk.
@MainActor
@Observable
final class RulesController {
    let preset: Preset

    private(set) var configuration: Configuration

    /// The rules in effect, recomputed on every change.
    private(set) var effectiveRules: [Rule]

    @ObservationIgnored private let store: ConfigurationStore
    @ObservationIgnored private let apply: ([Rule]) -> Void
    @ObservationIgnored private let applyWheelDirection: (WheelDirection) -> Void
    @ObservationIgnored private let applyDockClick: (Bool) -> Void
    @ObservationIgnored private let applyCtrlClick: (CtrlClick?) -> Void
    @ObservationIgnored private let applyKeyboards: ([Keyboard.ID: Dispatcher.KeyboardProfile]) -> Void
    @ObservationIgnored private let capture: ((@MainActor (Trigger) -> Void)?) -> Void

    /// - Parameters:
    ///   - apply: hands the engine the rules it should run with.
    ///   - applyWheelDirection: tells the engine which way wheels scroll.
    ///   - applyDockClick: tells the engine whether Dock clicks minimize.
    ///   - applyKeyboards: hands the engine what each keyboard with settings
    ///     of its own runs with (KB-243).
    ///   - capture: points the engine's key presses at a recorder, or back
    ///     at the rules with nil.
    init(
        preset: Preset = BuiltInRules.preset,
        store: ConfigurationStore = ConfigurationStore(),
        configuration: Configuration? = nil,
        capture: @escaping ((@MainActor (Trigger) -> Void)?) -> Void = { _ in },
        applyWheelDirection: @escaping (WheelDirection) -> Void = { _ in },
        applyDockClick: @escaping (Bool) -> Void = { _ in },
        applyCtrlClick: @escaping (CtrlClick?) -> Void = { _ in },
        applyKeyboards: @escaping ([Keyboard.ID: Dispatcher.KeyboardProfile]) -> Void = { _ in },
        apply: @escaping ([Rule]) -> Void = { _ in }
    ) {
        self.preset = preset
        self.store = store
        self.apply = apply
        self.applyWheelDirection = applyWheelDirection
        self.applyDockClick = applyDockClick
        self.applyCtrlClick = applyCtrlClick
        self.applyKeyboards = applyKeyboards
        self.capture = capture
        // Computed into locals first: `self` is off limits until every
        // stored property has a value.
        let loaded = configuration ?? store.load().configuration
        let rules = loaded.effectiveRules(of: preset)
        self.configuration = loaded
        effectiveRules = rules
        apply(rules)
        applyWheelDirection(loaded.wheelDirection)
        applyDockClick(loaded.dockClickMinimizes)
        applyCtrlClick(loaded.ctrlClick)
        applyKeyboards(loaded.keyboardProfiles(of: preset, connected: []))
    }

    /// Whether the preset is as it ships, with no group switched and no
    /// entry changed.
    var isDefault: Bool {
        configuration.isDefault
    }

    /// Puts the preset back as it ships, keeping custom rules. See
    /// `Configuration.restoreDefaults()`.
    func restoreDefaults() {
        guard !configuration.isDefault else { return }
        configuration.restoreDefaults()
        Logger.configuration.notice("Defaults restored")
        commit()
    }

    func isEnabled(group: String) -> Bool {
        guard let group = preset.groups.first(where: { $0.id == group }) else { return false }
        return configuration.isEnabled(group: group)
    }

    /// Switches a whole group on or off, saving and taking effect at once.
    func setGroup(_ id: String, enabled: Bool) {
        guard let group = preset.groups.first(where: { $0.id == id }),
              configuration.isEnabled(group: group) != enabled else { return }
        configuration.setGroup(group, enabled: enabled)
        Logger.configuration.notice(
            "Group \(id, privacy: .public) switched \(enabled ? "on" : "off", privacy: .public)"
        )
        commit()
    }

    var wheelDirection: WheelDirection {
        configuration.wheelDirection
    }

    func setWheelDirection(_ direction: WheelDirection) {
        guard configuration.wheelDirection != direction else { return }
        configuration.wheelDirection = direction
        Logger.configuration.notice("Wheel direction: \(direction.rawValue, privacy: .public)")
        commit()
    }

    var dockClickMinimizes: Bool {
        configuration.dockClickMinimizes
    }

    func setDockClickMinimizes(_ minimizes: Bool) {
        guard configuration.dockClickMinimizes != minimizes else { return }
        configuration.dockClickMinimizes = minimizes
        Logger.configuration.notice("Dock click minimizes: \(minimizes ? "on" : "off", privacy: .public)")
        commit()
    }

    var ctrlClickSelects: Bool {
        configuration.ctrlClickSelects
    }

    func setCtrlClickSelects(_ selects: Bool) {
        guard configuration.ctrlClickSelects != selects else { return }
        configuration.ctrlClickSelects = selects
        Logger.configuration.notice("Ctrl+click selects: \(selects ? "on" : "off", privacy: .public)")
        commit()
    }

    var controlKey: ControlKey {
        configuration.controlKey
    }

    /// Chooses the key the Ctrl shortcuts are pressed with, saving and taking
    /// effect at once.
    func setControlKey(_ key: ControlKey) {
        guard configuration.controlKey != key else { return }
        configuration.controlKey = key
        Logger.configuration.notice("Control key: \(key.rawValue, privacy: .public)")
        commit()
    }

    var modifierLayout: ModifierLayout {
        configuration.modifierLayout
    }

    /// Chooses which keys the Win and Alt shortcuts are pressed with, saving
    /// and taking effect at once.
    func setModifierLayout(_ layout: ModifierLayout) {
        guard configuration.modifierLayout != layout else { return }
        configuration.modifierLayout = layout
        Logger.configuration.notice("Modifier layout: \(layout.rawValue, privacy: .public)")
        commit()
    }

    /// Keyboards with settings of their own, as last saved (KB-243).
    var keyboardSettings: [KeyboardSettings] {
        configuration.keyboards
    }

    /// What a keyboard's row sets (KB-076): the keyboard then uses `key`.
    /// Matching the keyboard's default leaves it without a setting of its
    /// own, so it only keeps one while it differs.
    func chooseControlKey(_ key: ControlKey, for keyboard: Keyboard) {
        setControlKey(key == configuration.defaultControlKey(for: keyboard.id) ? nil : key, for: keyboard)
    }

    /// The same for the Win and Alt keys.
    func chooseModifierLayout(_ layout: ModifierLayout, for keyboard: Keyboard) {
        setModifierLayout(layout == configuration.defaultModifierLayout(for: keyboard.id) ? nil : layout, for: keyboard)
    }

    /// The keyboards connected now (`KeyboardList`). A PC keyboard among them
    /// gets rules of its own even with no setting of its own, since its
    /// defaults differ from the general choice.
    private(set) var connectedKeyboards: [Keyboard.ID] = []

    func setConnectedKeyboards(_ keyboards: [Keyboard]) {
        let ids = keyboards.map(\.id)
        guard ids != connectedKeyboards else { return }
        connectedKeyboards = ids
        applyKeyboards(configuration.keyboardProfiles(of: preset, connected: ids))
    }

    /// Every keyboard known now: connected, or with settings of its own.
    private var knownKeyboards: [Keyboard.ID] {
        connectedKeyboards + keyboardSettings.map(\.id).filter { !connectedKeyboards.contains($0) }
    }

    /// Every control key in effect somewhere: the general one, which a key
    /// from no known keyboard gets, and each known keyboard's. What the
    /// Overview says covers them all.
    var controlKeysInUse: Set<ControlKey> {
        Set([controlKey] + knownKeyboards.map { configuration.controlKey(for: $0) })
    }

    /// The same for the Win and Alt keys.
    var modifierLayoutsInUse: Set<ModifierLayout> {
        Set([modifierLayout] + knownKeyboards.map { configuration.modifierLayout(for: $0) })
    }

    /// Gives a keyboard its own control key, or nil to follow the general
    /// one, saving and taking effect at once.
    func setControlKey(_ key: ControlKey?, for keyboard: Keyboard) {
        let before = configuration
        configuration.setControlKey(key, for: keyboard)
        guard configuration != before else { return }
        Logger.configuration.notice("Control key for \(keyboard.description, privacy: .public): \(key?.rawValue ?? "general", privacy: .public)")
        commit()
    }

    /// Gives a keyboard its own Win and Alt keys, or nil to follow the
    /// general ones.
    func setModifierLayout(_ layout: ModifierLayout?, for keyboard: Keyboard) {
        let before = configuration
        configuration.setModifierLayout(layout, for: keyboard)
        guard configuration != before else { return }
        Logger.configuration.notice("Modifier layout for \(keyboard.description, privacy: .public): \(layout?.rawValue ?? "general", privacy: .public)")
        commit()
    }

    /// The modifiers held while scrolling to zoom, as the zoom rules have
    /// them.
    var zoomModifiers: Modifiers {
        for rule in rules(inGroup: "scroll") {
            if case .scroll(_, let modifiers) = rule.trigger { return modifiers }
        }
        return []
    }

    /// Changes the zoom modifier on both zoom rules. Choosing the preset's
    /// Ctrl, which follows each keyboard's control key, drops the
    /// customization.
    func setZoomModifiers(_ modifiers: Modifiers) {
        for var rule in rules(inGroup: "scroll") {
            guard case .scroll(let direction, _) = rule.trigger else { continue }
            rule.trigger = .scroll(direction: direction, modifiers: modifiers)
            update(rule)
        }
    }

    /// How many rules are in effect and switched on.
    var activeRuleCount: Int {
        effectiveRules.filter(\.isEnabled).count
    }

    /// How many preset entries the user has changed.
    var customizedCount: Int {
        configuration.overrides.filter { if case .modified = $0 { true } else { false } }.count
    }

    /// Apps that rules in effect leave alone, such as terminals for Ctrl+C.
    var exceptionApps: Set<String> {
        var apps: Set<String> = []
        for rule in effectiveRules where rule.isEnabled {
            if case .except(let bundleIDs) = rule.scope.applications { apps.formUnion(bundleIDs) }
        }
        return apps
    }

    /// The rules of one group, as shown under its card, whether or not the
    /// group is switched on: with the chosen Win and Alt keys, and before fn
    /// stands in for Ctrl.
    func rules(inGroup group: String) -> [Rule] {
        guard let group = preset.groups.first(where: { $0.id == group }) else { return [] }
        return configuration.rules(of: group)
    }

    /// The group a preset entry belongs to.
    private func group(of id: String) -> Preset.Group? {
        preset.groups.first { $0.rules.contains { $0.id == id } }
    }

    /// The user's own rules, in the order made.
    var customRules: [Rule] {
        configuration.customRules
    }

    /// Adds a custom rule or saves changes to one, taking effect at once.
    func saveCustomRule(_ rule: Rule) {
        let before = configuration
        configuration.setCustomRule(rule)
        guard configuration != before else { return }
        Logger.configuration.notice("Custom rule \(rule.id, privacy: .public) saved")
        commit()
    }

    func deleteCustomRule(_ id: String) {
        let before = configuration
        configuration.removeCustomRule(id)
        guard configuration != before else { return }
        Logger.configuration.notice("Custom rule \(id, privacy: .public) deleted")
        commit()
    }

    /// The preset's version of an entry, before any change by the user, with
    /// the chosen Win and Alt keys.
    func original(of id: String) -> Rule? {
        guard let group = group(of: id), let rule = group.rules.first(where: { $0.id == id }) else { return nil }
        return modifierLayout.apply(to: rule, inGroup: group.id)
    }

    func isCustomized(_ id: String) -> Bool {
        configuration.isCustomized(id)
    }

    /// Saves the user's version of a preset entry, as shown with the chosen
    /// Win and Alt keys, and puts it into effect.
    func update(_ rule: Rule) {
        guard let group = group(of: rule.id), let original = group.rules.first(where: { $0.id == rule.id }) else { return }
        let before = configuration
        // Kept in the preset's terms; trading ⌘ and ⌥ again undoes the layout.
        configuration.setRule(modifierLayout.apply(to: rule, inGroup: group.id), original: original)
        guard configuration != before else { return }
        Logger.configuration.notice(
            "Rule \(rule.id, privacy: .public) \(self.isCustomized(rule.id) ? "customized" : "back to default", privacy: .public)"
        )
        commit()
    }

    /// Brings back the preset's version of an entry.
    func reset(_ id: String) {
        guard isCustomized(id) else { return }
        configuration.resetRule(id)
        Logger.configuration.notice("Rule \(id, privacy: .public) reset")
        commit()
    }

    /// Other entries that react to the same trigger in the same apps, whether
    /// or not they are on: only one of them can win. A narrower app scope is
    /// no conflict — Ctrl+V moving files in Finder and pasting elsewhere is
    /// the point.
    func conflicts(with rule: Rule) -> [Rule] {
        (configuration.customRules + preset.groups.flatMap(configuration.rules(of:))).filter {
            $0.id != rule.id && $0.trigger == rule.trigger
                && $0.scope.applications == rule.scope.applications
        }
    }

    /// Whether the rule editor is recording a shortcut.
    private(set) var isRecording = false

    /// Hands every key combination and extra mouse button pressed to
    /// `onTrigger`, read by the event tap before the system or any window
    /// sees it, until `stopRecording`. Recording Ctrl+C gets Ctrl+C rather
    /// than ⌘C, and fn+C gets fn+C rather than Control Center.
    func startRecording(_ onTrigger: @escaping @MainActor (Trigger) -> Void) {
        isRecording = true
        capture(onTrigger)
        Logger.configuration.notice("Recording started")
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        capture(nil)
        Logger.configuration.notice("Recording ended")
    }

    private func commit() {
        effectiveRules = configuration.effectiveRules(of: preset)
        do {
            try store.save(configuration)
        } catch {
            // The engine still follows the change; only the file is behind.
            Logger.configuration.error(
                "Could not save the configuration: \(String(describing: error), privacy: .public)"
            )
        }
        apply(effectiveRules)
        applyWheelDirection(configuration.wheelDirection)
        applyDockClick(configuration.dockClickMinimizes)
        applyCtrlClick(configuration.ctrlClick)
        applyKeyboards(configuration.keyboardProfiles(of: preset, connected: connectedKeyboards))
    }
}

private extension Configuration {
    /// What the engine needs: the key follows the Ctrl / fn choice.
    var ctrlClick: CtrlClick? {
        ctrlClickSelects ? CtrlClick(controlKey: controlKey) : nil
    }

    /// The same for each keyboard that presses differently from the general
    /// choice: one with settings of its own, or a connected PC keyboard on
    /// its defaults. Every other keyboard is served by the general rules.
    func keyboardProfiles(of preset: Preset, connected: [Keyboard.ID]) -> [Keyboard.ID: Dispatcher.KeyboardProfile] {
        var profiles: [Keyboard.ID: Dispatcher.KeyboardProfile] = [:]
        for id in keyboards.map(\.id) + connected where profiles[id] == nil {
            guard controlKey(for: id) != controlKey || modifierLayout(for: id) != modifierLayout else { continue }
            profiles[id] = Dispatcher.KeyboardProfile(
                rules: effectiveRules(of: preset, for: id),
                ctrlClick: ctrlClickSelects ? CtrlClick(controlKey: controlKey(for: id)) : nil
            )
        }
        return profiles
    }
}
