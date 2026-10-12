/// What the user has changed on top of the built-in rules: the contents of the
/// configuration file.
///
/// Only the user's layer is stored. The preset layer ships with the app, so a
/// new release can improve it without touching anyone's file.
struct Configuration: Hashable, Sendable {
    /// The version of the file format this build writes. Raise it, and add a
    /// step to `ConfigurationStore.migrations`, whenever the encoded form
    /// changes; `RuleModelTests.ruleEncodingIsStable` catches such changes.
    static let currentVersion = 1

    var overrides: [Override] = []

    /// Preset groups the user has switched off. Absent from an older file
    /// means every group is on, so this needs no migration.
    var disabledGroups: Set<String> = []

    /// Preset groups that start off and the user has switched on. Absent
    /// from an older file means none, so this needs no migration either.
    var enabledGroups: Set<String> = []

    /// Which key the Windows Ctrl shortcuts are pressed with. Absent from an
    /// older file means Ctrl, so this needs no migration.
    var controlKey: ControlKey = .control

    /// Which way mouse wheels scroll. Absent from an older file means the
    /// system's way, so this needs no migration.
    var wheelDirection: WheelDirection = .system

    /// Whether clicking the Dock icon of the app in front minimizes its
    /// window, as a taskbar button does on Windows. Absent from an older file
    /// means on, the default, so this needs no migration.
    var dockClickMinimizes = true

    /// Whether a left click with the Windows Ctrl key goes out as ⌘+click
    /// (KB-222). Off until switched on: with Ctrl it replaces macOS's
    /// Ctrl+click for the shortcut menu. Absent from an older file means off.
    var ctrlClickSelects = false

    /// Which Mac keys play Win and Alt (KB-226). Absent from an older file
    /// means a PC keyboard's, as the preset is written.
    var modifierLayout: ModifierLayout = .pcKeyboard

    /// Keyboards with a control key or Win and Alt keys of their own
    /// (KB-243); every other keyboard follows the two settings above. Absent
    /// from an older file means none, so this needs no migration.
    var keyboards: [KeyboardSettings] = []

    /// The control key a keyboard's Ctrl shortcuts are pressed with: its own,
    /// or else its default.
    func controlKey(for keyboard: Keyboard.ID?) -> ControlKey {
        settings(for: keyboard)?.controlKey ?? defaultControlKey(for: keyboard)
    }

    /// The keys a keyboard's Win and Alt shortcuts are pressed with: its own,
    /// or else its default.
    func modifierLayout(for keyboard: Keyboard.ID?) -> ModifierLayout {
        settings(for: keyboard)?.modifierLayout ?? defaultModifierLayout(for: keyboard)
    }

    /// What a keyboard with no control key of its own uses. A PC keyboard
    /// has no fn key that reaches the Mac, so Ctrl, whatever the general
    /// choice, which is for the Mac's own keys (user's call, 2026-10-02): a
    /// PC keyboard plugged in next to a MacBook set to fn works at once.
    func defaultControlKey(for keyboard: Keyboard.ID?) -> ControlKey {
        if let keyboard, !keyboard.hasMacKeys { return .control }
        return controlKey
    }

    /// Likewise, a PC keyboard's Win and Alt keys work as printed: its Win
    /// key sends ⌘.
    func defaultModifierLayout(for keyboard: Keyboard.ID?) -> ModifierLayout {
        if let keyboard, !keyboard.hasMacKeys { return .pcKeyboard }
        return modifierLayout
    }

    func settings(for keyboard: Keyboard.ID?) -> KeyboardSettings? {
        guard let keyboard else { return nil }
        return keyboards.first { $0.id == keyboard }
    }

    /// Gives a keyboard its own control key, or nil to have it follow the
    /// general one. A keyboard left with nothing of its own is forgotten.
    mutating func setControlKey(_ key: ControlKey?, for keyboard: Keyboard) {
        changeSettings(for: keyboard) { $0.controlKey = key }
    }

