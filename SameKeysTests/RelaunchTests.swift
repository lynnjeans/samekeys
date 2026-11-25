import Testing

struct RelaunchTests {
    @Test func readsThePreviousCopyFromTheArguments() {
        #expect(Relaunch.previousCopy(in: ["SameKeys", "--previous-pid", "4242", "--reopen-guide"]) == 4242)
        #expect(Relaunch.previousCopy(in: ["SameKeys", "--reopen-guide"]) == nil)
        #expect(Relaunch.previousCopy(in: ["SameKeys", "--previous-pid"]) == nil)
        #expect(Relaunch.previousCopy(in: ["SameKeys", "--previous-pid", "x"]) == nil)
    }

    @Test @MainActor func runsAtOnceWithoutAPreviousCopy() {
        var ran = false
        Relaunch.afterPreviousCopyQuits(arguments: ["SameKeys"]) { ran = true }
        #expect(ran)
    }

    @Test @MainActor func runsAtOnceWhenThePreviousCopyIsGone() {
        var ran = false
        // No process has this ID.
        Relaunch.afterPreviousCopyQuits(arguments: ["SameKeys", "--previous-pid", "99999"]) { ran = true }
        #expect(ran)
    }
}
