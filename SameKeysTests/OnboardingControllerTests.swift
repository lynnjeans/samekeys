import Foundation
import IOKit.hid
import Testing

@MainActor
@Suite struct OnboardingControllerTests {
    let fake = FakePermissions()
    let loginItems = FakeLoginItems()
    let defaults: UserDefaults

    /// Every URL the guide sent the user to, and every time it was opened.
    final class Record {
        var urls: [URL] = []
        var presentations = 0
    }
    let record = Record()

    init() {
        let suite = "OnboardingControllerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    func grantAll() {
        fake.accessibility = true
        fake.inputMonitoring = kIOHIDAccessTypeGranted
    }

    func makeController(inApplications: Bool = true, launchArguments: [String] = []) -> (OnboardingController, PermissionMonitor) {
        let monitor = PermissionMonitor(service: fake.service)
        let controller = OnboardingController(
            permissions: monitor,
            loginItem: LoginItem(isAvailable: inApplications, system: loginItems.system),
            service: fake.service,
            defaults: defaults,
            openURL: { [record] in record.urls.append($0) },
            presentGuide: { [record] in record.presentations += 1 },
            launchArguments: launchArguments
        )
        return (controller, monitor)
    }

    @Test func startsAtAccessibilityWithNothingGranted() {
        let (controller, _) = makeController()
        #expect(controller.shouldOpenAtLaunch())
        #expect(controller.step == .accessibility)
        #expect(controller.step.number == 1)
    }

    @Test func advancesOnItsOwnAsPermissionsAreGranted() {
        let (controller, monitor) = makeController()

        fake.accessibility = true
        monitor.refresh()
        #expect(controller.step == .inputMonitoring, "The grant moves the guide on with no interaction")

        fake.inputMonitoring = kIOHIDAccessTypeGranted
        monitor.refresh()
        #expect(controller.step == .ready)
        #expect(record.presentations == 0, "Advancing opens nothing; the window is already up")
    }

    @Test func stepsBackWhenAPermissionIsRevoked() {
        grantAll()
        let (controller, monitor) = makeController()
        #expect(controller.step == .ready)

        fake.accessibility = false
        monitor.refresh(fresh: true)
        #expect(controller.step == .accessibility)
    }

    @Test func inputMonitoringIsAskedForEvenWhenNeverDetermined() {
        fake.accessibility = true
        let (controller, _) = makeController()
        #expect(fake.inputMonitoring == kIOHIDAccessTypeUnknown)
        #expect(controller.step == .inputMonitoring)
    }

    @Test func opensTheAuthorizationPaneForTheCurrentStep() {
        let (controller, monitor) = makeController()
        controller.openSettings()
        #expect(fake.requests.isEmpty, "Accessibility is never prompted for; the launch check lists SameKeys")
        #expect(record.urls == [Permission.accessibility.settingsURL])
        #expect(record.urls.last?.absoluteString.contains("Privacy_Accessibility") == true)

        fake.accessibility = true
        monitor.refresh()
        controller.openSettings()
        #expect(fake.requests == [.inputMonitoring], "Requesting is what puts SameKeys in this list")
        #expect(record.urls.last == Permission.inputMonitoring.settingsURL)
        #expect(record.urls.last?.absoluteString.contains("Privacy_ListenEvent") == true)
    }

    @Test func requestsInputMonitoringOnReachingItsStep() {
        let (controller, monitor) = makeController()
        controller.requestInputMonitoringIfNeeded()
        #expect(fake.requests.isEmpty, "Nothing is requested on the Accessibility step")

        fake.accessibility = true
        monitor.refresh()
        // The system grants it silently while the request is made.
        fake.inputMonitoring = kIOHIDAccessTypeGranted
        controller.requestInputMonitoringIfNeeded()
        #expect(fake.requests == [.inputMonitoring])
        #expect(record.urls.isEmpty, "Requesting on its own opens no pane")
        #expect(controller.step == .ready, "A silent grant shows at once, not on the next poll")
    }

    @Test func requestsInputMonitoringOnlyOnceAndOnlyWhenUndecided() {
        fake.accessibility = true
        let (controller, _) = makeController()
        controller.requestInputMonitoringIfNeeded()
        controller.requestInputMonitoringIfNeeded()
        #expect(fake.requests == [.inputMonitoring], "An alert must not come back every time the step shows")

        fake.inputMonitoring = kIOHIDAccessTypeDenied
        let (denied, _) = makeController()
        denied.requestInputMonitoringIfNeeded()
        #expect(fake.requests == [.inputMonitoring], "The system ignores a request once denied")
    }

    @Test func theClosingStepHasNothingToOpen() {
        grantAll()
        let (controller, _) = makeController()
        controller.openSettings()
        #expect(fake.requests.isEmpty)
        #expect(record.urls.isEmpty)
    }

