import XCTest
@testable import PausePathCore

final class NavigationProgressTests: XCTestCase {
    let start = Coordinate(0, 0)
    let middle = Coordinate(0, 0.001)
    let end = Coordinate(0, 0.002)
    func testProjectionUsesAlongPathDistance() {
        let projection = WalkingGeometry.project(Coordinate(0.0001, 0.0005), onto: [start, middle, end], near: 0)
        XCTAssertEqual(projection!.metersAlong, 55.6, accuracy: 1)
        XCTAssertEqual(projection!.metersAway, 11.1, accuracy: 1)
    }
    func testOutAndBackDoesNotArriveAtStart() {
        var progress = WalkProgress(paths: [[start, middle, end], [end, middle, start]])
        progress.update(position: start, accuracy: 5, age: 0)
        XCTAssertFalse(progress.arrived)
        XCTAssertEqual(progress.legIndex, 0)
        progress.update(position: middle, accuracy: 5, age: 0)
        progress.update(position: end, accuracy: 5, age: 0)
        XCTAssertEqual(progress.legIndex, 1)
        XCTAssertFalse(progress.arrived)
        progress.update(position: middle, accuracy: 5, age: 0)
        progress.update(position: start, accuracy: 5, age: 0)
        XCTAssertTrue(progress.arrived)
        XCTAssertEqual(progress.completedMeters, progress.totalMeters)
    }
    func testBadAndStaleGPSCannotAdvance() {
        var progress = WalkProgress(paths: [[start, middle, end]])
        XCTAssertFalse(progress.update(position: start, accuracy: 80, age: 0))
        XCTAssertFalse(progress.update(position: start, accuracy: 5, age: 30))
        XCTAssertFalse(progress.hasStarted)
        progress.update(position: start, accuracy: 5, age: 0)
        XCTAssertFalse(progress.update(position: middle, accuracy: -1, age: 0))
        XCTAssertEqual(progress.metersAlongLeg, 0)
    }
    func testMustBeginNearStart() {
        var progress = WalkProgress(paths: [[start, middle, end]])
        progress.update(position: end, accuracy: 5, age: 0)
        XCTAssertFalse(progress.offRoute) // Warning waits for a second fix.
        XCTAssertFalse(progress.hasStarted)
        XCTAssertEqual(progress.completedMeters, 0)
        progress.update(position: end, accuracy: 5, age: 0)
        XCTAssertTrue(progress.offRoute)
        XCTAssertFalse(progress.hasStarted)
        XCTAssertFalse(progress.arrived)
    }
    func testOffRouteDoesNotAdvance() {
        var progress = WalkProgress(paths: [[start, middle, end]])
        progress.update(position: start, accuracy: 5, age: 0)
        progress.update(position: Coordinate(0.001, 0.001), accuracy: 5, age: 0)
        XCTAssertFalse(progress.offRoute)
        XCTAssertEqual(progress.metersAlongLeg, 0)
        progress.update(position: Coordinate(0.001, 0.001), accuracy: 5, age: 0)
        XCTAssertTrue(progress.offRoute)
        XCTAssertEqual(progress.metersAlongLeg, 0)
        progress.update(position: middle, accuracy: 5, age: 0)
        XCTAssertFalse(progress.offRoute)
        XCTAssertGreaterThan(progress.metersAlongLeg, 100)
    }
    func testNearbyCrossingCannotSkipAhead() {
        let path = [start, middle, end, Coordinate(0.0001, 0.002), Coordinate(0.0001, 0)]
        let projection = WalkingGeometry.project(Coordinate(0.0001, 0.0001), onto: path, near: 0)
        XCTAssertLessThan(projection!.metersAlong, 30)
    }
    func testEmptyGeometryCannotArrive() {
        var progress = WalkProgress(paths: [[]])
        XCTAssertFalse(progress.update(position: start, accuracy: 5, age: 0))
        XCTAssertFalse(progress.arrived)
    }
    func testBacktrackingDoesNotDecreaseProgress() {
        var progress = WalkProgress(paths: [[start, middle, end]])
        progress.update(position: start, accuracy: 5, age: 0)
        progress.update(position: middle, accuracy: 5, age: 0)
        let before = progress.metersAlongLeg
        progress.update(position: Coordinate(0, 0.0009), accuracy: 5, age: 0)
        XCTAssertEqual(progress.metersAlongLeg, before)
    }
}
