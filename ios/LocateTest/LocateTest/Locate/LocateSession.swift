//  LocateSession.swift
//  `locate` glue: sensors → FloorPlanLocator → Position (docs/interfaces.md §1).
//
//  Alignment is two taps on the floor plan: where you're standing, then the point
//  you're facing. After that, one tap anywhere is "I'm here" (tap-to-correct).
//
//  Automatic fallback order (CLAUDE.md, Block 3): camera → motion + snapping → tap.
//    • camera: ARKit world tracking while it reports "normal"
//    • motion: steps + gyroscope (MotionDeadReckoner) when the camera is lost for 1 s
//    • tap:    after ~10 m on motion alone, confidence is too low and the app asks
//              the user to tap where they are
//  Switching keeps the user's current point and heading (FloorPlanLocator.rebase),
//  so the dot never jumps when the source changes.

import Foundation
import Observation

@Observable
final class LocateSession {
    enum Mode: Equatable {
        case tapHere                 // waiting for "I'm standing here"
        case tapToward(Point2D)      // waiting for "I'm facing toward here"
        case tracking                // aligned; a tap corrects the position
    }

    enum Tracker: String { case camera, motion }

    // Fallback tuning
    static let cameraLostAfter = 1.0         // s without good tracking → motion
    static let cameraBackAfter = 1.5         // s of good tracking → camera again
    static let motionTrustDistance = 10.0    // m on motion alone before asking for a tap

    let ar = ARPoseTracker()
    let motion = MotionDeadReckoner(stepLength: 0.74)   // measured in Block 1
    private(set) var locator: FloorPlanLocator?
    /// GPS: is this phone at the house's building?
    private(set) var building: BuildingCheck?
    private(set) var loadError: String?
    private(set) var mode: Mode = .tapHere
    private(set) var position: Position?
    private(set) var active: Tracker = .camera
    /// Testing / demo: pretend the camera is unavailable.
    var simulateCameraLoss = false {
        didSet { if simulateCameraLoss != oldValue { cameraStateSince = Date() } }
    }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTapDate: Date?
    @ObservationIgnored private var cameraWasUsable = true
    @ObservationIgnored private var cameraStateSince = Date()

    init() {
        do {
            let url = Bundle.main.url(forResource: "zyzG7fqtBDv", withExtension: "json")
                ?? Bundle.main.url(forResource: "zyzG7fqtBDv", withExtension: "json", subdirectory: "HouseData")
            guard let url else { throw CocoaError(.fileNoSuchFile) }
            let model = try MatterportModel.load(contentsOf: url)
            let graph = HouseGraph(model: model)
            locator = FloorPlanLocator(graph: graph)
            building = BuildingCheck(geo: model.sections.geolocation.geocoordinates, graph: graph)
        } catch {
            loadError = "Couldn't load house data: \(error.localizedDescription)"
        }
    }

    var graph: HouseGraph? { locator?.graph }

    /// Camera tracking is usable right now.
    var cameraUsable: Bool { ar.isNormal && !simulateCameraLoss }

    /// Metres walked on motion alone since the last good fix.
    var motionDistance: Double { active == .motion ? motion.distanceSinceReset : 0 }

    /// The app should ask the user to tap where they are.
    var needsTap: Bool {
        guard mode == .tracking, active == .motion else { return false }
        return !motion.isAvailable || motionDistance > Self.motionTrustDistance
    }

    func start() {
        ar.start()
        motion.start()
        building?.start()
        cameraStateSince = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        ar.stop()
        motion.stop()
        building?.stop()
    }

    func realign() {
        mode = .tapHere
        position = nil
    }

    /// A tap on the floor plan, in model coordinates.
    func tap(_ p: Point2D) {
        guard var loc = locator else { return }
        switch mode {
        case .tapHere:
            mode = .tapToward(p)
        case .tapToward(let here):
            guard hypot(p.x - here.x, p.y - here.y) > 0.2 else { return }
            // Align against whichever source is usable now (camera, else motion).
            active = cameraUsable ? .camera : .motion
            if active == .motion { motion.reset() }
            guard let pose = pose(of: active) else { return }
            loc.align(here: here, toward: p, pose: pose)
            locator = loc
            mode = .tracking
            lastTapDate = Date()
            publish(source: .tap)
        case .tracking:
            if active == .motion { motion.reset() }   // a tap is a fresh fix
            guard let pose = pose(of: active) else { return }
            loc.correct(to: p, pose: pose)
            locator = loc
            lastTapDate = Date()
            publish(source: .tap)
        }
    }

    private func pose(of tracker: Tracker) -> TrackingPose? {
        switch tracker {
        case .camera:
            guard let p = ar.position, let yaw = ar.yaw else { return nil }
            // Right-handed from above: u = AR x, v = −AR z; yaw is clockwise from +v.
            return TrackingPose(u: Double(p.x), v: Double(-p.z), yaw: yaw)
        case .motion:
            return motion.isAvailable ? motion.pose : nil
        }
    }

    private func tick() {
        // Track how long the camera has been usable / unusable.
        let usable = cameraUsable
        if usable != cameraWasUsable {
            cameraWasUsable = usable
            cameraStateSince = Date()
        }
        guard mode == .tracking, var loc = locator else { return }

        // Automatic fallback with hysteresis.
        let held = Date().timeIntervalSince(cameraStateSince)
        if active == .camera, !usable, held >= Self.cameraLostAfter, motion.isAvailable {
            motion.reset()
            loc.rebase(pose: motion.pose)
            active = .motion
        } else if active == .motion, usable, held >= Self.cameraBackAfter, let p = pose(of: .camera) {
            loc.rebase(pose: p)
            active = .camera
        }

        // While the camera is shaky but we haven't switched yet, hold position.
        if active == .camera && !usable {
            locator = loc
            publish(source: .camera, confidenceOverride: 0.3)
            return
        }

        if let p = pose(of: active) { loc.update(pose: p) }
        locator = loc

        let recentTap = lastTapDate.map { Date().timeIntervalSince($0) < 1.0 } ?? false
        publish(source: recentTap ? .tap : (active == .camera ? .camera : .motion))
    }

    private func publish(source: Position.Source, confidenceOverride: Double? = nil) {
        guard let loc = locator, let p = loc.point, let h = loc.heading else { return }
        let confidence: Double
        if let c = confidenceOverride {
            confidence = c
        } else {
            switch source {
            case .tap: confidence = 1.0
            case .camera: confidence = loc.roomId == nil ? 0.5 : 0.9
            case .motion: confidence = max(0.2, 0.8 - 0.04 * motionDistance)  // 0.4 at 10 m
            case .gps: confidence = 0.2
            }
        }
        position = Position(roomId: loc.roomId, x: p.x, y: p.y, heading: h,
                            confidence: confidence, source: source, timestamp: Position.now())
    }

    /// The Position as the JSON that goes on the wire (docs/interfaces.md §1).
    var positionJSON: String {
        guard let position else { return "–" }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(position)).flatMap { String(data: $0, encoding: .utf8) } ?? "–"
    }
}
