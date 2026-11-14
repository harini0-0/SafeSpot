"""Safe Spot backend — FastAPI app entry point.

Run (from the backend/ directory, with the venv active):

    uvicorn main:app --reload --host 0.0.0.0 --port 8000

The house graph is loaded once at startup (read-only) and reused for every
request, per CLAUDE.md. Wire shapes follow docs/interfaces.md:
  GET  /health     liveness + house info
  POST /plan       position + hazard -> Plan
  POST /report     a DamageEvent -> {ok, replan}; pushes a re-plan if the route changed
  WS   /ws/plan    server pushes fresh Plans when a room blocks

The damage/voice agents (model-backed) plug in next via agents/model.py.
"""

from __future__ import annotations

from typing import Optional

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from pydantic import BaseModel

from house_graph import HouseGraph, house_coords, load_house_graph
from planner.rules import plan as make_plan
from schemas import DamageEvent, Hazard, Plan, Position, RoomState
from state import ConnectionManager, RoomStateStore, Session, plan_signature

app = FastAPI(title="Safe Spot backend", version="0.1.0")

# Loaded once, read-only, reused for every request.
GRAPH: HouseGraph = load_house_graph()
STORE = RoomStateStore()
SESSION = Session()
WS = ConnectionManager()


def _plan_now() -> Plan:
    """Build a Plan from the active session + current room-state store."""
    return make_plan(
        GRAPH,
        current_room=SESSION.position.roomId if SESSION.position else None,
        hazard=SESSION.hazard,
        room_states=STORE.snapshot(),
        shaking=SESSION.shaking,
    )


@app.get("/health")
def health():
    """Liveness probe. Also used to verify the iPhone can reach the backend."""
    lat, lon = house_coords()
    return {
        "status": "ok",
        "service": "safe-spot-backend",
        "model_id": GRAPH.model_id,
        "rooms": len(GRAPH.rooms),
        "house": {"lat": lat, "lon": lon},
    }


class PlanRequest(BaseModel):
    """interfaces.md §4 POST /plan. `shaking` is a backend-only optional
    extension (earthquake cover-vs-exit); the app may omit it."""

    position: Position
    hazard: Hazard
    knownDamage: list[DamageEvent] = []
    shaking: bool = True


@app.post("/plan", response_model=Plan, response_model_exclude_none=True)
def post_plan(req: PlanRequest) -> Plan:
    """Return the safe target and route for a position + hazard (a Plan)."""
    for event in req.knownDamage:
        if event.roomId in GRAPH.rooms:
            STORE.apply_event(event)
    SESSION.set_context(req.position, req.hazard, req.shaking)
    plan = _plan_now()
    SESSION.last_signature = plan_signature(plan)
    return plan


class ReportResponse(BaseModel):
    ok: bool
    replan: Optional[Plan] = None


@app.post("/report", response_model=ReportResponse, response_model_exclude_none=True)
async def post_report(event: DamageEvent) -> ReportResponse:
    """Apply a DamageEvent (tap / phone_impact / feed) and re-plan if needed.

    Rejects unknown room ids (CLAUDE.md rule 3). If an active route exists and the
    report changes it, the new Plan is both returned inline and pushed over
    /ws/plan.
    """
    if event.roomId not in GRAPH.rooms:
        raise HTTPException(status_code=422, detail=f"Unknown roomId {event.roomId!r}")

    STORE.apply_event(event)

    if not SESSION.active():
        return ReportResponse(ok=True, replan=None)

    plan = _plan_now()
    signature = plan_signature(plan)
    if signature == SESSION.last_signature:
        return ReportResponse(ok=True, replan=None)  # route unchanged

    SESSION.last_signature = signature
    await WS.broadcast(plan)
    return ReportResponse(ok=True, replan=plan)


@app.websocket("/ws/plan")
async def ws_plan(ws: WebSocket) -> None:
    """App connects here to receive pushed Plans when a room becomes blocked."""
    await WS.connect(ws)
    try:
        while True:
            # We don't expect client messages; receive to detect disconnects.
            await ws.receive_text()
    except WebSocketDisconnect:
        WS.disconnect(ws)
    except Exception:  # noqa: BLE001 - any socket error ends the connection
        WS.disconnect(ws)
