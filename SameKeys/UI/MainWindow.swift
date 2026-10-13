import AppKit
import SwiftUI

/// The settings window: a sidebar of pages and the selected page beside it.
struct MainWindow: View {
    let engine: EngineController
    let onboarding: OnboardingController
    /// The preset and the user's changes to it, shown on the Shortcuts page.
    let rules: RulesController
    let secureInput: SecureInputMonitor
    let otherRemappers: OtherRemapperMonitor
    let clipboard: ClipboardController
    let quickSwitch: QuickSwitch
    let updates: UpdateController
    let loginItem: LoginItem
    let keyboards: KeyboardList
    let recorder: DiagnosticRecorder
    let logArchive: LogArchive
    /// Remembered across launches, so the window reopens where it was left.
    @SceneStorage("mainWindow.page") private var page: Page = .overview

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $page)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            PageContent(page: page) {
                switch page {
                case .overview:
                    OverviewPage(engine: engine, onboarding: onboarding, rules: rules, secureInput: secureInput,
                                 otherRemappers: otherRemappers, loginItem: loginItem) { page = $0 }
                case .shortcuts:
                    ShortcutsPage(rules: rules, keyboards: keyboards)
                case .mouse:
                    MousePage(rules: rules)
                case .clipboard:
                    ClipboardPage(clipboard: clipboard, rules: rules)
                case .finder:
                    FinderPage(rules: rules, locations: quickSwitch.locations,
                               clearHistory: quickSwitch.clearHistory)
                case .customRules:
                    CustomRulesPage(rules: rules)
                case .about:
                    AboutCard()
                    SupportCard()
                    UpdatesCard(updates: updates)
                    LegalCard()
                    SettingsBackupCard()
                    FeedbackCard()
                    DiagnosticsCard(recorder: recorder) {
                        await DiagnosticReport.collect(engine: engine, rules: rules, secureInput: secureInput,
                                                 otherRemappers: otherRemappers, clipboard: clipboard,
                                                 loginItem: loginItem, keyboards: keyboards,
                                                 locations: quickSwitch.locations,
                                                 updates: updates, recorder: recorder, logArchive: logArchive)
                    }
                default:
                    ComingSoon(page: page)
                }
            }
            .id(page)
        }
        .frame(minWidth: 780, minHeight: 520)
        // Which of ⌘ and ⌥ is called Win, on every page and in every sheet.
        .environment(\.triggerStyle, rules.modifierLayout.triggerStyle)
        .showsInDock()
        // A page asked for from outside, such as About from the menu bar
        // (KB-240): at once when the window is open, or as it opens.
        .onAppear { page = PageRequest.take() ?? page }
        .onReceive(NotificationCenter.default.publisher(for: .showPage)) { _ in
            if let requested = PageRequest.take() { page = requested }
        }
        #if DEBUG
        .onAppear { if let requested = LayoutCheck.page { page = requested } }
        #endif
    }
}

/// A page the main window should show next (KB-240). Set before the window
/// is opened, then either the open window hears `.showPage` or a newly
/// created one finds the request as it appears.
@MainActor
enum PageRequest {
    private static var pending: Page?

    static func show(_ page: Page) {
        pending = page
        NotificationCenter.default.post(name: .showPage, object: nil)
    }

    static func take() -> Page? {
        defer { pending = nil }
        return pending
    }
}

extension Notification.Name {
    static let showPage = Notification.Name("SameKeysShowPage")
}

/// A page's title and subtitle above its content, scrolling as one.
private struct PageContent<Content: View>: View {
    let page: Page
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(page.title)
                        .font(.largeTitle.bold())
                    Text(page.subtitle)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 6)
                content
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(page.title)
    }
}

/// The preset, group by group: a switch and an expander per group, each
/// entry as "what you press → what the Mac gets", and a search field.
private struct ShortcutsPage: View {
    let rules: RulesController
    let keyboards: KeyboardList
    @State private var search = ""
    @State private var expanded: Set<String> = Self.initiallyExpanded
    /// The entry open in the editor sheet.
    @State private var editing: Rule?
    @State private var confirmingWinKey = false

