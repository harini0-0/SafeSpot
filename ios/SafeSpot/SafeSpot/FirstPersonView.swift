//  FirstPersonView.swift
//  Continuous first-person walkthrough of the real house. In LIVE mode it's driven
//  by Sanjana's `locate` module: as you physically move, the camera moves through
//  the 3D model in real time (position is floor-snapped by locate, so you pass
//  through doorways, not walls). In Virtual mode a joystick moves and drag looks.
//  The 3D model is in true model coordinates, so the safe-spot arrow aligns exactly
//  (no photo calibration needed here).

import SwiftUI
import RealityKit
import Combine
import SafeSpotCore

@MainActor
final class WalkState {
    var house: LoadedHouse?
    var collision: WallCollision?
    var pos = Point2D(x: 0, y: 0)
    var yaw: Double = 0        // radians; model heading 0 = +Y, clockwise
    let eye: Double = 1.55
    let camera = PerspectiveCamera()

    func start(in house: LoadedHouse) {
        self.house = house
        self.collision = WallCollision(graph: house.graph)
        let panos = house.model.sections.panoramas?.panoLocations ?? []
        if let p = panos.first(where: { $0.anchor?.room?.id == "9hauvfhwiqt" }) ?? panos.first {
            pos = Point2D(x: p.position.x, y: p.position.y)
        } else {
            pos = house.graph.roomsById["9hauvfhwiqt"]?.centroid ?? Point2D(x: 0, y: 0)
        }
        camera.camera.fieldOfViewInDegrees = 65
        updateCamera()
    }

    /// LIVE: place the camera from a locate Position (continuous real-world tracking).
    func applyLive(_ p: Position) {
        pos = Point2D(x: p.x, y: p.y)
        yaw = p.heading * .pi / 180
        updateCamera()
    }

    func look(dx: Double) {        // Virtual only (yaw-only)
        yaw += dx * 0.004
        updateCamera()
    }

    func step(move: CGPoint, dt: Double) {   // Virtual joystick
        guard let collision, move != .zero else { return }
        let jx = Double(move.x), jy = Double(-move.y)
        let fwd = Point2D(x: sin(yaw), y: cos(yaw))
        let right = Point2D(x: cos(yaw), y: -sin(yaw))
        let target = Point2D(x: pos.x + (fwd.x * jy + right.x * jx) * 1.5 * dt,
                             y: pos.y + (fwd.y * jy + right.y * jx) * 1.5 * dt)
        pos = collision.resolve(from: pos, to: target)
        updateCamera()
    }

    func currentRoomLabel() -> String { house?.graph.room(containing: pos)?.type ?? "—" }

    /// Signed screen rotation (deg) from the look direction to a target point; 0 = ahead.
    func bearing(to target: Point2D) -> Double {
        let fwd = Point2D(x: sin(yaw), y: cos(yaw))
        let t = Point2D(x: target.x - pos.x, y: target.y - pos.y)
        let dot = fwd.x * t.x + fwd.y * t.y
        let cross = fwd.x * t.y - fwd.y * t.x
        return atan2(cross, dot) * 180 / .pi
    }

    func distance(to target: Point2D) -> Double { hypot(target.x - pos.x, target.y - pos.y) }

    private func updateCamera() {
        let p = CoordinateTransform.modelToScene(Vector3(x: pos.x, y: pos.y, z: eye))
        let origin = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
        let forward = SIMD3<Float>(Float(sin(yaw)), 0, Float(-cos(yaw)))
        camera.look(at: origin + forward, from: origin, relativeTo: nil)
    }
}

struct FirstPersonView: View {
    @State private var walk = WalkState()
    @State private var move: CGPoint = .zero
    @State private var lastLook: CGSize = .zero
    @State private var status = "Loading…"
    @State private var live = false
    @State private var locate: LocateSession?
    @State private var hazard: String?
    private let tick = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
    private let hazards = ["Tornado", "Earthquake", "Fire"]

