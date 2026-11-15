import XCTest
import Foundation
@testable import SafeSpotCore

final class CollisionTests: XCTestCase {

    func load() throws -> (HouseGraph, WallCollision) {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "zyzG7fqtBDv", withExtension: "json", subdirectory: "Fixtures"))
        let graph = HouseGraph(model: try MatterportModel.load(contentsOf: url))
        return (graph, WallCollision(graph: graph))
    }

    /// Unit normal of a segment a→b.
    private func normal(_ a: Point2D, _ b: Point2D) -> Point2D {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = (dx * dx + dy * dy).squareRoot()
        return len < 1e-9 ? Point2D(x: 0, y: 1) : Point2D(x: -dy / len, y: dx / len)
    }

    private func dist(_ a: Point2D, _ b: Point2D) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }

    func testNoOpMoveReturnsStart() throws {
        let (graph, col) = try load()
        let p = try XCTUnwrap(graph.rooms.first { $0.isWalkable }).centroid
        XCTAssertFalse(col.isBlocked(from: p, to: p))
        let r = col.resolve(from: p, to: p)
        XCTAssertEqual(r.x, p.x, accuracy: 1e-9)
        XCTAssertEqual(r.y, p.y, accuracy: 1e-9)
    }

    func testDoorwayLetsYouThrough() throws {
        let (_, col) = try load()
        // Cross each doorway along its edge normal, through the opening centre.
        var tested = 0
        for seg in col.segments where !seg.passableSpans.isEmpty {
            let n = normal(seg.a, seg.b)
            for span in seg.passableSpans {
                let mid = (span.lowerBound + span.upperBound) / 2
                let center = Point2D(x: seg.a.x + (seg.b.x - seg.a.x) * mid,
                                     y: seg.a.y + (seg.b.y - seg.a.y) * mid)
                let start = Point2D(x: center.x - n.x * 0.4, y: center.y - n.y * 0.4)
                let end = Point2D(x: center.x + n.x * 0.4, y: center.y + n.y * 0.4)
                XCTAssertFalse(col.isBlocked(from: start, to: end),
                               "doorway should let movement through")
                tested += 1
            }
        }
        XCTAssertGreaterThanOrEqual(tested, 9, "expected to test all 9 doorways")
    }

    func testSolidWallBlocks() throws {
        let (_, col) = try load()
        // A fully solid wall segment (no doorway spans, not open).
        let solid = try XCTUnwrap(col.segments.first { !$0.isOpen && $0.passableSpans.isEmpty && hypot($0.b.x - $0.a.x, $0.b.y - $0.a.y) > 0.8 })
        let n = normal(solid.a, solid.b)
        let mid = Point2D(x: (solid.a.x + solid.b.x) / 2, y: (solid.a.y + solid.b.y) / 2)
        let start = Point2D(x: mid.x - n.x * 0.5, y: mid.y - n.y * 0.5)
        let end = Point2D(x: mid.x + n.x * 0.5, y: mid.y + n.y * 0.5)
        XCTAssertTrue(col.isBlocked(from: start, to: end), "solid wall must block")
        let r = col.resolve(from: start, to: end)
        XCTAssertLessThan(dist(start, r), dist(start, end), "should stop before the wall")
        XCTAssertGreaterThan(dist(r, end), 0.05, "should not reach the far side")
    }

    func testOpenBoundaryLetsYouThrough() throws {
        let (_, col) = try load()
        // The open (invisible) boundary (Hallway–Living Room) must not block.
        let open = try XCTUnwrap(col.segments.first { $0.isOpen })
        let n = normal(open.a, open.b)
        let mid = Point2D(x: (open.a.x + open.b.x) / 2, y: (open.a.y + open.b.y) / 2)
        let start = Point2D(x: mid.x - n.x * 0.35, y: mid.y - n.y * 0.35)
        let end = Point2D(x: mid.x + n.x * 0.35, y: mid.y + n.y * 0.35)
        XCTAssertFalse(col.isBlocked(from: start, to: end), "open boundary must not block")
    }

    func testCannotLeaveThroughExteriorWall() throws {
        let (graph, col) = try load()
        // From a room centroid straight out past the house bbox → must be blocked.
        let bedroom = try XCTUnwrap(graph.roomsById["cdz3fkt38kae7tapstpt0eaeb"])  // Bedroom 1
        let far = Point2D(x: bedroom.centroid.x, y: bedroom.centroid.y + 50)  // way north, outside
        XCTAssertTrue(col.isBlocked(from: bedroom.centroid, to: far))
        let r = col.resolve(from: bedroom.centroid, to: far)
        XCTAssertLessThan(dist(bedroom.centroid, r), 10, "should be stopped inside the house")
    }

    func testRoomContainingCentroid() throws {
        let (graph, _) = try load()
        for room in graph.rooms where room.isWalkable {
            XCTAssertEqual(graph.room(containing: room.centroid)?.id, room.id,
                           "\(room.type) centroid should resolve to itself")
        }
    }
}