    private var connectedKeyboards: [Keyboard] {
        #if DEBUG
        if let keyboards = LayoutCheck.keyboards { return keyboards }
        #endif
        return keyboards.connected
    }

    var body: some View {
        PresetBar(rules: rules, groups: Self.groups(of: rules.preset))
        let choices = KeyboardChoices(connected: connectedKeyboards, withSettings: rules.keyboardSettings)
        ControlKeyCard(
            choice: Binding(get: { rules.controlKey }, set: { rules.setControlKey($0) }),
            keyboards: choices,
            keyboardChoice: { rules.configuration.controlKey(for: $0.id) },
            setKeyboardChoice: { rules.chooseControlKey($0, for: $1) }
        )
        WinAltCard(
            choice: Binding(get: { rules.modifierLayout }, set: { rules.setModifierLayout($0) }),
            keyboards: choices,
            keyboardChoice: { rules.configuration.modifierLayout(for: $0.id) },
            setKeyboardChoice: { rules.chooseModifierLayout($0, for: $1) }
        )

        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search shortcuts…", text: $search)
                .textFieldStyle(.plain)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.separator))

        ForEach(Self.groups(of: rules.preset)) { group in
            let matches = Self.matching(rules.rules(inGroup: group.id), search, rules.controlKey, rules.modifierLayout)
            // A search hides the groups it found nothing in, so what is left
            // on screen is only what matched.
            if search.isEmpty || !matches.isEmpty {
                GroupCard(
                    group: group,
                    entries: matches,
                    isOn: rules.isEnabled(group: group.id),
                    // While searching, matches stay open: collapsing them
                    // would hide the very thing that was looked for.
                    isExpanded: !search.isEmpty || expanded.contains(group.id),
                    canCollapse: search.isEmpty,
                    toggleExpanded: {
                        if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) }
                    },
                    setOn: { isOn in
                        if isOn && group.id == "winKey" {
                            confirmingWinKey = true
                        } else {
                            rules.setGroup(group.id, enabled: isOn)
                        }
                    },
                    isCustomized: rules.isCustomized,
                    displayTrigger: rules.controlKey.trigger(of:),
                    edit: { editing = $0 }
                )
            }
        }

        Color.clear.frame(height: 0)
            .sheet(item: $editing) { rule in
                RuleEditor(rules: rules, rule: rule)
            }
            .alert("Turn on Windows key shortcuts?", isPresented: $confirmingWinKey) {
                Button("Turn On") { rules.setGroup("winKey", enabled: true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                switch rules.modifierLayout {
                case .pcKeyboard:
                    Text("Win is ⌘, so these shortcuts take ⌘Tab, ⌘Space, ⌘L, ⌘E, ⌘D, ⌘. and ⌘⇧S, and tapping ⌘ on its own opens Apps. ⌘Tab then opens Mission Control; switch apps with ⌥Tab. While the clipboard history is on, ⌘V opens it instead of pasting.")
                case .macPosition:
                    Text("Win is ⌥, so these shortcuts take ⌥Tab, ⌥Space, ⌥L, ⌥E, ⌥D, ⌥. and ⌥⇧S, and tapping ⌥ on its own opens Apps. ⌥ and a letter types characters on a Mac (é, ¬, ∂; @ on some layouts).")
                }
            }

        if !search.isEmpty && Self.groups(of: rules.preset).allSatisfy({ Self.matching(rules.rules(inGroup: $0.id), search, rules.controlKey, rules.modifierLayout).isEmpty }) {
            ContentUnavailableView.search(text: search)
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
        }
    }

    /// None: the page opens as a list of groups and their switches, all of
    /// them in view (KB-228). A search shows its matches expanded anyway.
    private static var initiallyExpanded: Set<String> {
        #if DEBUG
        if LayoutCheck.expandsAllGroups { return Set(BuiltInRules.preset.groups.map(\.id)) }
        #endif
        return []
    }

    /// The keyboard groups; mouse buttons and scrolling are on the Mouse
    /// page.
    static func groups(of preset: Preset) -> [Preset.Group] {
        preset.groups.filter { !["mouse", "scroll"].contains($0.id) }
    }

    /// Entries whose name, or either side of the mapping, contains the text.
    static func matching(_ rules: [Rule], _ search: String, _ controlKey: ControlKey, _ layout: ModifierLayout) -> [Rule] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return rules }
        return rules.filter { rule in
            var haystack = [RuleNames.name(of: rule), rule.id]
            if case .key(let combo) = controlKey.trigger(of: rule) { haystack += combo.caps(layout.triggerStyle) }
            if case .key(let combo) = rule.action { haystack += combo.caps(.mac) }
            if case .systemAction(let function) = rule.action { haystack.append(function.name) }
            return haystack.contains { $0.lowercased().contains(query) }
        }
    }
}

