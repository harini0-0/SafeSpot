//  TexturedHouse.swift
//  Loads the photoreal MatterPak house (house_textured.usdz) as a RealityKit entity,
//  rotated from model space (Z-up) into scene space, with baked textures shown unlit
//  (Matterport textures already contain real lighting, so unlit reads truest).

import RealityKit
import Foundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
enum TexturedHouse {
    /// Loads the textured house entity, or nil if the USDZ isn't bundled.
    static func load(unlit: Bool = true) async -> Entity? {
        guard let url = Bundle.main.url(forResource: "house_textured", withExtension: "usdz"),
              let entity = try? await Entity(contentsOf: url) else { return nil }
        // Model coords are Z-up; rotate -90° about X to match scene space (modelToScene).
        entity.orientation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
        if unlit { makeUnlit(entity) }
        return entity
    }

    /// Replace lit materials with unlit ones that keep the baked-in texture.
    private static func makeUnlit(_ entity: Entity) {
        if var model = entity.components[ModelComponent.self] {
            model.materials = model.materials.map { material in
                if let pbr = material as? PhysicallyBasedMaterial,
                   let tex = pbr.baseColor.texture {
                    var u = UnlitMaterial()
                    u.color = .init(tint: .white, texture: .init(tex.resource))
                    return u
                }
                return material
            }
            entity.components.set(model)
        }
        for child in entity.children { makeUnlit(child) }
    }
}
