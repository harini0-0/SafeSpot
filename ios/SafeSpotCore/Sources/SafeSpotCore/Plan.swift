import Foundation

/// A safety plan from the backend (docs/interfaces.md §3). camelCase keys match the
/// wire format, so default Codable works.
public struct Plan: Codable, Sendable, Equatable {
    public let planId: String
    public let hazard: String                 // "tornado" | "earthquake" | "fire"
    public let target: Target?
    public let waypoints: [Waypoint]
    public let reasons: [String]
    public let takeCover: Bool                // true = cover in place now (earthquake shaking)
    public let generatedAt: String

    public init(planId: String, hazard: String, target: Target?, waypoints: [Waypoint],
                reasons: [String], takeCover: Bool, generatedAt: String) {
        self.planId = planId; self.hazard = hazard; self.target = target
        self.waypoints = waypoints; self.reasons = reasons
        self.takeCover = takeCover; self.generatedAt = generatedAt
    }
}

public struct Target: Codable, Sendable, Equatable {
    public let kind: String                   // "room" | "object" | "point"
    public let roomId: String?
    public let objectId: String?
    public let x: Double?                      // set only for "point" (e.g. an exit)
    public let y: Double?
    public init(kind: String, roomId: String? = nil, objectId: String? = nil,
                x: Double? = nil, y: Double? = nil) {
        self.kind = kind; self.roomId = roomId; self.objectId = objectId; self.x = x; self.y = y
    }
}

public struct Waypoint: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let roomId: String
    public init(x: Double, y: Double, roomId: String) { self.x = x; self.y = y; self.roomId = roomId }
}

/// A room's state change (docs/interfaces.md §2) — sent to /report and as knownDamage.
public struct DamageEvent: Codable, Sendable, Equatable {
    public let roomId: String
    public let state: String                  // "safe" | "at_risk" | "blocked"
    public let source: String                 // "nws" | "usgs" | "phone_impact" | "tap" | "predicted"
    public let confidence: Double
    public let timestamp: String
    public init(roomId: String, state: String, source: String, confidence: Double, timestamp: String) {
        self.roomId = roomId; self.state = state; self.source = source
        self.confidence = confidence; self.timestamp = timestamp
    }
}
