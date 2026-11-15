//  SkySphere.swift
//  A UV sphere built for viewing an equirectangular panorama from the inside, with a
//  duplicated seam column so the texture doesn't smear/double where it wraps (the
//  artifact RealityKit's generateSphere produces). Vertex directions match the equirect
//  convention used by scripts/build_panoramas.py:
//      dir = (sin(lat)cos(lon), cos(lat), sin(lat)sin(lon)),  u = lon/2π,  v = lat/π
//  Use with a material whose faceCulling = .none (so the inside face renders) and NO
//  negative scale (which would mirror and re-introduce a seam).

import RealityKit
import Foundation

enum SkySphere {
    static func make(radius: Float, stacks: Int = 64, slices: Int = 128) -> MeshResource {
        var positions: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        for i in 0...stacks {
            let lat = Float.pi * Float(i) / Float(stacks)
            let sinLat = sin(lat), cosLat = cos(lat)
            for j in 0...slices {
                let lon = 2 * Float.pi * Float(j) / Float(slices)
                positions.append(SIMD3<Float>(sinLat * cos(lon), cosLat, sinLat * sin(lon)) * radius)
                uvs.append(SIMD2<Float>(Float(j) / Float(slices), Float(i) / Float(stacks)))
            }
        }
        let cols = slices + 1
        var indices: [UInt32] = []
        for i in 0..<stacks {
            for j in 0..<slices {
                let a = UInt32(i * cols + j)
                let b = UInt32((i + 1) * cols + j)
                let c = UInt32((i + 1) * cols + j + 1)
                let d = UInt32(i * cols + j + 1)
                indices += [a, b, c, a, c, d]
            }
        }
        var md = MeshDescriptor(name: "sky")
        md.positions = MeshBuffer(positions)
        md.textureCoordinates = MeshBuffer(uvs)
        md.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [md])) ?? .generateSphere(radius: radius)
    }
}
