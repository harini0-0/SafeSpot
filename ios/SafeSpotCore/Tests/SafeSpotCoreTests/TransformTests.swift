import XCTest
@testable import SafeSpotCore

final class TransformTests: XCTestCase {

    func loadModel() throws -> MatterportModel {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "zyzG7fqtBDv", withExtension: "json",
                              subdirectory: "Fixtures"))
        return try MatterportModel.load(contentsOf: url)
    }

    func testModelToSceneMapping() {
        // model (x, y, z-up) -> scene (x, z, -y)
        let p = Vector3(x: 2, y: 3, z: 1)
        let s = CoordinateTransform.modelToScene(p)
        XCTAssertEqual(s.x, 2, accuracy: 1e-9)
        XCTAssertEqual(s.y, 1, accuracy: 1e-9)   // model z (up) -> scene y (up)
        XCTAssertEqual(s.z, -3, accuracy: 1e-9)  // scene z = -model y
    }

    func testSceneRoundTrip() {
        let p = Vector3(x: -7.1, y: 2.03, z: 2.44)
        let back = CoordinateTransform.sceneToModel(CoordinateTransform.modelToScene(p))
        XCTAssertEqual(back.x, p.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
        XCTAssertEqual(back.z, p.z, accuracy: 1e-9)
    }

    func testNorthHeadingIs26Point676() throws {
        let geo = try loadModel().sections.geolocation.geocoordinates
        XCTAssertEqual(CoordinateTransform.northHeadingDegrees(geo), 26.676, accuracy: 0.01)
    }

    func testLatLongRoundTrip() throws {
        let geo = try loadModel().sections.geolocation.geocoordinates
        for p in [Point2D(x: 0, y: 0), Point2D(x: -7.1, y: 2.0), Point2D(x: 0.4, y: -3.5)] {
            let ll = CoordinateTransform.modelToLatLong(p, geo: geo)
            let back = CoordinateTransform.latLongToModel(ll, geo: geo)
            XCTAssertEqual(back.x, p.x, accuracy: 1e-4, "x round-trip")
            XCTAssertEqual(back.y, p.y, accuracy: 1e-4, "y round-trip")
        }
    }

    func testModelOriginMapsNearPublishedCoordinate() throws {
        // The model origin should land within ~a block of the published building coord.
        let geo = try loadModel().sections.geolocation.geocoordinates
        let ll = CoordinateTransform.modelToLatLong(Point2D(x: 0, y: 0), geo: geo)
        XCTAssertEqual(ll.latitude, geo.latitude, accuracy: 0.001)
        XCTAssertEqual(ll.longitude, geo.longitude, accuracy: 0.001)
    }
}
