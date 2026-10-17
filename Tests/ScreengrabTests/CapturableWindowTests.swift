import CoreGraphics
import Testing
@testable import Screengrab

@Suite struct CapturableWindowTests {
    private func entry(layer: Int = 0, pid: pid_t = 42, alpha: Double = 1,
                       frame: CGRect = CGRect(x: 10, y: 20, width: 300, height: 200)) -> [String: Any] {
        [
            kCGWindowNumber as String: CGWindowID(7),
            kCGWindowLayer as String: layer,
            kCGWindowOwnerPID as String: pid,
            kCGWindowAlpha as String: alpha,
            kCGWindowBounds as String: frame.dictionaryRepresentation,
        ]
    }

    @Test func keepsVisibleNormalWindowsOfOtherApps() {
        let window = CapturableWindow(info: entry(), ownPID: 1)
        #expect(window?.id == 7)
        #expect(window?.frame == CGRect(x: 10, y: 20, width: 300, height: 200))
    }

    @Test func dropsOwnMenuBarDockHiddenAndTinyWindows() {
        #expect(CapturableWindow(info: entry(pid: 1), ownPID: 1) == nil)
        #expect(CapturableWindow(info: entry(layer: 24), ownPID: 1) == nil)
        #expect(CapturableWindow(info: entry(layer: 20), ownPID: 1) == nil)
        #expect(CapturableWindow(info: entry(alpha: 0), ownPID: 1) == nil)
        #expect(CapturableWindow(info: entry(frame: CGRect(x: 0, y: 0, width: 4, height: 400)), ownPID: 1) == nil)
    }

    @Test func flipsBetweenCocoaAndQuartzGlobalSpace() {
        // A display stacked above a 1440-point-tall primary has negative Quartz y.
        let cocoa = CGRect(x: 100, y: 1500, width: 200, height: 100)
        let quartz = cocoa.flippedGlobal(primaryHeight: 1440)
        #expect(quartz == CGRect(x: 100, y: -160, width: 200, height: 100))
        #expect(quartz.flippedGlobal(primaryHeight: 1440) == cocoa)
        #expect(CGPoint(x: 5, y: 1440).flippedGlobal(primaryHeight: 1440) == CGPoint(x: 5, y: 0))
    }
}
