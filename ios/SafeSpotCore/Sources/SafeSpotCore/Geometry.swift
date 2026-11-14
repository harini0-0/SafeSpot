import Foundation

/// Pure 2D geometry helpers used to derive the house graph from the real data.
/// All math is deterministic; no coordinates are invented.
public enum Geometry {

    /// Linear interpolation between two points, `t` in 0...1.
    public static func lerp(_ a: Point2D, _ b: Point2D, _ t: Double) -> Point2D {
        Point2D(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// World position of an opening: `relativeCenter` along its parent edge.
    public static func openingCenter(edge: Edge, relativeCenter t: Double) -> Point2D {
        guard edge.vertices.count >= 2 else {
            return edge.vertices.first?.position ?? Point2D(x: 0, y: 0)
        }
        return lerp(edge.vertices[0].position, edge.vertices[1].position, t)
    }

    /// Chain a room's edge segments into an ordered polygon loop by walking shared
    /// vertex ids. Works for `wall` and `invisible` edges alike (both bound the room).
    /// Returns the ordered vertices; may be empty if the edges don't form a loop.
    public static func orderedPolygon(edges: [Edge]) -> [Point2D] {
        guard !edges.isEmpty else { return [] }
        var pos: [String: Point2D] = [:]
        var adj: [String: [String]] = [:]
        for e in edges where e.vertices.count >= 2 {
            let a = e.vertices[0], b = e.vertices[1]
            pos[a.id] = a.position
            pos[b.id] = b.position
            adj[a.id, default: []].append(b.id)
            adj[b.id, default: []].append(a.id)
        }
        guard let start = edges.first?.vertices.first?.id, pos[start] != nil else { return [] }
        var order = [start]
        var prev: String? = nil
        var cur = start
        for _ in 0..<pos.count {
            let next = (adj[cur] ?? []).first { $0 != prev }
            guard let n = next, n != start else { break }
            order.append(n)
            prev = cur
            cur = n
        }
        return order.compactMap { pos[$0] }
    }

    /// Signed polygon area (shoelace); absolute value is the area in m².
    public static func polygonArea(_ poly: [Point2D]) -> Double {
        guard poly.count >= 3 else { return 0 }
        var sum = 0.0
        for i in 0..<poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2.0
    }

    /// Centroid of the polygon vertices (simple average; good enough for labels).
    public static func centroid(_ poly: [Point2D]) -> Point2D {
        guard !poly.isEmpty else { return Point2D(x: 0, y: 0) }
        let sx = poly.reduce(0) { $0 + $1.x }
        let sy = poly.reduce(0) { $0 + $1.y }
        return Point2D(x: sx / Double(poly.count), y: sy / Double(poly.count))
    }

    /// Ray-casting point-in-polygon test.
    public static func contains(_ poly: [Point2D], _ p: Point2D) -> Bool {
        guard poly.count >= 3 else { return false }
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y) {
                let xCross = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
                if p.x < xCross { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Shortest distance from a point to a line segment.
    public static func distance(from p: Point2D, toSegment a: Point2D, _ b: Point2D) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
        t = max(0, min(1, t))
        let proj = Point2D(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(p.x - proj.x, p.y - proj.y)
    }
}
