"""Wire schemas for the Safe Spot backend.

These mirror `docs/interfaces.md` exactly — the single contract the app
(`guide`), `locate` and `backend` code against — and the `SafeSpotCore` Swift
types. Field names are the on-the-wire JSON keys (camelCase) so serialization
matches the contract with no aliasing. All positions are Matterport model space,
meters; timestamps are ISO-8601 UTC strings; confidence is 0.0–1.0.
"""

from __future__ import annotations

from enum import Enum
from typing import Optional

from pydantic import BaseModel


class Hazard(str, Enum):
    tornado = "tornado"
    earthquake = "earthquake"
    fire = "fire"


class RoomState(str, Enum):
    safe = "safe"
    at_risk = "at_risk"
    blocked = "blocked"


class DamageSource(str, Enum):
    nws = "nws"
    usgs = "usgs"
    phone_impact = "phone_impact"
    tap = "tap"
    predicted = "predicted"


class PositionSource(str, Enum):
    camera = "camera"
    motion = "motion"
    gps = "gps"
    tap = "tap"


class TargetKind(str, Enum):
    room = "room"
    object = "object"
    point = "point"


# --- interfaces.md §1 -------------------------------------------------------
class Position(BaseModel):
    roomId: Optional[str] = None  # null when locate can't resolve the room yet
    x: float
    y: float
    heading: Optional[float] = None
    confidence: Optional[float] = None
    source: Optional[PositionSource] = None
    timestamp: Optional[str] = None


# --- interfaces.md §2 -------------------------------------------------------
class DamageEvent(BaseModel):
    roomId: str
    state: RoomState
    source: DamageSource
    confidence: float = 1.0
    timestamp: Optional[str] = None


# --- interfaces.md §3 -------------------------------------------------------
class Target(BaseModel):
    kind: TargetKind
    roomId: Optional[str] = None
    objectId: Optional[str] = None  # only for kind == object (Phase O)
    x: Optional[float] = None  # only for kind == point
    y: Optional[float] = None


class Waypoint(BaseModel):
    x: float
    y: float
    roomId: str


class Plan(BaseModel):
    planId: str
    hazard: Hazard
    target: Optional[Target]
    waypoints: list[Waypoint]
    reasons: list[str]
    takeCover: bool = False
    generatedAt: str
