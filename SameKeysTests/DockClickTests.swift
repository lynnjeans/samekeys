import CoreGraphics
import Foundation
import Testing

@MainActor
@Suite struct DockClickTests {
    /// A Dock watcher whose lookup finds "window" wherever it is asked and
    /// whose scheduled work runs at once, recording what it minimized.
    @MainActor private final class Harness {
        var minimized: [String] = []
        var lookups: [CGPoint] = []
        var found: String? = "window"
        lazy var click = DockClick<String>(
            lookUp: { [unowned self] point in lookups.append(point); return found },
            minimize: { [unowned self] in minimized.append($0) },
            schedule: { _, work in work() }
        )
    }

    private let icon = CGPoint(x: 700, y: 1100)

    @Test func aClickOnTheFrontAppsIconMinimizesItsWindow() {
        let harness = Harness()
        harness.click.mouseDown(at: icon, flags: [], time: 10)
        harness.click.mouseUp(at: icon, time: 10.1)
        #expect(harness.lookups == [icon])
        #expect(harness.minimized == ["window"])
    }

    @Test func nothingIsMinimizedWhenTheLookupFindsNothing() {
        // Not the Dock, a background app's icon, or no visible window: the
        // second click on a minimized app lands here, and the Dock restores.
        let harness = Harness()
        harness.found = nil
        harness.click.mouseDown(at: icon, flags: [], time: 10)
        harness.click.mouseUp(at: icon, time: 10.1)
        #expect(harness.minimized.isEmpty)
    }

    @Test func draggingAnIconIsNotAClick() {
        let harness = Harness()
        harness.click.mouseDown(at: icon, flags: [], time: 10)
        harness.click.mouseUp(at: CGPoint(x: icon.x + 30, y: icon.y), time: 10.2)
        #expect(harness.minimized.isEmpty)
    }

    @Test func aSmallWobbleStillCounts() {
        let harness = Harness()
        harness.click.mouseDown(at: icon, flags: [], time: 10)
        harness.click.mouseUp(at: CGPoint(x: icon.x + 2, y: icon.y + 2), time: 10.1)
        #expect(harness.minimized == ["window"])
    }

    @Test func aLongPressOpensTheIconsMenuInstead() {
        let harness = Harness()
        harness.click.mouseDown(at: icon, flags: [], time: 10)
        harness.click.mouseUp(at: icon, time: 11)
        #expect(harness.minimized.isEmpty)
    }

    @Test func modifierClicksKeepTheirDockMeaning() {
        for flags: CGEventFlags in [.maskCommand, .maskAlternate, .maskControl, .maskShift] {
            let harness = Harness()
            harness.click.mouseDown(at: icon, flags: flags, time: 10)
            harness.click.mouseUp(at: icon, time: 10.1)
            #expect(harness.lookups.isEmpty, "No Accessibility query for a modifier click")
            #expect(harness.minimized.isEmpty)
        }
    }

    @Test func switchedOffItOnlyWatches() {
        let harness = Harness()
        harness.click.isEnabled = false
        harness.click.mouseDown(at: icon, flags: [], time: 10)
        harness.click.mouseUp(at: icon, time: 10.1)
        #expect(harness.lookups.isEmpty)
        #expect(harness.minimized.isEmpty)
    }

    @Test func aReleaseWithoutAPressDoesNothing() {
        let harness = Harness()
        harness.click.mouseUp(at: icon, time: 10)
        #expect(harness.minimized.isEmpty)
    }

    @Test func eachClickMinimizesOnce() {
        let harness = Harness()
        harness.click.mouseDown(at: icon, flags: [], time: 10)
        harness.click.mouseUp(at: icon, time: 10.1)
        harness.click.mouseUp(at: icon, time: 10.2)
        #expect(harness.minimized == ["window"])
    }

    @Test func theLeftButtonGoesOnUnchangedAndReachesTheWatcher() throws {
        let dispatcher = Dispatcher(frontmostBundleID: { nil })
        var seen: [CGEventType] = []
        dispatcher.leftMouse = { _, type in seen.append(type) }
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: icon, mouseButton: .left))
            event.flags = []
            guard case .passThrough = dispatcher.process(event, type: type) else {
                Issue.record("A left click must never be changed or swallowed")
                return
            }
        }
        #expect(seen == [.leftMouseDown, .leftMouseUp])
    }

    @Test func theSettingReachesTheEngineAndIsSaved() {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SameKeysTests-\(UUID().uuidString)")
        let store = ConfigurationStore(fileURL: folder.appending(path: "config.json"))
        var applied: [Bool] = []
        let controller = RulesController(store: store, applyDockClick: { applied.append($0) })
        #expect(applied == [true], "On by default, and the engine learns it at launch")

        controller.setDockClickMinimizes(false)
        #expect(applied.last == false)
        #expect(RulesController(store: store).dockClickMinimizes == false)
    }

    @Test func olderFilesHaveItOn() throws {
        let older = Data(#"{"schemaVersion": 1, "overrides": []}"#.utf8)
        #expect(try JSONDecoder().decode(Configuration.self, from: older).dockClickMinimizes)
    }

    @Test func restoringDefaultsKeepsTheChoice() {
        var configuration = Configuration()
        configuration.dockClickMinimizes = false
        configuration.restoreDefaults()
        #expect(configuration.dockClickMinimizes == false)
    }
}
