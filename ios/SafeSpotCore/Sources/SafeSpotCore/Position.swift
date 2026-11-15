import Foundation

/// The user's position, as docs/interfaces.md §1 defines it. Produced by `locate`
/// (Sanjana's module) or by the virtual walkthrough, and consumed by `guide`.
public struct Position: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case camera, motion, gps, tap }

    /// A real room id from the house data, or nil when the room isn't resolved yet.
    public let roomId: String?
    /// Matterport model space, meters.
    public let x: Double
    public let y: Double
    /// Degrees in model space: 0° = model +Y, clockwise, 0–360 (true north = +26.676°).
    public let heading: Double
    /// 0–1.
    public let confidence: Double
    public let source: Source
    /// ISO-8601 UTC.
    public let timestamp: String

    public init(roomId: String?, x: Double, y: Double, heading: Double,
                confidence: Double, source: Source, timestamp: String) {
        self.roomId = roomId; self.x = x; self.y = y; self.heading = heading
        self.confidence = confidence; self.source = source; self.timestamp = timestamp
    }

    public static func now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}
