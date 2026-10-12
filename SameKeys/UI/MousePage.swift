import SwiftUI

/// Everything the mouse does, in the order people reach for it (KB-237):
/// its wheel, its buttons, and clicking the Dock. The wheel settings used to
/// be a Scroll page of their own.
struct MousePage: View {
    let rules: RulesController
    @State private var editing: Rule?
    /// A button the user added, open in the custom rule editor (KB-055).
    @State private var editingAdded: CustomRulesPage.EditedRule?
    @State private var isAdding = false
    @State private var recorder = KeyRecorder()

    /// Buttons the user added: custom rules pressed with a mouse button.
    private var addedButtons: [Rule] {
        rules.customRules.filter { if case .mouseButton = $0.trigger { true } else { false } }
    }

    var body: some View {
        // The wheel first: every mouse has one, while side buttons and
        // Ctrl-click are for some (user's call).
        PageSection("Wheel")
        WheelSettings(rules: rules)

        PageSection("Buttons")
        sideButtons
        ctrlClick

        PageSection("Dock")
        dockClick
    }

    @ViewBuilder private var sideButtons: some View {
        Card {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    IconTile(symbol: RuleNames.symbol(ofGroup: "mouse"), tint: RuleNames.tint(ofGroup: "mouse"), size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Side buttons")
                            .font(.headline)
                        Text("Back and forward in browsers and Finder, like on Windows.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    GroupSwitch(rules: rules, group: "mouse", label: "Side buttons")
                }
                Divider().padding(.top, 12)
                EntryList(rules: rules, group: "mouse", edit: { editing = $0 })
                ForEach(addedButtons, id: \.id) { rule in
                    Divider()
                    CustomRuleRow(rules: rules, rule: rule) { editingAdded = .init(rule: rule) }
                }
                Divider()
                HStack(spacing: 10) {
                    Button(isAdding ? "Press a mouse button…" : "Add Button…") { toggleAdding() }
                    if isAdding {
                        Text("Esc to cancel")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.top, 10)
            }
        }

        Text("Click an entry, then press the mouse button it should use; its number is shown. To use another button, choose Add Button… and press it; buttons you add are custom rules, also listed on the Custom Rules page. The left and right buttons cannot be remapped. A mouse's own software, or tools such as Karabiner-Elements, may remap buttons before SameKeys sees them.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .sheet(item: $editing) { RuleEditor(rules: rules, rule: $0) }
            #if DEBUG
            .onAppear { if LayoutCheck.opensRuleEditor { editing = rules.rules(inGroup: "mouse").first } }
            #endif
            .sheet(item: $editingAdded) { CustomRuleEditor(rules: rules, existing: $0.rule, trigger: $0.trigger) }
            .onDisappear { stopAdding() }
    }

    private var dockClick: some View {
        Card {
            HStack(spacing: 12) {
                IconTile(symbol: "dock.rectangle", tint: .indigo, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Click a Dock icon to minimize")
                        .font(.headline)
                    Text("Clicking the Dock icon of the app in front minimizes its window, like a taskbar button on Windows. Click it again to bring the window back.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("Click a Dock icon to minimize", isOn: Binding(
                    get: { rules.dockClickMinimizes },
                    set: { rules.setDockClickMinimizes($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
    }

    private var ctrlClick: some View {
        Card {
            HStack(spacing: 12) {
                IconTile(symbol: "cursorarrow.click.2", tint: .blue, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ctrl-click like on Windows")
                        .font(.headline)
                    Text(ctrlClickNote)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("Ctrl-click like on Windows", isOn: Binding(
                    get: { rules.ctrlClickSelects },
                    set: { rules.setCtrlClickSelects($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
    }
}

extension MousePage {
    /// What the Ctrl-click switch does with the key the Shortcuts page's
    /// Ctrl / fn choice names, and what it costs with Ctrl (KB-222).
    private var ctrlClickNote: String {
        switch rules.controlKey {
        case .function:
            String(localized: "fn+click adds to a selection and opens a link in a new tab, as ⌘+click does on a Mac. fn stands in for Ctrl, as on the Shortcuts page.")
        case .control:
            String(localized: "Ctrl+click adds to a selection and opens a link in a new tab, as ⌘+click does on a Mac. Ctrl+click then no longer opens the shortcut menu; the right button and a two-finger click still do.")
        case .both:
            String(localized: "fn+click and Ctrl+click add to a selection and open a link in a new tab, as ⌘+click does on a Mac. Ctrl+click then no longer opens the shortcut menu; the right button and a two-finger click still do.")
        }
    }

    /// Waits for a mouse button, then opens what it should do: the entry
    /// already using it, or a new custom rule pressed with it. Only buttons
    /// 3 and up reach the recorder; the left and right buttons never do.
    private func toggleAdding() {
        guard !isAdding else { return stopAdding() }
        isAdding = true
        recorder.start(rules: rules, accepting: { trigger in
            if case .mouseButton = trigger { true } else { false }
        }) { trigger in
            stopAdding()
            guard let trigger else { return }
            if let entry = rules.rules(inGroup: "mouse").first(where: { $0.trigger == trigger }) {
                editing = entry
            } else if let added = addedButtons.first(where: { $0.trigger == trigger }) {
                editingAdded = .init(rule: added)
            } else {
                editingAdded = .init(rule: nil, trigger: trigger)
            }
        }
    }

    private func stopAdding() {
        recorder.stop()
        isAdding = false
    }
}

/// The wheel's direction, and page zoom with modifier + wheel and which
/// modifier that is. Mouse only: the trackpad is left alone.
struct WheelSettings: View {
    let rules: RulesController
    @State private var editing: Rule?
    /// Shows the modifier checkboxes even when the choice is a single key.
    @State private var showsCustom = false

    var body: some View {
        // The direction first: every wheel user meets it, while zooming is
        // something to reach for (KB-223).
        Card {
            HStack(spacing: 12) {
                IconTile(symbol: "arrow.up.arrow.down", tint: .teal, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Windows scroll direction")
                        .font(.headline)
                    Text(directionNote)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("Windows scroll direction", isOn: Binding(
                    get: { rules.wheelDirection == .windows },
                    set: { rules.setWheelDirection($0 ? .windows : .system) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }

        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    IconTile(symbol: "plus.magnifyingglass", tint: RuleNames.tint(ofGroup: "scroll"), size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Zoom with modifier + scroll")
                            .font(.headline)
                        Text("Zooms pages and documents, like Ctrl+wheel on Windows.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    GroupSwitch(rules: rules, group: "scroll", label: "Zoom with modifier + scroll")
                }
                Divider().padding(.vertical, 12)
                modifierPicker
                if zoomsWithCtrlSomewhere {
                    Label {
                        Text("macOS can zoom the whole screen with Ctrl+scroll (Accessibility › Zoom › “Use scroll gesture with modifier keys”). If that is on, it wins and pages do not zoom: choose fn, or turn it off.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    }
                    .font(.callout)
                    .padding(.top, 10)
                }
                Divider().padding(.top, 12)
                EntryList(rules: rules, group: "scroll", edit: { editing = $0 })
            }
        }
        .sheet(item: $editing) { RuleEditor(rules: rules, rule: $0) }
    }

    /// macOS applies natural scrolling to the trackpad and every mouse at
    /// once. With it off, wheels already scroll the Windows way.
    private var directionNote: LocalizedStringKey {
        let natural = UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
        return natural
            ? "Rolling the wheel towards you moves down the page. The trackpad and a Magic Mouse keep natural scrolling."
            : "Natural scrolling is off in System Settings, so wheels already scroll this way."
    }

    /// Ctrl first: it is the Windows Ctrl, pressed as each keyboard presses
    /// its Ctrl shortcuts (SK-297), and the default.
    private static let singles: [(Modifiers, LocalizedStringKey)] = [
        ([.control], "Same key as Ctrl+C"), ([.function], "fn"), ([.option], "⌥ Option"), ([.command], "⌘ Command"),
    ]

    /// Whether Ctrl+scroll zooms pages on some keyboard, where the system's
    /// screen zoom may take it first.
    private var zoomsWithCtrlSomewhere: Bool {
        rules.zoomModifiers.contains(.control) && !rules.controlKeysInUse.isSubset(of: [.function])
    }

    private var choice: Binding<Modifiers?> {
        Binding(
            get: {
                let current = rules.zoomModifiers
                return !showsCustom && Self.singles.contains { $0.0 == current } ? current : nil
            },
            set: { modifiers in
                if let modifiers {
                    showsCustom = false
                    rules.setZoomModifiers(modifiers)
                } else {
                    showsCustom = true
                }
            }
        )
    }

    private var modifierPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The label apart from the menu, so a long translation wraps
            // instead of making the page wider than the window.
            AdaptiveRow(minFlexibleWidth: 140) {
                Text("Hold while scrolling")
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Hold while scrolling", selection: choice) {
                    ForEach(Self.singles, id: \.0.rawValue) { modifiers, name in
                        Text(name).tag(Optional(modifiers))
                    }
                    Divider()
                    Text("Custom…").tag(Modifiers?.none)
                }
                .labelsHidden()
                .fixedSize()
            }

            if choice.wrappedValue == [.control], rules.controlKeysInUse != [.control] {
                Text("Ctrl on keyboards that copy with Ctrl+C, fn on those that copy with fn+C.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if choice.wrappedValue == nil {
                HStack(spacing: 14) {
                    ForEach(Self.customizable, id: \.0.rawValue) { modifier, name in
                        Toggle(name, isOn: Binding(
                            get: { rules.zoomModifiers.contains(modifier) },
                            set: { isOn in
                                var modifiers = rules.zoomModifiers
                                if isOn { modifiers.insert(modifier) } else { modifiers.remove(modifier) }
                                // Plain scrolling must never zoom.
                                if !modifiers.isEmpty { rules.setZoomModifiers(modifiers) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
                if rules.zoomModifiers.contains(.shift) {
                    Text("Shift+scroll scrolls sideways in most apps; with Shift it no longer does.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private static let customizable: [(Modifiers, LocalizedStringKey)] = [
        ([.control], "Ctrl"), ([.option], "⌥"), ([.shift], "⇧"), ([.command], "⌘"), ([.function], "fn"),
    ]
}

/// A heading over a few cards on a page, like the group titles in System
/// Settings.
struct PageSection: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A group's on/off switch, saving at once.
struct GroupSwitch: View {
    let rules: RulesController
    let group: String
    let label: LocalizedStringKey

    var body: some View {
        Toggle(label, isOn: Binding(get: { rules.isEnabled(group: group) },
                                    set: { rules.setGroup(group, enabled: $0) }))
            .toggleStyle(.switch)
            .labelsHidden()
    }
}

/// A group's entries, each opening the editor, greyed out while the group is
/// off. A Ctrl trigger shows as the Ctrl / fn choice has it, as on the
/// Shortcuts page.
struct EntryList: View {
    let rules: RulesController
    let group: String
    let edit: (Rule) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rules.rules(inGroup: group).enumerated()), id: \.element.id) { index, rule in
                if index > 0 { Divider() }
                EntryRow(rule: rule, trigger: rules.controlKey.trigger(of: rule),
                         isCustomized: rules.isCustomized(rule.id)) { edit(rule) }
            }
        }
        .opacity(rules.isEnabled(group: group) ? 1 : 0.45)
    }
}
