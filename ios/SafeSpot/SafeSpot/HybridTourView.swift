//  HybridTourView.swift
//  The Matterport-style walkthrough: you STAND inside a sharp 360° panorama at each
//  scan point, and when you move you GLIDE through the textured mesh for ~0.5 s and
//  land on the next panorama. Sharp when still, continuous when moving, photoreal.
//
//  At rest: the panorama sphere is shown (mesh hidden) so the view is the crisp photo.
//  Moving: hide the sphere, show the textured mesh, dolly the camera to the next scan
//  point, then swap to that panorama. Movement comes from the minimap, Forward/Back,
//  or live tracking (Sanjana's locate).

import SwiftUI
import RealityKit
import ARKit
import Combine
import SafeSpotCore

@MainActor
final class TourModel {
    let graph: HouseGraph
    let panos: [Panorama]
    let roomTypeById: [String: String]
    var index = 0
    var yaw: Double = 0            // radians; model heading 0 = +Y, clockwise
    var transitioning = false

    let camera = PerspectiveCamera()
    let sphere = ModelEntity()
    var mesh: Entity?

    init(house: LoadedHouse) {
        graph = house.graph
        let all = house.model.sections.panoramas?.panoLocations ?? []
        panos = all.sorted { (Int($0.label ?? "") ?? 0) < (Int($1.label ?? "") ?? 0) }
        roomTypeById = Dictionary(uniqueKeysWithValues: house.graph.rooms.map { ($0.id, $0.type) })
        camera.camera.fieldOfViewInDegrees = 90   // wider so the room is easy to read
        sphere.components.set(ModelComponent(mesh: SkySphere.make(radius: 50), materials: []))
    }

    var current: Panorama? { panos.indices.contains(index) ? panos[index] : nil }

    /// Scene-space position of a scan point (camera + sphere centre sit here).
    func scenePos(_ i: Int) -> SIMD3<Float> {
        let p = panos[i].position
        let s = CoordinateTransform.modelToScene(Vector3(x: p.x, y: p.y, z: p.z))
        return SIMD3<Float>(Float(s.x), Float(s.y), Float(s.z))
    }

    func placeAtRest() {
        sphere.position = scenePos(index)
        sphere.isEnabled = true
        mesh?.isEnabled = false
        updateLook()
    }

    func updateLook() {
        let o = scenePos(index)
        let fwd = SIMD3<Float>(Float(sin(yaw)), 0, Float(-cos(yaw)))
        camera.look(at: o + fwd, from: o, relativeTo: nil)
    }

    func material(for pano: Panorama) async -> UnlitMaterial? {
        guard let url = Bundle.main.url(forResource: pano.id, withExtension: "jpg")
                ?? Bundle.main.url(forResource: pano.id, withExtension: "jpg", subdirectory: "panoramas"),
              let tex = try? await TextureResource(contentsOf: url) else { return nil }
        var m = UnlitMaterial()
        m.color = .init(tint: .white, texture: .init(tex))
        m.faceCulling = .none   // seamless sphere viewed from the inside
        return m
    }

    func roomLabel(_ pano: Panorama) -> String {
        guard let r = pano.anchor?.room?.id else { return "—" }
        return roomTypeById[r] ?? "—"
    }

    // MARK: movement helpers

    func viewAzimuthDeg() -> Double { 90 - yaw * 180 / .pi }

    func forwardIndex() -> Int? {
        guard let c = current else { return nil }
        let idxOf = Dictionary(uniqueKeysWithValues: panos.enumerated().map { ($0.element.id, $0.offset) })
        let va = viewAzimuthDeg()
        var best: Int?; var bd = 80.0
        for nid in c.anchor?.neighbors ?? [] {
            guard let ni = idxOf[nid] else { continue }
            let p = panos[ni].position, cc = c.position
            let az = atan2(p.y - cc.y, p.x - cc.x) * 180 / .pi
            var d = (az - va).truncatingRemainder(dividingBy: 360)
            if d > 180 { d -= 360 }; if d < -180 { d += 360 }
            if abs(d) < bd { bd = abs(d); best = ni }
        }
        return best
    }

    func nearestPanoIndex(x: Double, y: Double) -> Int {
        var best = 0; var bd = Double.greatestFiniteMagnitude
        for (i, p) in panos.enumerated() {
            let d = hypot(p.position.x - x, p.position.y - y)
            if d < bd { bd = d; best = i }
        }
        return best
    }

    // MARK: hazard (local demo stand-in for the backend planner/router)

