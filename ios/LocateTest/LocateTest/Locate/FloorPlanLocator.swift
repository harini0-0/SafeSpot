//  FloorPlanLocator.swift
//  `locate` Block 2: floor-plan snapping and room tracking.
//
//  Pure geometry on top of SafeSpotCore.HouseGraph — no ARKit, so it can be tested
//  off-device. Input is the phone's floor position and yaw in some tracking frame
//  (ARKit today, dead reckoning later); output is a model-space point, heading and
//  room id.
//
//  Rules (CLAUDE.md, `locate` module):
//    • The position can't cross a wall. A move that would cross one slides along it,
//      and the alignment absorbs the difference so the error doesn't build up.
//    • Room changes only happen through a doorway gap or an open ("invisible")
//      boundary, so doorways confirm room changes.
//  All geometry comes from the house data; nothing is invented.

import Foundation
import SafeSpotCore

/// A floor point in the tracking frame, already projected so that it is
/// right-handed seen from above: u = AR x, v = −AR z. `yaw` is degrees clockwise
/// from +v (the same convention as model heading).
struct TrackingPose: Equatable {
    let u: Double
    let v: Double
    let yaw: Double
}

struct FloorPlanLocator {
    let graph: HouseGraph

    /// Wall segments with their doorway gaps (exterior and interior walls).
    let walls: [Wall]
    /// Walkable rooms only (Void and zero-area rooms excluded).
    private let walkableRooms: [RoomNode]

    // Alignment: model = R(rotation) · (u, v) + offset
    private(set) var rotation: Double?          // degrees, clockwise
    private(set) var offset = Point2D(x: 0, y: 0)

    private(set) var point: Point2D?
    private(set) var heading: Double?
    private(set) var roomId: String?
    /// How many times the last walk was pushed back from a wall (for tuning).
    private(set) var snapCount = 0

    /// Keep this far from a wall's centre line after a slide, metres.
    static let wallMargin = 0.05

    struct Wall {
        let edgeId: String
        let a: Point2D
        let b: Point2D
        /// Gaps along the wall as (start, end) distances from `a`, metres.
        let gaps: [(Double, Double)]
    }

    init(graph: HouseGraph) {
        self.graph = graph
        self.walkableRooms = graph.rooms.filter { $0.isWalkable && $0.polygon.count >= 3 }

        var doorsByEdge: [String: [OpeningInfo]] = [:]
        for d in graph.doorways { doorsByEdge[d.parentEdgeId, default: []].append(d) }

        self.walls = graph.edges.filter { !$0.isOpen }.map { e in
            let len = hypot(e.v1.x - e.v0.x, e.v1.y - e.v0.y)
            let gaps: [(Double, Double)] = (doorsByEdge[e.id] ?? []).map { d in
                // Distance of the doorway centre from v0, measured on this edge.
                let c = hypot(d.worldCenter.x - e.v0.x, d.worldCenter.y - e.v0.y)
                return (max(0, c - d.width / 2), min(len, c + d.width / 2))
            }
            return Wall(edgeId: e.id, a: e.v0, b: e.v1, gaps: gaps)
        }
    }

    var isAligned: Bool { rotation != nil }

    // MARK: - Alignment and taps

    /// Two-tap alignment: the user is standing at `here` and facing `toward`
    /// (both model-space points tapped on the plan) with the given tracking pose.
    mutating func align(here: Point2D, toward: Point2D, pose: TrackingPose) {
        let modelHeading = Self.headingDegrees(from: here, to: toward)
        let rot = Self.wrap360(modelHeading - pose.yaw)
        rotation = rot
        let r = Self.rotate(Point2D(x: pose.u, y: pose.v), by: rot)
        offset = Point2D(x: here.x - r.x, y: here.y - r.y)
        point = here
        heading = modelHeading
        roomId = room(containing: here)?.id
        snapCount = 0
    }

    /// Tap-to-correct: "I'm here". Keeps the current rotation, moves the position.
    mutating func correct(to here: Point2D, pose: TrackingPose) {
        guard let rot = rotation else { return }
        let r = Self.rotate(Point2D(x: pose.u, y: pose.v), by: rot)
        offset = Point2D(x: here.x - r.x, y: here.y - r.y)
        point = here
        heading = Self.wrap360(pose.yaw + rot)
        roomId = room(containing: here)?.id
    }

    /// Switch tracking source (e.g. camera → motion) without moving the user: keep
    /// the current point and heading, and map the new source's `pose` onto them.
    mutating func rebase(pose: TrackingPose) {
        guard let p = point, let h = heading else { return }
        let rot = Self.wrap360(h - pose.yaw)
        rotation = rot
        let r = Self.rotate(Point2D(x: pose.u, y: pose.v), by: rot)
        offset = Point2D(x: p.x - r.x, y: p.y - r.y)
    }

    // MARK: - Tracking updates

    /// Feed a new tracking pose; returns the snapped model-space point.
    @discardableResult
    mutating func update(pose: TrackingPose) -> Point2D? {
        guard let rot = rotation else { return nil }
        let r = Self.rotate(Point2D(x: pose.u, y: pose.v), by: rot)
        let raw = Point2D(x: r.x + offset.x, y: r.y + offset.y)
        heading = Self.wrap360(pose.yaw + rot)

        guard let prev = point else {
            point = raw
            roomId = room(containing: raw)?.id
            return raw
        }

        let snapped = snap(from: prev, to: raw)
        if snapped != raw {
            snapCount += 1
            // Absorb the correction into the alignment so drift doesn't accumulate.
            offset = Point2D(x: offset.x + snapped.x - raw.x, y: offset.y + snapped.y - raw.y)
        }
        point = snapped
        roomId = resolveRoom(at: snapped)
        return snapped
    }

