/// The preset SameKeys ships with: the Windows shortcut coverage list from
/// the market research, as switchable groups. The user's saved overrides
/// (`Configuration`) apply on top of it by rule ID, so IDs must never change.
///
/// Left out on purpose:
/// - Delete erasing forwards: a PC keyboard's Delete already does on a Mac.
/// - F1–F12 as standard function keys: an Apple keyboard's top row sends
///   media-key events, not F-key codes, so this is the system setting the
///   System group points to.
enum BuiltInRules {
    /// Terminals, where Ctrl combinations are control characters for the
    /// shell (Ctrl+C interrupts, Ctrl+W deletes a word) and must arrive
    /// unchanged.
    static let terminals = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
    ]

    static let finderID = "com.apple.finder"

    static let preset = Preset(id: "windows-standard", groups: [
        // A PC keyboard's Win key arrives as ⌘, so these also take over ⌘Tab,
        // ⌘V, ⌘Space, ⌘L, ⌘E, ⌘D, ⌘. and ⌘⇧S, and ⌘ tapped alone, on a Mac
        // keyboard.
        // Off until the user asks. First in the list, so it is the first group
        // the Shortcuts page shows, and first to match: where another group's
        // rule of the same scope has the same trigger, this one wins (KB-266).
        .init(id: "winKey", rules: [
            // Win alone opens Start; Apps is macOS 26's nearest thing, a grid
            // of apps with a search field (KB-224). A tap only: ⌘ held for a
            // shortcut, or for longer than a second, is left alone.
            Rule(id: "winKey.start", trigger: .key(combo: KeyCombo(.command)),
                 action: .systemAction(.apps)),
            // Task View, every window at a glance (KB-227). With Win on ⌘ this
            // takes ⌘Tab: Alt+Tab (⌥Tab, the `windows` group) switches apps.
            Rule(id: "winKey.taskView", trigger: .key(combo: KeyCombo([.command], .tab)),
                 action: .systemAction(.missionControl)),
            // The clipboard history's own shortcut is a system hot key, ⌥V
            // unless recorded otherwise, which does not follow the Win key
            // (KB-245). This does, so Win+V opens it on every keyboard. Only
            // while the history is on: otherwise ⌘V pastes as before. Paste
            // on a PC keyboard is Ctrl+V, as on Windows.
            Rule(id: "winKey.clipboard", trigger: .key(combo: KeyCombo([.command], .v)),
                 action: .clipboardHistory),
            rule("winKey.lock", KeyCombo([.command], .l), KeyCombo([.control, .command], .q)),
            Rule(id: "winKey.explorer", trigger: .key(combo: KeyCombo([.command], .e)),
                 action: .openApplication(bundleID: finderID)),
            // Whatever Show Desktop is set to (F11 as shipped), so a changed
            // shortcut keeps working.
            Rule(id: "winKey.showDesktop", trigger: .key(combo: KeyCombo([.command], .d)),
                 action: .systemAction(.showDesktop)),
            // Windows 10 and 11 switch the input language or method with
            // Win+Space, whatever the language (SK-278). It takes ⌘Space,
            // Spotlight's shortcut, which is why the group is off by default.
            Rule(id: "winKey.inputSource", trigger: .key(combo: KeyCombo([.command], .space)),
                 action: .systemAction(.inputSource)),
            rule("winKey.emoji", KeyCombo([.command], .period), KeyCombo([.control, .command], .space)),
            rule("winKey.screenshotArea", KeyCombo([.shift, .command], .s), KeyCombo([.control, .shift, .command], .four)),
        ], isEnabledByDefault: false),
        .init(id: "editing", rules: [
            outsideTerminals("edit.copy", KeyCombo([.control], .c), KeyCombo([.command], .c)),
            outsideTerminals("edit.cut", KeyCombo([.control], .x), KeyCombo([.command], .x)),
            outsideTerminals("edit.paste", KeyCombo([.control], .v), KeyCombo([.command], .v)),
            outsideTerminals("edit.undo", KeyCombo([.control], .z), KeyCombo([.command], .z)),
            outsideTerminals("edit.redo", KeyCombo([.control], .y), KeyCombo([.shift, .command], .z)),
            outsideTerminals("edit.selectAll", KeyCombo([.control], .a), KeyCombo([.command], .a)),
            outsideTerminals("edit.save", KeyCombo([.control], .s), KeyCombo([.command], .s)),
            outsideTerminals("edit.find", KeyCombo([.control], .f), KeyCombo([.command], .f)),
            outsideTerminals("edit.new", KeyCombo([.control], .n), KeyCombo([.command], .n)),
            outsideTerminals("edit.open", KeyCombo([.control], .o), KeyCombo([.command], .o)),
            outsideTerminals("edit.print", KeyCombo([.control], .p), KeyCombo([.command], .p)),
        ]),
        .init(id: "navigation", rules: [
            outsideTerminals("nav.lineStart", KeyCombo(.home), KeyCombo([.command], .leftArrow)),
            outsideTerminals("nav.lineEnd", KeyCombo(.end), KeyCombo([.command], .rightArrow)),
            outsideTerminals("nav.selectLineStart", KeyCombo([.shift], .home), KeyCombo([.shift, .command], .leftArrow)),
            outsideTerminals("nav.selectLineEnd", KeyCombo([.shift], .end), KeyCombo([.shift, .command], .rightArrow)),
            outsideTerminals("nav.docStart", KeyCombo([.control], .home), KeyCombo([.command], .upArrow)),
            outsideTerminals("nav.docEnd", KeyCombo([.control], .end), KeyCombo([.command], .downArrow)),
            outsideTerminals("nav.selectDocStart", KeyCombo([.control, .shift], .home), KeyCombo([.shift, .command], .upArrow)),
            outsideTerminals("nav.selectDocEnd", KeyCombo([.control, .shift], .end), KeyCombo([.shift, .command], .downArrow)),
            outsideTerminals("nav.wordLeft", KeyCombo([.control], .leftArrow), KeyCombo([.option], .leftArrow)),
            outsideTerminals("nav.wordRight", KeyCombo([.control], .rightArrow), KeyCombo([.option], .rightArrow)),
            outsideTerminals("nav.selectWordLeft", KeyCombo([.control, .shift], .leftArrow), KeyCombo([.shift, .option], .leftArrow)),
            outsideTerminals("nav.selectWordRight", KeyCombo([.control, .shift], .rightArrow), KeyCombo([.shift, .option], .rightArrow)),
            outsideTerminals("nav.deleteWord", KeyCombo([.control], .delete), KeyCombo([.option], .delete)),
            // Its twin, the word after the insertion point (SK-284). ⌦ reports
            // fn by itself, so this stays on Ctrl in every Ctrl key mode.
            outsideTerminals("nav.deleteWordForward", KeyCombo([.control], .forwardDelete), KeyCombo([.option], .forwardDelete)),
        ]),
        // Only in Finder, and never while renaming or searching: there Enter,
        // Backspace and Ctrl+V have to do what they do in any text field.
        .init(id: "finder", rules: [
            inFinder("finder.trash", KeyCombo(.forwardDelete), KeyCombo([.command], .delete)),
            // Explorer's other delete key (KB-221). fn+D in fn mode, which is
            // also macOS's own dictation shortcut: taken in Finder only, and
            // let through while renaming, like the rest of the group.
            inFinder("finder.trashCtrlD", KeyCombo([.control], .d), KeyCombo([.command], .delete)),
            inFinder("finder.rename", KeyCombo(.f2), KeyCombo(.returnKey)),
            inFinder("finder.open", KeyCombo(.returnKey), KeyCombo([.command], .downArrow)),
            // Ctrl+X marks for moving: Finder has no cut, but ⌘C followed by
            // ⌥⌘V moves the files.
            inFinder("finder.cut", KeyCombo([.control], .x), KeyCombo([.command], .c)),
            inFinder("finder.move", KeyCombo([.control], .v), KeyCombo([.option, .command], .v)),
            inFinder("finder.parent", KeyCombo(.delete), KeyCombo([.command], .upArrow)),
        ]),
        // Listary's quick switch on Windows (KB-217). These match only while
        // an open or save dialog has the keyboard, whatever the scope says,
        // so ⌃G stays free everywhere else, terminals included.
        .init(id: "dialogs", rules: [
            Rule(id: "dialog.finderFolder", trigger: .key(combo: KeyCombo([.control], .g)),
                 action: .fileDialog(.finderFolder)),
            // Also in Finder, where the chosen folder is opened (KB-219).
            Rule(id: "dialog.recentLocations", trigger: .key(combo: KeyCombo([.control, .shift], .g)),
                 action: .fileDialog(.recentLocations)),
        ]),
        .init(id: "windows", rules: [
            rule("win.switchApp", KeyCombo([.option], .tab), KeyCombo([.command], .tab)),
            rule("win.quit", KeyCombo([.option], .f4), KeyCombo([.command], .q)),
            // PC keyboards send Print Screen as F13. As on Windows, the
            // screenshot goes to the clipboard (⌃ added), not to a file, so
            // it also lands in the clipboard history.
            rule("win.screenshot", KeyCombo(.f13), KeyCombo([.control, .shift, .command], .three)),
            Rule(id: "win.taskManager", trigger: .key(combo: KeyCombo([.control, .shift], .escape)),
                 action: .openApplication(bundleID: "com.apple.ActivityMonitor")),
            // Once a group of its own, "system" (SK-285); the ID stays, so a
            // change to it keeps applying.
            rule("sys.forceQuit", KeyCombo([.control, .option], .forwardDelete), KeyCombo([.option, .command], .escape)),
        ]),
        .init(id: "browser", rules: [
            outsideTerminals("browser.newTab", KeyCombo([.control], .t), KeyCombo([.command], .t)),
            outsideTerminals("browser.closeTab", KeyCombo([.control], .w), KeyCombo([.command], .w)),
            outsideTerminals("browser.reopenTab", KeyCombo([.control, .shift], .t), KeyCombo([.shift, .command], .t)),
            outsideTerminals("browser.address", KeyCombo([.control], .l), KeyCombo([.command], .l)),
            outsideTerminals("browser.reload", KeyCombo([.control], .r), KeyCombo([.command], .r)),
            // Page zoom by key (KB-225). Most document apps zoom with these
            // too, so they are not limited to browsers. ⌘= is what apps
            // expect for ⌘+, as with the scroll rules.
            outsideTerminals("browser.zoomIn", KeyCombo([.control], .equal), KeyCombo([.command], .equal)),
            outsideTerminals("browser.zoomOut", KeyCombo([.control], .minus), KeyCombo([.command], .minus)),
            outsideTerminals("browser.zoomReset", KeyCombo([.control], .zero), KeyCombo([.command], .zero)),
        ]),
        // Win+←/→/↑ on Windows. The trigger is ⌥, not ⌘, because these are
        // arrow keys pressed by feel: on a Mac keyboard ⌥ sits where the Win
        // key sits on a PC one, and ⌘ where Alt does. ⌥+arrow is macOS's own
        // move-by-word, but the people this preset is for reach for Ctrl+←
        // instead — the navigation group turns that into ⌥← for them, and
        // SameKeys's own output is stamped, so it never comes back through
        // here as a snap.
        .init(id: "window", rules: [
            Rule(id: "window.leftHalf", trigger: .key(combo: KeyCombo([.option], .leftArrow)),
                 action: .windowAction(.leftHalf)),
            Rule(id: "window.rightHalf", trigger: .key(combo: KeyCombo([.option], .rightArrow)),
                 action: .windowAction(.rightHalf)),
            Rule(id: "window.maximize", trigger: .key(combo: KeyCombo([.option], .upArrow)),
                 action: .windowAction(.maximize)),
            // Win+↓ on Windows restores a maximized window and minimizes a
            // normal one. Only the minimize half is here: restoring means
            // remembering what each window's frame was before it was snapped,
            // which is its own piece of state and its own ticket.
            Rule(id: "window.minimize", trigger: .key(combo: KeyCombo([.option], .downArrow)),
                 action: .windowAction(.minimize)),
        ]),
        .init(id: "mouse", rules: [
            // Back and forward in browsers and Finder. Not limited by app: the
            // side buttons mean nothing to a terminal either.
            Rule(id: "mouse.back", trigger: .mouseButton(number: 4),
                 action: .key(combo: KeyCombo([.command], .leftBracket))),
            Rule(id: "mouse.forward", trigger: .mouseButton(number: 5),
                 action: .key(combo: KeyCombo([.command], .rightBracket))),
        ]),
        .init(id: "scroll", rules: [
            // Page zoom, like Ctrl+wheel on Windows. Ctrl here is the Windows
            // Ctrl, so it follows each keyboard's control key (SK-297): fn+scroll
            // on a keyboard set to fn, where Ctrl+scroll stays the system's
            // screen zoom, and Ctrl+scroll on a PC keyboard, which has no fn.
            // ⌘= is what apps expect for ⌘+.
            Rule(id: "scroll.zoomIn", trigger: .scroll(direction: .up, modifiers: [.control]),
                 action: .key(combo: KeyCombo([.command], .equal))),
            Rule(id: "scroll.zoomOut", trigger: .scroll(direction: .down, modifiers: [.control]),
                 action: .key(combo: KeyCombo([.command], .minus))),
        ]),
    ])

    /// Every rule of the preset, including groups that start off.
    static var all: [Rule] { preset.rules }

    private static func rule(_ id: String, _ from: KeyCombo, _ to: KeyCombo, scope: Scope = .everywhere) -> Rule {
        Rule(id: id, trigger: .key(combo: from), action: .key(combo: to), scope: scope)
    }

    private static func outsideTerminals(_ id: String, _ from: KeyCombo, _ to: KeyCombo) -> Rule {
        rule(id, from, to, scope: Scope(applications: .except(bundleIDs: terminals)))
    }

    private static func inFinder(_ id: String, _ from: KeyCombo, _ to: KeyCombo) -> Rule {
        rule(id, from, to, scope: Scope(applications: .only(bundleIDs: [finderID]), skipsTextInput: true))
    }
}