    func safeTargetIndex(for hazard: String) -> Int {
        let room: String
        switch hazard {
        case "Tornado": room = "3m54yff1z7crxaywd8if9rb0d"
        case "Fire": room = "613htqkzf66zz7hf7n8kzszed"
        default: room = current?.anchor?.room?.id ?? "3m54yff1z7crxaywd8if9rb0d"
        }
        return panos.firstIndex { $0.anchor?.room?.id == room } ?? index
    }

    /// BFS over scan-point neighbours → ordered pano indices from current to target.
    func route(to target: Int) -> [Int] {
        let idxOf = Dictionary(uniqueKeysWithValues: panos.enumerated().map { ($0.element.id, $0.offset) })
        var prev = [Int: Int](); var seen = Set([index]); var q = [index]
        while !q.isEmpty {
            let cur = q.removeFirst()
            if cur == target { break }
            for nid in panos[cur].anchor?.neighbors ?? [] {
                guard let ni = idxOf[nid], !seen.contains(ni) else { continue }
                seen.insert(ni); prev[ni] = cur; q.append(ni)
            }
        }
        guard seen.contains(target) else { return [] }
        var path = [target]; var c = target
        while c != index, let p = prev[c] { path.append(p); c = p }
        return path.reversed()
    }
}

struct HybridTourView: View {
    @State private var model: TourModel?
    @State private var lastLook: CGSize = .zero
    @State private var status = "Loading…"
    @State private var fade: Double = 0
    @State private var plan: (hazard: String, route: [Int], instruction: String)?
    @State private var live = false
    @State private var locate: LocateSession?
    @State private var tickN = 0
    @State private var pendingRoute: [Int] = []
    private let hazards = ["Tornado", "Earthquake", "Fire"]
    private let tick = Timer.publish(every: 1.0 / 20.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .bottom) {
            RealityView { content in
                do {
                    let house = try HouseLoader.loadFromBundle()
                    let m = TourModel(house: house)
                    if let mesh = await TexturedHouse.load() { m.mesh = mesh; content.add(mesh) }
                    content.add(m.sphere)
                    content.add(m.camera)
                    model = m
                    await arrive(m, to: m.index)       // load first panorama
                    status = m.roomLabel(m.current!)
                } catch { status = "Load error: \(error.localizedDescription)" }
            }
            .background(.black)
            .ignoresSafeArea()
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard let m = model, !m.transitioning, !live else { return }
                    m.yaw += Double(g.translation.width - lastLook.width) * 0.004
                    lastLook = g.translation
                    m.updateLook()
                }
                .onEnded { _ in lastLook = .zero })

            if live, let s = locate {
                ARViewHost(arView: s.ar.arView).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
            }
            Color.black.opacity(fade).ignoresSafeArea().allowsHitTesting(false)

            if live, let s = locate, s.mode != .tracking {
                Text(s.mode == .tapHere ? "Tap the map where you are" : "Tap the map toward where you face")
                    .font(.title3.bold()).foregroundStyle(.white).padding(20)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center).allowsHitTesting(false)
            }

            if let m = model {
                VStack {
                    HStack {
                        Spacer()
                        Minimap(graph: m.graph, panos: m.panos, currentIndex: m.index,
                                route: plan?.route ?? [], headingRad: m.yaw,
                                onSelect: { i in if !live { travel(m, to: i) } },
                                onTapModel: live ? { p in locate?.tap(p) } : nil)
                        .frame(width: 180, height: 140).padding(8)
                        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.trailing, 10).padding(.top, 60)
                    }
                    Spacer()
                }
            }

            VStack(spacing: 10) {
                Text(statusLine).font(.caption.monospaced()).padding(8)
                    .background(.black.opacity(0.55)).foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                if let p = plan {
                    Text(p.instruction).font(.subheadline.bold()).multilineTextAlignment(.center)
                        .foregroundStyle(.white).padding(12).frame(maxWidth: 360)
                        .background(.green.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                }
                HStack(spacing: 10) {
                    Button { toggleLive() } label: { chip(live ? "📍 Live" : "Virtual", live) }
                    Button { if let m = model { glideBack(m) } } label: { chip("◀", false) }
                    Button { if let m = model, let n = m.forwardIndex() { glide(m, to: n) } } label: { chip("Forward ▶", false) }
                }
                HStack(spacing: 8) {
                    ForEach(hazards, id: \.self) { h in
                        Button { startHazard(h) } label: { chip(h, plan?.hazard == h) }
                    }
                    if plan != nil { Button { if let m = model { goNextStep(m) } } label: { chip("Go ▶", false) } }
                }
            }
            .padding(.bottom, 36)
        }
        .onReceive(tick) { _ in
            guard live, let m = model, let s = locate, let pos = s.position, !m.transitioning else { return }
            m.yaw = pos.heading * .pi / 180
            let ni = m.nearestPanoIndex(x: pos.x, y: pos.y)
            if ni != m.index { travel(m, to: ni) } else { m.updateLook() }
            tickN &+= 1
        }
    }

    @State private var historyStore: [Int] = []

    private var statusLine: String {
        guard let m = model else { return status }
        if live, let s = locate, s.mode != .tracking { return "LIVE — aligning" }
        return "\(live ? "LIVE" : "Tour") • \(m.current.map { m.roomLabel($0) } ?? "—")"
    }

    private func chip(_ t: String, _ on: Bool) -> some View {
        Text(t).font(.subheadline.bold()).padding(.horizontal, 14).padding(.vertical, 10)
            .background(on ? AnyShapeStyle(.green.opacity(0.6)) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
            .foregroundStyle(.white)
    }

    // MARK: transitions

    /// Travel to any scan point by gliding hop-by-hop along connected neighbours
    /// (so the camera never cuts straight through a wall).
    private func travel(_ m: TourModel, to target: Int) {
        guard !m.transitioning, target != m.index else { return }
        let r = m.route(to: target)
        guard r.count >= 2 else { return }
        pendingRoute = Array(r.dropFirst())   // drop current
        advancePending(m)
    }

    private func advancePending(_ m: TourModel) {
        guard let next = pendingRoute.first else { return }
        glide(m, to: next)
    }

    private func glide(_ m: TourModel, to target: Int) {
        guard !m.transitioning, target != m.index, m.panos.indices.contains(target) else { return }
        m.transitioning = true
        historyStore.append(m.index)
        let from = m.scenePos(m.index), to = m.scenePos(target)
        m.sphere.isEnabled = false
        m.mesh?.isEnabled = true
        // Face the target and dolly there through the mesh.
        m.camera.look(at: to, from: from, relativeTo: nil)
        var t = m.camera.transform; t.translation = to
        m.camera.move(to: t, relativeTo: nil, duration: 0.55, timingFunction: .easeInOut)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            Task { await arrive(m, to: target) }
        }
    }

    private func glideBack(_ m: TourModel) {
        guard !m.transitioning, let prev = historyStore.popLast() else { return }
        // temporary: don't double-push history on back
        m.transitioning = true
        let from = m.scenePos(m.index), to = m.scenePos(prev)
        m.sphere.isEnabled = false; m.mesh?.isEnabled = true
        m.camera.look(at: to, from: from, relativeTo: nil)
        var t = m.camera.transform; t.translation = to
        m.camera.move(to: t, relativeTo: nil, duration: 0.55, timingFunction: .easeInOut)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            Task { await arrive(m, to: prev) }
        }
    }

    private func arrive(_ m: TourModel, to target: Int) async {
        m.index = target
        withAnimation(.easeIn(duration: 0.1)) { fade = 0.6 }
        if let pano = m.current, let mat = await m.material(for: pano) {
            m.sphere.model?.materials = [mat]
        }
        m.placeAtRest()
        withAnimation(.easeOut(duration: 0.3)) { fade = 0 }
        m.transitioning = false
        status = m.current.map { m.roomLabel($0) } ?? "—"
        // Continue a multi-hop route (minimap tap / hazard Go), one neighbour at a time.
        if !pendingRoute.isEmpty, pendingRoute.first == target {
            pendingRoute.removeFirst()
            if !pendingRoute.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { advancePending(m) }
            }
        }
    }

    // MARK: hazard guidance

    private func startHazard(_ h: String) {
        guard let m = model else { return }
        let target = m.safeTargetIndex(for: h)
        let r = (h == "Earthquake") ? [m.index] : m.route(to: target)
        let name = m.roomTypeById[m.panos[target].anchor?.room?.id ?? ""] ?? "safe room"
        let instr: String
        switch h {
        case "Tornado": instr = "Tornado — go to the \(name) (interior, no windows). Get under cover."
        case "Fire": instr = "Fire — head to the \(name) and out the exterior door."
        default: instr = "Earthquake — take cover here now; move after the shaking stops."
        }
        plan = (h, r, instr)
    }

    private func goNextStep(_ m: TourModel) {
        guard let p = plan, let target = p.route.last, target != m.index else { return }
        travel(m, to: target)   // glide the whole route to the safe spot, hop by hop
    }

    private func toggleLive() {
        live.toggle()
        if live { let s = LocateSession(); s.start(); locate = s }
        else { locate?.stop(); locate = nil }
    }
}

#Preview { HybridTourView() }
