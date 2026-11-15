//  SensorStreamer.swift
//  Integration seam for /ws/sensors (docs/interfaces.md). During an earthquake the
//  app streams the phone's motion to the backend so the `damage` agent can tell when
//  shaking has stopped (→ Plan.takeCover flips false and we route to the exit).
//
//  The `guide`/wiring side (Harini) only START/STOPs this on entering/leaving the
//  earthquake flow. The actual accelerometer capture + WS send is Sanjana's
//  EarthquakeMotionStreamer (ported from the LocateTest app).

import Foundation

@MainActor
final class SensorStreamer {
    static let shared = SensorStreamer()
    private init() {}

    private let streamer = EarthquakeMotionStreamer()

    var running: Bool { streamer.isActive }

    /// Begin streaming phone motion to ws://<host>:8000/ws/sensors.
    func start(host: String = BackendConfig.host) {
        streamer.start(host: host)
    }

    /// Stop streaming (shaking over / left the earthquake flow).
    func stop() {
        streamer.stop()
    }
}
