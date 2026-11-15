//  WalkLogger.swift
//  LocateTest — Block 1 of the `locate` module.
//
//  Samples MotionTracker and ARPoseTracker at 10 Hz during a walk, writes a
//  CSV, and computes the two numbers Block 1 asks for:
//    • step length  = ARKit path length / pedometer steps
//    • heading drift = how much (compass − ARKit yaw) changed over the walk
//  ARKit is the reference: over a short indoor walk it is far more accurate
//  than step counting or the compass.

import Foundation
import Observation

struct WalkSample {
    let t: Double                 // seconds since start
    let steps: Int
    let pedometerDistance: Double?
    let cadence: Double?
    let fusedHeading: Double?
    let motionYaw: Double?
    let trueHeading: Double?
    let magneticHeading: Double?
    let headingAccuracy: Double?
    let arState: String
    let arPosition: SIMD3<Float>?
    let arYaw: Double?
}

struct WalkSummary {
    var duration: Double = 0
    var steps: Int = 0
    var pedometerDistance: Double?
    var arPathLength: Double = 0          // metres walked on the floor (x/z)
    var arStraightLine: Double = 0        // start → end distance on the floor
    var stepLengthFromAR: Double?         // arPathLength / steps
    var stepLengthFromPedometer: Double?  // pedometerDistance / steps
    var compassOffsetStart: Double?       // compass − AR yaw, first 2 s, degrees
    var compassOffsetEnd: Double?         // compass − AR yaw, last 2 s, degrees
    var compassDrift: Double?             // end − start, degrees, wrapped to ±180
    var fusedOffsetStart: Double?
    var fusedOffsetEnd: Double?
    var fusedDrift: Double?
    var arLimitedFraction: Double = 0     // share of samples where ARKit wasn't "normal"
}

@Observable
final class WalkLogger {
    let motion = MotionTracker()
    let ar = ARPoseTracker()

    private(set) var isRecording = false
    private(set) var samples: [WalkSample] = []
    private(set) var summary = WalkSummary()
    private(set) var csvURL: URL?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var startDate = Date()
    @ObservationIgnored private var lastFloorPoint: SIMD2<Double>?

    /// Movements smaller than this between samples are treated as hand jitter.
    static let jitterThreshold = 0.005  // metres

    func startARPreview() { ar.start() }

    func startWalk() {
        samples = []; summary = WalkSummary(); csvURL = nil; lastFloorPoint = nil
        motion.start()
        ar.start()                 // resets the AR origin to where you stand now
        startDate = Date()
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stopWalk() {
        timer?.invalidate(); timer = nil
        isRecording = false
        motion.stop()
        computeSummary()
        csvURL = writeCSV()
    }

    private func tick() {
        let s = WalkSample(
            t: Date().timeIntervalSince(startDate),
            steps: motion.steps,
            pedometerDistance: motion.pedometerDistance,
            cadence: motion.cadence,
            fusedHeading: motion.fusedHeading,
            motionYaw: motion.yaw,
            trueHeading: motion.trueHeading,
            magneticHeading: motion.magneticHeading,
            headingAccuracy: motion.headingAccuracy,
            arState: ar.trackingState,
            arPosition: ar.position,
            arYaw: ar.yaw
        )
        samples.append(s)

        // Live path length, only while ARKit tracking is normal.
        if ar.isNormal, let p = s.arPosition {
            let pt = SIMD2(Double(p.x), Double(p.z))
            if let last = lastFloorPoint {
                let d = (pt - last).magnitude
                if d >= Self.jitterThreshold {
                    summary.arPathLength += d
                    lastFloorPoint = pt
                }
            } else {
                lastFloorPoint = pt
            }
        }
        summary.steps = s.steps
        summary.duration = s.t
    }

    // MARK: - Summary

    private func computeSummary() {
        guard let first = samples.first, let last = samples.last else { return }
        summary.duration = last.t - first.t
        summary.steps = last.steps
        summary.pedometerDistance = last.pedometerDistance
        if summary.steps > 0 {
            summary.stepLengthFromAR = summary.arPathLength / Double(summary.steps)
            if let d = summary.pedometerDistance { summary.stepLengthFromPedometer = d / Double(summary.steps) }
        }
        let normal = samples.filter { $0.arState == "normal" && $0.arPosition != nil }
        if let a = normal.first?.arPosition, let b = normal.last?.arPosition {
            summary.arStraightLine = Double(SIMD2(b.x - a.x, b.z - a.z).magnitude)
        }
        summary.arLimitedFraction = 1 - Double(normal.count) / Double(samples.count)

        let window = 2.0
        let head = normal.filter { $0.t <= (normal.first?.t ?? 0) + window }
        let tail = normal.filter { $0.t >= (normal.last?.t ?? 0) - window }

        summary.compassOffsetStart = Self.meanOffset(head) { $0.trueHeading ?? $0.magneticHeading }
        summary.compassOffsetEnd = Self.meanOffset(tail) { $0.trueHeading ?? $0.magneticHeading }
        if let a = summary.compassOffsetStart, let b = summary.compassOffsetEnd {
            summary.compassDrift = Self.wrap180(b - a)
        }
        summary.fusedOffsetStart = Self.meanOffset(head) { $0.fusedHeading }
        summary.fusedOffsetEnd = Self.meanOffset(tail) { $0.fusedHeading }
        if let a = summary.fusedOffsetStart, let b = summary.fusedOffsetEnd {
            summary.fusedDrift = Self.wrap180(b - a)
        }
    }

    /// Circular mean of (heading − AR yaw) over the given samples.
    private static func meanOffset(_ xs: [WalkSample], _ heading: (WalkSample) -> Double?) -> Double? {
        var sx = 0.0, sy = 0.0, n = 0
        for s in xs {
            guard let h = heading(s), let y = s.arYaw else { continue }
            let r = (h - y) * .pi / 180
            sx += cos(r); sy += sin(r); n += 1
        }
        guard n > 0 else { return nil }
        let deg = atan2(sy, sx) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    static func wrap180(_ d: Double) -> Double {
        var x = d.truncatingRemainder(dividingBy: 360)
        if x > 180 { x -= 360 }
        if x < -180 { x += 360 }
        return x
    }

    // MARK: - CSV

    private func writeCSV() -> URL? {
        func f(_ v: Double?, _ digits: Int = 3) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "" }
        var out = "t,steps,pedometer_distance_m,cadence_sps,fused_heading_deg,motion_yaw_deg,true_heading_deg,magnetic_heading_deg,heading_accuracy_deg,ar_state,ar_x_m,ar_y_m,ar_z_m,ar_yaw_deg\n"
        for s in samples {
            let p = s.arPosition
            out += [f(s.t), String(s.steps), f(s.pedometerDistance), f(s.cadence),
                    f(s.fusedHeading, 1), f(s.motionYaw, 1), f(s.trueHeading, 1), f(s.magneticHeading, 1),
                    f(s.headingAccuracy, 1), s.arState,
                    f(p.map { Double($0.x) }), f(p.map { Double($0.y) }), f(p.map { Double($0.z) }),
                    f(s.arYaw, 1)].joined(separator: ",") + "\n"
        }
        let stamp = ISO8601DateFormatter().string(from: startDate).replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("walk-\(stamp).csv")
        do {
            try out.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

private extension SIMD2 where Scalar == Double {
    var magnitude: Double { (x * x + y * y).squareRoot() }
}

private extension SIMD2 where Scalar == Float {
    var magnitude: Float { (x * x + y * y).squareRoot() }
}
