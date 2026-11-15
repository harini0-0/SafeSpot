"""In-memory backend state: room states, the active session, and WebSocket
clients for re-plan push. Single-process, single-house demo scope (CLAUDE.md).

Deterministic plumbing only — no model here. The room-state map is the backend's
source of truth for which rooms are safe/at_risk/blocked; the session remembers
the latest position + hazard so a new DamageEvent can trigger a re-plan; the
connection manager pushes fresh Plans to the app over /ws/plan.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional

from fastapi import WebSocket

from schemas import DamageEvent, Hazard, Plan, Position, RoomState


class RoomStateStore:
    """Current state of every room. Defaults to safe when unseen."""

    def __init__(self) -> None:
        self._states: dict[str, RoomState] = {}

    def apply_event(self, event: DamageEvent) -> None:
        self._states[event.roomId] = event.state

    def set(self, room_id: str, state: RoomState) -> None:
        self._states[room_id] = state

    def snapshot(self) -> dict[str, RoomState]:
        return dict(self._states)

    def reset(self) -> None:
        self._states.clear()


@dataclass
class Session:
    """The latest position + hazard, so a report can re-plan from context."""

    position: Optional[Position] = None
    hazard: Optional[Hazard] = None
    shaking: bool = True
    last_signature: Optional[str] = None

    def set_context(self, position: Position, hazard: Hazard, shaking: bool) -> None:
        self.position = position
        self.hazard = hazard
        self.shaking = shaking

    def active(self) -> bool:
        return self.position is not None and self.hazard is not None


class ConnectionManager:
    """Tracks /ws/plan clients and broadcasts Plans to them."""

    def __init__(self) -> None:
        self.active: set[WebSocket] = set()

    async def connect(self, ws: WebSocket) -> None:
        await ws.accept()
        self.active.add(ws)

    def disconnect(self, ws: WebSocket) -> None:
        self.active.discard(ws)

    async def broadcast(self, plan: Plan) -> None:
        payload = plan.model_dump(mode="json", exclude_none=True)
        dead: list[WebSocket] = []
        for ws in self.active:
            try:
                await ws.send_json(payload)
            except Exception:  # noqa: BLE001 - drop broken sockets
                dead.append(ws)
        for ws in dead:
            self.disconnect(ws)


def plan_signature(plan: Plan) -> str:
    """Stable string identifying a plan's route, to detect real changes.

    Excludes planId/generatedAt (which change every call) so we only push when
    the target or route actually differs.
    """
    t = plan.target
    target = (
        f"{t.kind}:{t.roomId}:{t.objectId}:{t.x}:{t.y}" if t else "none"
    )
    path = ">".join(w.roomId for w in plan.waypoints)
    return f"{plan.hazard}|{target}|{path}|cover={plan.takeCover}"
