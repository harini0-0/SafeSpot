//  LocateSession.swift
//  `locate` Block 2 glue: ARKit pose → FloorPlanLocator → Position.
//
//  Alignment is two taps on the floor plan: where you're standing, then the point
//  you're facing. After that, one tap anywhere is "I'm here" (tap-to-correct).

import Foundation
import Observation

@Observable
final class LocateSession {
    enum Mode: Equatable {
        case tapHere                 // waiting for "I'm standing here"
        case tapToward(Point2D)      // waiting for "I'm facing toward here"
        case tracking                // aligned; a tap corrects the position
    }

    let ar = ARPoseTracker()
    private(set) var locator: FloorPlanLocator?
    private(set) var loadError: String?
    private(set) var mode: Mode = .tapHere
    private(set) var position: Position?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTapDate: Date?

    init() {
        do {
            let url = Bundle.main.url(forResource: "zyzG7fqtBDv", withExtension: "json")
                ?? Bundle.main.url(forResource: "zyzG7fqtBDv", withExtension: "json", subdirectory: "HouseData")
            guard let url else { throw CocoaError(.fileNoSuchFile) }
            let model = try MatterportModel.load(contentsOf: url)
            locator = FloorPlanLocator(graph: HouseGraph(model: model))
        } catch {
            loadError = "Couldn't load house data: \(error.localizedDescription)"
        }
    }

    var graph: HouseGraph? { locator?.graph }

    func start() {
        ar.start()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        ar.stop()
    }

    func realign() {
        mode = .tapHere
        position = nil
    }

    /// A tap on the floor plan, in model coordinates.
    func tap(_ p: Point2D) {
        guard var loc = locator, let pose = currentPose() else { return }
        switch mode {
        case .tapHere:
            mode = .tapToward(p)
        case .tapToward(let here):
            guard hypot(p.x - here.x, p.y - here.y) > 0.2 else { return }
            loc.align(here: here, toward: p, pose: pose)
            locator = loc
            mode = .tracking
            lastTapDate = Date()
            publish(source: .tap)
        case .tracking:
            loc.correct(to: p, pose: pose)
            locator = loc
            lastTapDate = Date()
            publish(source: .tap)
        }
    }

    private func currentPose() -> TrackingPose? {
        guard let p = ar.position, let yaw = ar.yaw else { return nil }
        // Right-handed from above: u = AR x, v = −AR z; yaw is clockwise from +v.
        return TrackingPose(u: Double(p.x), v: Double(-p.z), yaw: yaw)
    }

    private func tick() {
        guard mode == .tracking, var loc = locator, let pose = currentPose() else { return }
        // Only trust ARKit positions while tracking is normal; hold otherwise.
        guard ar.isNormal else {
            publish(source: .camera, confidenceOverride: 0.3)
            return
        }
        loc.update(pose: pose)
        locator = loc
        let recentTap = lastTapDate.map { Date().timeIntervalSince($0) < 1.0 } ?? false
        publish(source: recentTap ? .tap : .camera)
    }

    private func publish(source: Position.Source, confidenceOverride: Double? = nil) {
        guard let loc = locator, let p = loc.point, let h = loc.heading else { return }
        let confidence: Double
        if let c = confidenceOverride { confidence = c }
        else if source == .tap { confidence = 1.0 }
        else { confidence = loc.roomId == nil ? 0.5 : 0.9 }
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
