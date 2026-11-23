import Foundation
import Testing

@MainActor
@Suite struct SecureInputMonitorTests {
    final class State { var reading = SecureInputMonitor.Reading(isOn: false, pid: nil) }

    @Test func followsTheSystemState() {
        let state = State()
        let monitor = SecureInputMonitor { state.reading }
        let start = Date(timeIntervalSince1970: 1_000)

        monitor.refresh(now: start)
        #expect(monitor.holder == nil)

        state.reading = .init(isOn: true, pid: nil)
        monitor.refresh(now: start)
        #expect(monitor.holder?.since == start)
        monitor.refresh(now: start.addingTimeInterval(5))
        #expect(!monitor.isLingering, "Typing a password")

        monitor.refresh(now: start.addingTimeInterval(SecureInputMonitor.lingering))
        #expect(monitor.holder?.since == start, "Still the same holder, the clock keeps running")
        #expect(monitor.isLingering)

        state.reading = .init(isOn: false, pid: nil)
        monitor.refresh()
        #expect(monitor.holder == nil)
        #expect(!monitor.isLingering)
    }

    @Test func knownAppsGetAHowTo() {
        let terminal = SecureInputMonitor.Holder(appName: "Terminal", bundleID: "com.apple.Terminal", since: .now)
        #expect(terminal.switchOffHint?.contains("Secure Keyboard Entry") == true)
        let other = SecureInputMonitor.Holder(appName: "Safari", bundleID: "com.apple.Safari", since: .now)
        #expect(other.switchOffHint == nil)
    }
}

@MainActor
@Suite struct SecureInputBackgroundTests {
    final class State {
        var reading = SecureInputMonitor.Reading(isOn: false, pid: nil)
        var front: SecureInputMonitor.App?
    }
    static let chrome = SecureInputMonitor.App(name: "Google Chrome", bundleID: "com.google.Chrome", pid: 10, isRegular: true)
    static let weChat = SecureInputMonitor.App(name: "WeChat", bundleID: "com.tencent.xinWeChat", pid: 20, isRegular: true)
    static let touchID = SecureInputMonitor.App(name: "LocalAuthentication", bundleID: "com.apple.LocalAuthentication.UIAgent", pid: 30, isRegular: false)

    static func monitor(_ state: State) -> SecureInputMonitor {
        let apps = [chrome, weChat, touchID]
        return SecureInputMonitor(read: { state.reading },
                                  app: { pid in apps.first { $0.pid == pid } },
                                  frontmost: { state.front })
    }

    @Test func keepsTheAppThatTurnedItOn() {
        let state = State()
        let monitor = Self.monitor(state)
        let start = Date(timeIntervalSince1970: 1_000)
        state.front = Self.chrome
        state.reading = .init(isOn: true, pid: 10)
        monitor.refresh(now: start)
        #expect(monitor.holder?.bundleID == "com.google.Chrome")

        // macOS then reports the front app as the holder.
        state.front = Self.weChat
        state.reading = .init(isOn: true, pid: 20)
        monitor.refresh(now: start.addingTimeInterval(1))
        #expect(monitor.holder?.bundleID == "com.google.Chrome")
        #expect(monitor.holder?.since == start)
    }

    @Test func spotsTheHolderLeftInTheBackground() {
        let state = State()
        let monitor = Self.monitor(state)
        let start = Date(timeIntervalSince1970: 1_000)
        state.front = Self.chrome
        state.reading = .init(isOn: true, pid: 10)
        monitor.refresh(now: start)
        monitor.refresh(now: start.addingTimeInterval(10))
        #expect(!monitor.isHeldInBackground, "Typing a password in the front app")

        state.front = Self.weChat
        monitor.refresh(now: start.addingTimeInterval(11))
        monitor.refresh(now: start.addingTimeInterval(13))
        #expect(!monitor.isHeldInBackground, "A quick look elsewhere")
        monitor.refresh(now: start.addingTimeInterval(11 + SecureInputMonitor.backgroundDelay))
        #expect(monitor.isHeldInBackground)

        // Back in Chrome: the bubble goes, the clock starts again next time.
        state.front = Self.chrome
        monitor.refresh(now: start.addingTimeInterval(20))
        #expect(!monitor.isHeldInBackground)
        state.front = Self.weChat
        monitor.refresh(now: start.addingTimeInterval(21))
        #expect(!monitor.isHeldInBackground)

        state.reading = .init(isOn: false, pid: nil)
        monitor.refresh(now: start.addingTimeInterval(30))
        #expect(monitor.holder == nil)
        #expect(!monitor.isHeldInBackground)
    }

    @Test func systemPromptsAreNotLeftInTheBackground() {
        let state = State()
        let monitor = Self.monitor(state)
        let start = Date(timeIntervalSince1970: 1_000)
        state.front = Self.weChat
        state.reading = .init(isOn: true, pid: 30)
        monitor.refresh(now: start)
        monitor.refresh(now: start.addingTimeInterval(60))
        #expect(monitor.holder?.bundleID == "com.apple.LocalAuthentication.UIAgent")
        #expect(!monitor.isHeldInBackground)
    }
}