    // MARK: - Snapping

    /// Move from `p` toward `q` without passing through a wall (doorway gaps and open
    /// boundaries are passable). A blocked move slides along the wall it hits.
    func snap(from p: Point2D, to q: Point2D) -> Point2D {
        guard let hit = firstBlockingWall(from: p, to: q) else { return q }
        // Slide: keep only the motion component along the wall, then stay
        // wallMargin away from it on p's side.
        let f = hit.frame
        let dx = q.x - p.x, dy = q.y - p.y
        let along = dx * f.ux + dy * f.uy
        var s = Point2D(x: p.x + along * f.ux, y: p.y + along * f.uy)
        let dist = f.signedDistance(s) * hit.side
        if dist < Self.wallMargin {
            let push = Self.wallMargin - dist
            s = Point2D(x: s.x + f.nx * hit.side * push, y: s.y + f.ny * hit.side * push)
        }
        // If the slide itself runs into another wall (a corner), stay put.
        if firstBlockingWall(from: p, to: s) != nil { return p }
        return s
    }

    /// A move is blocked by a wall if it crosses the wall's line, or ends closer than
    /// half the margin while approaching it — at a point along the wall that isn't a
    /// doorway gap. The tolerance means a position can never sit exactly on a wall
    /// line, where floating-point error would let the next step slip through.
    private func firstBlockingWall(from p: Point2D, to q: Point2D)
        -> (wall: Wall, frame: WallFrame, side: Double)? {
        let hitZone = Self.wallMargin / 2
        var best: (wall: Wall, frame: WallFrame, side: Double, dp: Double)?
        for w in walls {
            let f = WallFrame(w)
            guard f.length > 0 else { continue }
            let dp = f.signedDistance(p), dq = f.signedDistance(q)
            let side: Double = abs(dp) > 1e-9 ? (dp > 0 ? 1 : -1) : (dq > 0 ? -1 : 1)
            let crosses = dp * dq < 0 || (abs(dp) <= 1e-9 && abs(dq) > 1e-9)
            let approaches = abs(dq) < hitZone && abs(dq) <= abs(dp)
            guard crosses || approaches else { continue }
            // Where along the wall: the crossing point, or q's projection.
            let along: Double
            if crosses, abs(dp - dq) > 1e-12 {
                let t = dp / (dp - dq)
                along = f.along(Point2D(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t))
            } else {
                along = f.along(q)
            }
            // Extend the wall ends slightly so corners have no pinhole.
            guard along >= -hitZone, along <= f.length + hitZone else { continue }
            if w.gaps.contains(where: { along >= $0.0 && along <= $0.1 }) { continue }
            if best == nil || abs(dp) < best!.dp { best = (w, f, side, abs(dp)) }
        }
        return best.map { ($0.wall, $0.frame, $0.side) }
    }

    /// Unit direction, normal and length of a wall, for distance/projection math.
    struct WallFrame {
        let a: Point2D
        let ux: Double, uy: Double     // along the wall, a → b
        let nx: Double, ny: Double     // left normal
        let length: Double
        init(_ w: Wall) {
            a = w.a
            let wx = w.b.x - w.a.x, wy = w.b.y - w.a.y
            length = hypot(wx, wy)
            ux = length > 0 ? wx / length : 0
            uy = length > 0 ? wy / length : 0
            nx = -uy; ny = ux
        }
        func signedDistance(_ p: Point2D) -> Double { (p.x - a.x) * nx + (p.y - a.y) * ny }
        func along(_ p: Point2D) -> Double { (p.x - a.x) * ux + (p.y - a.y) * uy }
    }

    // MARK: - Rooms

    func room(containing p: Point2D) -> RoomNode? {
        // Smallest containing room wins (closets inside bigger outlines, if any).
        walkableRooms
            .filter { Geometry.contains($0.polygon, p) }
            .min { $0.area < $1.area }
    }

    /// Keep the current room while still inside it (rooms share wall centre lines,
    /// so this avoids flicker on the boundary); otherwise take the containing room.
    /// Snapping guarantees the user only got there through a doorway or open edge.
    private func resolveRoom(at p: Point2D) -> String? {
        if let id = roomId, let r = graph.roomsById[id], Geometry.contains(r.polygon, p) {
            return id
        }
        return room(containing: p)?.id
    }

    // MARK: - Math helpers

    /// Rotate clockwise by `deg` (heading convention: 0 = +y, clockwise).
    static func rotate(_ p: Point2D, by deg: Double) -> Point2D {
        let r = deg * .pi / 180
        return Point2D(x: p.x * cos(r) + p.y * sin(r), y: -p.x * sin(r) + p.y * cos(r))
    }

    static func headingDegrees(from a: Point2D, to b: Point2D) -> Double {
        wrap360(atan2(b.x - a.x, b.y - a.y) * 180 / .pi)
    }

    static func wrap360(_ d: Double) -> Double {
        let x = d.truncatingRemainder(dividingBy: 360)
        return x < 0 ? x + 360 : x
    }

    /// Wrap an angle difference into −180…180.
    static func wrap180(_ d: Double) -> Double {
        var x = d.truncatingRemainder(dividingBy: 360)
        if x > 180 { x -= 360 }
        if x < -180 { x += 360 }
        return x
    }
}