/// Which preset is in use. Switching between presets and re-applying one
/// arrive with the preset packs (KB-060) and the apply action (KB-061).
private struct PresetBar: View {
    let rules: RulesController
    let groups: [Preset.Group]
    private var preset: Preset { rules.preset }

    var body: some View {
        Card {
            HStack(spacing: 14) {
                IconTile(symbol: "list.bullet.rectangle", tint: .accentColor, size: 34)
                AdaptiveRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Preset: \(RuleNames.presetName(preset.id))")
                            .font(.headline)
                        Text("^[\(groups.flatMap(\.rules).count) shortcut](inflect: true) in \(groups.count) groups; the mouse and its wheel are on the Mouse page.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    RestoreDefaultsButton(rules: rules)
                }
            }
        }
    }
}

/// Which key the Ctrl shortcuts are pressed with: one choice, or with two
/// keyboards or more, one for each (KB-076). A PC keyboard has no fn key
/// that reaches the Mac, so it is Ctrl there, with nothing to choose.
private struct ControlKeyCard: View {
    @Binding var choice: ControlKey
    let keyboards: KeyboardChoices
    /// What a keyboard uses: its own choice, or else its default.
    let keyboardChoice: (Keyboard) -> ControlKey
    let setKeyboardChoice: (ControlKey, Keyboard) -> Void

    var body: some View {
        Card {
            if keyboards.isShown {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        icon
                        heading(perKeyboardDescription)
                    }
                    ForEach(keyboards.entries) { entry in
                        Divider()
                        Group {
                            if entry.keyboard.hasMacKeys {
                                KeyboardRow(
                                    entry: entry,
                                    example: Self.example(keyboardChoice(entry.keyboard)),
                                    value: Binding(get: { keyboardChoice(entry.keyboard) },
                                                   set: { setKeyboardChoice($0, entry.keyboard) })
                                ) { options }
                            } else {
                                KeyboardRow(entry: entry, example: Text("No fn key, so Ctrl shortcuts are pressed with Ctrl. For example, Ctrl+C copies.")) {
                                    FixedValue(text: "Ctrl")
                                }
                            }
                        }
                        .padding(.leading, 48)
                    }
                }
            } else if let only = keyboards.entries.first, !only.keyboard.hasMacKeys {
                HStack(spacing: 14) {
                    icon
                    heading(Text("This keyboard has no fn key, so Ctrl shortcuts are pressed with Ctrl, as on Windows. For example, Ctrl+C copies."))
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 14) {
                    icon
                    AdaptiveRow {
                        heading(Text(description))
                        Picker("Press Ctrl shortcuts with", selection: $choice) { options }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                    }
                }
            }
        }
    }

    private var icon: some View { IconTile(symbol: "globe", tint: .indigo, size: 34) }

    private func heading(_ description: Text) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Press Ctrl shortcuts with")
                .font(.headline)
            description
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // In the order the keys sit on a Mac keyboard: fn, then Ctrl.
    @ViewBuilder private var options: some View {
        Text("fn").tag(ControlKey.function)
        Text("Ctrl").tag(ControlKey.control)
        Text("Both").tag(ControlKey.both)
    }

    /// fn turns these keys into others, so fn cannot stand in for Ctrl with
    /// them (`KeyCode.keepsControl`).
    private static let keepsControlNote = String(localized: "With arrows, Home, End and ⌫ it stays Ctrl, since fn+← is Home and fn+⌫ is ⌦.")

    /// What maps to what and one example, for every group at once.
    private var description: LocalizedStringKey {
        switch choice {
        case .control: "Ctrl shortcuts in every group are pressed with Ctrl, as on Windows. For example, Ctrl+C copies."
        case .function: "Ctrl shortcuts in every group are pressed with fn; Ctrl keeps its Mac meaning. For example, fn+C copies. \(Self.keepsControlNote)"
        case .both: "Ctrl shortcuts in every group work with Ctrl and with fn. For example, Ctrl+C and fn+C copy. \(Self.keepsControlNote)"
        }
    }

    /// With a row per keyboard, the examples are in the rows; the note on
    /// arrows stays while a keyboard presses them with fn.
    private var perKeyboardDescription: Text {
        let usesFn = keyboards.entries.contains { keyboardChoice($0.keyboard) != .control }
        return usesFn
            ? Text("Each keyboard presses the Ctrl shortcuts with its own key. \(Self.keepsControlNote)")
            : Text("Each keyboard presses the Ctrl shortcuts with its own key.")
    }

    static func example(_ key: ControlKey) -> Text {
        switch key {
        case .control: Text("For example, Ctrl+C copies.")
        case .function: Text("For example, fn+C copies.")
        case .both: Text("For example, Ctrl+C and fn+C copy.")
        }
    }
}

