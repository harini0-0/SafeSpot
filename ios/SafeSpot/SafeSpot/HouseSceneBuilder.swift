//  HouseSceneBuilder.swift
//  Builds the RealityKit scene from the C3 per-room segmentation (Option B:
//  untextured real geometry). One entity per room (so rooms can later be tinted /
//  highlighted / blocked); the ceiling slab is a separate child so it can be hidden
//  for the overhead cutaway.
//
//  NOTE: the material is LIT (PhysicallyBasedMaterial) rather than UnlitMaterial.
//  Untextured scan geometry is unreadable when flat-shaded, so we light it to read
//  as a clean grey "dollhouse". When real textures arrive (Option A), swap `material`
//  back to UnlitMaterial so the baked lighting in the photos shows through.

import RealityKit
import SafeSpotCore
#if canImport(UIKit)
import UIKit
#endif

@MainActor
enum HouseSceneBuilder {

    // Neutral warm-grey palette (kept fairly dark so lighting doesn't blow it out).
    static let wallColor = UIColor(red: 0.70, green: 0.67, blue: 0.63, alpha: 1)
    static let floorColor = UIColor(red: 0.45, green: 0.42, blue: 0.39, alpha: 1)
    static let ceilingColor = UIColor(red: 0.78, green: 0.76, blue: 0.73, alpha: 1)
    static let edgeColor = UIColor(red: 0.18, green: 0.16, blue: 0.14, alpha: 1)
    static let groundColor = UIColor(red: 0.40, green: 0.37, blue: 0.34, alpha: 1)

    static func build(house: LoadedHouse) -> Entity {
        let root = Entity()
        root.name = "House"

        for room in house.graph.rooms {
            guard let seg = house.segmentation.segmentsByRoom[room.id] else { continue }
            let roomEntity = Entity()
            roomEntity.name = "room:\(room.id)"

            var floorIdx: [Int] = []
            var wallIdx: [Int] = []
            for i in seg.shellTriangles {
                let t = house.mesh.triangles[i]
                let c = house.mesh.centroid(t)
                if c.z < 0.3 && abs(house.mesh.normalZ(t)) > 0.7 { floorIdx.append(i) }
                else { wallIdx.append(i) }
            }
            if let m = mesh(from: wallIdx, mesh: house.mesh) {
                let e = modelEntity(m, color: wallColor); e.name = "walls"; roomEntity.addChild(e)
            }
            if let m = mesh(from: floorIdx, mesh: house.mesh) {
                let e = modelEntity(m, color: floorColor); e.name = "floor"; roomEntity.addChild(e)
            }
            if let m = mesh(from: seg.ceilingTriangles, mesh: house.mesh) {
                let e = modelEntity(m, color: ceilingColor); e.name = "ceiling:\(room.id)"; roomEntity.addChild(e)
            }
            root.addChild(roomEntity)
        }

        // Exterior shell: triangles whose centroid fell outside every room polygon
        // (mostly the outward-facing exterior wall surfaces). Without these the outer
        // walls have holes.
        if let m = mesh(from: house.segmentation.unassigned, mesh: house.mesh) {
            let e = modelEntity(m, color: wallColor); e.name = "exterior"
            root.addChild(e)
        }

        // Solid ground slab just under the floor so the scan's floor holes don't
        // show the dark background through them.
        root.addChild(groundPlane(graph: house.graph))

        root.addChild(edgeLines(graph: house.graph))
        return root
    }

    private static func groundPlane(graph: HouseGraph) -> ModelEntity {
        let pts = graph.rooms.flatMap { $0.polygon }
        let xs = pts.map { $0.x }, ys = pts.map { $0.y }
        let minX = xs.min() ?? -11, maxX = xs.max() ?? 1
        let minY = ys.min() ?? -4, maxY = ys.max() ?? 5
        let width = Float(maxX - minX) + 0.6
        let depth = Float(maxY - minY) + 0.6
        let c = CoordinateTransform.modelToScene(Vector3(x: (minX + maxX) / 2, y: (minY + maxY) / 2, z: 0))
        let plane = MeshResource.generatePlane(width: width, depth: depth)
        let e = modelEntity(plane, color: groundColor)
        e.name = "ground"
        e.position = SIMD3<Float>(Float(c.x), Float(c.y) - 0.04, Float(c.z))
        return e
    }

    static func setCeilingsHidden(_ hidden: Bool, in root: Entity) {
        for room in root.children {
            for child in room.children where child.name.hasPrefix("ceiling:") {
                child.isEnabled = !hidden
            }
        }
    }

    // MARK: - Materials / meshes

    private static func modelEntity(_ mesh: MeshResource, color: UIColor) -> ModelEntity {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.roughness = 0.95
        material.metallic = 0.0
        material.faceCulling = .none  // scan winding isn't guaranteed; render both sides
        return ModelEntity(mesh: mesh, materials: [material])
    }

    /// Builds a MeshResource (with smooth normals) from triangle indices, converting
    /// model space (z-up) to RealityKit scene space (y-up) via SafeSpotCore.
    private static func mesh(from triangleIndices: [Int], mesh: LoadedMesh) -> MeshResource? {
        guard !triangleIndices.isEmpty else { return nil }
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        var remap: [Int: UInt32] = [:]
        for ti in triangleIndices {
            let t = mesh.triangles[ti]
            for vi in [t.a, t.b, t.c] {
                let mapped: UInt32
                if let r = remap[vi] { mapped = r }
                else {
                    let s = CoordinateTransform.modelToScene(mesh.vertices[vi])
                    mapped = UInt32(positions.count)
                    remap[vi] = mapped
                    positions.append(SIMD3<Float>(Float(s.x), Float(s.y), Float(s.z)))
                }
                indices.append(mapped)
            }
        }
        // Smooth per-vertex normals so lighting shades the geometry.
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        var i = 0
        while i < indices.count {
            let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
            let n = cross(positions[b] - positions[a], positions[c] - positions[a])
            normals[a] += n; normals[b] += n; normals[c] += n
            i += 3
        }
        for j in normals.indices {
            let len = length(normals[j])
            normals[j] = len > 1e-6 ? normals[j] / len : SIMD3<Float>(0, 1, 0)
        }
        var d = MeshDescriptor(name: "segment")
        d.positions = MeshBuffer(positions)
        d.normals = MeshBuffer(normals)
        d.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [d])
    }

    private static func edgeLines(graph: HouseGraph) -> Entity {
        let parent = Entity()
        parent.name = "edges"
        let lineMesh = MeshResource.generateBox(size: 1)
        var mat = PhysicallyBasedMaterial()
        mat.baseColor = .init(tint: edgeColor)
        mat.roughness = 1.0
        for e in graph.edges where e.type == "wall" {
            let a = CoordinateTransform.modelToScene(Point2D(x: e.v0.x, y: e.v0.y), modelZ: 0.03)
            let b = CoordinateTransform.modelToScene(Point2D(x: e.v1.x, y: e.v1.y), modelZ: 0.03)
            let dx = Float(b.x - a.x), dz = Float(b.z - a.z)
            let len = (dx * dx + dz * dz).squareRoot()
            if len < 1e-4 { continue }
            let m = ModelEntity(mesh: lineMesh, materials: [mat])
            m.scale = SIMD3<Float>(len, 0.04, 0.04)
            m.position = SIMD3<Float>(Float((a.x + b.x) / 2), Float((a.y + b.y) / 2), Float((a.z + b.z) / 2))
            m.orientation = simd_quatf(angle: -atan2(dz, dx), axis: SIMD3<Float>(0, 1, 0))
            parent.addChild(m)
        }
        return parent
    }
}