    private func targetRoom(_ h: String) -> String {
        switch h {
        case "Tornado": return "3m54yff1z7crxaywd8if9rb0d"
        case "Fire": return "613htqkzf66zz7hf7n8kzszed"
        default: return walk.house?.graph.room(containing: walk.pos)?.id ?? "3m54yff1z7crxaywd8if9rb0d"
        }
    }
    private func targetPoint(_ h: String) -> Point2D? {
        walk.house?.graph.roomsById[targetRoom(h)]?.centroid
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            RealityView { content in
                do {
                    let house = try HouseLoader.loadFromBundle()   // graph: collision, arrow, minimap
                    walk.start(in: house)
                    content.add(walk.camera)
                    addLighting(to: content)
                    // Photoreal textured house (MatterPak). It's in model coords (Z-up),
                    // so rotate -90° about X to match our scene space (modelToScene).
                    if let url = Bundle.main.url(forResource: "house_textured", withExtension: "usdz") {
                        let model = try await Entity(contentsOf: url)
                        model.orientation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
                        content.add(model)
                    } else {
                        let root = HouseSceneBuilder.build(house: house)   // grey fallback
                        HouseSceneBuilder.setCeilingsHidden(true, in: root)
                        content.add(root)
                    }
                    status = walk.currentRoomLabel()
                } catch { status = "Load error: \(error.localizedDescription)" }
            }
            .background(Color(white: 0.14))
            .ignoresSafeArea()

            // Look by dragging (Virtual only; in Live the heading comes from sensors).
            if !live {
                Color.clear.contentShape(Rectangle()).ignoresSafeArea()
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            walk.look(dx: Double(g.translation.width - lastLook.width))
                            lastLook = g.translation
                        }
                        .onEnded { _ in lastLook = .zero })
            }

            // Safe-spot arrow (aligned to the model — correct with no calibration).
            if let h = hazard, h != "Earthquake", let tp = targetPoint(h), walk.distance(to: tp) > 0.8 {
                VStack(spacing: 6) {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 72, weight: .bold)).foregroundStyle(.green)
                        .rotationEffect(.degrees(walk.bearing(to: tp)))
                        .shadow(color: .black.opacity(0.6), radius: 6)
                    Text("\(Int(walk.distance(to: tp).rounded())) m to safe spot")
                        .font(.caption.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.5), in: Capsule())
                }
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }

            // Minimap with the "you are here" dot; taps align locate in Live mode.
            if let house = walk.house {
                let panos = house.model.sections.panoramas?.panoLocations ?? []
                VStack {
                    HStack {
                        Spacer()
                        Minimap(graph: house.graph, panos: panos, currentIndex: -1, route: [],
                                onSelect: { _ in },
                                onTapModel: live ? { p in locate?.tap(p) } : nil)
                        .frame(width: 170, height: 132)
                        .padding(8).background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(UserDot(walk: walk))
                        .padding(.trailing, 10).padding(.top, 60)
                    }
                    Spacer()
                }
            }

            if !live { Joystick(vector: $move).padding(.leading, 28).padding(.bottom, 150) }

            VStack(spacing: 8) {
                Text(statusLine).font(.caption.monospaced())
                    .padding(8).background(.black.opacity(0.55))
                    .foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 10) {
                    Button { toggleLive() } label: { chip(live ? "📍 Live" : "Virtual", on: live) }
                    ForEach(hazards, id: \.self) { h in
                        Button { hazard = h } label: { chip(h, on: hazard == h) }
                    }
                }
            }
            .padding(.bottom, 40)
        }
        .onReceive(tick) { _ in
            guard walk.house != nil, !live else { return }
            if move != .zero { walk.step(move: move, dt: 1.0 / 60.0) }
            let r = walk.currentRoomLabel(); if r != status { status = r }
        }
        .onChange(of: locate?.position) { _, pos in
            guard live, let pos else { return }
            walk.applyLive(pos)
            status = walk.currentRoomLabel()
        }
    }

    private var statusLine: String {
        if live, let s = locate {
            if let e = s.loadError { return e }
            switch s.mode {
            case .tapHere: return "LIVE — tap the map where you're standing"
            case .tapToward: return "LIVE — tap the map toward what you face"
            case .tracking:
                let src = s.position?.source.rawValue ?? "…"
                return "LIVE • \(walk.currentRoomLabel()) • \(src)"
            }
        }
        return "Walk • \(status)"
    }

    private func toggleLive() {
        live.toggle()
        if live { let s = LocateSession(); s.start(); locate = s }
        else { locate?.stop(); locate = nil }
    }

    private func chip(_ t: String, on: Bool) -> some View {
        Text(t).font(.subheadline.bold()).padding(.horizontal, 14).padding(.vertical, 10)
            .background(on ? AnyShapeStyle(.green.opacity(0.6)) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
            .foregroundStyle(.white)
    }

    private func addLighting(to content: some RealityViewContentProtocol) {
        let key = DirectionalLight(); key.light.intensity = 900
        key.look(at: .zero, from: SIMD3<Float>(-3, 8, 4), relativeTo: nil); content.add(key)
        let fill = DirectionalLight(); fill.light.intensity = 400
        fill.look(at: .zero, from: SIMD3<Float>(4, 6, -4), relativeTo: nil); content.add(fill)
        let bounce = DirectionalLight(); bounce.light.intensity = 200
        bounce.look(at: .zero, from: SIMD3<Float>(0, 3, -6), relativeTo: nil); content.add(bounce)
    }
}

/// Draws the current walk position as a dot on top of the minimap.
private struct UserDot: View {
    let walk: WalkState
    var body: some View {
        GeometryReader { geo in
            if let house = walk.house {
                let pts = house.graph.rooms.flatMap { $0.polygon }
                let minX = pts.map { $0.x }.min() ?? -11, maxX = pts.map { $0.x }.max() ?? 1
                let minY = pts.map { $0.y }.min() ?? -4, maxY = pts.map { $0.y }.max() ?? 5
                let pad: CGFloat = 14  // 6 inner + 8 outer padding
                let w = geo.size.width - pad * 2, h = geo.size.height - pad * 2
                let fx = (walk.pos.x - minX) / max(maxX - minX, 1e-6)
                let fy = (walk.pos.y - minY) / max(maxY - minY, 1e-6)
                Circle().fill(.yellow)
                    .frame(width: 10, height: 10)
                    .position(x: pad + CGFloat(fx) * w, y: pad + (1 - CGFloat(fy)) * h)
            }
        }
    }
}

/// On-screen movement joystick reporting a vector in -1...1 on each axis.
struct Joystick: View {
    @Binding var vector: CGPoint
    @State private var knob: CGSize = .zero
    private let size: CGFloat = 130
    private let knobSize: CGFloat = 50

    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.14))
            Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1)
            Circle().fill(.white.opacity(0.55)).frame(width: knobSize, height: knobSize).offset(knob)
        }
        .frame(width: size, height: size).contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                let radius = size / 2 - knobSize / 2
                var dx = g.translation.width, dy = g.translation.height
                let len = sqrt(dx * dx + dy * dy)
                if len > radius { dx = dx / len * radius; dy = dy / len * radius }
                knob = CGSize(width: dx, height: dy)
                vector = CGPoint(x: dx / radius, y: dy / radius)
            }
            .onEnded { _ in knob = .zero; vector = .zero })
    }
}

#Preview { FirstPersonView() }
