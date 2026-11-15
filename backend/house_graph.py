"""House graph loader for the Safe Spot backend.

Reads the read-only CoStar/Matterport export in `data/` and builds a validated,
deterministic graph of rooms, walls, doorways, windows, exits and room
adjacency. Code only — no judgment, no invented data. Field paths follow the
data contract in CLAUDE.md.

Adjacency & exterior rules (straight from the data contract):
  * An edge `id` that appears in TWO rooms is an INTERIOR wall shared by them.
  * An edge `id` in only ONE room is EXTERIOR.
  * A doorway on a shared edge connects the two rooms that edge belongs to.
  * A doorway on an exterior edge (one room) is an exterior EXIT.
  * A wall of type "invisible" is an open boundary (walkable, no door).
  * Two rooms are PASSABLE neighbours when they share an edge that is either
    "invisible" or carries a doorway. A shared solid wall with no opening is
    adjacent but NOT passable.

Objects (furniture) are NOT in the Matterport data (objectAnnotations: 0). Per
CLAUDE.md they are derived separately into `data/derived/objects.json`
("Phase O"). That file does not exist yet and its schema is unconfirmed, so
objects load leniently: present -> attach raw contents; absent -> empty list and
the planner's safe-object step stays gated. We never invent objects.

Run `python backend/house_graph.py` to print a summary and a self-check against
the counts stated in the data contract.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Optional

from pydantic import BaseModel

REPO_ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = REPO_ROOT / "data"
DEFAULT_MODEL_ID = "zyzG7fqtBDv"

# Room classifications / keywords that are not navigable space.
NON_NAVIGABLE_LABELS = {"Void"}
NON_NAVIGABLE_KEYWORDS = {"nonArea", "hide"}


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------
class Point(BaseModel):
    x: float
    y: float


class Opening(BaseModel):
    id: str
    type: str  # "doorway" | "window"
    label: Optional[str] = None
    width: Optional[float] = None
    height: Optional[float] = None
    lower_elevation: Optional[float] = None
    relative_center: Optional[float] = None
    parent_edge_id: str


class Edge(BaseModel):
    id: str
    type: str  # "wall" | "invisible"
    thickness: Optional[float] = None
    start: Point
    end: Point
    room_ids: list[str] = []  # rooms whose boundary references this edge id
    opening_ids: list[str] = []

    @property
    def is_exterior(self) -> bool:
        return len(set(self.room_ids)) <= 1


class Room(BaseModel):
    id: str
    type: str  # classification label (Living Room, Bedroom, Kitchen, ...)
    floor_id: Optional[str] = None
    floor_sequence: Optional[int] = None
    navigable: bool = True
    area: Optional[float] = None
    height: Optional[float] = None
    edge_ids: list[str] = []
    polygon: list[Point] = []
    keywords: list[str] = []


class HouseGraph(BaseModel):
    model_id: str
    rooms: dict[str, Room]
    edges: dict[str, Edge]
    openings: dict[str, Opening]
    adjacency: dict[str, list[str]]  # room_id -> passable neighbour room_ids
    exits: list[str]  # doorway opening ids that are exterior exits
    objects: list[dict] = []  # raw Phase O objects if present, else []

    # -- convenience accessors -------------------------------------------
    def doorways(self) -> list[Opening]:
        return [o for o in self.openings.values() if o.type == "doorway"]

    def windows(self) -> list[Opening]:
        return [o for o in self.openings.values() if o.type == "window"]

    def rooms_with_windows(self) -> set[str]:
        """Room ids that have at least one window on one of their edges."""
        out: set[str] = set()
        for o in self.windows():
            edge = self.edges.get(o.parent_edge_id)
            if edge:
                out.update(edge.room_ids)
        return out

    def rooms_on_exterior_wall(self) -> set[str]:
        """Room ids that own at least one exterior edge."""
        out: set[str] = set()
        for edge in self.edges.values():
            if edge.is_exterior:
                out.update(edge.room_ids)
        return out


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------
def _classification_label(room_raw: dict) -> str:
    classifications = room_raw.get("classifications") or []
    if classifications:
        return classifications[0].get("label") or "Unknown"
    return "Unknown"


def load_house_graph(model_id: str = DEFAULT_MODEL_ID) -> HouseGraph:
    """Build the HouseGraph from data/<model_id>.json (read-only)."""
    full = json.loads((DATA_DIR / f"{model_id}.json").read_text())
    rooms_raw = (
        full.get("sections", {}).get("rooms", {}).get("rooms", [])
    )

    rooms: dict[str, Room] = {}
    edges: dict[str, Edge] = {}
    openings: dict[str, Opening] = {}

    for room_raw in rooms_raw:
        room_id = room_raw["id"]
        label = _classification_label(room_raw)
        keywords = room_raw.get("keywords") or []
        navigable = (
            label not in NON_NAVIGABLE_LABELS
            and not (set(keywords) & NON_NAVIGABLE_KEYWORDS)
        )
        floor = room_raw.get("floor") or {}
        dims = room_raw.get("dimensionEstimates") or {}

        edge_ids: list[str] = []
        polygon: list[Point] = []
        for edge_raw in (room_raw.get("boundary", {}).get("edges", []) or []):
            edge_id = edge_raw["id"]
            edge_ids.append(edge_id)
            verts = edge_raw.get("vertices") or []

            if edge_id not in edges:
                start = verts[0]["position"]
                end = verts[1]["position"]
                edges[edge_id] = Edge(
                    id=edge_id,
                    type=edge_raw.get("type", "wall"),
                    thickness=edge_raw.get("thickness"),
                    start=Point(x=start["x"], y=start["y"]),
                    end=Point(x=end["x"], y=end["y"]),
                )
            if room_id not in edges[edge_id].room_ids:
                edges[edge_id].room_ids.append(room_id)

            # Polygon: first vertex of each edge, in boundary order.
            if verts:
                p = verts[0]["position"]
                polygon.append(Point(x=p["x"], y=p["y"]))

            for op_raw in (edge_raw.get("openings") or []):
                op_id = op_raw["id"]
                if op_id not in openings:
                    openings[op_id] = Opening(
                        id=op_id,
                        type=op_raw.get("type", "unknown"),
                        label=op_raw.get("label"),
                        width=op_raw.get("width"),
                        height=op_raw.get("height"),
                        lower_elevation=op_raw.get("lowerElevation"),
                        relative_center=op_raw.get("relativeCenter"),
                        parent_edge_id=edge_id,
                    )
                if op_id not in edges[edge_id].opening_ids:
                    edges[edge_id].opening_ids.append(op_id)

        rooms[room_id] = Room(
            id=room_id,
            type=label,
            floor_id=floor.get("id"),
            floor_sequence=floor.get("sequence"),
            navigable=navigable,
            area=dims.get("area"),
            height=dims.get("height"),
            edge_ids=edge_ids,
            polygon=polygon,
            keywords=keywords,
        )

    adjacency = _build_adjacency(rooms, edges)
    exits = _find_exits(edges, openings)
    objects = _load_objects()

    return HouseGraph(
        model_id=model_id,
        rooms=rooms,
        edges=edges,
        openings=openings,
        adjacency=adjacency,
        exits=exits,
        objects=objects,
    )


def _build_adjacency(
    rooms: dict[str, Room], edges: dict[str, Edge]
) -> dict[str, list[str]]:
    """Passable room-to-room neighbours via shared invisible/doorway edges."""
    adj: dict[str, set[str]] = {rid: set() for rid in rooms}
    for edge in edges.values():
        room_ids = list(dict.fromkeys(edge.room_ids))  # unique, keep order
        if len(room_ids) != 2:
            continue
        passable = edge.type == "invisible" or bool(edge.opening_ids)
        if not passable:
            continue
        a, b = room_ids
        if a in adj and b in adj:
            adj[a].add(b)
            adj[b].add(a)
    return {rid: sorted(neighbours) for rid, neighbours in adj.items()}


def _find_exits(
    edges: dict[str, Edge], openings: dict[str, Opening]
) -> list[str]:
    """Doorway openings on exterior edges = exterior exits."""
    exits: list[str] = []
    for op in openings.values():
        if op.type != "doorway":
            continue
        edge = edges.get(op.parent_edge_id)
        if edge and edge.is_exterior:
            exits.append(op.id)
    return exits


def _load_objects() -> list[dict]:
    """Load Phase O objects if present. Schema unconfirmed -> load leniently."""
    path = DATA_DIR / "derived" / "objects.json"
    if not path.exists():
        return []
    raw = json.loads(path.read_text())
    if isinstance(raw, list):
        return raw
    if isinstance(raw, dict):
        return raw.get("objects", [])
    return []


def house_coords(model_id: str = DEFAULT_MODEL_ID) -> tuple[float, float]:
    """(latitude, longitude) of the house from the read-only geo export."""
    geo = json.loads((DATA_DIR / f"{model_id}_geo.json").read_text())
    g = geo["data"]["model"]["geocoordinates"]
    return g["latitude"], g["longitude"]


# ---------------------------------------------------------------------------
# Summary / self-check
# ---------------------------------------------------------------------------
def _summary(graph: HouseGraph) -> str:
    shared = sum(1 for e in graph.edges.values() if len(set(e.room_ids)) == 2)
    exterior = sum(1 for e in graph.edges.values() if e.is_exterior)
    # The contract counts doorways by boundary occurrence: a door on a shared
    # wall is listed in both rooms. We store one canonical id per physical door,
    # so reconstruct the occurrence count for the self-check.
    doorway_occurrences = sum(
        len(set(graph.edges[o.parent_edge_id].room_ids))
        for o in graph.doorways()
        if o.parent_edge_id in graph.edges
    )
    lines = [
        f"model: {graph.model_id}",
        f"rooms: {len(graph.rooms)} "
        f"(navigable {sum(r.navigable for r in graph.rooms.values())})",
        f"edges: {len(graph.edges)} (shared/interior {shared}, exterior {exterior})",
        f"doorways: {len(graph.doorways())} unique "
        f"({doorway_occurrences} boundary occurrences)  "
        f"windows: {len(graph.windows())}",
        f"exterior exits: {len(graph.exits)}",
        f"objects (Phase O): {len(graph.objects)}",
        "",
        "rooms:",
    ]
    for r in graph.rooms.values():
        tag = "" if r.navigable else "  [non-navigable]"
        lines.append(
            f"  {r.type:<12} {r.id}  "
            f"neighbours={graph.adjacency.get(r.id, [])}{tag}"
        )

    # Self-check against the data contract's stated counts for this house.
    # "doorways" in the contract = boundary occurrences (17), not unique doors (9).
    expected = {"rooms": 11, "edges": 39, "shared": 25, "doorways": 17, "windows": 4}
    actual = {
        "rooms": len(graph.rooms),
        "edges": len(graph.edges),
        "shared": shared,
        "doorways": doorway_occurrences,
        "windows": len(graph.windows()),
    }
    lines.append("")
    lines.append("contract self-check (expected vs actual):")
    for k, exp in expected.items():
        ok = "OK " if actual[k] == exp else "!! "
        lines.append(f"  {ok}{k}: expected {exp}, got {actual[k]}")
    return "\n".join(lines)


if __name__ == "__main__":
    print(_summary(load_house_graph()))
