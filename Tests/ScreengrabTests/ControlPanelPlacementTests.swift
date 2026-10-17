import CoreGraphics
import Testing
@testable import Screengrab

@Suite struct ControlPanelPlacementTests {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let panel = CGSize(width: 140, height: 360)

    @Test func rightOfTheAreaTopAligned() {
        let origin = controlPanelOrigin(size: panel, area: CGRect(x: 100, y: 200, width: 400, height: 500), visible: screen)
        #expect(origin == CGPoint(x: 512, y: 340))
    }

    @Test func leftWhenTheRightHasNoRoom() {
        let origin = controlPanelOrigin(size: panel, area: CGRect(x: 400, y: 200, width: 500, height: 500), visible: screen)
        #expect(origin == CGPoint(x: 248, y: 340))
    }

    @Test func belowAndCenteredWhenNeitherSideHasRoom() {
        let origin = controlPanelOrigin(size: panel, area: CGRect(x: 50, y: 400, width: 900, height: 380), visible: screen)
        #expect(origin == CGPoint(x: 430, y: 28))
    }

    @Test func aboveWhenBelowHasNoRoomEither() {
        let origin = controlPanelOrigin(size: panel, area: CGRect(x: 50, y: 20, width: 900, height: 400), visible: screen)
        #expect(origin == CGPoint(x: 430, y: 432))
    }

    @Test func insideTheBottomRightCornerOfAFullScreenArea() {
        let origin = controlPanelOrigin(size: panel, area: screen, visible: screen)
        #expect(origin == CGPoint(x: 848, y: 12))
    }

    @Test func staysOnScreenWhenTheAreaTopIsLow() {
        let origin = controlPanelOrigin(size: panel, area: CGRect(x: 100, y: 10, width: 300, height: 100), visible: screen)
        #expect(origin == CGPoint(x: 412, y: 0))
    }

    @Test func respectsAnOffsetScreen() {
        let left = CGRect(x: -1470, y: 484, width: 1470, height: 900)
        let origin = controlPanelOrigin(size: panel, area: CGRect(x: -1400, y: 600, width: 600, height: 600), visible: left)
        #expect(origin == CGPoint(x: -788, y: 840))
    }
}
