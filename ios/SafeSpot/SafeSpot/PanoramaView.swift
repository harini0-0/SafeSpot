//  PanoramaView.swift
//  Photoreal walkthrough: stand inside a real 360° scan photo (equirectangular on a
//  sphere) and look around by dragging. Step between scan points with the button.
//  The equirects were built offline from the real skybox faces (scripts/build_panoramas.py).

import SwiftUI
import RealityKit
import ARKit
import Combine
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

    /// Yaw-only look: turning left/right around the vertical axis. Pitch stays level
    /// (no looking up/down) so navigation reads clearly.
    func look(dx: Double, dy: Double) {
        yaw += dx * 0.004
        updateCamera()
    }

    // MARK: - Movement between scan points (look where you want, then go forward)

    var history: [Int] = []

    private func neighborIndices() -> [Int] {
        guard let c = current else { return [] }
        let idxOf = Dictionary(uniqueKeysWithValues: panos.enumerated().map { ($0.element.id, $0.offset) })
        return (c.anchor?.neighbors ?? []).compactMap { idxOf[$0] }
    }

    private func angleDiff(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }; if d < -180 { d += 360 }
        return abs(d)
    }

    /// Nearest scan point to a model position (used by live tracking).
    func nearestPanoIndex(x: Double, y: Double) -> Int {
        var best = 0; var bd = Double.greatestFiniteMagnitude
        for (i, p) in panos.enumerated() {
            let d = hypot(p.position.x - x, p.position.y - y)
            if d < bd { bd = d; best = i }
        }
        return best
    }

    /// Point the view at a model-space heading (deg) — used by live tracking.
    func applyHeadingDeg(_ h: Double) {
        yaw = (90 - h) * .pi / 180
        updateCamera()
    }

    /// The neighbouring scan point closest to the current look direction (within ~80°).
    func forwardIndex() -> Int? {
        let va = viewAzimuthDeg
        var best: Int?; var bd = 80.0
        for ni in neighborIndices() {
            let d = angleDiff(azimuthDeg(to: panos[ni].position), va)
            if d < bd { bd = d; best = ni }
        }
        return best
    }

    func advance(by delta: Int) { index = (index + delta + panos.count) % max(panos.count, 1) }

    // MARK: - Heading alignment (photo ↔ house)
    // Verified offline: a model direction at azimuth `az` appears in the equirect at
    // longitude (az - panoYaw + 90). We rotate the sphere so the photo lines up with
    // model azimuths; `headingCalibDeg`/`headingSign` absorb the sphere-UV + mirror
    // convention and are tuned once on device.
    var headingCalibDeg: Double = 0
    var headingSign: Double = -1

    func panoYawDeg(_ p: Panorama) -> Double {
        guard let q = p.rotation else { return 0 }
        return atan2(q.z, q.w) * 2 * 180 / .pi
    }

    func alignSphere(to pano: Panorama) {
        let deg = headingSign * panoYawDeg(pano) + headingCalibDeg
        sphere.orientation = simd_quatf(angle: Float(deg * .pi / 180), axis: SIMD3<Float>(0, 1, 0))
    }

    /// Current look direction as a model-space azimuth (degrees).
    var viewAzimuthDeg: Double { (90 - yaw * 180 / .pi) }

    /// Azimuth (deg) from the current scan point to a model position.
    func azimuthDeg(to p: Vector3) -> Double {
        guard let c = current else { return 0 }
        return atan2(p.y - c.position.y, p.x - c.position.x) * 180 / .pi
    }

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
    @State private var headingTick = 0
    @State private var showCalib = false
    @State private var live = false
    @State private var locate: LocateSession?
    private let hazards = ["Tornado", "Earthquake", "Fire"]
    private let tick = Timer.publish(every: 1.0 / 20.0, on: .main, in: .common).autoconnect()

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
                        model?.look(dx: Double(g.translation.width - lastLook.width), dy: 0)
                        lastLook = g.translation
                        headingTick &+= 1   // refresh the arrow as you turn
                    }
                    .onEnded { _ in lastLook = .zero }
            )

            // Keep the ARKit session alive (frames only flow when its view exists).
            if live, let s = locate {
                ARViewHost(arView: s.ar.arView).frame(width: 1, height: 1).opacity(0.01)
                    .allowsHitTesting(false)
            }

            // Cross-fade overlay while swapping panoramas.
            Color.black.opacity(fade).ignoresSafeArea().allowsHitTesting(false)

            // Live-tracking align guide (big, centred).
            if live, let s = locate, s.mode != .tracking {
                VStack(spacing: 10) {
                    Image(systemName: "hand.tap.fill").font(.system(size: 44)).foregroundStyle(.white)
                    Text(alignPrompt(s)).font(.title3.bold()).multilineTextAlignment(.center)
                        .foregroundStyle(.white).padding(.horizontal, 24)
                }
                .padding(24).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .allowsHitTesting(false)
            }

            // Floating directional arrow toward the safe spot, composited over the photo.
            if let m = model, let p = plan, p.hazard != "Earthquake",
               let targetIdx = p.routePanoIndices.last, m.panos.indices.contains(targetIdx),
               m.index != targetIdx {
                let _ = headingTick
                let target = m.panos[targetIdx].position
                let rel = m.azimuthDeg(to: target) - m.viewAzimuthDeg
                let dist = Int((hypot(target.x - (m.current?.position.x ?? 0),
                                      target.y - (m.current?.position.y ?? 0))).rounded())
                VStack(spacing: 6) {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 70, weight: .bold))
                        .foregroundStyle(.green)
                        .rotationEffect(.degrees(rel))
                        .shadow(color: .black.opacity(0.6), radius: 6)
                    Text("\(dist) m to safe spot")
                        .font(.caption.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.5), in: Capsule())
                }
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }

            // Minimap: tap a dot to move there.
            if let m = model {
                VStack {
                    HStack {
                        Spacer()
                        Minimap(graph: m.graph, panos: m.panos, currentIndex: m.index,
                                route: plan?.routePanoIndices ?? [],
                                onSelect: { i in
                                    guard !live, i != m.index else { return }
                                    m.index = i
                                    Task { await load(m, index: i) }
                                },
                                onTapModel: live ? { p in locate?.tap(p) } : nil)
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
                    let arrived = atSafeSpot(p)
                    Text(arrived ? "You're at the safe spot ✓ — take cover." : p.instruction)
                        .font(.subheadline.bold())
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(12)
                        .frame(maxWidth: 360)
                        .background(.green.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                }

                // Movement: Live (real walking) or manual turn + forward.
                HStack(spacing: 12) {
                    Button { toggleLive() } label: {
                        Text(live ? "📍 Live ON" : "📍 Go Live").font(.subheadline.bold())
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(live ? AnyShapeStyle(.green.opacity(0.6)) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    Button { moveBack() } label: { label("◀ Back") }
                        .disabled(live || (model?.history.isEmpty ?? true))
                    Button { moveForward() } label: { label("Forward ▶") }
                        .disabled(live || model?.forwardIndex() == nil)
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

            // Debug: one-time heading calibration (align the photo to the house).
            if showCalib, let m = model {
                HStack(spacing: 8) {
                    Text("align").font(.caption2).foregroundStyle(.white)
                    Button("◂15°") { m.headingCalibDeg -= 15; reAlign(m) }
                    Button("▸15°") { m.headingCalibDeg += 15; reAlign(m) }
                    Button("flip") { m.headingSign *= -1; reAlign(m) }
                }
                .font(.caption2).buttonStyle(.bordered).tint(.white)
                .padding(6).background(.black.opacity(0.6), in: Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 12).padding(.bottom, 300)
            }
        }
        .onLongPressGesture { showCalib.toggle() }
        .onReceive(tick) { _ in
            guard live, let s = locate, let m = model, let pos = s.position else { return }
            // Continuous heading → look; snap to the nearest scan photo as you move.
            m.applyHeadingDeg(pos.heading)
            let ni = m.nearestPanoIndex(x: pos.x, y: pos.y)
            if ni != m.index { m.index = ni; Task { await load(m, index: ni) } }
            headingTick &+= 1
        }
    }

    private func toggleLive() {
        live.toggle()
        if live { let s = LocateSession(); s.start(); locate = s }
        else { locate?.stop(); locate = nil }
    }

    private func alignPrompt(_ s: LocateSession) -> String {
        if let e = s.loadError { return e }
        switch s.mode {
        case .tapHere: return "Tap the map (top-right)\nwhere you are standing"
        case .tapToward: return "Now tap the map\ntoward where you're facing"
        case .tracking: return ""
        }
    }

    private func reAlign(_ m: PanoramaModel) {
        if let pano = m.current { m.alignSphere(to: pano) }
    }

    private func startHazard(_ h: String) {
        guard let m = model else { return }
        plan = m.demoPlan(for: h)   // keep you where you are; the arrow guides you out
    }

    private func atSafeSpot(_ p: PanoramaModel.DemoPlan) -> Bool {
        guard let m = model, let t = p.routePanoIndices.last else { return false }
        return m.index == t
    }

    private func moveForward() {
        guard let m = model, let ni = m.forwardIndex() else { return }
        m.history.append(m.index); m.index = ni
        Task { await load(m, index: ni) }
    }

    private func moveBack() {
        guard let m = model, let prev = m.history.popLast() else { return }
        m.index = prev
        Task { await load(m, index: prev) }
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.subheadline.bold()).padding(.horizontal, 18).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule()).foregroundStyle(.white)
    }

    private func load(_ m: PanoramaModel, index: Int) async {
        guard let pano = m.current else { return }
        withAnimation(.easeIn(duration: 0.15)) { fade = 1 }
        if let mat = await m.material(for: pano) {
            m.sphere.model?.materials = [mat]
            m.alignSphere(to: pano)
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
    /// When set (live tracking), a tap reports the model point instead of selecting a scan.
    var onTapModel: ((Point2D) -> Void)? = nil

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

    private func unproject(_ p: CGPoint, in size: CGSize) -> Point2D {
        let b = bounds
        let pad: CGFloat = 6
        let w = size.width - pad * 2, h = size.height - pad * 2
        let fx = Double((p.x - pad) / max(w, 1))
        let fy = Double(1 - (p.y - pad) / max(h, 1))
        return Point2D(x: b.minX + fx * (b.maxX - b.minX), y: b.minY + fy * (b.maxY - b.minY))
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
                // Safe-spot destination: a glowing green ring (no route line).
                if let target = route.last {
                    let c = project(panos[target].position.x, panos[target].position.y, in: size)
                    for (r, a) in [(11.0, 0.25), (8.0, 0.5), (5.0, 1.0)] {
                        let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                        ctx.fill(Path(ellipseIn: rect), with: .color(.green.opacity(a)))
                    }
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
                    if let onTapModel {
                        onTapModel(unproject(g.location, in: geo.size))
                        return
                    }
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

/// Hosts the locate module's ARView so the ARKit session actually delivers frames
/// (an ARSession's frames only flow while its view is in the hierarchy). Kept tiny
/// and nearly invisible — the panorama is what the user sees.
struct ARViewHost: UIViewRepresentable {
    let arView: ARView
    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

#Preview {
    PanoramaView()
}
