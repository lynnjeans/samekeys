import AppKit
import OSLog

/// Notices every copy and hands what may be kept to the history.
///
/// macOS has no notification for pasteboard changes; its change count is
/// polled instead, twice a second. Reading the count is a cheap call, and
/// the contents are only read when it has moved.
///
/// The contents are read off the main thread. An app can promise data and
/// only produce it when asked; a remote desktop client whose session has
/// closed never does, and the read waits about a minute for it. On the main
/// thread that froze the key and scroll taps and the menu bar (SK-302).
@MainActor
final class ClipboardMonitor {
    let pasteboard: NSPasteboard
    private let history: ClipboardHistory
    var privacy: ClipboardPrivacy
    /// The app in front when the copy happened, for copies that do not say
    /// where they came from.
    private let frontmostBundleID: @MainActor () -> String?

    private var lastChangeCount: Int
    private var timer: Timer?
    /// The read in progress; while it runs, newer copies wait for it.
    private var reading: Task<Void, Never>?
    private static let readQueue = DispatchQueue(label: "com.samekeys.clipboard-read", qos: .utility)

    /// Copies larger than this are not kept: a huge image would bloat the
    /// history file for little use.
    nonisolated static let maximumSize = 10 * 1024 * 1024

    init(
        pasteboard: NSPasteboard = .general,
        history: ClipboardHistory,
        privacy: ClipboardPrivacy,
        frontmostBundleID: @escaping @MainActor () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    ) {
        self.pasteboard = pasteboard
        self.history = history
        self.privacy = privacy
        self.frontmostBundleID = frontmostBundleID
        lastChangeCount = pasteboard.changeCount
    }

    var isRunning: Bool { timer != nil }

    /// Starts watching. What was on the pasteboard before is not recorded:
    /// only copies made while the history is on.
    func start() {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Logger.clipboard.notice("Clipboard history on")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        Logger.clipboard.notice("Clipboard history off")
    }

    /// Records the pasteboard if it changed since the last look. Returns the
    /// read it started, if any, so tests can wait for it.
    @discardableResult
    func check() -> Task<Void, Never>? {
        guard isRunning, reading == nil else { return nil }
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return nil }
        lastChangeCount = count
        let task = capture()
        reading = task
        return task
    }

    private func capture() -> Task<Void, Never> {
        let pasteboard = UncheckedPasteboard(pasteboard: pasteboard)
        let privacy = privacy
        let frontmost = frontmostBundleID()
        return Task { [weak self] in
            let item = await withCheckedContinuation { continuation in
                Self.readQueue.async {
                    continuation.resume(returning: Self.read(pasteboard.pasteboard, privacy: privacy, frontmost: frontmost))
                }
            }
            guard let self else { return }
            reading = nil
            if let item, isRunning { history.add(item) }
        }
    }

    /// Reads the newest copy, or nil when it is not to be kept. May block
    /// for as long as the app that made the copy takes to provide it.
    private nonisolated static func read(_ pasteboard: NSPasteboard, privacy: ClipboardPrivacy, frontmost: String?) -> ClipboardItem? {
        guard let pasteboardItem = pasteboard.pasteboardItems?.first else { return nil }
        let types = pasteboardItem.types.map(\.rawValue)
        // Apps following nspasteboard.org name themselves; others are taken
        // to be the app in front.
        let source = pasteboard.string(forType: .init("org.nspasteboard.source")) ?? frontmost

        let verdict = privacy.verdict(types: types, sourceBundleID: source)
        guard verdict == .keep else {
            // What was skipped is never logged, only that something was.
            Logger.clipboard.info("Copy skipped: \(String(describing: verdict), privacy: .public)")
            return nil
        }

        var contents: [String: Data] = [:]
        var size = 0
        for type in ClipboardItem.keptTypes {
            guard let data = pasteboardItem.data(forType: type) else { continue }
            size += data.count
            contents[type.rawValue] = data
        }
        guard !contents.isEmpty else { return nil }
        guard size <= maximumSize else {
            Logger.clipboard.info("Copy skipped: \(size, privacy: .public) bytes is over the limit")
            return nil
        }
        return ClipboardItem(date: .now, sourceBundleID: source, contents: contents)
    }
}

/// Carries the pasteboard to the read queue. Only that queue touches it
/// while a read runs.
private struct UncheckedPasteboard: @unchecked Sendable {
    let pasteboard: NSPasteboard
}

extension Logger {
    static let clipboard = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "SameKeys",
        category: "clipboard"
    )
}
