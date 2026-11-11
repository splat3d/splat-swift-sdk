import CoreGraphics
import XCTest

// MARK: - Tap-to-point tests
//
// The SplatCapture picker's math, PickGeometry.swift beside this file. The
// package builds both as one test target (Package.swift), so `swift test`
// runs them; the app's Xcode project compiles PickGeometry.swift alone.

final class PickGeometryTests: XCTestCase {

    private static let accuracy: CGFloat = 1e-9

    /// SplatScanner's frame as stored, and as a player shows it.
    private static let stored = CGSize(width: 1920, height: 1440)
    private static let upright = CGSize(width: 1440, height: 1920)

    private func assertEqual(_ point: CGPoint?, _ expected: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
        guard let point else {
            return XCTFail("Expected \(expected), got nil", file: file, line: line)
        }
        XCTAssertEqual(point.x, expected.x, accuracy: Self.accuracy, file: file, line: line)
        XCTAssertEqual(point.y, expected.y, accuracy: Self.accuracy, file: file, line: line)
    }

    private func assertEqual(_ size: CGSize, _ expected: CGSize, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(size.width, expected.width, accuracy: Self.accuracy, file: file, line: line)
        XCTAssertEqual(size.height, expected.height, accuracy: Self.accuracy, file: file, line: line)
    }

    // MARK: - Displayed size

    func testTurnedTrackShowsUpright() {
        // What SplatScanner writes: a quarter turn, no translation.
        let quarterTurn = CGAffineTransform(rotationAngle: .pi / 2)
        // What the Camera app writes for portrait: the same turn, moved back
        // into view.
        let cameraPortrait = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1440, ty: 0)

        assertEqual(PickGeometry.displaySize(naturalSize: Self.stored, transform: quarterTurn), Self.upright)
        assertEqual(PickGeometry.displaySize(naturalSize: Self.stored, transform: cameraPortrait), Self.upright)
    }

    func testUnturnedTrackKeepsItsSize() {
        let halfTurn = CGAffineTransform(rotationAngle: .pi)

        assertEqual(PickGeometry.displaySize(naturalSize: Self.stored, transform: .identity), Self.stored)
        assertEqual(PickGeometry.displaySize(naturalSize: Self.stored, transform: halfTurn), Self.stored)
    }

    // MARK: - Letterbox

    func testPortraitVideoInLandscapeBox() {
        // 1440 × 1920 fitted into 800 × 400 is 300 × 400, with 250 pt bars
        // left and right.
        let rect = PickGeometry.videoRect(displaySize: Self.upright, in: CGSize(width: 800, height: 400))

        XCTAssertEqual(rect.minX, 250, accuracy: Self.accuracy)
        XCTAssertEqual(rect.minY, 0, accuracy: Self.accuracy)
        assertEqual(rect.size, CGSize(width: 300, height: 400))

        assertEqual(PickGeometry.fraction(of: CGPoint(x: 400, y: 200), in: rect), CGPoint(x: 0.5, y: 0.5))
        assertEqual(PickGeometry.fraction(of: CGPoint(x: 250, y: 0), in: rect), CGPoint(x: 0, y: 0))
        assertEqual(PickGeometry.fraction(of: CGPoint(x: 550, y: 400), in: rect), CGPoint(x: 1, y: 1))
        assertEqual(PickGeometry.fraction(of: CGPoint(x: 325, y: 300), in: rect), CGPoint(x: 0.25, y: 0.75))
    }

    func testLandscapeVideoInPortraitBox() {
        // 1920 × 1440 fitted into 390 × 700 is 390 × 292.5, with 203.75 pt
        // bars above and below.
        let rect = PickGeometry.videoRect(displaySize: Self.stored, in: CGSize(width: 390, height: 700))

        XCTAssertEqual(rect.minX, 0, accuracy: Self.accuracy)
        XCTAssertEqual(rect.minY, 203.75, accuracy: Self.accuracy)
        assertEqual(rect.size, CGSize(width: 390, height: 292.5))

        assertEqual(PickGeometry.fraction(of: CGPoint(x: 195, y: 350), in: rect), CGPoint(x: 0.5, y: 0.5))
        assertEqual(PickGeometry.fraction(of: CGPoint(x: 97.5, y: 276.875), in: rect), CGPoint(x: 0.25, y: 0.25))
    }

    func testTapOnTheBarsIsNoPoint() {
        let sideBars = PickGeometry.videoRect(displaySize: Self.upright, in: CGSize(width: 800, height: 400))
        let topBars = PickGeometry.videoRect(displaySize: Self.stored, in: CGSize(width: 390, height: 700))

        XCTAssertNil(PickGeometry.fraction(of: CGPoint(x: 249, y: 200), in: sideBars))
        XCTAssertNil(PickGeometry.fraction(of: CGPoint(x: 551, y: 200), in: sideBars))
        XCTAssertNil(PickGeometry.fraction(of: CGPoint(x: 195, y: 203), in: topBars))
        XCTAssertNil(PickGeometry.fraction(of: CGPoint(x: 195, y: 497), in: topBars))
    }

    func testSameShapeFillsTheBox() {
        let rect = PickGeometry.videoRect(displaySize: Self.upright, in: CGSize(width: 360, height: 480))

        XCTAssertEqual(rect.minX, 0, accuracy: Self.accuracy)
        XCTAssertEqual(rect.minY, 0, accuracy: Self.accuracy)
        assertEqual(rect.size, CGSize(width: 360, height: 480))
    }

    func testNothingToTapBeforeLayout() {
        let noBox = PickGeometry.videoRect(displaySize: Self.upright, in: .zero)
        let noVideo = PickGeometry.videoRect(displaySize: .zero, in: CGSize(width: 390, height: 700))

        XCTAssertEqual(noBox, .zero)
        XCTAssertEqual(noVideo, .zero)
        XCTAssertNil(PickGeometry.fraction(of: .zero, in: noBox))
    }

    // MARK: - Drawing a point back

    func testPositionIsWhereThePointWasTapped() {
        let rect = PickGeometry.videoRect(displaySize: Self.upright, in: CGSize(width: 800, height: 400))
        let tap = CGPoint(x: 310, y: 123)

        let fraction = PickGeometry.fraction(of: tap, in: rect)

        assertEqual(fraction.map { PickGeometry.position(of: $0, in: rect) }, tap)
    }
}
