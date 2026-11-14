import XCTest
@testable import SafeSpotCore

final class HouseGraphTests: XCTestCase {

    // Canonical real ids (see docs/interfaces.md / docs/house_summary.md).
    enum ID {
        static let livingRoom = "613htqkzf66zz7hf7n8kzszed"
        static let hallway    = "9hauvfhwiqt"
        static let kitchen    = "tt6gm2a0463x9wmnx7rn6gugc"
        static let bedroom1   = "cdz3fkt38kae7tapstpt0eaeb"   // 13.1 m²
        static let bedroom2   = "xy2x8mpaaqknp7q2c3nnbw1ma"   // 11.6 m²
        static let closetBed1 = "3m54yff1z7crxaywd8if9rb0d"   // off Bedroom 1
        static let closetBed2 = "a5f9age4zzxewres6iqux2emc"   // off Bedroom 2
        static let closetHall = "m8npxsuk79xy21dd09x9wtped"
        static let bathHall   = "h26t7ky77ew74yb0pg8qqf5rd"
        static let bathEnsuite = "2qdmc5i9byxi79ry1pxdkqzea"
        static let void       = "19ab05tns5h6y4qm42esqqpea"
        static let exteriorExit = "0s3c7t6b07uzr0yizazsri18c"
    }

    func loadGraph() throws -> (MatterportModel, HouseGraph) {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "zyzG7fqtBDv", withExtension: "json",
                              subdirectory: "Fixtures"),
            "fixture zyzG7fqtBDv.json not found")
        let model = try MatterportModel.load(contentsOf: url)
        return (model, HouseGraph(model: model))
    }

    func testRoomCount() throws {
        let (_, g) = try loadGraph()
        XCTAssertEqual(g.rooms.count, 11)
    }

    func testDoorwayCount() throws {
        let (_, g) = try loadGraph()
        XCTAssertEqual(g.doorways.count, 9, "expected 9 unique doorways")
    }

    func testWindowCount() throws {
        let (_, g) = try loadGraph()
        XCTAssertEqual(g.windows.count, 4, "expected 4 windows")
    }

    func testExactlyOneExteriorExitInLivingRoom() throws {
        let (_, g) = try loadGraph()
        XCTAssertEqual(g.exteriorExits.count, 1)
        let exit = try XCTUnwrap(g.exteriorExits.first)
        XCTAssertEqual(exit.id, ID.exteriorExit)
        XCTAssertEqual(exit.roomIds, [ID.livingRoom])
    }

    func testClosetOffBedroom1HasNoWindowsNoExteriorWalls() throws {
        let (_, g) = try loadGraph()
        let closet = try XCTUnwrap(g.roomsById[ID.closetBed1])
        XCTAssertEqual(closet.type, "Closet")
        XCTAssertFalse(closet.hasWindows, "closet off Bedroom 1 should have no windows")
        XCTAssertFalse(closet.hasExteriorWalls, "closet off Bedroom 1 should have no exterior walls")
        XCTAssertTrue(g.doorwayConnects(ID.bedroom1, ID.closetBed1),
                      "this closet should open off Bedroom 1")
    }

    func testHallwayLivingRoomBoundaryIsOpen() throws {
        let (_, g) = try loadGraph()
        let shared = g.edges.filter { Set($0.roomIds) == Set([ID.hallway, ID.livingRoom]) }
        XCTAssertEqual(shared.count, 1, "one shared edge between Hallway and Living Room")
        XCTAssertTrue(shared.first?.isOpen ?? false, "that boundary should be open (invisible)")
        // And no doorway there.
        XCTAssertFalse(g.doorwayConnects(ID.hallway, ID.livingRoom))
    }

    func testDoorwayConnectionsMatchSummary() throws {
        let (_, g) = try loadGraph()
        // Connections asserted in docs/house_summary.md.
        XCTAssertTrue(g.doorwayConnects(ID.livingRoom, ID.kitchen))
        XCTAssertTrue(g.doorwayConnects(ID.hallway, ID.closetHall))
        XCTAssertTrue(g.doorwayConnects(ID.hallway, ID.bedroom1))
        XCTAssertTrue(g.doorwayConnects(ID.hallway, ID.bedroom2))
        XCTAssertTrue(g.doorwayConnects(ID.hallway, ID.bathHall))
        XCTAssertTrue(g.doorwayConnects(ID.bedroom1, ID.bathEnsuite))
        XCTAssertTrue(g.doorwayConnects(ID.bedroom1, ID.closetBed1))
        XCTAssertTrue(g.doorwayConnects(ID.bedroom2, ID.closetBed2))
        // Negative controls.
        XCTAssertFalse(g.doorwayConnects(ID.kitchen, ID.bedroom1))
        XCTAssertFalse(g.doorwayConnects(ID.bedroom1, ID.bedroom2))
    }

    func testVoidIsNonWalkable() throws {
        let (_, g) = try loadGraph()
        let void = try XCTUnwrap(g.roomsById[ID.void])
        XCTAssertFalse(void.isWalkable)
        // All non-void rooms with area are walkable.
        for r in g.rooms where r.type != "Void" {
            XCTAssertTrue(r.isWalkable, "\(r.type) \(r.id) should be walkable")
        }
    }

    func testRoomPolygonsAreClosedWithArea() throws {
        let (_, g) = try loadGraph()
        for r in g.rooms where r.isWalkable {
            XCTAssertGreaterThanOrEqual(r.polygon.count, 3, "\(r.type) polygon should have >=3 verts")
            let polyArea = Geometry.polygonArea(r.polygon)
            // Polygon area should be in the same ballpark as the reported indoor area.
            XCTAssertEqual(polyArea, r.area, accuracy: max(1.0, r.area * 0.35),
                           "\(r.type) polygon area \(polyArea) vs reported \(r.area)")
        }
    }

    func testNeighborsThroughDoorwayAndOpenBoundary() throws {
        let (_, g) = try loadGraph()
        let hallNeighbors = g.neighbors(of: ID.hallway)
        XCTAssertTrue(hallNeighbors.contains(ID.livingRoom), "open boundary neighbor")
        XCTAssertTrue(hallNeighbors.contains(ID.bedroom1))
        XCTAssertTrue(hallNeighbors.contains(ID.bathHall))
    }

    func testWindowsPerRoom() throws {
        let (_, g) = try loadGraph()
        XCTAssertEqual(g.roomsById[ID.livingRoom]?.windowIds.count, 2)
        XCTAssertEqual(g.roomsById[ID.bedroom1]?.windowIds.count, 1)
        XCTAssertEqual(g.roomsById[ID.bedroom2]?.windowIds.count, 1)
    }
}
