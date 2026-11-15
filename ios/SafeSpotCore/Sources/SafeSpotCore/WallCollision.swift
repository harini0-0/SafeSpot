import Foundation

// Keeps a moving point (the first-person camera, later the located user) from
// crossing solid walls, while letting it pass through real doorways and the open
// (invisible) room boundaries. Pure 2D geometry on the floor plane — deterministic
// code, as CLAUDE.md requires. Windows are NOT passable (only doorways).

public struct WallCollision: Sendable {

    public struct Segment: Sendable {
        public let a: Point2D
        public let b: Point2D
        /// Invisible edges (open boundaries between rooms) never block movement.
        public let isOpen: Bool
        /// Parameter ranges along a→b (0...1) that a doorway opens up, so movement
        /// through them is allowed.
        public let passableSpans: [ClosedRange<Double>]
    }

    public let segments: [Segment]

    public init(graph: HouseGraph) {
        var doorwaysByEdge: [String: [OpeningInfo]] = [:]
        for d in graph.doorways { doorwaysByEdge[d.parentEdgeId, default: []].append(d) }

        segments = graph.edges.map { e in
            let len = (hypot(e.v1.x - e.v0.x, e.v1.y - e.v0.y))
            var spans: [ClosedRange<Double>] = []
            if len > 1e-6 {
                for d in doorwaysByEdge[e.id] ?? [] {
                    let half = (d.width / 2) / len
                    let lo = max(0, d.relativeCenter - half)
                    let hi = min(1, d.relativeCenter + half)
                    if lo < hi { spans.append(lo...hi) }
                }
            }
            return Segment(a: e.v0, b: e.v1, isOpen: e.type == "invisible", passableSpans: spans)
        }
    }

    /// Would a straight move from `from` to `to` cross a solid wall?
    public func isBlocked(from: Point2D, to: Point2D) -> Bool {
        firstBlockingT(from: from, to: to) != nil
    }

    /// The furthest point along `from`→`to` that doesn't cross a solid wall,
    /// backing off a few cm so the camera doesn't sit inside the wall.
    public func resolve(from: Point2D, to: Point2D, backoff: Double = 0.12) -> Point2D {
        guard let t = firstBlockingT(from: from, to: to) else { return to }
        let len = hypot(to.x - from.x, to.y - from.y)
        let backFrac = len > 1e-9 ? backoff / len : 0
        let tt = max(0, t - backFrac)
        return Point2D(x: from.x + (to.x - from.x) * tt,
                       y: from.y + (to.y - from.y) * tt)
    }

    // Smallest intersection parameter along from→to that hits a solid (non-passable)
    // part of a wall.
    private func firstBlockingT(from A: Point2D, to B: Point2D) -> Double? {
        var best: Double?
        for s in segments where !s.isOpen {
            guard let (tAB, tEdge) = Self.intersect(A, B, s.a, s.b) else { continue }
            if tAB <= 1e-9 { continue }  // already at/behind this wall
            if s.passableSpans.contains(where: { $0.contains(tEdge) }) { continue }  // doorway
            if best == nil || tAB < best! { best = tAB }
        }
        return best
    }

    /// Segment–segment intersection; returns (t along P→P2, u along Q→Q2) if they cross.
    static func intersect(_ p: Point2D, _ p2: Point2D,
                          _ q: Point2D, _ q2: Point2D) -> (Double, Double)? {
        let rx = p2.x - p.x, ry = p2.y - p.y
        let sx = q2.x - q.x, sy = q2.y - q.y
        let denom = rx * sy - ry * sx
        if abs(denom) < 1e-12 { return nil }  // parallel
        let qpx = q.x - p.x, qpy = q.y - p.y
        let t = (qpx * sy - qpy * sx) / denom
        let u = (qpx * ry - qpy * rx) / denom
        if t < 0 || t > 1 || u < 0 || u > 1 { return nil }
        return (t, u)
    }
}
