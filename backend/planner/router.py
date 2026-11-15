"""Router: shortest path over the house's room adjacency graph (A*).

Deterministic code only. The graph's nodes are rooms; edges are the *passable*
adjacencies computed by house_graph (shared invisible walls or doorways). Blocked
and non-navigable rooms are removed (except the start room, since the user is
already standing in it). Edge cost is the Euclidean distance between room
centroids. Re-run on every change (new blocked room) to re-plan.
"""

from __future__ import annotations

import heapq
import math
from typing import Iterable, Optional

from house_graph import HouseGraph, Point, Room


def euclidean(a: Point, b: Point) -> float:
    return math.hypot(a.x - b.x, a.y - b.y)


def centroid(room: Room) -> Point:
    pts = room.polygon
    if not pts:
        return Point(x=0.0, y=0.0)
    return Point(
        x=sum(p.x for p in pts) / len(pts),
        y=sum(p.y for p in pts) / len(pts),
    )


def route(
    graph: HouseGraph,
    start_room: str,
    goal_room: str,
    blocked: Iterable[str] = (),
) -> tuple[Optional[list[str]], float]:
    """A* from start_room to goal_room over passable room adjacency.

    Returns (path_as_room_ids, total_distance). Path is None and distance is inf
    if the goal is unreachable (e.g. it is blocked, or every route to it passes
    only through blocked/non-navigable rooms).
    """
    if start_room not in graph.rooms or goal_room not in graph.rooms:
        return None, math.inf

    blocked_set = set(blocked)
    if goal_room in blocked_set:
        return None, math.inf  # cannot send someone into a blocked room

    if start_room == goal_room:
        return [start_room], 0.0

    cents = {rid: centroid(r) for rid, r in graph.rooms.items()}

    def heuristic(rid: str) -> float:
        return euclidean(cents[rid], cents[goal_room])

    # (f_score, g_score, room_id, path)
    open_heap: list[tuple[float, float, str, list[str]]] = [
        (heuristic(start_room), 0.0, start_room, [start_room])
    ]
    best_g: dict[str, float] = {start_room: 0.0}

    while open_heap:
        _, g, current, path = heapq.heappop(open_heap)
        if current == goal_room:
            return path, g
        if g > best_g.get(current, math.inf):
            continue  # stale heap entry

        for nb in graph.adjacency.get(current, []):
            # The goal may be entered; any intermediate node must be passable.
            if nb != goal_room:
                if nb in blocked_set or not graph.rooms[nb].navigable:
                    continue
            new_g = g + euclidean(cents[current], cents[nb])
            if new_g < best_g.get(nb, math.inf):
                best_g[nb] = new_g
                heapq.heappush(
                    open_heap, (new_g + heuristic(nb), new_g, nb, path + [nb])
                )

    return None, math.inf
