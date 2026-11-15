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
import AVFoundation
import SafeSpotCore

@MainActor
final class TourModel {
    let graph: HouseGraph
    let panos: [Panorama]
    let roomTypeById: [String: String]
    var index = 0
    var yaw: Double = 0            // radians; model heading 0 = +Y, clockwise
    var transitioning = false
    // Per-pano orientation (ported from Photo mode, which renders correctly).
    var headingCalibDeg: Double = 0
    var headingSign: Double = -1
    var blockedRooms: Set<String> = []   // rooms the route must avoid (damage)

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
        mesh?.isEnabled = false        // the raw mesh looks like clay; pano only
        alignCurrent()
        updateLook()
    }

    func updateLook() {
        let o = scenePos(index)
        let fwd = SIMD3<Float>(Float(sin(yaw)), 0, Float(-cos(yaw)))
        camera.look(at: o + fwd, from: o, relativeTo: nil)
    }

    /// Yaw from a model heading, Photo-mode convention (yaw = 90 - heading).
    func applyHeadingDeg(_ h: Double) { yaw = (90 - h) * .pi / 180; updateLook() }

    func panoYawDeg(_ p: Panorama) -> Double {
        guard let q = p.rotation else { return 0 }
        return atan2(q.z, q.w) * 2 * 180 / .pi
    }

    /// Rotate the sphere so the photo lines up with model directions (Photo mode's
    /// calibrated fix). Without this each pano is pasted at a random angle (the
    /// "collaged surfaces" / wrong-facing arrow).
    func alignCurrent() {
        guard let p = current else { return }
        let deg = headingSign * panoYawDeg(p) + headingCalibDeg
        sphere.orientation = simd_quatf(angle: Float(deg * .pi / 180), axis: SIMD3<Float>(0, 1, 0))
    }

    /// Which scan point to show in live tracking: locked to the room `locate` reports,
    /// with hysteresis so position noise near a boundary doesn't flip rooms.
    func liveTargetIndex(x: Double, y: Double, roomId: String?) -> Int {
        func d(_ i: Int) -> Double { hypot(panos[i].position.x - x, panos[i].position.y - y) }
        let margin = 0.8   // metres a candidate must beat the current by to switch
        let curRoom = panos[index].anchor?.room?.id
        if let r = roomId, !r.isEmpty {
            let pool = panos.indices.filter { panos[$0].anchor?.room?.id == r }
            if let best = pool.min(by: { d($0) < d($1) }) {
                if r == curRoom { return d(best) + margin < d(index) ? best : index }
                return best    // locate says we changed rooms → go to that room's nearest
            }
        }
        let best = panos.indices.min(by: { d($0) < d($1) }) ?? index
        return d(best) + margin < d(index) ? best : index
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

    /// BFS over scan-point neighbours → ordered pano indices from current to target,
    /// skipping scan points in blocked rooms (a damaged room blocks the whole room).
    func route(to target: Int) -> [Int] {
        let idxOf = Dictionary(uniqueKeysWithValues: panos.enumerated().map { ($0.element.id, $0.offset) })
        var prev = [Int: Int](); var seen = Set([index]); var q = [index]
        while !q.isEmpty {
            let cur = q.removeFirst()
            if cur == target { break }
            for nid in panos[cur].anchor?.neighbors ?? [] {
                guard let ni = idxOf[nid], !seen.contains(ni) else { continue }
                if ni != target, blockedRooms.contains(panos[ni].anchor?.room?.id ?? "") { continue }
                seen.insert(ni); prev[ni] = cur; q.append(ni)
            }
        }
        guard seen.contains(target) else { return [] }
        var path = [target]; var c = target
        while c != index, let p = prev[c] { path.append(p); c = p }
        return path.reversed()
    }

    /// Nearest reachable scan point (by neighbour hops, avoiding blocked rooms) whose
    /// room type is one of `types` — used to pick a safe spot for the scripted demo.
    func nearestSafePano(from start: Int, avoiding blocked: Set<String>, types: [String]) -> Int? {
        let idxOf = Dictionary(uniqueKeysWithValues: panos.enumerated().map { ($0.element.id, $0.offset) })
        var seen = Set([start]); var q = [start]
        while !q.isEmpty {
            let cur = q.removeFirst()
            let room = panos[cur].anchor?.room?.id ?? ""
            if cur != start, !blocked.contains(room), types.contains(roomTypeById[room] ?? "") { return cur }
            for nid in panos[cur].anchor?.neighbors ?? [] {
                guard let ni = idxOf[nid], !seen.contains(ni) else { continue }
                if blocked.contains(panos[ni].anchor?.room?.id ?? "") { continue }
                seen.insert(ni); q.append(ni)
            }
        }
        return nil
    }

    func typeName(_ i: Int) -> String {
        (roomTypeById[panos[i].anchor?.room?.id ?? ""] ?? "safe room").lowercased()
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
    // Earthquake is driven by Lavanya's backend (take cover while shaking → exit after).
    @State private var planChannel: PlanChannel?
    @State private var backendPlan: Plan?
    @State private var takeCover = false
    @State private var speaker = AVSpeechSynthesizer()
    @State private var voice = VoiceAsk()
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

            if takeCover {
                VStack(spacing: 10) {
                    Image(systemName: "figure.fall").font(.system(size: 54, weight: .bold))
                    Text("TAKE COVER").font(.largeTitle.bold())
                    Text("Drop, cover, hold on. Don't run.").font(.title3)
                }
                .foregroundStyle(.white).padding(28)
                .background(.red.opacity(0.78), in: RoundedRectangle(cornerRadius: 20))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .allowsHitTesting(false)
            }

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
                    Button { runDemo() } label: { chip("▶︎ Demo", false) }
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
                if plan != nil {
                    HStack(spacing: 8) {
                        Button { reportBlockedHere() } label: { chip("⚠︎ Blocked here", false) }
                        Button { voice.toggle() } label: {
                            chip(voice.listening ? "🎤 Listening…" : "🎤 Ask", voice.listening)
                        }
                    }
                }
            }
            .padding(.bottom, 36)
        }
        .onAppear { configureVoice() }
        .onReceive(tick) { _ in
            guard live, let m = model, let s = locate, let pos = s.position, !m.transitioning else { return }
            m.applyHeadingDeg(pos.heading)   // continuous look (Photo-mode convention)
            let ni = m.liveTargetIndex(x: pos.x, y: pos.y, roomId: pos.roomId)
            if ni != m.index { liveJump(m, to: ni) }
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

    /// Move to a scan point as a quick fade-cut between panoramas (the textured mesh
    /// in between looked like clay, so we don't show it).
    private func glide(_ m: TourModel, to target: Int) {
        guard !m.transitioning, target != m.index, m.panos.indices.contains(target) else { return }
        m.transitioning = true
        historyStore.append(m.index)
        Task { await arrive(m, to: target) }
    }

    private func glideBack(_ m: TourModel) {
        guard !m.transitioning, let prev = historyStore.popLast() else { return }
        m.transitioning = true
        Task { await arrive(m, to: prev) }
    }

    /// Live tracking: teleport straight to the room-locked scan point (no route glide).
    private func liveJump(_ m: TourModel, to target: Int) {
        guard !m.transitioning, target != m.index, m.panos.indices.contains(target) else { return }
        m.transitioning = true
        Task { await arrive(m, to: target) }
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

    /// Any hazard button → the backend planner/router (POST /plan), then a /ws/plan
    /// subscription for live re-plans (room blocked, shaking stops). Earthquake also
    /// streams this phone's motion. Falls back to a local plan if the backend is
    /// unreachable, so the demo still runs offline.
    private func startHazard(_ h: String) {
        guard let m = model else { return }
        stopBackend()
        let hazardKey = h.lowercased()
        if h == "Earthquake" { SensorStreamer.shared.start() }
        let client = BackendClient()
        Task {
            if let pos = currentPosition(m),
               let p = try? await client.requestPlan(position: pos, hazard: hazardKey) {
                applyBackendPlan(m, p)
            } else {
                localFallback(m, h)
            }
        }
        // position is read fresh on each poll so a reconnect re-plans from where the
        // user actually is.
        let ch = PlanChannel(client: client, hazard: hazardKey,
                             position: { currentPosition(m) },
                             onPlan: { p in applyBackendPlan(m, p) })
        ch.start()
        planChannel = ch
    }

    /// Local stand-in used only when the backend can't be reached.
    private func localFallback(_ m: TourModel, _ h: String) {
        let target = m.safeTargetIndex(for: h)
        let r = (h == "Earthquake") ? [m.index] : m.route(to: target)
        let name = m.roomTypeById[m.panos[target].anchor?.room?.id ?? ""] ?? "safe room"
        let instr: String
        switch h {
        case "Tornado": instr = "Tornado — go to the \(name) (interior, no windows). Get under cover."
        case "Fire": instr = "Fire — head to the \(name) and out the exterior door."
        default: takeCover = true; instr = "Earthquake — take cover here now; move after the shaking stops."
        }
        plan = (h, r, instr)
        if h != "Earthquake", target != m.index { travel(m, to: target) }
    }

    private func goNextStep(_ m: TourModel) {
        guard let p = plan, let target = p.route.last, target != m.index else { return }
        travel(m, to: target)   // glide the whole route to the safe spot, hop by hop
    }

    // MARK: scripted demo (deterministic — no sensors, Wi-Fi, or backend)

    /// One-button story: tornado → route to a safe interior room → hallway blocked
    /// → reroute → arrive. Uses the real house graph and routing, with voice.
    private func runDemo() {
        guard let m = model else { return }
        stopBackend()
        live = false
        locate?.stop(); locate = nil
        m.blockedRooms = []
        historyStore.removeAll(); pendingRoute = []

        func firstType(_ t: String) -> Int? {
            m.panos.firstIndex { m.roomTypeById[$0.anchor?.room?.id ?? ""] == t }
        }
        let start = firstType("Living Room") ?? firstType("Kitchen") ?? 0
        let hallway = m.graph.rooms.first { $0.type == "Hallway" }?.id

        Task {
            // Stage 0 — start + warning.
            await arrive(m, to: start)
            let t1 = m.nearestSafePano(from: start, avoiding: [],
                                       types: ["Bathroom", "Closet", "Bedroom"]) ?? start
            plan = ("Tornado", m.route(to: t1),
                    "Tornado warning. Go to the \(m.typeName(t1)) — interior, away from windows.")
            speak("Tornado warning. Move to the \(m.typeName(t1)). It's interior, away from windows.")

            // Stage 1 — start walking.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { travel(m, to: t1) }

            // Stage 2 — hallway blocked → reroute.
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
                if let h = hallway { m.blockedRooms.insert(h) }
                let t2 = m.nearestSafePano(from: m.index, avoiding: m.blockedRooms,
                                           types: ["Bedroom", "Closet", "Bathroom"]) ?? m.index
                plan = ("Tornado", m.route(to: t2),
                        "Hallway reported blocked. Rerouting to the \(m.typeName(t2)).")
                speak("The hallway is blocked. Rerouting to the \(m.typeName(t2)). Get under a sturdy table and cover your head.")
                travel(m, to: t2)

                // Stage 3 — arrival.
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    plan = ("Tornado", [m.index],
                            "You're in the safe spot. Get low, cover your head, stay until the all-clear.")
                    speak("You've reached the safe spot. Get low and cover your head until the all clear.")
                }
            }
        }
    }

    private func stopBackend() {
        planChannel?.stop(); planChannel = nil
        SensorStreamer.shared.stop()
        backendPlan = nil
        takeCover = false
    }

    // MARK: one-tap damage report → reroute (/report)

    /// "Blocked here" — mark the current room blocked. The backend re-plans and the
    /// new route arrives inline and over /ws/plan (CLAUDE.md: a damaged room blocks
    /// the whole room; the route avoids it).
    private func reportBlockedHere() {
        guard let m = model, let room = m.current?.anchor?.room?.id, plan != nil else { return }
        let event = DamageEvent(roomId: room, state: "blocked", source: "tap",
                                confidence: 1.0, timestamp: Position.now())
        Task {
            if let replan = try? await BackendClient().report(event) { applyBackendPlan(m, replan) }
        }
    }

    // MARK: voice Q&A (/voice)

    private func configureVoice() {
        voice.onResult = { q in
            Task {
                if let answer = try? await BackendClient().ask(q) { speak(answer) }
            }
        }
    }

    // MARK: render a backend Plan (CLAUDE.md rule 5: no running during shaking).

    private func applyBackendPlan(_ m: TourModel, _ p: Plan) {
        backendPlan = p
        takeCover = p.takeCover
        let label = p.hazard.capitalized   // "Tornado" / "Earthquake" / "Fire"
        if p.takeCover {
            plan = (label, [m.index],
                    p.reasons.first ?? "Take cover here now — drop, cover, hold on. Don't run.")
            speak(p.reasons.first ?? "Take cover now. Drop, cover, and hold on. Do not run.")
        } else {
            let target = backendTargetIndex(m, p) ?? m.index
            let r = m.route(to: target)
            plan = (label, r,
                    p.reasons.first ?? "Move to the \(m.roomTypeById[m.panos[target].anchor?.room?.id ?? ""] ?? "safe spot") now.")
            speak(p.reasons.first ?? "Move to safety now.")
            if target != m.index { travel(m, to: target) }   // walk the route automatically
        }
    }

    /// Map the backend's target/waypoints onto a scan point. Validates against the
    /// house data (CLAUDE.md rule 3): an unknown room id falls back to coordinates,
    /// then to the last waypoint.
    private func backendTargetIndex(_ m: TourModel, _ p: Plan) -> Int? {
        if let t = p.target {
            if t.kind == "room", let rid = t.roomId,
               let i = m.panos.firstIndex(where: { $0.anchor?.room?.id == rid }) { return i }
            if let x = t.x, let y = t.y { return m.nearestPanoIndex(x: x, y: y) }
        }
        if let wp = p.waypoints.last { return m.nearestPanoIndex(x: wp.x, y: wp.y) }
        return nil
    }

    /// The live Position to send the backend: from `locate` when tracking, otherwise
    /// the current scan point and look direction.
    private func currentPosition(_ m: TourModel) -> Position? {
        if live, let p = locate?.position { return p }
        guard let pano = m.current else { return nil }
        var hdg = m.yaw * 180 / .pi
        hdg = hdg.truncatingRemainder(dividingBy: 360); if hdg < 0 { hdg += 360 }
        return Position(roomId: pano.anchor?.room?.id, x: pano.position.x, y: pano.position.y,
                        heading: hdg, confidence: 0.6, source: .tap, timestamp: Position.now())
    }

    private func speak(_ text: String) {
        speaker.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.rate = 0.5
        speaker.speak(u)
    }

    private func toggleLive() {
        live.toggle()
        if live { let s = LocateSession(); s.start(); locate = s }
        else { locate?.stop(); locate = nil }
    }
}

#Preview { HybridTourView() }
