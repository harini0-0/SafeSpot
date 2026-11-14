//  HouseView.swift
//  Step 1: shows the real house as a lit grey "dollhouse" from a tilted bird's-eye
//  angle, using a virtual camera (not ARKit — that's Sanjana's `locate` module).
//  Ceilings are hidden so the whole floor plan is visible.

import SwiftUI
import RealityKit
import SafeSpotCore

struct HouseView: View {
    @State private var status: String = "Loading house…"

    var body: some View {
        ZStack(alignment: .top) {
            RealityView { content in
                do {
                    let house = try HouseLoader.loadFromBundle()
                    let root = HouseSceneBuilder.build(house: house)
                    HouseSceneBuilder.setCeilingsHidden(true, in: root)
                    content.add(root)
                    addLighting(to: content)
                    content.add(makeBirdsEyeCamera(for: house))
                    status = "\(house.graph.rooms.count) rooms • \(house.mesh.triangles.count) triangles"
                } catch {
                    status = "Load error: \(error.localizedDescription)"
                }
            }
            .background(Color(white: 0.14))

            Text(status)
                .font(.caption.monospaced())
                .padding(8)
                .background(.black.opacity(0.55))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.top, 8)
        }
        .ignoresSafeArea()
    }

    // MARK: - Camera & lights

    /// Model-space centre + footprint of the house, in RealityKit scene space.
    private func sceneBounds(_ house: LoadedHouse) -> (center: SIMD3<Float>, width: Float, depth: Float) {
        let pts = house.graph.rooms.flatMap { $0.polygon }
        let xs = pts.map { $0.x }, ys = pts.map { $0.y }
        let minX = xs.min() ?? -10, maxX = xs.max() ?? 0
        let minY = ys.min() ?? -4, maxY = ys.max() ?? 4
        let c = CoordinateTransform.modelToScene(Vector3(x: (minX + maxX) / 2, y: (minY + maxY) / 2, z: 1.2))
        // scene x = model x (width), scene z = -model y (depth)
        return (SIMD3<Float>(Float(c.x), Float(c.y), Float(c.z)),
                Float(maxX - minX), Float(maxY - minY))
    }

    private func makeBirdsEyeCamera(for house: LoadedHouse) -> Entity {
        let (center, width, depth) = sceneBounds(house)
        let span = max(width, depth)
        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 42
        // Tilted bird's-eye (~34° down), pulled back so the whole house frames.
        let back = span * 1.15
        let up = span * 0.78
        camera.position = center + SIMD3<Float>(0, up, back)
        camera.look(at: center, from: camera.position, relativeTo: nil)
        return camera
    }

    private func addLighting(to content: some RealityViewContentProtocol) {
        // Key light (from upper-front). Kept low so the grey surfaces don't blow out.
        let key = DirectionalLight()
        key.light.intensity = 900
        key.look(at: .zero, from: SIMD3<Float>(-3, 8, 4), relativeTo: nil)
        content.add(key)

        // Fill light (dimmer, opposite side) so no face is fully black.
        let fill = DirectionalLight()
        fill.light.intensity = 350
        fill.look(at: .zero, from: SIMD3<Float>(4, 5, -4), relativeTo: nil)
        content.add(fill)

        // Low up-fill to lift the undersides a touch.
        let bounce = DirectionalLight()
        bounce.light.intensity = 150
        bounce.look(at: .zero, from: SIMD3<Float>(0, -5, 0), relativeTo: nil)
        content.add(bounce)
    }
}

#Preview {
    HouseView()
}
