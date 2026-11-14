//  FloorPlanView.swift
//  LocateTest — the house floor plan with your live position (locate Block 2).
//  Everything drawn comes from the house data via SafeSpotCore.HouseGraph.

import SafeSpotCore
import SwiftUI

struct FloorPlanView: View {
    @State private var session = LocateSession()
    @State private var showJSON = false

    var body: some View {
        VStack(spacing: 0) {
            ARPreview(arView: session.ar.arView)
                .frame(height: 110)
                .overlay(alignment: .topLeading) {
                    Text("AR: \(session.ar.trackingState)")
                        .font(.caption2.monospaced())
                        .padding(4)
                        .background(.black.opacity(0.6))
                        .foregroundStyle(session.ar.isNormal ? Color.green : Color.orange)
                        .padding(6)
                }

            Text(instruction)
                .font(.callout.weight(.semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(8)
                .background(session.needsTap ? Color.orange.opacity(0.35) : Color.accentColor.opacity(0.12))

            if let error = session.loadError {
                Text(error).foregroundStyle(.red).padding()
                Spacer()
            } else if let locator = session.locator {
                PlanCanvas(locator: locator, session: session)
                    .padding(8)
                    .overlay(alignment: .top) {
                        if let m = session.startSuggestion {
                            Button("Camera thinks: \(roomType(m.roomId)) — start here") {
                                session.startAtSuggestion()
                            }
                            .buttonStyle(.borderedProminent)
                            .font(.callout)
                            .padding(.top, 6)
                        }
                    }
            }

            statusBar
        }
        .onAppear { session.start() }
        .onDisappear { session.stop() }
        .sheet(isPresented: $showJSON) {
            ScrollView {
                Text(session.positionJSON)
                    .font(.footnote.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .presentationDetents([.medium])
        }
    }

    private var instruction: String {
        switch session.mode {
        case .tapHere: return "1 of 2 — Tap where you're standing on the plan"
        case .tapToward: return "2 of 2 — Tap a point you're facing"
        case .tracking:
            if session.needsTap { return "Not sure where you are — tap where you are on the plan" }
            if let note = session.scanNote { return note }
            if session.active == .motion { return "Camera lost — following your steps. Tap to correct." }
            return "Walk. Tap the plan any time to say \"I'm here\"."
        }
    }

    private func roomType(_ id: String) -> String {
        session.graph?.roomsById[id]?.type ?? "a room"
    }

    private var scanText: String {
        let scan = session.scan
        if let e = scan.loadError { return "Scan match: \(e)" }
        guard scan.isReady else { return "Scan match: loading scan photos…" }
        if session.simulateCameraLoss || session.active == .motion { return "Scan match: paused (no camera)" }
        guard let m = scan.match else { return "Scan match: look around slowly…" }
        let detail = String(format: "gap %.2f, dist %.2f, %d views", m.margin ?? 0, m.distance, m.views)
        if m.looksElsewhere { return "Scan match: this doesn't look like the house (\(detail))" }
        if session.mode == .tracking, m.roomId == session.position?.roomId, m.isHint {
            return "Scan match: confirms \(roomType(m.roomId)) ✓ (\(detail))"
        }
        if m.isConfident { return "Scan match: sure it's the \(roomType(m.roomId)) (\(detail))" }
        if m.isHint { return "Scan match: maybe the \(roomType(m.roomId)) (\(detail))" }
        return "Scan match: not sure (\(detail))"
    }

    private var trackerText: String {
        switch session.active {
        case .camera:
            return session.cameraUsable ? "Tracking: camera" : "Tracking: camera (unsteady…)"
        case .motion:
            let walking = session.motion.isWalking ? "walking" : "standing"
            return String(format: "Tracking: steps + gyro · %@ · %.1f m since fix", walking, session.motionDistance)
        }
    }

    private var statusBar: some View {
        VStack(spacing: 6) {
            HStack {
                Text(roomName).font(.headline)
                Spacer()
                if let p = session.position {
                    Text("\(p.source.rawValue) · \(Int(p.confidence * 100))%")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            if let p = session.position {
                HStack {
                    Text(String(format: "x %.2f  y %.2f  heading %.0f°", p.x, p.y, p.heading))
                        .font(.caption.monospaced())
                    Spacer()
                    Text("wall snaps: \(session.locator?.snapCount ?? 0)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Text(trackerText)
                    .font(.caption)
                    .foregroundStyle(session.active == .motion ? Color.orange : Color.secondary)
                Spacer()
                Toggle("No camera", isOn: $session.simulateCameraLoss)
                    .toggleStyle(.button)
                    .font(.caption)
                    .tint(.orange)
            }
            Text(scanText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let b = session.building {
                BuildingRow(building: b)
            }
            HStack {
                Button("Re-align") { session.realign() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Position JSON") { showJSON = true }
                    .buttonStyle(.bordered)
                    .disabled(session.position == nil)
            }
        }
        .padding()
        .background(.bar)
    }

    private var roomName: String {
        guard session.mode == .tracking else { return "Not aligned yet" }
        guard let id = session.position?.roomId else { return "Outside / unknown room" }
        return session.graph?.roomsById[id]?.type ?? id
    }
}

/// Draws the house and handles taps. Model space is y-up; the screen is y-down.
private struct PlanCanvas: View {
    let locator: FloorPlanLocator
    let session: LocateSession

    var body: some View {
        GeometryReader { geo in
            let map = PlanMapping(rooms: locator.graph.rooms, size: geo.size)
            Canvas { ctx, _ in
                draw(ctx: ctx, map: map)
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { pt in
                session.tap(map.toModel(pt))
            }
        }
    }

    private func draw(ctx: GraphicsContext, map: PlanMapping) {
        let g = locator.graph
        let currentRoom = session.mode == .tracking ? session.position?.roomId : nil

        // Rooms
        for room in g.rooms where room.polygon.count >= 3 {
            var path = Path()
            path.addLines(room.polygon.map(map.toScreen))
            path.closeSubpath()
            let fill: Color = !room.isWalkable ? .gray.opacity(0.5)
                : room.id == currentRoom ? Color.accentColor.opacity(0.28)
                : Color.secondary.opacity(0.08)
            ctx.fill(path, with: .color(fill))
            if room.isWalkable, room.area >= 1.5 {
                ctx.draw(Text(room.type).font(.system(size: 10)).foregroundColor(.secondary),
                         at: map.toScreen(room.centroid))
            }
        }

        // Open boundaries (no physical wall)
        for e in g.edges where e.isOpen {
            var p = Path(); p.move(to: map.toScreen(e.v0)); p.addLine(to: map.toScreen(e.v1))
            ctx.stroke(p, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }

        // Walls, with doorway gaps left open
        for w in locator.walls {
            let len = hypot(w.b.x - w.a.x, w.b.y - w.a.y)
            guard len > 0 else { continue }
            var cuts: [(Double, Double)] = []
            var start = 0.0
            for gap in w.gaps.sorted(by: { $0.0 < $1.0 }) {
                if gap.0 > start { cuts.append((start, gap.0)) }
                start = max(start, gap.1)
            }
            if start < len { cuts.append((start, len)) }
            for (s0, s1) in cuts {
                var p = Path()
                p.move(to: map.toScreen(Geometry.lerp(w.a, w.b, s0 / len)))
                p.addLine(to: map.toScreen(Geometry.lerp(w.a, w.b, s1 / len)))
                ctx.stroke(p, with: .color(.primary), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
        }

        // Windows
        let edgeById = Dictionary(uniqueKeysWithValues: g.edges.map { ($0.id, $0) })
        for win in g.windows {
            guard let e = edgeById[win.parentEdgeId] else { continue }
            let len = hypot(e.v1.x - e.v0.x, e.v1.y - e.v0.y)
            guard len > 0 else { continue }
            let ux = (e.v1.x - e.v0.x) / len, uy = (e.v1.y - e.v0.y) / len
            let c = win.worldCenter, h = win.width / 2
            var p = Path()
            p.move(to: map.toScreen(Point2D(x: c.x - ux * h, y: c.y - uy * h)))
            p.addLine(to: map.toScreen(Point2D(x: c.x + ux * h, y: c.y + uy * h)))
            ctx.stroke(p, with: .color(.cyan), style: StrokeStyle(lineWidth: 5))
        }

        // Exterior exits
        for exit in g.exteriorExits {
            let s = map.toScreen(exit.worldCenter)
            ctx.draw(Text("EXIT").font(.system(size: 9, weight: .bold)).foregroundColor(.green),
                     at: CGPoint(x: s.x, y: s.y - 10))
        }

        // Alignment marker (first tap)
        if case .tapToward(let here) = session.mode {
            let s = map.toScreen(here)
            ctx.fill(Path(ellipseIn: CGRect(x: s.x - 7, y: s.y - 7, width: 14, height: 14)), with: .color(.orange))
        }

        // You
        if session.mode == .tracking, let pos = session.position {
            let s = map.toScreen(Point2D(x: pos.x, y: pos.y))
            // Heading wedge: model heading is clockwise from +y; screen y is flipped.
            let r = pos.heading * .pi / 180
            let tip = CGPoint(x: s.x + sin(r) * 22, y: s.y - cos(r) * 22)
            let l = CGPoint(x: s.x + sin(r - 0.5) * 10, y: s.y - cos(r - 0.5) * 10)
            let rr = CGPoint(x: s.x + sin(r + 0.5) * 10, y: s.y - cos(r + 0.5) * 10)
            var wedge = Path(); wedge.move(to: tip); wedge.addLine(to: l); wedge.addLine(to: rr); wedge.closeSubpath()
            ctx.fill(wedge, with: .color(.blue.opacity(0.6)))
            ctx.fill(Path(ellipseIn: CGRect(x: s.x - 7, y: s.y - 7, width: 14, height: 14)), with: .color(.blue))
            ctx.stroke(Path(ellipseIn: CGRect(x: s.x - 7, y: s.y - 7, width: 14, height: 14)), with: .color(.white), lineWidth: 2)
        }
    }
}

/// Fits the house into the view, keeping aspect ratio. Model y-up → screen y-down.
private struct PlanMapping {
    let minX: Double, maxY: Double, scale: Double, ox: Double, oy: Double

    init(rooms: [RoomNode], size: CGSize) {
        let pts = rooms.flatMap(\.polygon)
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 1
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 1
        let w = max(maxX - minX, 0.1), h = max(maxY - minY, 0.1)
        let pad = 12.0
        let scale = min((Double(size.width) - 2 * pad) / w, (Double(size.height) - 2 * pad) / h)
        self.minX = minX; self.maxY = maxY; self.scale = scale
        self.ox = (Double(size.width) - w * scale) / 2
        self.oy = (Double(size.height) - h * scale) / 2
    }

    func toScreen(_ p: Point2D) -> CGPoint {
        CGPoint(x: ox + (p.x - minX) * scale, y: oy + (maxY - p.y) * scale)
    }

    func toModel(_ s: CGPoint) -> Point2D {
        Point2D(x: (Double(s.x) - ox) / scale + minX, y: maxY - (Double(s.y) - oy) / scale)
    }
}

/// GPS building check, with the demo override shown loudly when it's on.
private struct BuildingRow: View {
    @Bindable var building: BuildingCheck

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.caption)
            Spacer()
            Toggle("Demo", isOn: $building.demoOverride)
                .toggleStyle(.button)
                .font(.caption)
                .tint(.orange)
        }
    }

    private var text: String {
        if building.permissionDenied { return "Building: location permission off" }
        let base: String
        switch building.verdict {
        case .waiting: base = "Building: waiting for GPS…"
        case .atHouse(let d): base = "Building: at the house (\(Self.fmt(d)))"
        case .notAtHouse(let d): base = "Building: not at the house (\(Self.fmt(d)) away)"
        case .unsure(let d): base = "Building: GPS too rough to tell (\(Self.fmt(d)))"
        }
        return building.demoOverride ? base + " — DEMO OVERRIDE ON" : base
    }

    private var icon: String {
        building.isAtHouse ? "checkmark.seal.fill" : "questionmark.circle"
    }

    private var color: Color {
        if building.demoOverride { return .orange }
        return building.isAtHouse ? .green : .secondary
    }

    static func fmt(_ m: Double) -> String {
        m >= 1000 ? String(format: "%.0f km", m / 1000) : String(format: "%.0f m", m)
    }
}