/// Which Mac keys the Win and Alt shortcuts are pressed with (KB-226): as a
/// PC keyboard sends them, or where they sit on a Mac keyboard. One choice,
/// or with two keyboards or more, one for each (KB-076).
///
/// A PC keyboard is spoken of in its own keys (user's call, 2026-10-02): its
/// Win key already reads Win, so the choice there is "as printed" or
/// "swapped", and ⌘ and ⌥, which it has none of, are not named.
private struct WinAltCard: View {
    @Binding var choice: ModifierLayout
    let keyboards: KeyboardChoices
    let keyboardChoice: (Keyboard) -> ModifierLayout
    let setKeyboardChoice: (ModifierLayout, Keyboard) -> Void

    var body: some View {
        Card {
            if keyboards.isShown {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        icon
                        heading(Text("Which keys Win and Alt are on each keyboard."))
                    }
                    ForEach(keyboards.entries) { entry in
                        Divider()
                        KeyboardRow(
                            entry: entry,
                            example: Self.example(keyboardChoice(entry.keyboard), on: entry.keyboard),
                            value: binding(for: entry.keyboard)
                        ) { options(for: entry.keyboard) }
                        .padding(.leading, 48)
                    }
                }
            } else if let only = keyboards.entries.first, !only.keyboard.hasMacKeys {
                HStack(spacing: 14) {
                    icon
                    AdaptiveRow {
                        heading(Self.example(keyboardChoice(only.keyboard), on: only.keyboard))
                        Picker("Win and Alt keys", selection: binding(for: only.keyboard)) { options(for: only.keyboard) }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                    }
                }
            } else {
                HStack(spacing: 14) {
                    icon
                    AdaptiveRow {
                        heading(Text(description))
                        Picker("Win and Alt keys", selection: $choice) { macOptions }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                    }
                }
            }
        }
    }

    private var icon: some View { IconTile(symbol: "command", tint: .pink, size: 34) }

    private func heading(_ description: Text) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Win and Alt keys")
                .font(.headline)
            description
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func binding(for keyboard: Keyboard) -> Binding<ModifierLayout> {
        Binding(get: { keyboardChoice(keyboard) }, set: { setKeyboardChoice($0, keyboard) })
    }

    @ViewBuilder private func options(for keyboard: Keyboard) -> some View {
        if keyboard.hasMacKeys {
            macOptions
        } else {
            Text("As printed").tag(ModifierLayout.pcKeyboard)
            Text("Win and Alt swapped").tag(ModifierLayout.macPosition)
        }
    }

    // Both keys named in each option, and no keyboard: which keyboard
    // someone has says less than where they reach for Win. The same in
    // every language.
    @ViewBuilder private var macOptions: some View {
        Text(verbatim: "Win → ⌥ · Alt → ⌘").tag(ModifierLayout.macPosition)
        Text(verbatim: "Win → ⌘ · Alt → ⌥").tag(ModifierLayout.pcKeyboard)
    }

    private var description: LocalizedStringKey {
        switch choice {
        case .pcKeyboard:
            "Win maps to ⌘ and Alt to ⌥. For example, Win+L is ⌘L."
        case .macPosition:
            "Win maps to ⌥ and Alt to ⌘. For example, Win+L is ⌥L."
        }
    }

    /// In the keys printed on that keyboard.
    static func example(_ layout: ModifierLayout, on keyboard: Keyboard) -> Text {
        switch (layout, keyboard.hasMacKeys) {
        case (.pcKeyboard, true): Text("For example, Win+L is ⌘L.")
        case (.macPosition, true): Text("For example, Win+L is ⌥L.")
        case (.pcKeyboard, false): Text("For example, Win+L: press the Win key and L.")
        case (.macPosition, false): Text("For example, Win+L: press the Alt key and L.")
        }
    }
}

