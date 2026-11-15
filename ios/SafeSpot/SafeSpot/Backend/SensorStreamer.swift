//  SensorStreamer.swift
//  Integration seam for /ws/sensors (docs/interfaces.md). During an earthquake the
//  app streams the phone's motion to the backend so the `damage` agent can tell when
//  shaking has stopped (→ Plan.takeCover flips false and we route to the exit).
//
//  The `guide`/wiring side (Harini) only START/STOPs this on entering/leaving the
//  earthquake flow. The actual accelerometer capture + WS send belongs to Sanjana's
//  `locate` module.
//
//  TODO(Sanjana): fill start()/stop() with the CoreMotion → URLSessionWebSocketTask
//  stream to `wsBaseURL/ws/sensors` (device-motion userAcceleration at ~20 Hz).
//  Until then this is a safe no-op: the earthquake flow still works via the backend's
//  own USGS feed, just without this phone's impact signal.

import Foundation

@MainActor
final class SensorStreamer {
    static let shared = SensorStreamer()
    private init() {}

    private(set) var running = false

    /// Begin streaming phone motion to `wsBaseURL/ws/sensors`.
    func start(wsBaseURL: URL = BackendConfig.wsBaseURL) {
        guard !running else { return }
        running = true
        // TODO(Sanjana): start CoreMotion capture + open WS to wsBaseURL/ws/sensors.
    }

    /// Stop streaming (shaking over / left the earthquake flow).
    func stop() {
        guard running else { return }
        running = false
        // TODO(Sanjana): stop capture + close the WS.
    }
}
