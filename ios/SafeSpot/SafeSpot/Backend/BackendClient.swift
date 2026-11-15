//  BackendClient.swift
//  Talks to Lavanya's planner/router (docs/interfaces.md):
//    • requestPlan   — POST /plan   {position, hazard, knownDamage} → Plan
//    • PlanChannel   — WS  /ws/plan  the backend PUSHES a fresh Plan on every re-plan
//                      (room blocked, shaking stopped, …). Auto-reconnects, and while
//                      disconnected it polls POST /plan every 2 s so the app still
//                      re-plans if the socket is down.
//
//  Per CLAUDE.md: the agent never invents routes — this only transports plans the
//  backend computed. If a call fails, the caller keeps the last valid plan.

import Foundation
import SafeSpotCore

struct BackendClient {
    var base: URL = BackendConfig.baseURL
    var wsBase: URL = BackendConfig.wsBaseURL

    private struct PlanRequest: Encodable {
        let position: Position
        let hazard: String
        let knownDamage: [DamageEvent]
    }

    /// POST /plan → the current safe target and route for this position + hazard.
    func requestPlan(position: Position, hazard: String,
                     knownDamage: [DamageEvent] = []) async throws -> Plan {
        try await post("plan", PlanRequest(position: position, hazard: hazard,
                                           knownDamage: knownDamage), as: Plan.self)
    }

    private struct ReportResponse: Decodable { let ok: Bool; let replan: Plan? }

    /// POST /report → apply a DamageEvent and, if the route changed, the new Plan
    /// (also pushed over /ws/plan). Returns nil if the route is unchanged.
    func report(_ event: DamageEvent) async throws -> Plan? {
        try await post("report", event, as: ReportResponse.self).replan
    }

    private struct VoiceRequest: Encodable { let question: String }
    private struct VoiceResponse: Decodable { let answer: String }

    /// POST /voice → a spoken-style answer drawn only from the current route state.
    func ask(_ question: String) async throws -> String {
        try await post("voice", VoiceRequest(question: question), as: VoiceResponse.self).answer
    }

    private func post<B: Encodable, R: Decodable>(_ path: String, _ body: B,
                                                  as: R.Type) async throws -> R {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 8
        req.httpBody = try JSONEncoder().encode(body)
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(R.self, from: data)
    }
}

/// A live connection to /ws/plan that forwards every pushed Plan to `onPlan`.
/// Reconnects automatically and polls POST /plan while the socket is down.
@MainActor
final class PlanChannel {
    private let client: BackendClient
    private let hazard: String
    private let positionProvider: () -> Position?
    private let onPlan: (Plan) -> Void

    private var task: URLSessionWebSocketTask?
    private var pollTimer: Timer?
    private var active = false

    init(client: BackendClient = BackendClient(), hazard: String,
         position: @escaping () -> Position?, onPlan: @escaping (Plan) -> Void) {
        self.client = client
        self.hazard = hazard
        self.positionProvider = position
        self.onPlan = onPlan
    }

    func start() {
        guard !active else { return }
        active = true
        connect()
    }

    func stop() {
        active = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        pollTimer?.invalidate(); pollTimer = nil
    }

    // MARK: socket

    private func connect() {
        let url = wsPlanURL()
        let t = URLSession.shared.webSocketTask(with: url)
        task = t
        t.resume()
        stopPolling()          // socket is (re)connecting; drop the fallback poll
        receive()
    }

    private func wsPlanURL() -> URL {
        var c = URLComponents(url: client.wsBase.appendingPathComponent("ws/plan"),
                              resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "hazard", value: hazard)]
        return c.url!
    }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.active else { return }
                switch result {
                case .success(let message):
                    self.handle(message)
                    self.receive()                       // keep listening
                case .failure:
                    self.task = nil
                    self.startPolling()                  // fall back while down
                    self.reconnectSoon()
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .string(let s): data = s.data(using: .utf8)
        case .data(let d): data = d
        @unknown default: data = nil
        }
        if let data, let plan = try? JSONDecoder().decode(Plan.self, from: data) {
            onPlan(plan)
        }
    }

    private func reconnectSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.active else { return }
            self.connect()
        }
    }

    // MARK: poll fallback (socket down)

    private func startPolling() {
        guard pollTimer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.active, let pos = self.positionProvider() else { return }
                if let plan = try? await self.client.requestPlan(position: pos, hazard: self.hazard) {
                    self.onPlan(plan)
                }
            }
        }
        pollTimer = t
    }

    private func stopPolling() {
        pollTimer?.invalidate(); pollTimer = nil
    }
}
