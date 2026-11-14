//  MotionDeadReckoner.swift
//  `locate` Block 3: position without the camera (step counting + gyroscope).
//
//  Measured on a real walk (Block 1): step length ≈ 0.74 m, and the compass swung
//  15–90° indoors, so turns come from the gyroscope only. CMPedometer reports only
//  every ~2.6 s (~4 steps), so motion is driven continuously by
//      walking? (accelerometer)  ×  speed = cadence × step length  along the gyro heading
//  and kept within one pedometer update of the real step count.
//
//  Output is a TrackingPose in the reckoner's own frame; FloorPlanLocator rebases it
//  onto the house plan and applies wall snapping, which also corrects drift.

import CoreMotion
import Foundation
import Observation

/// Pure dead-reckoning integrator (testable off-device).
struct DeadReckoning {
    var stepLength: Double
    /// Used until the pedometer reports a cadence, steps per second.
    var defaultCadence = 1.6
    /// How far ahead of the counted steps we may run, metres (≈ one pedometer update).
    var maxLead = 3.0

    private(set) var u = 0.0
    private(set) var v = 0.0
    /// Degrees, clockwise.
    private(set) var yaw = 0.0
    /// Metres moved since reset.
    private(set) var distance = 0.0
    private var stepsAtReset: Int?
    private var stepTarget: Double?

    init(stepLength: Double) { self.stepLength = stepLength }

    var pose: TrackingPose { TrackingPose(u: u, v: v, yaw: yaw) }

    /// Start counting from here; `steps` is the pedometer's cumulative count now.
    mutating func reset(steps: Int?) {
        stepsAtReset = steps
        stepTarget = steps == nil ? nil : 0
        distance = 0
    }

    mutating func turn(clockwiseDegrees d: Double) {
        yaw = FloorPlanLocator.wrap360(yaw + d)
    }

    /// Advance by `dt` seconds.
    mutating func advance(dt: Double, walking: Bool, cadence: Double?, steps: Int?) {
        if let s = steps {
            if stepsAtReset == nil { stepsAtReset = s }
            stepTarget = Double(max(0, s - (stepsAtReset ?? s))) * stepLength
        }
        guard walking, dt > 0 else { return }
        var d = (cadence ?? defaultCadence) * stepLength * dt
        if let target = stepTarget {
            if distance + d > target + maxLead {
                d = max(0, target + maxLead - distance)      // too far ahead: wait for steps
            } else if distance < target - 1.0 {
                d *= 1.5                                       // behind the step count: catch up
            }
        }
        let r = yaw * .pi / 180
        u += sin(r) * d
        v += cos(r) * d
        distance += d
    }
}

/// Device side: CoreMotion → DeadReckoning.
@Observable
final class MotionDeadReckoner {
    private(set) var pose = TrackingPose(u: 0, v: 0, yaw: 0)
    private(set) var isWalking = false
    private(set) var isAvailable = false
    /// Metres moved since the last reset (used for confidence decay).
    private(set) var distanceSinceReset = 0.0

    @ObservationIgnored private var dr: DeadReckoning
    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private let pedometer = CMPedometer()
    @ObservationIgnored private var steps: Int?
    @ObservationIgnored private var cadence: Double?
    @ObservationIgnored private var lastTimestamp: TimeInterval?
    @ObservationIgnored private var verticalWindow: [Double] = []

    /// Std-dev of vertical acceleration (g) over ~1 s above which we call it walking.
    static let walkingThreshold = 0.035
    static let windowSize = 50   // 1 s at 50 Hz

    init(stepLength: Double = 0.74) {
        dr = DeadReckoning(stepLength: stepLength)
    }

    func start() {
        isAvailable = motion.isDeviceMotionAvailable
        guard isAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 50.0
        // xArbitraryZVertical: gyro + accelerometer only, no magnetometer.
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] dm, _ in
            guard let self, let dm else { return }
            self.handle(dm)
        }
        if CMPedometer.isStepCountingAvailable() {
            pedometer.startUpdates(from: Date()) { [weak self] data, _ in
                guard let data else { return }
                let s = data.numberOfSteps.intValue
                let c = data.currentCadence?.doubleValue
                Task { @MainActor in
                    self?.steps = s
                    if let c { self?.cadence = c }
                }
            }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        pedometer.stopUpdates()
        lastTimestamp = nil
    }

    /// Start a new dead-reckoning leg from here (the locator rebases onto it).
    func reset() {
        dr.reset(steps: steps)
        distanceSinceReset = 0
        pose = dr.pose
    }

    private func handle(_ dm: CMDeviceMotion) {
        let g = dm.gravity
        let gl = sqrt(g.x * g.x + g.y * g.y + g.z * g.z)
        guard gl > 0.1 else { return }
        // "Up" in device coordinates is opposite to gravity.
        let ux = -g.x / gl, uy = -g.y / gl, uz = -g.z / gl

        let dt = lastTimestamp.map { dm.timestamp - $0 } ?? 0
        lastTimestamp = dm.timestamp
        guard dt > 0, dt < 0.5 else { return }

        // Turning: rotation rate about the vertical axis. Right-hand rule about "up" is
        // counter-clockwise seen from above, so negate for clockwise heading.
        let w = dm.rotationRate
        let yawRateCCW = w.x * ux + w.y * uy + w.z * uz          // rad/s
        dr.turn(clockwiseDegrees: -yawRateCCW * dt * 180 / .pi)

        // Walking: spread of vertical acceleration over the last second.
        let a = dm.userAcceleration
        verticalWindow.append(a.x * ux + a.y * uy + a.z * uz)
        if verticalWindow.count > Self.windowSize { verticalWindow.removeFirst() }
        let mean = verticalWindow.reduce(0, +) / Double(verticalWindow.count)
        let variance = verticalWindow.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(verticalWindow.count)
        isWalking = verticalWindow.count >= Self.windowSize / 2 && variance.squareRoot() > Self.walkingThreshold

        dr.advance(dt: dt, walking: isWalking, cadence: cadence, steps: steps)
        pose = dr.pose
        distanceSinceReset = dr.distance
    }
}
