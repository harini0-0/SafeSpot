import XCTest
@testable import SafeSpotCore

final class SegmentationTests: XCTestCase {

    func load() throws -> (LoadedMesh, HouseGraph, MeshSegmentation) {
        let meshURL = try XCTUnwrap(Bundle.module.url(
            forResource: "out_res_50k", withExtension: "obj", subdirectory: "Fixtures"))
        let modelURL = try XCTUnwrap(Bundle.module.url(
            forResource: "zyzG7fqtBDv", withExtension: "json", subdirectory: "Fixtures"))
        let mesh = try OBJLoader.load(contentsOf: meshURL)
        let graph = HouseGraph(model: try MatterportModel.load(contentsOf: modelURL))
        return (mesh, graph, MeshSegmentation(mesh: mesh, graph: graph))
    }

    func testMeshLoaded() throws {
        let (mesh, _, _) = try load()
        XCTAssertEqual(mesh.vertices.count, 23438)
        XCTAssertEqual(mesh.triangles.count, 48063)
    }

    func testTriangleConservation() throws {
        let (mesh, _, seg) = try load()
        XCTAssertEqual(seg.totalAssignedTriangles + seg.unassigned.count, mesh.triangles.count)
    }

    func testMostTrianglesAssigned() throws {
        // Interior surfaces land inside a room polygon; only outward-facing exterior
        // wall faces fall outside. Expect the large majority assigned.
        let (mesh, _, seg) = try load()
        let frac = Double(seg.totalAssignedTriangles) / Double(mesh.triangles.count)
        XCTAssertGreaterThan(frac, 0.6, "assigned fraction \(frac)")
    }

    func testEveryRealRoomGetsGeometry() throws {
        // Real (non-degenerate) rooms get mesh triangles. The 0.5 m² zero-height
        // closet (ceilingHeight == nil) has no scanned geometry and is skipped.
        let (_, graph, seg) = try load()
        for r in graph.rooms where r.isWalkable && r.ceilingHeight != nil {
            let s = seg.segmentsByRoom[r.id]
            XCTAssertNotNil(s, "\(r.type) \(r.id) got no triangles")
            XCTAssertGreaterThan(s?.triangleCount ?? 0, 0)
        }
    }

    func testLivingRoomHasSubstantialGeometry() throws {
        // Triangle count tracks surface detail, not floor area, so we don't assert
        // the Living Room is the max — just that it has a healthy amount of geometry.
        let (_, _, seg) = try load()
        let livingRoom = "613htqkzf66zz7hf7n8kzszed"
        let s = try XCTUnwrap(seg.segmentsByRoom[livingRoom])
        XCTAssertGreaterThan(s.triangleCount, 1000)
    }

    func testCeilingSeparatedAndNearCeilingHeight() throws {
        let (mesh, graph, seg) = try load()
        let livingRoom = "613htqkzf66zz7hf7n8kzszed"
        let s = try XCTUnwrap(seg.segmentsByRoom[livingRoom])
        XCTAssertGreaterThan(s.ceilingTriangles.count, 0, "Living Room should have a ceiling layer")
        let h = try XCTUnwrap(graph.roomsById[livingRoom]?.ceilingHeight)
        // Every ceiling triangle centroid should be near the ceiling height.
        for i in s.ceilingTriangles {
            let z = mesh.centroid(mesh.triangles[i]).z
            XCTAssertGreaterThan(z, h - 0.5, "ceiling triangle z=\(z) vs height \(h)")
        }
        // Shell triangles should include low (floor/wall) geometry.
        let minShellZ = s.shellTriangles.map { mesh.centroid(mesh.triangles[$0]).z }.min() ?? 99
        XCTAssertLessThan(minShellZ, 0.5, "shell should include floor-level geometry")
    }

    func testObjParserHandlesSlashFaces() {
        // "f v/vt v/vt v/vt" should parse to vertex indices.
        let m = OBJLoader.parse("""
        v 0 0 0
        v 1 0 0
        v 0 1 0
        f 1/5 2/6 3/7
        """)
        XCTAssertEqual(m.vertices.count, 3)
        XCTAssertEqual(m.triangles.count, 1)
        XCTAssertEqual(m.triangles[0], Triangle(a: 0, b: 1, c: 2))
    }

    func testObjParserFanTriangulatesQuads() {
        let m = OBJLoader.parse("""
        v 0 0 0
        v 1 0 0
        v 1 1 0
        v 0 1 0
        f 1 2 3 4
        """)
        XCTAssertEqual(m.triangles.count, 2)  // quad -> 2 triangles
    }
}
