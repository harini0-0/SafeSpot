//  PanoramaView.swift
//  Photoreal walkthrough: stand inside a real 360° scan photo (equirectangular on a
//  sphere) and look around by dragging. Step between scan points with the button.
//  The equirects were built offline from the real skybox faces (scripts/build_panoramas.py).

import SwiftUI
import RealityKit
import SafeSpotCore

@MainActor
final class PanoramaModel {
    let panos: [Panorama]          // ordered scan points
    var index: Int = 0
    var yaw: Double = 0
    var pitch: Double = 0
    let camera = PerspectiveCamera()
    let sphere = ModelEntity()

    let roomTypeById: [String: String]

    init(house: LoadedHouse) {
        let all = house.model.sections.panoramas?.panoLocations ?? []
        panos = all.sorted { (Int($0.label ?? "") ?? 0) < (Int($1.label ?? "") ?? 0) }
        roomTypeById = Dictionary(uniqueKeysWithValues: house.graph.rooms.map { ($0.id, $0.type) })
        camera.camera.fieldOfViewInDegrees = 75
        // Big inward-facing sphere; negative x scale shows the texture from the inside.
        sphere.components.set(ModelComponent(mesh: .generateSphere(radius: 50), materials: []))
        sphere.scale = SIMD3<Float>(-1, 1, 1)
        updateCamera()
    }

    var current: Panorama? { panos.indices.contains(index) ? panos[index] : nil }

    func look(dx: Double, dy: Double) {
        yaw += dx * 0.004
        pitch = max(-1.3, min(1.3, pitch - dy * 0.004))
        updateCamera()
    }

    func advance(by delta: Int) { index = (index + delta + panos.count) % max(panos.count, 1) }

    private func updateCamera() {
        let cp = cos(pitch), sp = sin(pitch)
        let fwd = SIMD3<Float>(Float(cp * sin(yaw)), Float(sp), Float(-cp * cos(yaw)))
        camera.look(at: fwd, from: .zero, relativeTo: nil)
    }

    func material(for pano: Panorama) async -> UnlitMaterial? {
        guard let url = Self.resourceURL(pano.id) else { return nil }
        guard let tex = try? await TextureResource(contentsOf: url) else { return nil }
        var m = UnlitMaterial()
        m.color = .init(tint: .white, texture: .init(tex))
        return m
    }

    static func resourceURL(_ id: String) -> URL? {
        Bundle.main.url(forResource: id, withExtension: "jpg")
            ?? Bundle.main.url(forResource: id, withExtension: "jpg", subdirectory: "panoramas")
    }
}

struct PanoramaView: View {
    @State private var model: PanoramaModel?
    @State private var lastLook: CGSize = .zero
    @State private var status = "Loading…"

    var body: some View {
        ZStack(alignment: .bottom) {
            RealityView { content in
                do {
                    let house = try HouseLoader.loadFromBundle()
                    let m = PanoramaModel(house: house)
                    content.add(m.sphere)
                    content.add(m.camera)
                    model = m
                    await load(m, index: m.index)
                } catch {
                    status = "Load error: \(error.localizedDescription)"
                }
            }
            .background(.black)
            .ignoresSafeArea()
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        model?.look(dx: Double(g.translation.width - lastLook.width),
                                    dy: Double(g.translation.height - lastLook.height))
                        lastLook = g.translation
                    }
                    .onEnded { _ in lastLook = .zero }
            )

            VStack(spacing: 12) {
                Text(status)
                    .font(.caption.monospaced())
                    .padding(8)
                    .background(.black.opacity(0.55))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                HStack {
                    Button { step(-1) } label: { label("◀ Prev") }
                    Button { step(1) } label: { label("Next ▶") }
                }
            }
            .padding(.bottom, 230)
        }
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.subheadline.bold()).padding(.horizontal, 18).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule()).foregroundStyle(.white)
    }

    private func step(_ d: Int) {
        guard let m = model else { return }
        m.advance(by: d)
        Task { await load(m, index: m.index) }
    }

    private func load(_ m: PanoramaModel, index: Int) async {
        guard let pano = m.current else { return }
        if let mat = await m.material(for: pano) {
            m.sphere.model?.materials = [mat]
            status = "Scan \(pano.label ?? "?") • \(roomLabel(pano))"
        } else {
            status = "Missing panorama image for \(pano.id)"
        }
    }

    private func roomLabel(_ pano: Panorama) -> String {
        guard let rid = pano.anchor?.room?.id else { return "—" }
        return model?.roomTypeById[rid] ?? "—"
    }
}

#Preview {
    PanoramaView()
}
