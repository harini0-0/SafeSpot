//  ARPoseTracker.swift
//  LocateTest — Block 1 of the `locate` module.
//
//  Runs an ARKit world-tracking session and exposes the camera position.
//  World alignment is .gravity: +y is up, the origin is where the session
//  started and -z is the direction the phone faced at start. Compass heading
//  is logged separately by MotionTracker, so the two can be compared.

import ARKit
import Foundation
import Observation
import RealityKit

@Observable
final class ARPoseTracker: NSObject {
    /// Camera position in metres, session frame.
    private(set) var position: SIMD3<Float>?
    /// Direction the back camera faces, projected on the floor; degrees,
    /// clockwise seen from above, 0 = the direction faced at session start.
    private(set) var yaw: Double?
    private(set) var trackingState: String = "not started"
    private(set) var isNormal = false

    /// Called on the main thread for each camera frame with its image and yaw.
    /// Receivers must not keep the buffer longer than one short task.
    @ObservationIgnored
    var onFrame: ((CVPixelBuffer, Double) -> Void)?

    @ObservationIgnored
    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)

    func start() {
        guard ARWorldTrackingConfiguration.isSupported else {
            trackingState = "world tracking not supported"
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.planeDetection = [.horizontal]
        arView.session.delegate = self
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        position = nil; yaw = nil
    }

    func stop() {
        arView.session.pause()
    }

    static func describe(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal: return "normal"
        case .notAvailable: return "notAvailable"
        case .limited(let reason):
            switch reason {
            case .initializing: return "limited:initializing"
            case .excessiveMotion: return "limited:excessiveMotion"
            case .insufficientFeatures: return "limited:insufficientFeatures"
            case .relocalizing: return "limited:relocalizing"
            @unknown default: return "limited:unknown"
            }
        @unknown default: return "unknown"
        }
    }
}

extension ARPoseTracker: ARSessionDelegate {
    // delegateQueue is nil, so ARKit calls back on the main queue.
    // Copy values out of the frame right away; holding ARFrames stalls ARKit.
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let m = frame.camera.transform
        let state = frame.camera.trackingState
        let image = frame.capturedImage
        let pos = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        let forward = -SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        let yawDeg = Double(atan2(forward.x, -forward.z)) * 180 / .pi
        MainActor.assumeIsolated {
            self.position = pos
            self.yaw = (yawDeg + 360).truncatingRemainder(dividingBy: 360)
            self.trackingState = Self.describe(state)
            if case .normal = state { self.isNormal = true } else { self.isNormal = false }
            if let yaw = self.yaw { self.onFrame?(image, yaw) }
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let msg = error.localizedDescription
        MainActor.assumeIsolated { self.trackingState = "failed: \(msg)" }
    }
}
