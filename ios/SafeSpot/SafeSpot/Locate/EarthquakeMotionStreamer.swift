//  EarthquakeMotionStreamer.swift
//  `locate`: stream a 1 Hz motion summary to the backend during earthquake mode.
//
//  Spec from Lavanya (backend owns ALL earthquake decisions — shaking or not,
//  take cover vs exit). This file only measures and sends:
//    • CMMotionManager device motion at ~50 Hz → userAcceleration (G, gravity removed)
//    • CMMotionActivityManager → Apple's activity label + confidence
//    • once per second, one JSON text message over a WebSocket to
//      ws://<host>:8000/ws/sensors
//          { "rms": 0.03, "activity": "stationary",
//            "activityConfidence": "high", "ts": "2026-11-15T01:23:45Z" }
//      rms = RMS of |userAcceleration| over the last second, in G.
//  No thresholds or shaking detection here, by design.
//  Runs only while started (earthquake mode); stop() tears everything down.
//  Reconnects if the socket drops; messages produced while disconnected are dropped.

import CoreMotion
import Foundation
import Observation

/// One message, keys exactly as the backend expects.
struct SensorSummary: Codable, Equatable {
    let rms: Double
    let activity: String
    let activityConfidence: String
    let ts: String
}

enum SensorSummaryMath {
    /// RMS of acceleration magnitudes (G). Empty → 0.
    static func rms(of magnitudes: [Double]) -> Double {
        guard !magnitudes.isEmpty else { return 0 }
        let meanSquare = magnitudes.reduce(0) { $0 + $1 * $1 } / Double(magnitudes.count)
        return meanSquare.squareRoot()
    }

    /// Apple can set several flags at once; report the most specific one.
    static func label(stationary: Bool, walking: Bool, running: Bool,
                      automotive: Bool, cycling: Bool) -> String {
        if automotive { return "automotive" }
        if cycling { return "cycling" }
        if running { return "running" }
        if walking { return "walking" }
        if stationary { return "stationary" }
        return "unknown"
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]   // UTC, "Z", no fractional seconds
        return f.string(from: date)
    }
}

@Observable
final class EarthquakeMotionStreamer {
    enum Connection: Equatable {
        case off, connecting, connected, waitingToRetry(String)
    }

    private(set) var isActive = false
    private(set) var connection: Connection = .off
    private(set) var lastSummary: SensorSummary?
    private(set) var sentCount = 0
    private(set) var droppedCount = 0
    private(set) var url: URL?
    private(set) var problem: String?

    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private let activityManager = CMMotionActivityManager()
    @ObservationIgnored private var magnitudes: [(t: TimeInterval, m: Double)] = []
    @ObservationIgnored private var activity = "unknown"
    @ObservationIgnored private var confidence = "low"
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var session = URLSession(configuration: .default)
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var retryDelay = 1.0

    /// ws://<host>:8000/ws/sensors. `host` is a name or IP, no scheme or port.
    static func sensorsURL(host: String) -> URL? {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !h.contains("/"), !h.contains(" ") else { return nil }
        return URL(string: "ws://\(h):8000/ws/sensors")
    }

    // MARK: - Start / stop (earthquake mode)

    func start(host: String) {
        guard !isActive else { return }
        guard let u = Self.sensorsURL(host: host) else {
            problem = "Enter the backend host (e.g. 192.168.1.20)"
            return
        }
        url = u
        problem = nil
        isActive = true
        sentCount = 0; droppedCount = 0; lastSummary = nil
        startMotion()
        connect()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        timer?.invalidate(); timer = nil
        motion.stopDeviceMotionUpdates()
        activityManager.stopActivityUpdates()
        magnitudes.removeAll()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        connection = .off
        print("[sensors] stopped (sent \(sentCount), dropped \(droppedCount))")
    }

    // MARK: - Motion

    private func startMotion() {
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / 50.0
            motion.startDeviceMotionUpdates(to: .main) { [weak self] dm, _ in
                guard let self, let dm else { return }
                let a = dm.userAcceleration
                self.magnitudes.append((dm.timestamp, (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()))
                // Keep only the last second.
                let cutoff = dm.timestamp - 1.0
                if let i = self.magnitudes.firstIndex(where: { $0.t >= cutoff }), i > 0 {
                    self.magnitudes.removeFirst(i)
                }
            }
        } else {
            problem = "Device motion not available"
        }

        if CMMotionActivityManager.isActivityAvailable() {
            activityManager.startActivityUpdates(to: .main) { [weak self] act in
                guard let self, let act else { return }
                self.activity = SensorSummaryMath.label(
                    stationary: act.stationary, walking: act.walking, running: act.running,
                    automotive: act.automotive, cycling: act.cycling)
                switch act.confidence {
                case .low: self.confidence = "low"
                case .medium: self.confidence = "medium"
                case .high: self.confidence = "high"
                @unknown default: self.confidence = "low"
                }
            }
        }
    }

    private func tick() {
        guard isActive, !magnitudes.isEmpty else { return }
        var r = SensorSummaryMath.rms(of: magnitudes.map(\.m))
        r = (r * 1000).rounded() / 1000
        let summary = SensorSummary(rms: r, activity: activity,
                                    activityConfidence: confidence, ts: SensorSummaryMath.timestamp())
        lastSummary = summary
        send(summary)
    }

    // MARK: - WebSocket

    private func connect() {
        guard isActive, let url else { return }
        connection = .connecting
        let task = session.webSocketTask(with: url)
        socket = task
        task.resume()
        receive(on: task)
        // A ping confirms the connection is really open.
        task.sendPing { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.socket === task else { return }
                if let error { self.dropped(task, error.localizedDescription) }
                else { self.connection = .connected; self.retryDelay = 1.0 }
            }
        }
    }

    /// Keep a receive pending so a closed socket is noticed; incoming text is ignored.
    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.socket === task else { return }
                switch result {
                case .success: self.receive(on: task)
                case .failure(let e): self.dropped(task, e.localizedDescription)
                }
            }
        }
    }

    private func send(_ summary: SensorSummary) {
        guard let data = try? JSONEncoder().encode(summary),
              let text = String(data: data, encoding: .utf8) else { return }
        guard connection == .connected, let task = socket else {
            droppedCount += 1
            print("[sensors] not connected, dropped: \(text)")
            return
        }
        task.send(.string(text)) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.droppedCount += 1
                    self.dropped(task, error.localizedDescription)
                } else {
                    self.sentCount += 1
                    print("[sensors] sent \(text)")
                }
            }
        }
    }

    private func dropped(_ task: URLSessionWebSocketTask, _ reason: String) {
        guard isActive, socket === task else { return }
        task.cancel(with: .goingAway, reason: nil)
        socket = nil
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 10)
        connection = .waitingToRetry(reason)
        print("[sensors] connection lost (\(reason)); retrying in \(Int(delay)) s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isActive, self.socket == nil else { return }
            self.connect()
        }
    }
}
