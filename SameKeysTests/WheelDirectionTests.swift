import CoreGraphics
import Foundation
import Testing

@MainActor
@Suite struct WheelDirectionTests {
    @Test func onlyWheelsUnderNaturalScrollingAreReversed() {
        #expect(WheelDirection.windows.reverses(source: .notchedWheel, isNatural: true))
        #expect(WheelDirection.windows.reverses(source: .smoothWheel, isNatural: true))
        #expect(!WheelDirection.windows.reverses(source: .gesture, isNatural: true), "The trackpad keeps its setting")
        #expect(!WheelDirection.windows.reverses(source: .notchedWheel, isNatural: false), "Already the Windows way")
        #expect(!WheelDirection.system.reverses(source: .notchedWheel, isNatural: true))
    }

    @Test func reversingFlipsEveryFormOfTheDistance() throws {
        let event = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 3, wheel2: -1, wheel3: 0
        ))
        event.flags = []
        let before = (
            event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
            event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
            event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
            event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        )
        #expect(before.0 == 3 && before.3 == -1)
        event.reverseScroll()
        #expect(event.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -before.0)
        #expect(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) == -before.1)
        #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -before.2)
        #expect(event.getIntegerValueField(.scrollWheelEventDeltaAxis2) == 1)
    }

    @Test func theChoiceReachesTheEngineAndIsSaved() {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SameKeysTests-\(UUID().uuidString)")
        let store = ConfigurationStore(fileURL: folder.appending(path: "config.json"))
        var applied: [WheelDirection] = []
        let controller = RulesController(store: store, applyWheelDirection: { applied.append($0) })
        #expect(applied == [.system], "The engine learns it at launch")

        controller.setWheelDirection(.windows)
        #expect(applied.last == .windows)
        #expect(RulesController(store: store).wheelDirection == .windows)
    }

    @Test func olderFilesScrollTheSystemsWay() throws {
        let older = Data(#"{"schemaVersion": 1, "overrides": []}"#.utf8)
        #expect(try JSONDecoder().decode(Configuration.self, from: older).wheelDirection == .system)
    }
}
