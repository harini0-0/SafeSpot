import Foundation

// The navigable house, derived entirely from the real Matterport data. No values
// are hand-entered. Interior/exterior walls, doorway connectivity and exterior
// exits are derived per CLAUDE.md:
//   - an edge id shared by two rooms is interior; an edge in one room is exterior
//   - a doorway on a single-room edge is an exterior exit
//   - a damaged corner blocks the whole room (enforced by the planner, not here)

public struct RoomNode: Sendable, Identifiable {
    public let id: String
    /// Classification label, e.g. "Living Room", "Bedroom", "Void".
    public let type: String
    public let classificationConfidence: Double?
    public let floorId: String?
    public let area: Double
    /// Ceiling height in meters: `ceiling.maxHeight`, falling back to the room's
    /// `dimensionEstimates.height`. Nil when the data has neither (zero-height rooms).
    public let ceilingHeight: Double?
    public let polygon: [Point2D]
    public let centroid: Point2D
    /// Void rooms (and any zero-area room) are not walkable.
    public let isWalkable: Bool
    public let windowIds: [String]
    /// Ids of this room's exterior wall edges (edges belonging only to this room).
    public let exteriorWallEdgeIds: [String]

    public var hasWindows: Bool { !windowIds.isEmpty }
    public var hasExteriorWalls: Bool { !exteriorWallEdgeIds.isEmpty }
}

public struct EdgeInfo: Sendable {
    public let id: String
    /// "wall" or "invisible".
    public let type: String
    /// Rooms this edge belongs to, in encounter order (1 = exterior, 2 = interior).
    public let roomIds: [String]
    public let v0: Point2D
    public let v1: Point2D
    public let thickness: Double?

    public var isInterior: Bool { Set(roomIds).count >= 2 }
    public var isExterior: Bool { !isInterior }
    /// An open boundary between rooms (no physical wall to render or collide).
    public var isOpen: Bool { type == "invisible" }
}

public struct OpeningInfo: Sendable {
    public let id: String
    /// "doorway" or "window".
    public let kind: String
    public let parentEdgeId: String
    /// Rooms joined by the parent edge (1 = exterior, 2 = connects those rooms).
    public let roomIds: [String]
    public let width: Double
    public let height: Double
    public let lowerElevation: Double
    public let relativeCenter: Double
    public let worldCenter: Point2D

    public var isExterior: Bool { Set(roomIds).count < 2 }
    /// For a doorway, the two rooms it connects (empty if exterior).
    public var connectsRooms: [String] { isExterior ? [] : roomIds }
}

public struct HouseGraph: Sendable {
    public let rooms: [RoomNode]
    public let edges: [EdgeInfo]
    public let doorways: [OpeningInfo]
    public let windows: [OpeningInfo]

    public let roomsById: [String: RoomNode]

    /// Doorways that open to the outside (on an exterior edge).
    public var exteriorExits: [OpeningInfo] { doorways.filter { $0.isExterior } }

    public init(model: MatterportModel) {
        let rooms = model.sections.rooms.rooms

        // edge id -> ordered list of room ids that contain it
        var edgeRooms: [String: [String]] = [:]
        // edge id -> representative Edge (geometry is identical across rooms)
        var edgeById: [String: Edge] = [:]
        for room in rooms {
            for edge in room.boundary.edges {
                edgeRooms[edge.id, default: []].append(room.id)
                if edgeById[edge.id] == nil { edgeById[edge.id] = edge }
            }
        }

        // Unique edges.
        var edgeInfos: [EdgeInfo] = []
        for (id, edge) in edgeById {
            let v = edge.vertices
            guard v.count >= 2 else { continue }
            edgeInfos.append(EdgeInfo(
                id: id, type: edge.type, roomIds: edgeRooms[id] ?? [],
                v0: v[0].position, v1: v[1].position, thickness: edge.thickness))
        }
        edgeInfos.sort { $0.id < $1.id }
        self.edges = edgeInfos

        // Unique openings (dedup by id), with world center and the parent edge's rooms.
        var seenOpenings = Set<String>()
        var doorways: [OpeningInfo] = []
        var windows: [OpeningInfo] = []
        for room in rooms {
            for edge in room.boundary.edges {
                for opening in edge.openings ?? [] {
                    guard !seenOpenings.contains(opening.id) else { continue }
                    seenOpenings.insert(opening.id)
                    let info = OpeningInfo(
                        id: opening.id, kind: opening.type, parentEdgeId: edge.id,
                        roomIds: edgeRooms[edge.id] ?? [],
                        width: opening.width, height: opening.height,
                        lowerElevation: opening.lowerElevation,
                        relativeCenter: opening.relativeCenter,
                        worldCenter: Geometry.openingCenter(edge: edge, relativeCenter: opening.relativeCenter))
                    if opening.type == "doorway" { doorways.append(info) }
                    else if opening.type == "window" { windows.append(info) }
                }
            }
        }
        doorways.sort { $0.id < $1.id }
        windows.sort { $0.id < $1.id }
        self.doorways = doorways
        self.windows = windows

        // Room nodes.
        let windowIdsByRoom: [String: [String]] = Self.group(windows) { $0.roomIds }
        var nodes: [RoomNode] = []
        for room in rooms {
            let poly = Geometry.orderedPolygon(edges: room.boundary.edges)
            let exteriorWallIds = room.boundary.edges
                .filter { $0.type == "wall" && Set(edgeRooms[$0.id] ?? []).count < 2 }
                .map { $0.id }
            let ceiling = room.ceiling?.maxHeight ?? room.dimensionEstimates.height
            let area = room.dimensionEstimates.area ?? Geometry.polygonArea(poly)
            let type = room.primaryType
            nodes.append(RoomNode(
                id: room.id,
                type: type,
                classificationConfidence: room.classifications.first?.confidence,
                floorId: room.floor?.id,
                area: area,
                ceilingHeight: (ceiling ?? 0) > 0 ? ceiling : nil,
                polygon: poly,
                centroid: Geometry.centroid(poly),
                isWalkable: type != "Void" && area > 0,
                windowIds: windowIdsByRoom[room.id] ?? [],
                exteriorWallEdgeIds: exteriorWallIds))
        }
        self.rooms = nodes
        self.roomsById = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    }

    /// Rooms reachable from `roomId` through a doorway or an open (invisible) boundary.
    public func neighbors(of roomId: String) -> Set<String> {
        var result = Set<String>()
        for d in doorways where !d.isExterior && d.roomIds.contains(roomId) {
            result.formUnion(d.roomIds.filter { $0 != roomId })
        }
        for e in edges where e.isOpen && e.roomIds.contains(roomId) {
            result.formUnion(e.roomIds.filter { $0 != roomId })
        }
        return result
    }

    /// Does a doorway directly connect these two rooms?
    public func doorwayConnects(_ a: String, _ b: String) -> Bool {
        doorways.contains { Set($0.roomIds) == Set([a, b]) }
    }

    /// The walkable room whose polygon contains this floor point, if any.
    public func room(containing p: Point2D) -> RoomNode? {
        rooms.first { $0.isWalkable && $0.polygon.count >= 3 && Geometry.contains($0.polygon, p) }
    }

    private static func group(_ items: [OpeningInfo],
                              _ key: (OpeningInfo) -> [String]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for item in items {
            for roomId in key(item) {
                out[roomId, default: []].append(item.id)
            }
        }
        return out
    }
}