/// A value with nothing to choose, where a row would have its control.
private struct FixedValue: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// One group: its switch, and its entries when expanded.
struct GroupCard: View {
    let group: Preset.Group
    let entries: [Rule]
    let isOn: Bool
    let isExpanded: Bool
    let canCollapse: Bool
    let toggleExpanded: () -> Void
    let setOn: (Bool) -> Void
    let isCustomized: (String) -> Bool
    /// The trigger as the user presses it, which differs from the rule's
    /// when fn stands in for Ctrl.
    let displayTrigger: (Rule) -> Trigger
    let edit: (Rule) -> Void
    @Environment(\.triggerStyle) private var triggerStyle

    var body: some View {
        Card {
            VStack(spacing: 0) {
                header
                if isExpanded {
                    Divider().padding(.top, 12)
                    entryList
                    if group.id == "windows" {
                        Divider()
                        FunctionKeysRow()
                    }
                }
            }
        }
    }

    /// While a search narrows the group, the header says how much of it is
    /// showing, so the entries left out do not look lost.
    private var countText: LocalizedStringKey {
        entries.count < group.rules.count
            ? "\(entries.count) of ^[\(group.rules.count) mapping](inflect: true)"
            : "^[\(group.rules.count) mapping](inflect: true)"
    }

    private var header: some View {
        HStack(spacing: 12) {
            IconTile(symbol: RuleNames.symbol(ofGroup: group.id), tint: RuleNames.tint(ofGroup: group.id), size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(RuleNames.name(ofGroup: group.id))
                    .font(.headline)
                Text(countText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let note = RuleNames.note(ofGroup: group.id, style: triggerStyle) {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { isOn }, set: setOn))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel(RuleNames.name(ofGroup: group.id))
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .opacity(canCollapse ? 1 : 0.3)
        }
        // The whole header expands, except the switch itself.
        .contentShape(.rect)
        .onTapGesture { if canCollapse { toggleExpanded() } }
    }

    private var entryList: some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, rule in
                if index > 0 { Divider() }
                EntryRow(rule: rule, trigger: displayTrigger(rule), isCustomized: isCustomized(rule.id)) { edit(rule) }
            }
        }
        // A switched-off group still shows what it would do, greyed out.
        .opacity(isOn ? 1 : 0.45)
    }
}

