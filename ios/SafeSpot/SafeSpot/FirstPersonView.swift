//  FirstPersonView.swift
//  Step 2: walk the real house in first person with a virtual camera at eye height
//  (1.55 m). Not ARKit — that's Sanjana's `locate` module. A left joystick moves,
//  dragging elsewhere looks. Movement is constrained by SafeSpotCore.WallCollision,
//  so you can only go through real doorways and the open Hallway–Living Room boundary.

import SwiftUI
import RealityKit
import Combine
import SafeSpotCore

/// Reference holder for the walkthrough (entities are reference types, so we update
/// the camera transform directly each tick without round-tripping through SwiftUI).
@MainActor
final class WalkState {
    var house: LoadedHouse?
    var collision: WallCollision?
    var pos = Point2D(x: 0, y: 0)
    var yaw: Double = 0        // model heading, 0 = +Y, clockwise
    var pitch: Double = 0
    let eye: Double = 1.55
    let camera = PerspectiveCamera()

    func start(in house: LoadedHouse) {
        self.house = house
        self.collision = WallCollision(graph: house.graph)
        // Start at a real scan standpoint (guaranteed inside a room), preferring the
        // hallway; fall back to the hallway centroid.
        let panos = house.model.sections.panoramas?.panoLocations ?? []
        if let p = panos.first(where: { $0.anchor?.room?.id == "9hauvfhwiqt" }) ?? panos.first {
            pos = Point2D(x: p.position.x, y: p.position.y)
        } else {
            pos = house.graph.roomsById["9hauvfhwiqt"]?.centroid ?? Point2D(x: 0, y: 0)
        }
        camera.camera.fieldOfViewInDegrees = 60
        updateCamera()
    }

    func look(dx: Double, dy: Double) {
        yaw += dx * 0.004
        pitch = max(-1.3, min(1.3, pitch - dy * 0.004))
        updateCamera()
    }

    /// Advance by the joystick vector (x = strafe, y = forward). Returns room label.
    func step(move: CGPoint, dt: Double) {
        guard let collision else { return }
        let jx = Double(move.x), jy = Double(-move.y)  // up on stick = forward
        if jx != 0 || jy != 0 {
            let speed = 1.5
            let fwd = Point2D(x: sin(yaw), y: cos(yaw))
            let right = Point2D(x: cos(yaw), y: -sin(yaw))
            let target = Point2D(x: pos.x + (fwd.x * jy + right.x * jx) * speed * dt,
                                 y: pos.y + (fwd.y * jy + right.y * jx) * speed * dt)
            pos = collision.resolve(from: pos, to: target)
        }
        updateCamera()
    }

    func currentRoomLabel() -> String {
        guard let house else { return "" }
        return house.graph.room(containing: pos)?.type ?? "—"
    }

    private func updateCamera() {
        let p = CoordinateTransform.modelToScene(Vector3(x: pos.x, y: pos.y, z: eye))
        let origin = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
        let cp = cos(pitch), sp = sin(pitch)
        let forward = SIMD3<Float>(Float(cp * sin(yaw)), Float(sp), Float(-cp * cos(yaw)))
        camera.look(at: origin + forward, from: origin, relativeTo: nil)
    }
}

struct FirstPersonView: View {
    @State private var walk = WalkState()
    @State private var move: CGPoint = .zero
    @State private var lastLook: CGSize = .zero
    @State private var status = "Loading…"
    private let tick = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RealityView { content in
                do {
                    let house = try HouseLoader.loadFromBundle()
                    let root = HouseSceneBuilder.build(house: house)
                    HouseSceneBuilder.setCeilingsHidden(true, in: root)
                    content.add(root)
                    addLighting(to: content)
                    walk.start(in: house)
                    content.add(walk.camera)
                    status = walk.currentRoomLabel()
                } catch {
                    status = "Load error: \(error.localizedDescription)"
                }
            }
            .background(Color(white: 0.14))
            .ignoresSafeArea()

            // Dedicated transparent look layer (reliable hit-testing). The joystick
            // sits on top of this and intercepts touches in its own area.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            walk.look(dx: Double(g.translation.width - lastLook.width),
                                      dy: Double(g.translation.height - lastLook.height))
                            lastLook = g.translation
                        }
                        .onEnded { _ in lastLook = .zero }
                )

            Joystick(vector: $move)
                .padding(.leading, 28)
                .padding(.bottom, 40)

            VStack {
                Text("Walk • \(status)")
                    .font(.caption.monospaced())
                    .padding(8)
                    .background(.black.opacity(0.55))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
        }
        .onReceive(tick) { _ in
            guard walk.house != nil else { return }
            walk.step(move: move, dt: 1.0 / 60.0)
            let r = walk.currentRoomLabel()
            if r != status { status = r }
        }
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

/// A simple on-screen movement joystick reporting a vector in -1...1 on each axis.
struct Joystick: View {
    @Binding var vector: CGPoint
    @State private var knob: CGSize = .zero
    private let size: CGFloat = 130
    private let knobSize: CGFloat = 50

    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.14))
            Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1)
            Circle().fill(.white.opacity(0.55))
                .frame(width: knobSize, height: knobSize)
                .offset(knob)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let radius = size / 2 - knobSize / 2
                    var dx = g.translation.width, dy = g.translation.height
                    let len = sqrt(dx * dx + dy * dy)
                    if len > radius { dx = dx / len * radius; dy = dy / len * radius }
                    knob = CGSize(width: dx, height: dy)
                    vector = CGPoint(x: dx / radius, y: dy / radius)
                }
                .onEnded { _ in knob = .zero; vector = .zero }
        )
    }
}

#Preview {
    FirstPersonView()
}