    @Test func doesNotComeBackOnceCompletedWithOnePermissionMissing() {
        let (first, _) = makeController()
        #expect(first.shouldOpenAtLaunch())
        first.complete()
        #expect(first.hasCompleted)

        fake.accessibility = true
        let (second, _) = makeController()
        #expect(!second.shouldOpenAtLaunch(), "Input Monitoring may have been turned off on purpose")
    }

    /// SK-303: a language picked in the guide restarts SameKeys, and the
    /// guide comes back even where a plain launch would leave it closed.
    @Test func comesBackAfterARestartFromTheGuide() {
        grantAll()
        defaults.set(true, forKey: OnboardingController.completedKey)
        let (controller, _) = makeController(launchArguments: ["SameKeys", OnboardingController.reopenArgument])
        #expect(controller.shouldOpenAtLaunch())
        #expect(controller.step == .ready)
        #expect(!controller.shouldOpenAtLaunch(), "Still once per run")
    }

    @Test func aFirstRunRestartedOnTheClosingStepIsNotMarkedDone() {
        grantAll()
        let (controller, _) = makeController(launchArguments: [OnboardingController.reopenArgument])
        #expect(controller.shouldOpenAtLaunch())
        #expect(!controller.hasCompleted)
    }

    /// SK-269: a new signature or a reset leaves SameKeys with nothing, and
    /// the menu bar alone is easy to miss.
    @Test func comesBackOnceCompletedWhenBothPermissionsAreGone() {
        defaults.set(true, forKey: OnboardingController.completedKey)
        let (controller, _) = makeController()
        #expect(controller.shouldOpenAtLaunch())
        #expect(controller.step == .accessibility)
        #expect(!controller.shouldOpenAtLaunch(), "Still once per run")
    }

    @Test func aFirstRunWithEverythingGrantedIsSilentlyDone() {
        grantAll()
        let (controller, _) = makeController()
        #expect(!controller.shouldOpenAtLaunch())
        #expect(controller.hasCompleted)
    }

    @Test func theLaunchDecisionIsMadeOnlyOnce() {
        let (controller, _) = makeController()
        #expect(controller.shouldOpenAtLaunch())
        #expect(!controller.shouldOpenAtLaunch(), "Put aside once, it does not come back mid-run")
    }

    @Test func canBeOpenedAgainAfterCompleting() {
        let (controller, _) = makeController()
        controller.complete()
        controller.open()
        #expect(record.presentations == 1, "The menu bar and the Overview lead back in")
    }

    // MARK: Open at Login (KB-242)

    @Test func finishingAFirstRunOpensSameKeysAtLogin() {
        grantAll()
        let (controller, _) = makeController()
        #expect(controller.opensAtLogin, "Ticked unless the user unticks it")
        controller.finish()
        #expect(loginItems.calls == ["register"])
        #expect(controller.hasCompleted)
    }

    @Test func finishingWithTheChoiceUntickedRegistersNothing() {
        grantAll()
        let (controller, _) = makeController()
        controller.opensAtLogin = false
        controller.finish()
        #expect(loginItems.calls.isEmpty)
        #expect(controller.hasCompleted)
    }

    @Test func aFirstRunThatNeedsNoGuideRegistersNothing() {
        grantAll()
        let (controller, _) = makeController()
        #expect(!controller.shouldOpenAtLaunch())
        #expect(controller.hasCompleted)
        #expect(loginItems.calls.isEmpty, "Nobody was asked")
    }

    @Test func theGuideOpenedAgainShowsWhatTheSystemHas() {
        grantAll()
        defaults.set(true, forKey: OnboardingController.completedKey)
        let (controller, _) = makeController()
        #expect(!controller.opensAtLogin, "Someone who finished the guide before is not signed up by it")
        controller.finish()
        #expect(loginItems.calls.isEmpty)

        loginItems.isEnabled = true
        controller.open()
        #expect(controller.opensAtLogin, "Switched on elsewhere since")
        controller.opensAtLogin = false
        controller.finish()
        #expect(loginItems.calls == ["unregister"], "Unticking it there is a choice like any other")
    }

    @Test func aCopyOutsideApplicationsIsNotRegisteredByTheGuide() {
        grantAll()
        let (controller, _) = makeController(inApplications: false)
        controller.finish()
        #expect(loginItems.calls.isEmpty)
        #expect(loginItems.reads == 0)
        #expect(controller.hasCompleted)
    }

    @Test func aRefusedLoginItemDoesNotHoldUpTheGuide() {
        grantAll()
        loginItems.refuses = true
        let (controller, _) = makeController()
        controller.finish()
        #expect(controller.hasCompleted)
        #expect(controller.loginItem.hasFailed, "The Overview says so")
    }
}
