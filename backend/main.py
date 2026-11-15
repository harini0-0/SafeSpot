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

import os
import threading
import uuid
from datetime import datetime, timezone
from typing import Optional

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from pydantic import BaseModel

from house_graph import HouseGraph, house_coords, load_house_graph
from planner.rules import plan as make_plan
from schemas import DamageEvent, DamageSource, Hazard, Plan, Position, RoomState
from state import ConnectionManager, RoomStateStore, Session, plan_signature

app = FastAPI(title="Safe Spot backend", version="0.1.0")

# Loaded once, read-only, reused for every request.
GRAPH: HouseGraph = load_house_graph()
STORE = RoomStateStore()
SESSION = Session()
WS = ConnectionManager()
LAST_VALID_PLAN: Optional[Plan] = None


def _plan_now() -> Plan:
    """Build a Plan from the active session + current room-state store."""
    return make_plan(
        GRAPH,
        current_room=SESSION.position.roomId if SESSION.position else None,
        hazard=SESSION.hazard,
        room_states=STORE.snapshot(),
        shaking=SESSION.shaking,
    )


def _holding_plan(hazard: Optional[Hazard]) -> Plan:
    """A safe empty plan when planning fails and there is no last-valid plan."""
    return Plan(
        planId=str(uuid.uuid4()),
        hazard=hazard or Hazard.tornado,
        target=None,
        waypoints=[],
        reasons=["Planner temporarily unavailable; holding last known guidance."],
        takeCover=False,
        generatedAt=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    )


def _safe_plan() -> Plan:
    """Compute the current plan, but never fail: on error keep the last valid plan
    (CLAUDE.md Block 4 — a failed call keeps the last valid plan)."""
    global LAST_VALID_PLAN
    try:
        plan = _plan_now()
        LAST_VALID_PLAN = plan
        return plan
    except Exception:  # noqa: BLE001 - robustness: never break the live route
        return LAST_VALID_PLAN or _holding_plan(SESSION.hazard)


def _prewarm_models() -> None:
    from agents.model import get_agent_model

    try:
        get_agent_model("DAMAGE_MODEL", "qwen2.5:7b").invoke("ok")
    except Exception:  # noqa: BLE001
        pass


@app.on_event("startup")
def _startup() -> None:
    # Optionally load the (slow) damage model into RAM before the demo so the
    # first /interpret isn't a cold start. Off by default; set PREWARM_MODELS=1.
    if os.getenv("PREWARM_MODELS", "").lower() in ("1", "true", "yes"):
        threading.Thread(target=_prewarm_models, daemon=True).start()


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
    plan = _safe_plan()
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


def _route_state() -> dict:
    """Summary of the current plan for the voice agent (names, not raw ids)."""
    if not SESSION.active():
        return {"active": False}
    plan = _safe_plan()
    target_room = None
    if plan.target and plan.target.roomId in GRAPH.rooms:
        target_room = GRAPH.rooms[plan.target.roomId].type
    next_room = None
    if len(plan.waypoints) > 1:
        next_room = GRAPH.rooms[plan.waypoints[1].roomId].type
    elif plan.waypoints:
        next_room = GRAPH.rooms[plan.waypoints[0].roomId].type
    return {
        "active": True,
        "hazard": plan.hazard.value,
        "takeCover": plan.takeCover,
        "targetRoom": target_room,
        "targetKind": plan.target.kind.value if plan.target else None,
        "nextRoom": next_room,
        "reasons": plan.reasons,
    }


async def _apply_events_and_replan(events: list[DamageEvent]) -> Optional[Plan]:
    """Apply damage events to the store, re-plan, push over WS if changed."""
    for event in events:
        if event.roomId in GRAPH.rooms:
            STORE.apply_event(event)
    if not SESSION.active():
        return None
    plan = _safe_plan()
    signature = plan_signature(plan)
    if signature == SESSION.last_signature:
        return None
    SESSION.last_signature = signature
    await WS.broadcast(plan)
    return plan


class InterpretRequest(BaseModel):
    """Backend-internal: run the damage agent on a feed alert. Not an app-facing
    contract endpoint (feeds are backend-side)."""

    hazard: Hazard
    alert: str
    source: DamageSource = DamageSource.nws


class InterpretResponse(BaseModel):
    events: list[DamageEvent]
    replan: Optional[Plan] = None


@app.post("/interpret", response_model=InterpretResponse, response_model_exclude_none=True)
async def post_interpret(req: InterpretRequest) -> InterpretResponse:
    """Damage agent: feed alert text -> validated room states -> re-plan."""
    from agents.damage import interpret

    events = interpret(GRAPH, req.hazard, req.alert, req.source)
    replan = await _apply_events_and_replan(events)
    return InterpretResponse(events=events, replan=replan)


class VoiceRequest(BaseModel):
    question: str


class VoiceResponse(BaseModel):
    answer: str


@app.post("/voice", response_model=VoiceResponse)
def post_voice(req: VoiceRequest) -> VoiceResponse:
    """Voice Q&A: answer from the current route state only."""
    from agents.voice import answer

    return VoiceResponse(answer=answer(req.question, _route_state))


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
