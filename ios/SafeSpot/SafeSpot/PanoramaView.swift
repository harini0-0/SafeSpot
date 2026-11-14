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
    let graph: HouseGraph

    init(house: LoadedHouse) {
        let all = house.model.sections.panoramas?.panoLocations ?? []
        panos = all.sorted { (Int($0.label ?? "") ?? 0) < (Int($1.label ?? "") ?? 0) }
        roomTypeById = Dictionary(uniqueKeysWithValues: house.graph.rooms.map { ($0.id, $0.type) })
        graph = house.graph
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

    // MARK: - DEBUG demo guidance (stand-in for the backend planner/router, Phase E).
    // Fixture safe targets derived from the real data + a BFS over scan-point
    // neighbors. The real Plan will come from POST /plan.

    struct DemoPlan {
        let hazard: String
        let targetRoomId: String
        let routePanoIndices: [Int]   // from current scan to the safe scan
        let instruction: String
    }

    /// Fixture target room per hazard (matches CLAUDE.md safe-spot logic for this house).
    private func targetRoom(for hazard: String) -> String {
        switch hazard {
        case "Tornado":    return "3m54yff1z7crxaywd8if9rb0d"   // interior closet off Bedroom 1: no windows, no exterior walls
        case "Fire":       return "613htqkzf66zz7hf7n8kzszed"   // Living Room: has the exterior exit
        default:           return currentRoomId() ?? "3m54yff1z7crxaywd8if9rb0d"  // Earthquake: cover in place
        }
    }

    func currentRoomId() -> String? { current?.anchor?.room?.id }

    private func panoIndexMap() -> [String: Int] {
        Dictionary(uniqueKeysWithValues: panos.enumerated().map { ($0.element.id, $0.offset) })
    }

    private func firstPanoIndex(inRoom roomId: String) -> Int? {
        panos.firstIndex { $0.anchor?.room?.id == roomId }
    }

    /// BFS over scan-point neighbours.
    private func route(from startIdx: Int, to targetIdx: Int) -> [Int] {
        let idxOf = panoIndexMap()
        var prev = [Int: Int]()
        var seen = Set([startIdx])
        var queue = [startIdx]
        while !queue.isEmpty {
            let cur = queue.removeFirst()
            if cur == targetIdx { break }
            for nid in panos[cur].anchor?.neighbors ?? [] {
                guard let ni = idxOf[nid], !seen.contains(ni) else { continue }
                seen.insert(ni); prev[ni] = cur; queue.append(ni)
            }
        }
        guard seen.contains(targetIdx) else { return [] }
        var path = [targetIdx]; var c = targetIdx
        while c != startIdx, let p = prev[c] { path.append(p); c = p }
        return path.reversed()
    }

    func demoPlan(for hazard: String) -> DemoPlan {
        let targetRoomId = targetRoom(for: hazard)
        let targetIdx = firstPanoIndex(inRoom: targetRoomId) ?? index
        let r = (hazard == "Earthquake") ? [index] : route(from: index, to: targetIdx)
        let roomName = roomTypeById[targetRoomId] ?? "safe room"
        let instruction: String
        switch hazard {
        case "Tornado":    instruction = "Tornado — go to the \(roomName) (interior, no windows). Get under cover."
        case "Fire":       instruction = "Fire — head to the \(roomName) and out the exterior door."
        default:           instruction = "Earthquake — take cover here now. Move to safety after the shaking stops."
        }
        return DemoPlan(hazard: hazard, targetRoomId: targetRoomId,
                        routePanoIndices: r, instruction: instruction)
    }

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
    @State private var fade: Double = 0
    @State private var plan: PanoramaModel.DemoPlan?
    @State private var routeStep = 0
    private let hazards = ["Tornado", "Earthquake", "Fire"]

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

            // Cross-fade overlay while swapping panoramas.
            Color.black.opacity(fade).ignoresSafeArea().allowsHitTesting(false)

            // Minimap: tap a dot to move there.
            if let m = model {
                VStack {
                    HStack {
                        Spacer()
                        Minimap(graph: m.graph, panos: m.panos, currentIndex: m.index,
                                route: plan?.routePanoIndices ?? []) { i in
                            guard i != m.index else { return }
                            m.index = i
                            Task { await load(m, index: i) }
                        }
                        .frame(width: 180, height: 140)
                        .padding(8)
                        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.trailing, 10)
                        .padding(.top, 110)
                    }
                    Spacer()
                }
            }

            VStack(spacing: 10) {
                Text(status)
                    .font(.caption.monospaced())
                    .padding(8)
                    .background(.black.opacity(0.55))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                if let p = plan {
                    VStack(spacing: 8) {
                        Text(p.instruction)
                            .font(.subheadline.bold())
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                        if p.hazard != "Earthquake" && p.routePanoIndices.count > 1 {
                            let atEnd = routeStep >= p.routePanoIndices.count - 1
                            Button { nextRouteStep(p) } label: {
                                label(atEnd ? "You're at the safe spot ✓" : "Go ▶  (step \(routeStep + 1)/\(p.routePanoIndices.count))")
                            }
                            .disabled(atEnd)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: 360)
                    .background(.green.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                }

                HStack(spacing: 10) {
                    ForEach(hazards, id: \.self) { h in
                        Button { startHazard(h) } label: {
                            Text(h).font(.subheadline.bold())
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(.ultraThinMaterial, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
            .padding(.bottom, 150)
        }
    }

    private func startHazard(_ h: String) {
        guard let m = model else { return }
        let p = m.demoPlan(for: h)
        plan = p
        routeStep = 0
        // Jump to the start of the route (current scan).
        if let first = p.routePanoIndices.first, first != m.index {
            m.index = first; Task { await load(m, index: first) }
        }
    }

    private func nextRouteStep(_ p: PanoramaModel.DemoPlan) {
        guard let m = model, routeStep < p.routePanoIndices.count - 1 else { return }
        routeStep += 1
        let idx = p.routePanoIndices[routeStep]
        m.index = idx
        Task { await load(m, index: idx) }
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
        withAnimation(.easeIn(duration: 0.15)) { fade = 1 }
        if let mat = await m.material(for: pano) {
            m.sphere.model?.materials = [mat]
            status = "Scan \(pano.label ?? "?") • \(roomLabel(pano))"
        } else {
            status = "Missing panorama image for \(pano.id)"
        }
        withAnimation(.easeOut(duration: 0.35)) { fade = 0 }
    }

    private func roomLabel(_ pano: Panorama) -> String {
        guard let rid = pano.anchor?.room?.id else { return "—" }
        return model?.roomTypeById[rid] ?? "—"
    }
}

/// A small floor-plan minimap with the scan points; tap a dot to jump there.
struct Minimap: View {
    let graph: HouseGraph
    let panos: [Panorama]
    let currentIndex: Int
    var route: [Int] = []
    let onSelect: (Int) -> Void

    private var bounds: (minX: Double, maxX: Double, minY: Double, maxY: Double) {
        let pts = graph.rooms.flatMap { $0.polygon }
        return (pts.map { $0.x }.min() ?? -11, pts.map { $0.x }.max() ?? 1,
                pts.map { $0.y }.min() ?? -4, pts.map { $0.y }.max() ?? 5)
    }

    private func project(_ x: Double, _ y: Double, in size: CGSize) -> CGPoint {
        let b = bounds
        let pad: CGFloat = 6
        let w = size.width - pad * 2
        let h = size.height - pad * 2
        let fx = (x - b.minX) / max(b.maxX - b.minX, 1e-6)
        let fy = (y - b.minY) / max(b.maxY - b.minY, 1e-6)
        let px = pad + CGFloat(fx) * w
        let py = pad + (1 - CGFloat(fy)) * h  // +y up
        return CGPoint(x: px, y: py)
    }

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                for r in graph.rooms where r.isWalkable && r.polygon.count >= 3 {
                    var path = Path()
                    let poly: [CGPoint] = r.polygon.map { project($0.x, $0.y, in: size) }
                    path.addLines(poly)
                    path.closeSubpath()
                    ctx.fill(path, with: .color(Color.white.opacity(0.22)))
                    ctx.stroke(path, with: .color(Color.white.opacity(0.55)), lineWidth: 1)
                }
                // Route polyline + safe target ring.
                if route.count >= 2 {
                    var rp = Path()
                    rp.addLines(route.map { project(panos[$0].position.x, panos[$0].position.y, in: size) })
                    ctx.stroke(rp, with: .color(.green), style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
                }
                if let target = route.last {
                    let c = project(panos[target].position.x, panos[target].position.y, in: size)
                    let rect = CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16)
                    ctx.stroke(Path(ellipseIn: rect), with: .color(.green), lineWidth: 2)
                }
                for (i, p) in panos.enumerated() {
                    let c = project(p.position.x, p.position.y, in: size)
                    let rad: CGFloat = (i == currentIndex) ? 6 : 3.5
                    let rect = CGRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2)
                    let color: Color = (i == currentIndex) ? Color.yellow : Color.white.opacity(0.85)
                    ctx.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onEnded { g in
                    var best = 0
                    var bd = CGFloat.greatestFiniteMagnitude
                    for (i, p) in panos.enumerated() {
                        let c = project(p.position.x, p.position.y, in: geo.size)
                        let d = hypot(c.x - g.location.x, c.y - g.location.y)
                        if d < bd { bd = d; best = i }
                    }
                    if bd < 28 { onSelect(best) }
                }
            )
        }
    }
}

#Preview {
    PanoramaView()
}
