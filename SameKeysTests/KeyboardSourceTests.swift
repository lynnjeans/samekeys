import CoreGraphics
import Foundation
import IOKit
import Testing

@MainActor
@Suite struct KeyboardSourceTests {
    private static let external = Keyboard(vendorID: 0x000E, productID: 0x3412, name: "RK-KB5.0", isBuiltIn: false)

    /// A source whose registry holds `keyboards`, and the IDs it was asked for.
    private func source(_ keyboards: [UInt64: Keyboard]) -> (KeyboardSource, () -> [UInt64]) {
        final class Asked: @unchecked Sendable { var ids: [UInt64] = [] }
        let asked = Asked()
        let source = KeyboardSource { id in
            asked.ids.append(id)
            return keyboards[id]
        }
        return (source, { asked.ids })
    }

    @Test func registryPropertiesBecomeAKeyboard() {
        let keyboard = Keyboard(properties: ["VendorID": 14, "ProductID": 13330, "Product": "RK-KB5.0 ", "PrimaryUsage": 6])
        #expect(keyboard == Self.external, "The padding of the name goes")

        let builtIn = Keyboard(properties: ["VendorID": 0, "ProductID": 0, "Product": "Apple Internal Keyboard / Trackpad", "Built-In": true])
        #expect(builtIn.isBuiltIn && builtIn.vendorID == 0)

        let bare = Keyboard(properties: [:])
        #expect(bare == Keyboard(vendorID: 0, productID: 0, name: "", isBuiltIn: false))
    }

    @Test func theEventsSenderNamesItsKeyboard() throws {
        let (source, asked) = source([0x1000035D4: Self.external])
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        event.flags = []
        event.setIntegerValueField(try #require(CGEventField(rawValue: 87)), value: 0x1000035D4)
        #expect(event.senderID == 0x1000035D4)
        #expect(source.keyboard(of: event) == Self.external)
        #expect(asked() == [0x1000035D4])
    }

    @Test func anEventPostedBySoftwareHasNoKeyboard() throws {
        let (source, asked) = source([:])
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        event.flags = []
        #expect(event.senderID == 0)
        #expect(source.keyboard(of: event) == nil)
        #expect(asked().isEmpty, "No sender, nothing to look up")
    }

    @Test func theRegistryIsReadOnceForEachSender() {
        let (source, asked) = source([7: Self.external])
        let found = (0..<3).map { _ in source.keyboard(ofSender: 7) }
        let missing = (0..<3).map { _ in source.keyboard(ofSender: 8) }
        #expect(found == [Self.external, Self.external, Self.external])
        #expect(missing == [nil, nil, nil])
        #expect(asked() == [7, 8], "A sender that is no keyboard is remembered too")
    }

    @Test func aRunOfNothingButMissesStopsLooking() {
        let (source, asked) = source([1000: Self.external])
        for id in 1...UInt64(KeyboardSource.missLimit) {
            #expect(!source.hasGivenUp)
            _ = source.keyboard(ofSender: id)
        }
        #expect(source.hasGivenUp)
        let late = source.keyboard(ofSender: 1000)
        #expect(late == nil, "The field holds something else on this system")
        #expect(asked().count == KeyboardSource.missLimit)
    }

    @Test func missesAfterAKeyboardWasFoundDoNotStopIt() {
        let (source, asked) = source([1000: Self.external, 2000: Self.external])
        _ = source.keyboard(ofSender: 1000)
        for id in 1...UInt64(KeyboardSource.missLimit + 4) { _ = source.keyboard(ofSender: id) }
        #expect(!source.hasGivenUp)
        let reconnected = source.keyboard(ofSender: 2000)
        #expect(reconnected == Self.external)
        #expect(asked().last == 2000)
    }

    @Test func manyReconnectionsDoNotGrowWithoutEnd() {
        let keyboards = Dictionary(uniqueKeysWithValues: (1...200).map { (UInt64($0), Self.external) })
        let (source, asked) = source(keyboards)
        for id in 1...UInt64(200) { _ = source.keyboard(ofSender: id) }
        let again = source.keyboard(ofSender: 200)
        #expect(again == Self.external)
        #expect(asked().count == 200, "The latest sender is still known after the older ones were dropped")
    }

    @Test func onlyAHIDEntryInTheRegistryIsAKeyboard() {
        var rootID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IORegistryGetRootEntry(kIOMainPortDefault), &rootID)
        #expect(rootID != 0)
        #expect(KeyboardSource.keyboard(ofRegistryEntry: rootID) == nil, "An entry, but not a HID one")
        #expect(KeyboardSource.keyboard(ofRegistryEntry: 0xDEAD_BEEF_0000) == nil, "No such entry")
    }
}