    /// Gives a keyboard its own Win and Alt keys, or nil to have it follow
    /// the general ones.
    mutating func setModifierLayout(_ layout: ModifierLayout?, for keyboard: Keyboard) {
        changeSettings(for: keyboard) { $0.modifierLayout = layout }
    }

    private mutating func changeSettings(for keyboard: Keyboard, _ change: (inout KeyboardSettings) -> Void) {
        var settings = self.settings(for: keyboard.id) ?? KeyboardSettings(keyboard: keyboard)
        // The name as the keyboard last gave it, for showing it unplugged.
        settings.name = keyboard.name
        change(&settings)
        keyboards.removeAll { $0.id == keyboard.id }
        if !settings.isEmpty { keyboards.append(settings) }
    }

    /// The rules in effect: the user's custom rules, then the preset's groups
    /// that are on with the user's changes, pressed with the chosen Win/Alt
    /// keys and control key. A switched-off group contributes nothing, even
    /// where the user has customised one of its entries — the group switch is
    /// the broader, later decision. Custom rules are taken as recorded: the
    /// keys are a setting for the preset.
    ///
    /// For a given keyboard (KB-243), that keyboard's keys instead.
    func effectiveRules(of preset: Preset, for keyboard: Keyboard.ID? = nil) -> [Rule] {
        let layout = modifierLayout(for: keyboard)
        let enabled = preset.groups
            .filter(isEnabled(group:))
            .flatMap { rules(of: $0, layout: layout) }
        return customRules + controlKey(for: keyboard).apply(to: enabled)
    }

    /// A group's rules with the user's changes, pressed with the chosen Win
    /// and Alt keys. Changes are kept in the preset's terms, Win as ⌘, so a
    /// re-recorded Win+K stays Win+K when the choice changes.
    func rules(of group: Preset.Group) -> [Rule] {
        rules(of: group, layout: modifierLayout)
    }

    private func rules(of group: Preset.Group, layout: ModifierLayout) -> [Rule] {
        layout.apply(to: presetRules(base: group.rules), inGroup: group.id)
    }

    /// Whether a group is switched on: the user's choice, or else the
    /// group's default.
    func isEnabled(group: Preset.Group) -> Bool {
        if enabledGroups.contains(group.id) { return true }
        if disabledGroups.contains(group.id) { return false }
        return group.isEnabledByDefault
    }

    /// Records the user's choice. Choosing a group's default forgets the
    /// choice, so a later release can change what the default is.
    mutating func setGroup(_ group: Preset.Group, enabled: Bool) {
        enabledGroups.remove(group.id)
        disabledGroups.remove(group.id)
        guard enabled != group.isEnabledByDefault else { return }
        if enabled {
            enabledGroups.insert(group.id)
        } else {
            disabledGroups.insert(group.id)
        }
    }

    /// Puts the preset back as it ships: every group at its default — the
    /// Windows key group off, the rest on — and every changed entry back to
    /// the preset's version. The user's own rules stay, and so do the
    /// settings that are not part of the preset: the control key, the Win
    /// and Alt keys and the wheel direction.
    mutating func restoreDefaults() {
        disabledGroups = []
        enabledGroups = []
        overrides.removeAll { if case .modified = $0 { true } else { false } }
    }

    /// Whether `restoreDefaults()` would change nothing.
    var isDefault: Bool {
        disabledGroups.isEmpty && enabledGroups.isEmpty
            && !overrides.contains { if case .modified = $0 { true } else { false } }
    }

    /// Whether the user has changed the preset rule with this ID.
    func isCustomized(_ id: String) -> Bool {
        overrides.contains { if case .modified(let rule) = $0 { rule.id == id } else { false } }
    }

    /// Makes `rule` the user's version of the preset's `original`. Saving
    /// the preset's own version drops the override instead, so an entry
    /// edited back to what it was no longer counts as customized.
    mutating func setRule(_ rule: Rule, original: Rule) {
        precondition(rule.id == original.id, "An edit keeps the entry's ID")
        resetRule(rule.id)
        if rule != original {
            overrides.append(.modified(rule: rule))
        }
    }

