import CoreGraphics
import Testing
@testable import Screengrab

@Suite struct SelectionMoveTests {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let anchor = CGPoint(x: 100, y: 200)
    private let current = CGPoint(x: 300, y: 350)

    private func move(_ dx: CGFloat, _ dy: CGFloat) -> (anchor: CGPoint, current: CGPoint) {
        movedSelection(anchor: anchor, current: current, by: CGPoint(x: dx, y: dy), within: bounds)
    }

    @Test func movesBothPointsInsideBounds() {
        let moved = move(40, -30)
        #expect(moved.anchor == CGPoint(x: 140, y: 170))
        #expect(moved.current == CGPoint(x: 340, y: 320))
    }

    @Test func stopsAtTheLeftEdge() {
        let moved = move(-500, 0)
        #expect(moved.anchor == CGPoint(x: 0, y: 200))
        #expect(moved.current == CGPoint(x: 200, y: 350))
    }

    @Test func stopsAtTheRightEdge() {
        let moved = move(900, 0)
        #expect(moved.anchor == CGPoint(x: 800, y: 200))
        #expect(moved.current == CGPoint(x: 1000, y: 350))
    }

    @Test func stopsAtTheBottomEdge() {
        let moved = move(0, -500)
        #expect(moved.anchor == CGPoint(x: 100, y: 0))
        #expect(moved.current == CGPoint(x: 300, y: 150))
    }

    @Test func stopsAtTheTopEdge() {
        let moved = move(0, 900)
        #expect(moved.anchor == CGPoint(x: 100, y: 650))
        #expect(moved.current == CGPoint(x: 300, y: 800))
    }

    @Test func keepsOrientationWhenAnchorIsTopRight() {
        let moved = movedSelection(anchor: CGPoint(x: 300, y: 350), current: CGPoint(x: 100, y: 200), by: CGPoint(x: -500, y: 10), within: bounds)
        #expect(moved.anchor == CGPoint(x: 200, y: 360))
        #expect(moved.current == CGPoint(x: 0, y: 210))
    }

    @Test func zeroDeltaReturnsTheSamePoints() {
        let moved = move(0, 0)
        #expect(moved.anchor == anchor)
        #expect(moved.current == current)
    }
}
