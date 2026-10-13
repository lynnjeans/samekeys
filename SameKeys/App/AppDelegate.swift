import AppKit
import OSLog

/// Owns the app-lifetime services that SwiftUI scenes have no natural home for.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let permissionMonitor = PermissionMonitor()
    let secureInput = SecureInputMonitor()
    let otherRemappers = OtherRemapperMonitor()
    lazy var clipboard = ClipboardController()
    lazy var clipboardPanel = ClipboardPanelController(clipboard: clipboard)
    lazy var quickSwitch = QuickSwitch(locations: FileLocations())
    let frontmost = FrontmostApplication()
    /// Terminals inside other apps, and Accessibility switched on in the
    /// Electron apps they live in (SK-298).
    let embeddedTerminal = EmbeddedTerminal()
    let electronAccessibility = ElectronAccessibility()
    let inputSources = InputSourceSwitcher()
    let keyboards = KeyboardList()
    let dockClick = DockClick(lookUp: DockWindow.target(forClickAt:), minimize: DockWindow.minimize)
    /// Which keyboard a key came from, for keyboards with settings of their
    /// own (KB-243).
    let keyboardSource = KeyboardSource()
    lazy var dispatcher = Dispatcher(
        // While one of SameKeys's own panels has the keyboard (recent
        // locations, clipboard history), keys are typed into
        // it, not into the app behind: rules for that app (Finder's Return
        // opens) must not turn them into something else (KB-268). Rules for
        // every app, such as Ctrl+V pasting, still apply.
        frontmostBundleID: { [frontmost] in
            NSApp.keyWindow != nil ? Bundle.main.bundleIdentifier : frontmost.bundleID
        },
        isEditingText: FocusedElement.isEditingText,
        isInFileDialog: FileDialog.isFocused,
        // Not while one of SameKeys's own panels has the keyboard: the app
        // behind does not get the keys then.
        isInTerminal: { [frontmost, embeddedTerminal] in
            guard NSApp.keyWindow == nil, let pid = frontmost.processIdentifier else { return false }
            return embeddedTerminal.hasFocus(in: pid, of: frontmost.bundleID)
        },
        fileDialog: { [quickSwitch] in quickSwitch.perform($0) },
        isClipboardHistoryOn: { [weak self] in self?.clipboard.isEnabled ?? false },
        toggleClipboardHistory: { [weak self] in self?.clipboardPanel.toggle() },
        switchInputSource: { [inputSources] in inputSources.toggle() },
        keyboard: { [keyboardSource] in keyboardSource.keyboard(of: $0) }
    )
    /// The preset, the user's changes to it, and the rules that result. It
    /// hands each new set straight to the dispatcher, so a switch flipped in
    /// the window takes effect on the next key press.
    lazy var rules = RulesController(
        capture: { [dispatcher] recorder in dispatcher.recorder = recorder },
        applyWheelDirection: { [dispatcher] direction in dispatcher.wheelDirection = direction },
        applyDockClick: { [dockClick] minimizes in dockClick.isEnabled = minimizes },
        applyCtrlClick: { [dispatcher] ctrlClick in dispatcher.ctrlClick = ctrlClick },
        applyKeyboards: { [dispatcher] profiles in dispatcher.keyboardProfiles = profiles },
        apply: { [dispatcher] rules in dispatcher.rules = rules }
    )
    lazy var eventTap = EventTap(dispatcher: dispatcher)
    /// Notes shortcuts for a report while the user has it on (KB-247).
    lazy var recorder = DiagnosticRecorder { [dispatcher] trace in dispatcher.trace = trace }
    /// This launch's log, kept for the reports of later launches (KB-247).
    let logArchive = LogArchive()
    private var logArchiveTimer: Timer?
    lazy var engine = EngineController(permissions: permissionMonitor, tap: eventTap)
    let loginItem: LoginItem = {
        #if DEBUG
        if let standIn = LayoutCheck.loginItem { return standIn }
        #endif
        return LoginItem(isAvailable: LoginItem.isInApplicationsFolder)
    }()
    lazy var onboarding = OnboardingController(permissions: permissionMonitor, loginItem: loginItem)
    let updates = UpdateController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        logLaunchState()
        startLogArchive()
        // Before anything starts: moving quits this copy and opens the one in
        // Applications, which then starts properly, guide and all (KB-233).
        if MoveToApplications.offerAtLaunch(location: updates.location) { return }
        // Reading the configuration installs the first set of rules.
        _ = rules.effectiveRules
        permissionMonitor.start()
        electronAccessibility.start()
        secureInput.start()
        otherRemappers.start()
        keyboards.onChange = { [rules] in rules.setConnectedKeyboards($0) }
        keyboards.start()
        clipboard.togglePanel = { [clipboardPanel] in clipboardPanel.toggle() }
        // The path box (KB-213) went in SK-276; its settings go with it.
        for key in ["pathBox.enabled", "pathBox.hotKey"] { UserDefaults.standard.removeObject(forKey: key) }
        var isFinderFront = frontmost.bundleID == BuiltInRules.finderID
        frontmost.onChange = { [quickSwitch] bundleID in
            // Finder's recent folders are taken in as Finder leaves the
            // front, so the history keeps roughly the order things happened.
            let isFinder = bundleID == BuiltInRules.finderID
            if isFinderFront, !isFinder { quickSwitch.mergeFinderRecents() }
            isFinderFront = isFinder
        }
        dispatcher.leftMouse = { [dockClick] event, type in
            let now = ProcessInfo.processInfo.systemUptime
            if type == .leftMouseDown {
                dockClick.mouseDown(at: event.location, flags: event.flags, time: now)
            } else {
                dockClick.mouseUp(at: event.location, time: now)
            }
        }
        engine.update()
        updates.start()
        SettingsImportNotice.showIfNeeded()

        #if DEBUG
        if engine.isActive {
            EventTapSelfTest.runIfRequested(dispatcher: dispatcher)
        }
        LayoutCheck.showRequestedWindow(clipboardPanel: clipboardPanel)
        DockWindow.selfTest()
        WindowElement.selfTest()
        WindowElement.snapSelfTest()
        FinderFolder.selfTest()
        FileDialog.selfTest { [quickSwitch] in quickSwitch.perform($0) }
        if let name = ProcessInfo.processInfo.environment["KB_DEBUG_SYSACTION"],
           let function = SystemAction(rawValue: name) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [dispatcher] in
                Logger.engine.notice("sysaction selftest \(name, privacy: .public)")
                dispatcher.selfTestTrigger(function)
            }
        }
        // Writes the report the About page exports, without the save panel.
        if let path = ProcessInfo.processInfo.environment["KB_DEBUG_DIAGNOSTICS"] {
            Task { [self] in
                try? await Task.sleep(for: .seconds(3))
                let report = await DiagnosticReport.collect(engine: engine, rules: rules, secureInput: secureInput,
                                                            otherRemappers: otherRemappers, clipboard: clipboard,
                                                            loginItem: loginItem, keyboards: keyboards,
                                                            locations: quickSwitch.locations,
                                                            updates: updates, recorder: recorder, logArchive: logArchive)
                try? report.text.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        eventTap.stop()
        logArchive.copyNewEntries()
    }

    /// Copies the log into this launch's file every two minutes, off the
    /// main thread, so a report made after a restart still has it.
    private func startLogArchive() {
        let archive = logArchive
        DispatchQueue.global(qos: .utility).async {
            archive.prune()
            archive.copyNewEntries()
        }
        logArchiveTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in
            DispatchQueue.global(qos: .utility).async { archive.copyNewEntries() }
        }
    }

    /// Opening SameKeys again while it runs, from Finder or Spotlight, shows
    /// the main window. On a MacBook with a full menu bar the notch can hide
    /// the status item, and this is then the only way in.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // SameKeys bringing its own window forward (`WindowID.bringToFront`).
        guard !WindowID.isActivatingItself else { return false }
        NotificationCenter.default.post(name: .openMainWindow, object: nil)
        return false
    }

    /// Choices from the Finder extension's menu arrive as samekeys:// URLs
    /// (KB-210). Any app can open one, so only the extension's are carried
    /// out (KB-254).
    func application(_ application: NSApplication, open urls: [URL]) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        guard FinderMenuSender.isFinderExtension(event) else {
            Logger.finderMenu.error(
                "Ignored \(urls.count, privacy: .public) samekeys:// request(s) from \(FinderMenuSender.describe(event), privacy: .public)"
            )
            return
        }
        for url in urls {
            FinderMenuHandler.handle(url) { [quickSwitch] in quickSwitch.locations.setFavorite($0, true) }
        }
    }

    /// Records the version and permission state at launch, so a user's setup
    /// can be diagnosed from the system log.
    private func logLaunchState() {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        Logger.permissions.notice(
            "SameKeys \(version, privacy: .public) on macOS \(DiagnosticReport.systemVersion, privacy: .public)"
        )
        for permission in Permission.allCases {
            let status = permissionMonitor.status(of: permission)
            Logger.permissions.notice(
                "\(permission.rawValue, privacy: .public): \(status.rawValue, privacy: .public)"
            )
        }
        // Which copy this is matters as much: a login item can point at
        // another one, and one signed differently has none of these grants.
        Logger.permissions.notice(
            "Open at login: \(self.loginItem.summary, privacy: .public), running from \(Bundle.main.bundlePath, privacy: .public)"
        )
    }
}

extension Notification.Name {
    /// Asks the SwiftUI side to open the main window, which only a view can do.
    static let openMainWindow = Notification.Name("SameKeysOpenMainWindow")
}
