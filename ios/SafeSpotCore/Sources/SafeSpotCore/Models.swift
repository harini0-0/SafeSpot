import Foundation

// Codable models mapping the real Matterport export `data/zyzG7fqtBDv.json` as it
// actually is. Field names match the JSON exactly. Nothing here is invented; every
// property corresponds to a key documented in CLAUDE.md's data contract.
//
// Only the sections the `house` module needs are modeled: geolocation, floors,
// rooms (with classifications, dimensionEstimates, ceiling, boundary.edges and
// their openings) and panoramas. Unmodeled sections are ignored on decode.

// MARK: - Geometry primitives

public struct Point2D: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct Vector3: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let z: Double
    public init(x: Double, y: Double, z: Double) { self.x = x; self.y = y; self.z = z }
}

public struct Quaternion: Codable, Sendable, Equatable {
    public let w: Double
    public let x: Double
    public let y: Double
    public let z: Double
    public init(w: Double, x: Double, y: Double, z: Double) {
        self.w = w; self.x = x; self.y = y; self.z = z
    }
}

// MARK: - Top level

public struct MatterportModel: Codable, Sendable {
    public let modelId: String
    public let units: String
    public let sections: Sections

    /// Decode from raw JSON data.
    public static func decode(from data: Data) throws -> MatterportModel {
        try JSONDecoder().decode(MatterportModel.self, from: data)
    }

    /// Decode from a file URL.
    public static func load(contentsOf url: URL) throws -> MatterportModel {
        try decode(from: Data(contentsOf: url))
    }
}

public struct Sections: Codable, Sendable {
    public let geolocation: GeolocationSection
    public let floors: FloorsSection
    public let rooms: RoomsSection
    public let panoramas: PanoramasSection?
}

// MARK: - Geolocation

public struct GeolocationSection: Codable, Sendable {
    public let geocoordinates: GeoCoordinate
}

public struct GeoCoordinate: Codable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double?
    public let source: String?
    public let rotation: Quaternion
    public let translation: Vector3
}

// MARK: - Floors

public struct FloorsSection: Codable, Sendable {
    public let floors: [Floor]
}

public struct Floor: Codable, Sendable {
    public let id: String
    public let label: String?
    public let sequence: Int?
}

// MARK: - Rooms

public struct RoomsSection: Codable, Sendable {
    public let rooms: [Room]
}

public struct Room: Codable, Sendable {
    public let id: String
    public let label: String?
    public let keywords: [String]?
    public let tags: [String]?
    public let floor: RoomFloorRef?
    public let classifications: [Classification]
    public let dimensionEstimates: DimensionEstimates
    public let ceiling: Ceiling?
    public let boundary: Boundary

    /// Primary classification label (e.g. "Living Room", "Bedroom", "Void").
    public var primaryType: String { classifications.first?.label ?? "" }
}

public struct RoomFloorRef: Codable, Sendable {
    public let id: String
    public let label: String?
    public let sequence: Int?
}

public struct Classification: Codable, Sendable {
    public let id: String?
    public let label: String
    public let confidence: Double?
    public let defaultKeywords: [String]?
}

public struct DimensionEstimates: Codable, Sendable {
    public let area: Double?
    public let areaIndoor: Double?
    public let areaIndoorWithWalls: Double?
    public let depth: Double?
    public let width: Double?
    public let height: Double?
    public let units: String?
}

/// Ceiling min/max height in meters. The source may be an empty object `{}` for
/// zero-height rooms, in which case both values are nil.
public struct Ceiling: Codable, Sendable {
    public let minHeight: Double?
    public let maxHeight: Double?
}

public struct Boundary: Codable, Sendable {
    public let edges: [Edge]
}

public struct Edge: Codable, Sendable {
    public let id: String
    /// "wall" or "invisible" (an open boundary between two rooms).
    public let type: String
    public let thickness: Double?
    public let centerLineBias: Double?
    public let vertices: [Vertex]
    public let openings: [Opening]?
}

public struct Vertex: Codable, Sendable {
    public let id: String
    public let position: Point2D
}

public struct Opening: Codable, Sendable {
    public let id: String
    /// "doorway" or "window".
    public let type: String
    public let label: String?
    public let width: Double
    public let height: Double
    public let lowerElevation: Double
    public let relativeCenter: Double
}

// MARK: - Panoramas

public struct PanoramasSection: Codable, Sendable {
    public let panoLocations: [Panorama]
}

public struct Panorama: Codable, Sendable {
    public let id: String
    public let label: String?
    public let position: Vector3
    public let rotation: Quaternion?
    public let anchor: PanoAnchor?
}

public struct PanoAnchor: Codable, Sendable {
    public let room: PanoRoomRef?
    public let floor: PanoFloorRef?
    public let neighbors: [String]?
}

public struct PanoRoomRef: Codable, Sendable { public let id: String }
public struct PanoFloorRef: Codable, Sendable { public let id: String }