    /// Drops the user's version of a preset rule, bringing the preset's back.
    mutating func resetRule(_ id: String) {
        overrides.removeAll { if case .modified(let rule) = $0 { rule.id == id } else { false } }
    }

    /// The rules in effect: the custom rules, then `base` with the user's
    /// changes.
    ///
    /// Custom rules come first so that, where one shares a trigger with a
    /// preset rule in the same scope, the user's own rule wins: the matcher
    /// keeps the given order between equally narrow scopes.
    func effectiveRules(base: [Rule]) -> [Rule] {
        customRules + presetRules(base: base)
    }

    /// `base` with the user's changes. A modified rule takes the place of the
    /// base rule with the same ID, so order and matching priority are kept;
    /// one whose ID the base no longer has is ignored. Re-applying presets
    /// while keeping customizations is KB-031.
    func presetRules(base: [Rule]) -> [Rule] {
        var modified: [String: Rule] = [:]
        for case .modified(let rule) in overrides {
            modified[rule.id] = rule
        }
        return base.map { modified[$0.id] ?? $0 }
    }

    /// Rules the user made that no preset provides, in the order made.
    var customRules: [Rule] {
        overrides.compactMap { if case .custom(let rule) = $0 { rule } else { nil } }
    }

    /// Adds a custom rule, or replaces the one with the same ID in place.
    mutating func setCustomRule(_ rule: Rule) {
        let custom = Override.custom(rule: rule)
        if let index = overrides.firstIndex(where: { if case .custom(let old) = $0 { old.id == rule.id } else { false } }) {
            overrides[index] = custom
        } else {
            overrides.append(custom)
        }
    }

    mutating func removeCustomRule(_ id: String) {
        overrides.removeAll { if case .custom(let rule) = $0 { rule.id == id } else { false } }
    }
}

// The version is written into the file but not kept in memory: by the time a
// `Configuration` exists, `ConfigurationStore` has already migrated it.
extension Configuration: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, overrides, disabledGroups, enabledGroups, controlKey, wheelDirection, dockClickMinimizes
        case ctrlClickSelects, modifierLayout, keyboards
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        overrides = try container.decodeIfPresent([Override].self, forKey: .overrides) ?? []
        disabledGroups = try container.decodeIfPresent(Set<String>.self, forKey: .disabledGroups) ?? []
        enabledGroups = try container.decodeIfPresent(Set<String>.self, forKey: .enabledGroups) ?? []
        controlKey = try container.decodeIfPresent(ControlKey.self, forKey: .controlKey) ?? .control
        wheelDirection = try container.decodeIfPresent(WheelDirection.self, forKey: .wheelDirection) ?? .system
        dockClickMinimizes = try container.decodeIfPresent(Bool.self, forKey: .dockClickMinimizes) ?? true
        ctrlClickSelects = try container.decodeIfPresent(Bool.self, forKey: .ctrlClickSelects) ?? false
        modifierLayout = try container.decodeIfPresent(ModifierLayout.self, forKey: .modifierLayout) ?? .pcKeyboard
        keyboards = try container.decodeIfPresent([KeyboardSettings].self, forKey: .keyboards) ?? []
        foldSystemGroup()
        dropZoomOverridesMatchingPreset()
    }

    /// The zoom rules moved from fn to Ctrl, the Windows Ctrl that follows
    /// each keyboard's control key (SK-297). A file that chose Ctrl kept it as
    /// a change, which is now the preset itself, so the entries would show
    /// as customized for nothing. Done on reading, like `foldSystemGroup`.
    private mutating func dropZoomOverridesMatchingPreset() {
        let zoom = BuiltInRules.all.filter { $0.id.hasPrefix("scroll.") }
        overrides.removeAll { override in
            guard case .modified(let rule) = override else { return false }
            return zoom.contains(rule)
        }
    }

    /// The System group, Force Quit alone, went into Apps & System (SK-285).
    /// A file that switched it off keeps Force Quit off, as that entry's own
    /// switch; the group's ID is dropped. Done on reading rather than as a
    /// migration, since the file's layout is unchanged.
    private mutating func foldSystemGroup() {
        guard disabledGroups.remove("system") != nil else { return }
        if let index = overrides.firstIndex(where: { if case .modified(let rule) = $0 { rule.id == "sys.forceQuit" } else { false } }),
           case .modified(var rule) = overrides[index] {
            rule.isEnabled = false
            overrides[index] = .modified(rule: rule)
        } else if var forceQuit = BuiltInRules.all.first(where: { $0.id == "sys.forceQuit" }) {
            forceQuit.isEnabled = false
            overrides.append(.modified(rule: forceQuit))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .schemaVersion)
        try container.encode(overrides, forKey: .overrides)
        // Written in a stable order, so the file does not churn between saves.
        try container.encode(disabledGroups.sorted(), forKey: .disabledGroups)
        try container.encode(enabledGroups.sorted(), forKey: .enabledGroups)
        try container.encode(controlKey, forKey: .controlKey)
        try container.encode(wheelDirection, forKey: .wheelDirection)
        try container.encode(dockClickMinimizes, forKey: .dockClickMinimizes)
        // Left out while off, so the file only changes for those who use it.
        if ctrlClickSelects { try container.encode(true, forKey: .ctrlClickSelects) }
        if modifierLayout != .pcKeyboard { try container.encode(modifierLayout, forKey: .modifierLayout) }
        if !keyboards.isEmpty { try container.encode(keyboards, forKey: .keyboards) }
    }
}