/// F1–F12 as standard function keys is a system setting, not a mapping: an
/// Apple keyboard's top row sends brightness and volume events, not F-keys.
private struct FunctionKeysRow: View {
    var body: some View {
        AdaptiveRow {
            VStack(alignment: .leading, spacing: 2) {
                Text("F1–F12 as standard function keys")
                Text("Set in System Settings › Keyboard › Keyboard Shortcuts › Function Keys. A PC keyboard's F-keys already work.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Open Keyboard Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(.vertical, 9)
    }
}

/// One entry of a group. Clicking it opens the editor.
struct EntryRow: View {
    let rule: Rule
    let trigger: Trigger
    let isCustomized: Bool
    let edit: () -> Void
    @State private var isHovered = false

    private var displayed: Rule {
        var rule = rule
        rule.trigger = trigger
        return rule
    }

    var body: some View {
        Button(action: edit) {
            // A long name goes under the keys rather than being squeezed
            // beside them.
            AdaptiveRow(flexible: .trailing, minFlexibleWidth: 100, stackedSpacing: 6) {
                MappingView(rule: displayed)
                    .opacity(rule.isEnabled ? 1 : 0.45)
                HStack(spacing: 12) {
                    if isCustomized {
                        CustomizedBadge()
                    }
                    Text(RuleNames.name(of: rule))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .strikethrough(!rule.isEnabled)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "pencil")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .opacity(isHovered ? 1 : 0)
                }
            }
            .padding(.vertical, 9)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityHint("Edit")
    }
}

/// Names for what the model only knows by identifier. The preset packs
/// (KB-060) will carry their own, and localization is KB-090.
enum RuleNames {
    static func presetName(_ id: String) -> String {
        id == "windows-standard" ? String(localized: "Windows Standard") : id
    }

    static func name(ofGroup id: String) -> String {
        switch id {
        case "editing": String(localized: "Editing")
        case "navigation": String(localized: "Text Navigation")
        case "finder": String(localized: "File Management")
        case "dialogs": String(localized: "Open & Save Dialogs")
        case "windows": String(localized: "Apps & System")
        case "browser": String(localized: "Browser")
        case "winKey": String(localized: "Windows Key")
        case "mouse": String(localized: "Mouse")
        case "scroll": String(localized: "Scroll")
        case "window": String(localized: "Window Snapping")
        default: id
        }
    }

    /// A line under the group's name, for groups that need explaining.
    static func note(ofGroup id: String, style: KeyStyle = .windows) -> String? {
        switch id {
        case "winKey" where style == .windowsByPosition:
            String(localized: "Off by default: also takes over ⌥ and a letter, which types characters on a Mac")
        case "finder": String(localized: "Only in Finder, and not while renaming or searching")
        case "dialogs": String(localized: "Only in an open or save dialog (the list also in Finder), like Listary on Windows")
        case "winKey": String(localized: "Off by default: also takes over ⌘ shortcuts on a Mac keyboard")
        case "window": String(localized: "⌥ sits where the Windows key does, so ⌥ and an arrow places or minimizes the window in front")
        default: nil
        }
    }

    static func symbol(ofGroup id: String) -> String {
        switch id {
        case "editing": "pencil"
        case "navigation": "arrow.left.and.right.text.vertical"
        case "finder": "folder.fill"
        case "dialogs": "folder.badge.gearshape"
        case "windows": "macwindow.on.rectangle"
        case "browser": "globe"
        case "winKey": "command"
        case "mouse": "computermouse.fill"
        case "scroll": "arrow.up.and.down"
        case "window": "rectangle.split.2x1"
        default: "square.grid.2x2.fill"
        }
    }

    static func tint(ofGroup id: String) -> Color {
        switch id {
        case "editing": .indigo
        case "navigation": .teal
        case "finder": .blue
        case "dialogs": .brown
        case "windows": .purple
        case "browser": .green
        case "winKey": .pink
        case "mouse": .orange
        case "scroll": .cyan
        case "window": .mint
        default: .gray
        }
    }

    static func name(of rule: Rule) -> String {
        names[rule.id] ?? rule.id
    }

    private static let names: [String: String] = [
        "edit.copy": String(localized: "Copy"), "edit.cut": String(localized: "Cut"), "edit.paste": String(localized: "Paste"), "edit.undo": String(localized: "Undo"),
        "edit.redo": String(localized: "Redo"), "edit.selectAll": String(localized: "Select all"), "edit.save": String(localized: "Save"), "edit.find": String(localized: "Find"),
        "edit.new": String(localized: "New"), "edit.newFolder": String(localized: "New folder / private window"), "edit.open": String(localized: "Open"), "edit.print": String(localized: "Print"),
        "nav.lineStart": String(localized: "Line start"), "nav.lineEnd": String(localized: "Line end"),
        "nav.selectLineStart": String(localized: "Select to line start"), "nav.selectLineEnd": String(localized: "Select to line end"),
        "nav.docStart": String(localized: "Document start"), "nav.docEnd": String(localized: "Document end"),
        "nav.selectDocStart": String(localized: "Select to document start"), "nav.selectDocEnd": String(localized: "Select to document end"),
        "nav.wordLeft": String(localized: "Previous word"), "nav.wordRight": String(localized: "Next word"),
        "nav.selectWordLeft": String(localized: "Select previous word"), "nav.selectWordRight": String(localized: "Select next word"),
        "nav.deleteWord": String(localized: "Delete previous word"),
        "nav.deleteWordForward": String(localized: "Delete next word"),
        "finder.trash": String(localized: "Move to Trash"), "finder.trashCtrlD": String(localized: "Move to Trash"), "finder.rename": String(localized: "Rename"), "finder.open": String(localized: "Open"),
        "dialog.finderFolder": String(localized: "Go to Finder's folder"),
        "dialog.recentLocations": String(localized: "Recent and favorite folders"),
        "finder.cut": String(localized: "Cut (mark to move)"), "finder.move": String(localized: "Move here"), "finder.parent": String(localized: "Enclosing folder"),
        "win.switchApp": String(localized: "Switch apps"), "win.quit": String(localized: "Quit app"), "win.screenshot": String(localized: "Screenshot to clipboard"),
        "win.taskManager": String(localized: "Task Manager (Activity Monitor)"),
        "browser.newTab": String(localized: "New tab"), "browser.closeTab": String(localized: "Close tab"), "browser.reopenTab": String(localized: "Reopen closed tab"),
        "browser.address": String(localized: "Address bar"), "browser.reload": String(localized: "Reload"),
        "browser.zoomIn": String(localized: "Zoom in"), "browser.zoomOut": String(localized: "Zoom out"),
        "browser.zoomReset": String(localized: "Reset zoom"),
        "sys.forceQuit": String(localized: "Force Quit"),
        "winKey.start": String(localized: "Start menu (Apps)"), "winKey.taskView": String(localized: "Task View (Mission Control)"),
        "winKey.clipboard": String(localized: "Clipboard history"),
        "winKey.lock": String(localized: "Lock screen"), "winKey.explorer": String(localized: "File Explorer (Finder)"),
        "winKey.showDesktop": String(localized: "Show desktop"), "winKey.emoji": String(localized: "Emoji & symbols"),
        "winKey.inputSource": String(localized: "Switch input source"),
        "winKey.screenshotArea": String(localized: "Screenshot of an area to clipboard"),
        "mouse.back": String(localized: "Back"), "mouse.forward": String(localized: "Forward"),
        "scroll.zoomIn": String(localized: "Zoom in"), "scroll.zoomOut": String(localized: "Zoom out"),
        "window.leftHalf": String(localized: "Snap to the left half"), "window.rightHalf": String(localized: "Snap to the right half"),
        "window.maximize": String(localized: "Fill the screen"),
        "window.minimize": String(localized: "Minimize"),
    ]
}

/// Stands in for a page that a later release fills in.
private struct ComingSoon: View {
    let page: Page

    var body: some View {
        ContentUnavailableView {
            Label {
                Text("Coming soon")
            } icon: {
                IconTile(symbol: page.symbol, tint: page.tint, size: 44)
            }
        } description: {
            Text("This page is not built yet. What SameKeys does today is on the Overview.")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

/// The app's version and license.
private struct AboutCard: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return String(localized: "Version \(short) (\(build))")
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    AppIcon(size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SameKeys")
                            .font(.headline)
                        Text(version)
                            .foregroundStyle(.secondary)
                    }
                }
                // What SameKeys is for (SK-272, replacing the author's note of KB-250).
                Text("Moving from Windows to Mac can take time. Many familiar shortcuts and controls work differently.\nSameKeys brings your Windows habits to Mac, so you can keep working the way you know.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// About › the offer to sponsor (KB-104), in the words the website uses.
/// Only a link: nothing is sent anywhere until someone clicks it.
private struct SupportCard: View {
    static let sponsorURL = URL(string: "https://github.com/sponsors/lynnjeans")!
    @Environment(\.openURL) private var openURL

    var body: some View {
        Card {
            HStack(spacing: 14) {
                IconTile(symbol: "heart.fill", tint: .pink, size: 34)
                AdaptiveRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enjoying SameKeys?")
                            .font(.headline)
                        Text("SameKeys is free and open source, and it will stay that way. If it saves you some frustration, a sponsorship keeps the work going — never required, always appreciated.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Sponsor on GitHub") { openURL(Self.sponsorURL) }
                }
            }
        }
    }
}

/// About › ways to report a problem or ask for something (SK-280), just
/// above the diagnostics to attach. Only links: nothing is sent until the
/// person sends it themselves.
private struct FeedbackCard: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Card {
            HStack(spacing: 14) {
                IconTile(symbol: "envelope.fill", tint: .blue, size: 34)
                AdaptiveRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Feedback")
                            .font(.headline)
                        Text("Something not working, or a Windows habit you miss? Report it on GitHub or by email. For a problem, attach the diagnostics below.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Button("Report on GitHub") {
                            openURL(FeedbackLinks.issue(app: FeedbackLinks.appVersion, system: DiagnosticReport.systemVersion))
                        }
                        Button("Send Email") {
                            openURL(FeedbackLinks.mail(app: FeedbackLinks.appVersion, system: DiagnosticReport.systemVersion))
                        }
                    }
                }
            }
        }
    }
}

/// The master switch.
struct ModeCard: View {
    let engine: EngineController
    var controlKey: ControlKey = .control

