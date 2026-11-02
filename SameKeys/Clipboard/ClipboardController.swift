import AppKit
import Observation
import OSLog

/// The clipboard history as a feature: whether it is on, what it leaves out,
/// and the history itself. Its settings live in UserDefaults, apart from the
/// shortcut configuration, since they belong to a separate subsystem.
@MainActor
@Observable
final class ClipboardController {
    let history: ClipboardHistory

    /// Off until the user turns it on: it records what they copy.
    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Keys.enabled)
            update()
        }
    }

    /// Apps whose copies are never recorded.
    private(set) var excludedApps: [String]

    /// How many unpinned items are kept.
    var limit: Int {
        get { history.limit }
        set {
            history.limit = newValue
            defaults.set(newValue, forKey: Keys.limit)
        }
    }

    static let limitChoices = [25, 50, 100, 200, 500, 1000]

    /// The shortcut that brings up the history panel from any app.
    private(set) var hotKey: KeyCombo

    /// Why the shortcut does not work, when it does not.
    private(set) var hotKeyProblem: String?

    /// ⌥V (KB-238): on a Mac keyboard ⌥ sits where the Windows key is, so
    /// this is Win+V by position. ⌘⇧V would be closer by name but is Paste
    /// and Match Style in many apps. ⌥V types a character on many layouts
    /// (√ on US English); whoever needs it records another shortcut.
    static let defaultHotKey = KeyCombo([.option], .v)

    /// Shows or hides the history panel; set by the app, which owns it.
    @ObservationIgnored var togglePanel: (@MainActor () -> Void)?
    @ObservationIgnored private lazy var globalHotKey = GlobalHotKey { [weak self] in self?.togglePanel?() }

    @ObservationIgnored private let monitor: ClipboardMonitor
    @ObservationIgnored private let defaults: UserDefaults

    enum Keys {
        static let enabled = "clipboard.enabled"
        static let excludedApps = "clipboard.excludedApps"
        static let limit = "clipboard.limit"
        static let hotKey = "clipboard.hotKey"
    }

    init(pasteboard: NSPasteboard = .general, defaults: UserDefaults = .standard, store: ClipboardStore = ClipboardStore()) {
        self.defaults = defaults
        let excluded = defaults.stringArray(forKey: Keys.excludedApps)
            ?? ClipboardPrivacy.defaultExcludedApps.sorted()
        let limit = defaults.object(forKey: Keys.limit) as? Int ?? 200
        let history = ClipboardHistory(items: store.load(), limit: limit)
        // Every change is written straight away: copies are rare events,
        // and each writes one small file plus the index.
        history.onChange = { items in
            do {
                try store.save(items)
            } catch {
                Logger.clipboard.error("Could not save the clipboard history: \(String(describing: error), privacy: .public)")
            }
        }
        self.history = history
        excludedApps = excluded
        hotKey = defaults.data(forKey: Keys.hotKey).flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) }
            ?? Self.defaultHotKey
        isEnabled = defaults.bool(forKey: Keys.enabled)
        monitor = ClipboardMonitor(
            pasteboard: pasteboard, history: history,
            privacy: ClipboardPrivacy(excludedApps: Set(excluded))
        )
        update()
    }

    func exclude(_ bundleID: String) {
        guard !excludedApps.contains(bundleID) else { return }
        setExcludedApps(excludedApps + [bundleID])
    }

    func include(_ bundleID: String) {
        setExcludedApps(excludedApps.filter { $0 != bundleID })
    }

    func resetExcludedApps() {
        setExcludedApps(ClipboardPrivacy.defaultExcludedApps.sorted())
    }

    /// Changes the shortcut and registers it at once.
    func setHotKey(_ combo: KeyCombo) {
        hotKey = combo
        defaults.set(try? JSONEncoder().encode(combo), forKey: Keys.hotKey)
        update()
    }

    /// Lets go of the shortcut while a new one is being recorded, so
    /// pressing the current one records it instead of opening the panel.
    func suspendHotKey() {
        globalHotKey.unregister()
    }

    func resumeHotKey() {
        update()
    }

    /// Puts an item back on the pasteboard in every form it was copied in.
    /// It then counts as the newest copy and moves to the top.
    func restore(_ item: ClipboardItem) {
        let pasteboard = monitor.pasteboard
        pasteboard.clearContents()
        let pasteboardItem = NSPasteboardItem()
        for type in ClipboardItem.keptTypes {
            if let data = item.contents[type.rawValue] { pasteboardItem.setData(data, forType: type) }
        }
        pasteboard.writeObjects([pasteboardItem])
    }

    /// Checks the pasteboard now rather than at the next poll; for tests.
    func checkNow() async {
        await monitor.check()?.value
    }

    private func setExcludedApps(_ apps: [String]) {
        excludedApps = apps
        defaults.set(apps, forKey: Keys.excludedApps)
        monitor.privacy = ClipboardPrivacy(excludedApps: Set(apps))
    }

    private func update() {
        if isEnabled && !monitor.isRunning {
            monitor.start()
        } else if !isEnabled && monitor.isRunning {
            monitor.stop()
        }
        registerHotKey()
    }

    private func registerHotKey() {
        guard isEnabled else {
            globalHotKey.unregister()
            hotKeyProblem = nil
            return
        }
        do {
            try globalHotKey.register(hotKey)
            hotKeyProblem = nil
        } catch .unsupportedModifier {
            hotKeyProblem = String(localized: "fn cannot be part of this shortcut. Choose one with ⌘, ⌥, ⌃ or ⇧.")
        } catch .taken {
            hotKeyProblem = String(localized: "Another app already uses this shortcut. Choose a different one.")
        } catch {
            hotKeyProblem = String(localized: "The shortcut could not be set up. Choose a different one.")
        }
        if let hotKeyProblem {
            Logger.clipboard.error("Hot key not registered: \(hotKeyProblem, privacy: .public)")
        }
    }
}
