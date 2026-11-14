//  Position.swift
//  `locate` output, exactly as docs/interfaces.md §1 defines it.
//
//  docs/interfaces.md says this type lives in SafeSpotCore as `Position`; it isn't
//  there yet, so it's defined here with the same fields. When SafeSpotCore.Position
//  lands, delete this file and use that one.

import Foundation

struct Position: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable { case camera, motion, gps, tap }

    /// A real room id from the house data, or nil when locate can't resolve the room.
    let roomId: String?
    /// Matterport model space, meters.
    let x: Double
    let y: Double
    /// Degrees in model space: 0° = model +Y, increasing clockwise, 0–360.
    let heading: Double
    /// 0–1.
    let confidence: Double
    let source: Source
    /// ISO-8601 UTC.
    let timestamp: String

    static func now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}