/// What one keyboard has of its own (KB-243). Kept by model, as `Keyboard.ID`
/// tells keyboards apart, so it outlasts unplugging; nil follows the general
/// setting. Written flat, so the file reads as it would be typed:
///
///     {"vendorID": 14, "productID": 13330, "name": "RK-KB5.0", "controlKey": "control"}
struct KeyboardSettings: Hashable, Codable, Sendable {
    var vendorID: Int
    var productID: Int
    /// Written only for the built-in keyboard.
    var isBuiltIn: Bool
    /// As the keyboard last gave it; only for showing.
    var name: String
    var controlKey: ControlKey?
    var modifierLayout: ModifierLayout?

    init(keyboard: Keyboard, controlKey: ControlKey? = nil, modifierLayout: ModifierLayout? = nil) {
        vendorID = keyboard.vendorID
        productID = keyboard.productID
        isBuiltIn = keyboard.isBuiltIn
        name = keyboard.name
        self.controlKey = controlKey
        self.modifierLayout = modifierLayout
    }

    var id: Keyboard.ID { Keyboard.ID(vendorID: vendorID, productID: productID, isBuiltIn: isBuiltIn) }

    var keyboard: Keyboard { Keyboard(vendorID: vendorID, productID: productID, name: name, isBuiltIn: isBuiltIn) }

    /// Nothing of its own: the keyboard follows the general settings.
    var isEmpty: Bool { controlKey == nil && modifierLayout == nil }

    private enum CodingKeys: String, CodingKey {
        case vendorID, productID, isBuiltIn, name, controlKey, modifierLayout
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vendorID = try container.decodeIfPresent(Int.self, forKey: .vendorID) ?? 0
        productID = try container.decodeIfPresent(Int.self, forKey: .productID) ?? 0
        isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        controlKey = try container.decodeIfPresent(ControlKey.self, forKey: .controlKey)
        modifierLayout = try container.decodeIfPresent(ModifierLayout.self, forKey: .modifierLayout)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(vendorID, forKey: .vendorID)
        try container.encode(productID, forKey: .productID)
        if isBuiltIn { try container.encode(true, forKey: .isBuiltIn) }
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(controlKey, forKey: .controlKey)
        try container.encodeIfPresent(modifierLayout, forKey: .modifierLayout)
    }
}
