"""Planner: pick the safe target and route for a hazard (contract-conformant).

Deterministic code only — the "math", never the agent's judgment. Output is the
`Plan` shape from docs/interfaces.md (§3): planId, target (room/object/point),
waypoints in model-space meters, reasons[], takeCover, generatedAt. The planner
chooses WHERE to go; the router computes the room path; this module turns that
path into waypoints. It never invents rooms, objects or coordinates — every id
and point comes from the real house graph.

Safe-spot logic (CLAUDE.md):
  * Tornado:    interior, lowest-floor, windowless room -> sturdy object -> exit
  * Earthquake: take cover in place while shaking (no running) -> exit after
  * Fire:       nearest exit avoiding fire/blocked rooms -> second exit

Fallback order: safe room -> safe object -> exit. The object step depends on
data/derived/objects.json (Phase O, Harini); until it exists select_safe_object
returns None and we emit room/point targets only (interfaces.md §3 note).
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone
from typing import Optional

from house_graph import HouseGraph, Point
from planner.router import centroid, route
from schemas import (
    Hazard,
    Plan,
    RoomState,
    Target,
    TargetKind,
    Waypoint,
)

# Internal ranked candidate: (target_room_id, path_room_ids, distance, reason).
_RoomCand = tuple[str, list[str], float, str]
# Internal ranked exit: (opening_id, exit_room_id, path_room_ids, distance, reason).
_ExitCand = tuple[str, str, list[str], float, str]


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _new_plan_id() -> str:
    return str(uuid.uuid4())


# ---------------------------------------------------------------------------
# Safe-object step (gated on Phase O)
# ---------------------------------------------------------------------------
def select_safe_object(
    graph: HouseGraph, room_id: str, hazard: Hazard
) -> Optional[Target]:
    """Pick a sturdy object (table/tub) in the room. Gated on Phase O.

    data/derived/objects.json does not exist yet and its schema is unconfirmed
    (Harini owns Phase O). While graph.objects is empty this returns None and the
    planner emits room/point targets only. Wire real selection here once the
    objects.json schema is fixed (types limited to table/bed/bathtub/sofa/counter
    per interfaces.md §5).
    """
    if not graph.objects:
        return None
    # TODO(Phase O): filter graph.objects to room_id, keep sturdy types sized for
    # the person, return nearest as Target(kind=object, objectId=..., roomId=...).
    return None


# ---------------------------------------------------------------------------
# Geometry helpers
# ---------------------------------------------------------------------------
def _opening_point(graph: HouseGraph, opening_id: str) -> Optional[Point]:
    """World point of an opening = start + relativeCenter * (end - start)."""
    op = graph.openings.get(opening_id)
    if not op or op.parent_edge_id not in graph.edges:
        return None
    edge = graph.edges[op.parent_edge_id]
    t = op.relative_center if op.relative_center is not None else 0.5
    return Point(
        x=edge.start.x + t * (edge.end.x - edge.start.x),
        y=edge.start.y + t * (edge.end.y - edge.start.y),
    )


def _room_waypoints(graph: HouseGraph, path: list[str]) -> list[Waypoint]:
    out: list[Waypoint] = []
    for rid in path:
        c = centroid(graph.rooms[rid])
        out.append(Waypoint(x=c.x, y=c.y, roomId=rid))
    return out


def _blocked_rooms(room_states: dict[str, RoomState]) -> set[str]:
    return {rid for rid, st in room_states.items() if st == RoomState.blocked}


def _blocked_reason(
    graph: HouseGraph, room_states: dict[str, RoomState]
) -> Optional[str]:
    blocked = _blocked_rooms(room_states)
    if not blocked:
        return None
    names = sorted(
        graph.rooms[r].type for r in blocked if r in graph.rooms
    )
    return "Route avoids blocked room(s): " + ", ".join(names)


# ---------------------------------------------------------------------------
# Candidate ranking
# ---------------------------------------------------------------------------
def _lowest_floor_rooms(graph: HouseGraph) -> set[str]:
    seqs = [r.floor_sequence for r in graph.rooms.values() if r.floor_sequence is not None]
    if not seqs:
        return set(graph.rooms)
    lowest = min(seqs)
    return {rid for rid, r in graph.rooms.items() if r.floor_sequence == lowest}


def _exterior_wall_count(graph: HouseGraph, room_id: str) -> int:
    return sum(1 for e in graph.edges.values() if room_id in e.room_ids and e.is_exterior)


def _window_count(graph: HouseGraph, room_id: str) -> int:
    return sum(
        1
        for o in graph.windows()
        if o.parent_edge_id in graph.edges
        and room_id in graph.edges[o.parent_edge_id].room_ids
    )


def rank_tornado_rooms(
    graph: HouseGraph, current_room: str, blocked: set[str]
) -> list[_RoomCand]:
    """Interior, windowless, lowest-floor rooms nearest first; relaxed if none."""
    on_exterior = graph.rooms_on_exterior_wall()
    windowed = graph.rooms_with_windows()
    lowest = _lowest_floor_rooms(graph)

    def reachable(room_id: str) -> Optional[tuple[list[str], float]]:
        room = graph.rooms[room_id]
        if not room.navigable or room_id in blocked or room_id not in lowest:
            return None
        path, dist = route(graph, current_room, room_id, blocked)
        return (path, dist) if path is not None else None

    strict: list[_RoomCand] = []
    for room_id in graph.rooms:
        if room_id in on_exterior or room_id in windowed:
            continue
        r = reachable(room_id)
        if r:
            strict.append(
                (room_id, r[0], r[1], "Interior room, lowest floor, no windows, no outside walls")
            )
    if strict:
        strict.sort(key=lambda c: c[2])
        return strict

    relaxed: list[tuple[int, int, _RoomCand]] = []
    for room_id in graph.rooms:
        r = reachable(room_id)
        if not r:
            continue
        cand: _RoomCand = (
            room_id,
            r[0],
            r[1],
            "Best available shelter: fewest outside walls and windows",
        )
        relaxed.append((_exterior_wall_count(graph, room_id), _window_count(graph, room_id), cand))
    relaxed.sort(key=lambda t: (t[0], t[1], t[2][2]))
    return [c for _, _, c in relaxed]


def rank_exits(
    graph: HouseGraph, current_room: str, blocked: set[str]
) -> list[_ExitCand]:
    """All reachable exterior exits, nearest first."""
    found: list[_ExitCand] = []
    for exit_id in graph.exits:
        op = graph.openings.get(exit_id)
        if not op or op.parent_edge_id not in graph.edges:
            continue
        room_ids = graph.edges[op.parent_edge_id].room_ids
        if not room_ids:
            continue
        exit_room = room_ids[0]
        path, dist = route(graph, current_room, exit_room, blocked)
        if path is None:
            continue
        found.append((exit_id, exit_room, path, dist, "Nearest exterior exit with a clear path"))
    found.sort(key=lambda c: c[3])
    return found


# ---------------------------------------------------------------------------
# Plan builders
# ---------------------------------------------------------------------------
def _empty_plan(hazard: Hazard, reasons: list[str], take_cover: bool = False) -> Plan:
    return Plan(
        planId=_new_plan_id(),
        hazard=hazard,
        target=None,
        waypoints=[],
        reasons=reasons,
        takeCover=take_cover,
        generatedAt=_now_iso(),
    )


def _room_plan(graph, hazard, cand: _RoomCand, extra_reasons: list[str]) -> Plan:
    room_id, path, _dist, reason = cand
    reasons = [reason] + extra_reasons
    if not graph.objects:
        reasons.append("No safe object data available (objects.json empty)")
    return Plan(
        planId=_new_plan_id(),
        hazard=hazard,
        target=Target(kind=TargetKind.room, roomId=room_id),
        waypoints=_room_waypoints(graph, path),
        reasons=reasons,
        takeCover=False,
        generatedAt=_now_iso(),
    )


def _exit_plan(graph, hazard, cand: _ExitCand, extra_reasons: list[str]) -> Plan:
    opening_id, exit_room, path, _dist, reason = cand
    waypoints = _room_waypoints(graph, path)
    door = _opening_point(graph, opening_id)
    if door is not None:
        waypoints.append(Waypoint(x=door.x, y=door.y, roomId=exit_room))
        target = Target(kind=TargetKind.point, x=door.x, y=door.y, roomId=exit_room)
    else:
        target = Target(kind=TargetKind.room, roomId=exit_room)
    return Plan(
        planId=_new_plan_id(),
        hazard=hazard,
        target=target,
        waypoints=waypoints,
        reasons=[reason] + extra_reasons,
        takeCover=False,
        generatedAt=_now_iso(),
    )


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------
def plan(
    graph: HouseGraph,
    current_room: Optional[str],
    hazard: Hazard,
    room_states: Optional[dict[str, RoomState]] = None,
    shaking: bool = True,
) -> Plan:
    """Pick the safe target + route for a position + hazard, as a contract Plan."""
    room_states = room_states or {}
    blocked = _blocked_rooms(room_states)

    if current_room is None or current_room not in graph.rooms:
        return _empty_plan(
            hazard, [f"Current room unknown or invalid ({current_room!r}); cannot route."]
        )

    extra = []
    br = _blocked_reason(graph, room_states)
    if br:
        extra.append(br)

    if hazard == Hazard.earthquake:
        if shaking:
            room = graph.rooms[current_room]
            obj = select_safe_object(graph, current_room, Hazard.earthquake)
            if obj is not None:
                obj.roomId = obj.roomId or current_room
                target = obj
            else:
                target = Target(kind=TargetKind.room, roomId=current_room)
            c = centroid(room)
            return Plan(
                planId=_new_plan_id(),
                hazard=hazard,
                target=target,
                waypoints=[Waypoint(x=c.x, y=c.y, roomId=current_room)],
                reasons=[
                    "Take cover here now; do not run while it is shaking",
                    "Exit once the shaking stops",
                ],
                takeCover=True,
                generatedAt=_now_iso(),
            )
        exits = rank_exits(graph, current_room, blocked)
        if exits:
            return _exit_plan(graph, hazard, exits[0], extra + ["Shaking stopped: move to the exit"])
        return _empty_plan(hazard, extra + ["Shaking stopped but no exit reachable"])

    if hazard == Hazard.fire:
        exits = rank_exits(graph, current_room, blocked)
        if exits:
            more = extra + (["Second exit available as backup"] if len(exits) > 1 else [])
            return _exit_plan(graph, hazard, exits[0], more)
        return _empty_plan(hazard, extra + ["No exit reachable avoiding the fire/blocked rooms"])

    # Tornado (default): safe room -> object (gated) -> exit.
    rooms = rank_tornado_rooms(graph, current_room, blocked)
    if rooms:
        return _room_plan(graph, hazard, rooms[0], extra)
    exits = rank_exits(graph, current_room, blocked)
    if exits:
        return _exit_plan(graph, hazard, exits[0], extra + ["No safe room reachable; routing to exit"])
    return _empty_plan(hazard, extra + ["No safe room or exit reachable"])