    var body: some View {
        Card {
            HStack(alignment: .center, spacing: 14) {
                IconTile(symbol: "command", tint: .accentColor, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Enable SameKeys")
                        .font(.headline)
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if engine.isPaused {
                    Button("Resume") { engine.resume() }
                }
                // Shown off while it cannot run, even if the user left it on;
                // it comes back on by itself once the permissions are granted.
                Toggle("Enable SameKeys", isOn: Binding(
                    get: { engine.isEnabled && engine.canEnable },
                    set: { engine.isEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!engine.canEnable)
            }
        }
    }

    private var detail: String {
        if !engine.canEnable {
            return String(localized: "Unavailable until SameKeys has the permissions below. macOS does not let an app change shortcuts without them.")
        }
        if !engine.isEnabled {
            return String(localized: "Off. Every key, click and scroll reaches apps unchanged.")
        }
        if let until = engine.pausedUntil {
            return until == .distantFuture
                ? String(localized: "Paused. Every key, click and scroll reaches apps unchanged until you resume.")
                : String(localized: "Paused until \(until.formatted(date: .omitted, time: .shortened)). Every key, click and scroll reaches apps unchanged until then.")
        }
        if !engine.isActive {
            return String(localized: "On, but the event tap could not be started. Quitting and reopening SameKeys may help.")
        }
        return String(localized: "On. \(copyKey)+C, Home/End, Alt+Tab, the mouse side buttons and scroll zoom work the Windows way.")
    }

    /// The key the user copies with, as they chose on the Shortcuts page.
    private var copyKey: String {
        switch controlKey {
        case .control: String(localized: "Ctrl")
        case .function: String(localized: "fn")
        case .both: String(localized: "Ctrl or fn")
        }
    }
}

/// Whether SameKeys has what it needs from macOS, and where to grant it.
struct PermissionsCard: View {
    let permissions: PermissionMonitor
    let onboarding: OnboardingController

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Permissions")
                        .font(.headline)
                    Spacer()
                    if permissions.allGranted {
                        Label("Ready", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Action needed", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.subheadline.weight(.semibold))

                ForEach(Permission.allCases, id: \.self) { permission in
                    PermissionRow(permission: permission, granted: permissions.status(of: permission) == .granted)
                }

                // The guided way through, for anyone who closed it on the
                // first run or lost a permission later.
                if !permissions.allGranted {
                    Button("Set Up Permissions…") { onboarding.open() }
                }
            }
        }
    }
}

private struct PermissionRow: View {
    let permission: Permission
    let granted: Bool

    var body: some View {
        AdaptiveRow {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(granted ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(permission.title)
                    Text(permission.purpose)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let hint = permission.settingsHint(granted: granted) {
                        Text(hint)
                            .font(.caption)
                            // Secondary, not tertiary: tertiary is too faint to
                            // read in the dark appearance.
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if granted {
                Text("Granted")
                    .foregroundStyle(.secondary)
            } else {
                Button("Open Settings") {
                    NSWorkspace.shared.open(permission.settingsURL)
                }
            }
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
