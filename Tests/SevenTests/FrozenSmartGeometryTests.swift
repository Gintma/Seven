import Foundation
import XCTest
@testable import Seven

final class FrozenSmartGeometryTests: XCTestCase {
    func testRetinaPointsAcrossLoggedBoundaryStayInTheirPhysicalPixelAndHalfOpenRow() {
        let geometry = FrozenSmartGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            pixelSize: CGSize(width: 3840, height: 2160), primaryScreenTop: 1080)
        let upper = CGRect(x: 707, y: 455, width: 526, height: 36)
        let lower = CGRect(x: 707, y: 419, width: 526, height: 36)
        for y: CGFloat in [454.98828125, 454.76171875] {
            let point = geometry.point(CGPoint(x: 940.66015625, y: y))
            XCTAssertEqual(point, CGPoint(x: 940.75, y: 454.75))
            XCTAssertTrue(lower.contains(point)); XCTAssertFalse(upper.contains(point))
            XCTAssertEqual(geometry.point(point), point)
        }
        XCTAssertTrue(upper.contains(geometry.point(CGPoint(x: 940.66, y: 455.0390625))))
    }
    func testBoundsPreserveRetinaHalfPointsAndCompleteOriginalBorders() {
        let geometry = FrozenSmartGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            pixelSize: CGSize(width: 3840, height: 2160), primaryScreenTop: 1080)
        let original = CGRect(x: 88, y: 762, width: 197, height: 30)
        XCTAssertEqual(geometry.rect(original), original)
        XCTAssertEqual(geometry.rect(CGRect(x: 88.25, y: 762.25, width: 197.25, height: 30.25)),
            CGRect(x: 88, y: 762, width: 197.5, height: 30.5))
    }
    func testNegativeMonitorCoordinatesUseItsOwnPixelGrid() {
        let geometry = FrozenSmartGeometry(screenFrame: CGRect(x: -1920, y: -200, width: 1920, height: 1080),
            pixelSize: CGSize(width: 3840, height: 2160), primaryScreenTop: 1080)
        let point = geometry.point(CGPoint(x: -2.24, y: -50.02))
        XCTAssertEqual(point, CGPoint(x: -2.25, y: -50.25))
        XCTAssertEqual(geometry.point(point), point)
        let rect = geometry.rect(CGRect(x: -3.1, y: -51.1, width: 1.2, height: 2.2))
        XCTAssertEqual(rect, CGRect(x: -3.5, y: -51.5, width: 2, height: 3))
        XCTAssertTrue(rect.contains(point))
    }
}
