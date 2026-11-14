import Foundation

/// A point in RealityKit scene space (meters, y-up).
public struct ScenePoint: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let z: Double
    public init(x: Double, y: Double, z: Double) { self.x = x; self.y = y; self.z = z }
}

/// Coordinate transforms between Matterport model space, RealityKit scene space,
/// and geographic coordinates.
///
/// Model space (Matterport): right-handed, meters, **z is up**; floor geometry is the
/// `(x, y)` plane. RealityKit scene space: **y is up**. We map:
///     scene.x = model.x,  scene.y = model.z,  scene.z = -model.y
/// so the model floor plane lies on the scene's x/z ground plane with the scene
/// looking down the conventional -z.
public enum CoordinateTransform {

    // MARK: Model <-> Scene

    public static func modelToScene(_ p: Vector3) -> ScenePoint {
        ScenePoint(x: p.x, y: p.z, z: -p.y)
    }

    /// A 2D floor point at model height `z` (default 0 = floor).
    public static func modelToScene(_ p: Point2D, modelZ: Double = 0) -> ScenePoint {
        ScenePoint(x: p.x, y: modelZ, z: -p.y)
    }

    public static func sceneToModel(_ s: ScenePoint) -> Vector3 {
        Vector3(x: s.x, y: -s.z, z: s.y)
    }

    // MARK: North

    /// Heading of geographic north expressed in model space, in degrees (rotation
    /// about +z), derived from the geo rotation quaternion. For this house ≈ 26.676°.
    public static func northHeadingDegrees(_ geo: GeoCoordinate) -> Double {
        let r = geo.rotation
        return atan2(r.z, r.w) * 2.0 * 180.0 / .pi
    }

    // MARK: Model <-> Geographic (lat/long)
    //
    // The geo rotation quaternion rotates model space into a geo-aligned local ENU
    // frame; `translation` offsets the model origin within that frame. We then convert
    // ENU meters to lat/long around the published origin. This is invertible and used
    // for building-level geo-referencing; absolute per-point accuracy depends on
    // Matterport's convention and is not relied on beyond the building coordinate
    // (see docs/alignment.md).

    private static let metersPerDegreeLat = 111_320.0

    /// Rotate a model-space vector by the geo quaternion (model -> ENU meters).
    private static func rotate(_ q: Quaternion, _ v: Vector3) -> Vector3 {
        // q * (0,v) * q^-1 for a unit quaternion.
        let (w, x, y, z) = (q.w, q.x, q.y, q.z)
        let ix =  w * v.x + y * v.z - z * v.y
        let iy =  w * v.y + z * v.x - x * v.z
        let iz =  w * v.z + x * v.y - y * v.x
        let iw = -x * v.x - y * v.y - z * v.z
        return Vector3(
            x: ix * w + iw * -x + iy * -z - iz * -y,
            y: iy * w + iw * -y + iz * -x - ix * -z,
            z: iz * w + iw * -z + ix * -y - iy * -x)
    }

    /// Inverse rotation (ENU meters -> model-space vector), using the conjugate.
    private static func rotateInverse(_ q: Quaternion, _ v: Vector3) -> Vector3 {
        rotate(Quaternion(w: q.w, x: -q.x, y: -q.y, z: -q.z), v)
    }

    public struct LatLong: Sendable, Equatable {
        public let latitude: Double
        public let longitude: Double
        public init(latitude: Double, longitude: Double) {
            self.latitude = latitude; self.longitude = longitude
        }
    }

    public static func modelToLatLong(_ p: Point2D, geo: GeoCoordinate) -> LatLong {
        let enu = rotate(geo.rotation, Vector3(x: p.x, y: p.y, z: 0))
        let east = enu.x + geo.translation.x
        let north = enu.y + geo.translation.y
        let lat = geo.latitude + north / metersPerDegreeLat
        let lon = geo.longitude + east / (metersPerDegreeLat * cos(geo.latitude * .pi / 180.0))
        return LatLong(latitude: lat, longitude: lon)
    }

    public static func latLongToModel(_ ll: LatLong, geo: GeoCoordinate) -> Point2D {
        let north = (ll.latitude - geo.latitude) * metersPerDegreeLat
        let east = (ll.longitude - geo.longitude) * metersPerDegreeLat * cos(geo.latitude * .pi / 180.0)
        let v = rotateInverse(geo.rotation, Vector3(x: east - geo.translation.x,
                                                    y: north - geo.translation.y, z: 0))
        return Point2D(x: v.x, y: v.y)
    }
}
