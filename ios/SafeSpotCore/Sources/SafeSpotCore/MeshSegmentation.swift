import Foundation

// Loads the real Matterport OBJ geometry and splits it into one group of triangles
// per room using the HouseGraph polygons, with the ceiling slab separated into its
// own layer (for the overhead cutaway and per-room effects). Pure, deterministic
// geometry — no RealityKit here; the app's scene builder consumes this.

public struct Triangle: Sendable, Equatable {
    public let a: Int
    public let b: Int
    public let c: Int
}

public struct LoadedMesh: Sendable {
    public let vertices: [Vector3]
    public let triangles: [Triangle]

    public func centroid(_ t: Triangle) -> Vector3 {
        let va = vertices[t.a], vb = vertices[t.b], vc = vertices[t.c]
        return Vector3(x: (va.x + vb.x + vc.x) / 3,
                       y: (va.y + vb.y + vc.y) / 3,
                       z: (va.z + vb.z + vc.z) / 3)
    }

    /// Unit normal z-component of a triangle (sign depends on winding).
    public func normalZ(_ t: Triangle) -> Double {
        let va = vertices[t.a], vb = vertices[t.b], vc = vertices[t.c]
        let ux = vb.x - va.x, uy = vb.y - va.y, uz = vb.z - va.z
        let wx = vc.x - va.x, wy = vc.y - va.y, wz = vc.z - va.z
        let nx = uy * wz - uz * wy
        let ny = uz * wx - ux * wz
        let nz = ux * wy - uy * wx
        let len = (nx * nx + ny * ny + nz * nz).squareRoot()
        return len == 0 ? 0 : nz / len
    }
}

public enum OBJLoader {
    public static func load(contentsOf url: URL) throws -> LoadedMesh {
        parse(try String(contentsOf: url, encoding: .utf8))
    }

    /// Parses `v` and `f` lines. Face vertex refs may be `v`, `v/vt` or `v/vt/vn`
    /// (we take the vertex index). Polygons with >3 vertices are fan-triangulated.
    public static func parse(_ text: String) -> LoadedMesh {
        var verts: [Vector3] = []
        var tris: [Triangle] = []
        text.enumerateLines { line, _ in
            if line.hasPrefix("v ") {
                let p = line.split(separator: " ")
                if p.count >= 4, let x = Double(p[1]), let y = Double(p[2]), let z = Double(p[3]) {
                    verts.append(Vector3(x: x, y: y, z: z))
                }
            } else if line.hasPrefix("f ") {
                let parts = line.split(separator: " ").dropFirst()
                let idxs: [Int] = parts.compactMap { tok in
                    guard let first = tok.split(separator: "/").first, let i = Int(first) else { return nil }
                    return i > 0 ? i - 1 : verts.count + i   // 1-based, or negative relative
                }
                if idxs.count >= 3 {
                    for k in 1..<(idxs.count - 1) {
                        tris.append(Triangle(a: idxs[0], b: idxs[k], c: idxs[k + 1]))
                    }
                }
            }
        }
        return LoadedMesh(vertices: verts, triangles: tris)
    }
}

public struct RoomSegment: Sendable {
    public let roomId: String
    /// Walls + floor (everything that isn't the ceiling slab).
    public let shellTriangles: [Int]
    /// Downward-/upward-facing triangles near the room's ceiling height.
    public let ceilingTriangles: [Int]
    public var triangleCount: Int { shellTriangles.count + ceilingTriangles.count }
}

public struct MeshSegmentation: Sendable {
    public let segments: [RoomSegment]
    /// Triangle indices whose centroid fell outside every room polygon
    /// (mostly outward-facing exterior-wall surfaces).
    public let unassigned: [Int]
    public let segmentsByRoom: [String: RoomSegment]

    /// - Parameters:
    ///   - ceilingBand: how far below `ceilingHeight` still counts as ceiling (m).
    ///   - ceilingFlatness: min |normal.z| for a triangle to count as a horizontal slab.
    public init(mesh: LoadedMesh, graph: HouseGraph,
                ceilingBand: Double = 0.35, ceilingFlatness: Double = 0.7) {
        // Rooms with a usable polygon, checked largest-area-last so small rooms
        // (closets) inside no one else win ties naturally by first-match order.
        let polyRooms = graph.rooms.filter { $0.polygon.count >= 3 }

        var shell: [String: [Int]] = [:]
        var ceil: [String: [Int]] = [:]
        var unassigned: [Int] = []

        for (i, t) in mesh.triangles.enumerated() {
            let c = mesh.centroid(t)
            let p = Point2D(x: c.x, y: c.y)
            guard let room = polyRooms.first(where: { Geometry.contains($0.polygon, p) }) else {
                unassigned.append(i)
                continue
            }
            let isCeiling: Bool = {
                guard let h = room.ceilingHeight else { return false }
                return c.z >= h - ceilingBand && abs(mesh.normalZ(t)) >= ceilingFlatness
            }()
            if isCeiling { ceil[room.id, default: []].append(i) }
            else { shell[room.id, default: []].append(i) }
        }

        var segs: [RoomSegment] = []
        for r in graph.rooms {
            let s = shell[r.id] ?? []
            let c = ceil[r.id] ?? []
            if s.isEmpty && c.isEmpty { continue }
            segs.append(RoomSegment(roomId: r.id, shellTriangles: s, ceilingTriangles: c))
        }
        self.segments = segs
        self.unassigned = unassigned
        self.segmentsByRoom = Dictionary(uniqueKeysWithValues: segs.map { ($0.roomId, $0) })
    }

    public var totalAssignedTriangles: Int { segments.reduce(0) { $0 + $1.triangleCount } }
}
