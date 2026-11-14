//  MotionTracker.swift
//  LocateTest — Block 1 of the `locate` module.
//
//  Step counting (CMPedometer), fused heading (CMDeviceMotion) and compass
//  heading (CLLocationManager). Self-contained so it can move into the
//  SafeSpot app later unchanged.

import CoreLocation
import CoreMotion
import Foundation
import Observation

@Observable
final class MotionTracker: NSObject {
    // Pedometer (cumulative since start; updates every few steps)
    private(set) var steps: Int = 0
    private(set) var pedometerDistance: Double?   // metres, Apple's own estimate
    private(set) var cadence: Double?             // steps per second

    // Device motion (gyro + accel + magnetometer fused), degrees
    private(set) var fusedHeading: Double?        // 0 = magnetic north, clockwise
    private(set) var yaw: Double?                 // attitude yaw, degrees

    // Compass (CLHeading), degrees
    private(set) var trueHeading: Double?
    private(set) var magneticHeading: Double?
    private(set) var headingAccuracy: Double?

    private(set) var errors: [String] = []

    private let pedometer = CMPedometer()
    private let motion = CMMotionManager()
    private let location = CLLocationManager()

    func start() {
        steps = 0; pedometerDistance = nil; cadence = nil
        errors = []

        if CMPedometer.isStepCountingAvailable() {
            pedometer.startUpdates(from: Date()) { [weak self] data, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error { self.errors.append("pedometer: \(error.localizedDescription)"); return }
                    guard let data else { return }
                    self.steps = data.numberOfSteps.intValue
                    self.pedometerDistance = data.distance?.doubleValue
                    self.cadence = data.currentCadence?.doubleValue
                }
            }
        } else {
            errors.append("step counting not available")
        }

        if motion.isDeviceMotionAvailable,
           CMMotionManager.availableAttitudeReferenceFrames().contains(.xMagneticNorthZVertical) {
            motion.deviceMotionUpdateInterval = 1.0 / 50.0
            motion.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: .main) { [weak self] dm, _ in
                guard let self, let dm else { return }
                self.fusedHeading = dm.heading >= 0 ? dm.heading : nil
                self.yaw = dm.attitude.yaw * 180 / .pi
            }
        } else {
            errors.append("device motion (magnetic north frame) not available")
        }

        location.delegate = self
        location.headingFilter = kCLHeadingFilterNone
        location.requestWhenInUseAuthorization()
        if CLLocationManager.headingAvailable() {
            location.startUpdatingHeading()
        } else {
            errors.append("compass not available")
        }
    }

    func stop() {
        pedometer.stopUpdates()
        motion.stopDeviceMotionUpdates()
        location.stopUpdatingHeading()
    }
}

extension MotionTracker: CLLocationManagerDelegate {
    // CLLocationManager calls back on the thread it was created on (main).
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let t = newHeading.trueHeading, m = newHeading.magneticHeading, a = newHeading.headingAccuracy
        MainActor.assumeIsolated {
            self.trueHeading = t >= 0 ? t : nil
            self.magneticHeading = m
            self.headingAccuracy = a >= 0 ? a : nil   // negative = invalid
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let msg = error.localizedDescription
        MainActor.assumeIsolated { self.errors.append("compass: \(msg)") }
    }
}
