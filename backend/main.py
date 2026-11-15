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

import json
import os
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, HTMLResponse
from pydantic import BaseModel

from earthquake import EarthquakeMonitor
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
MONITOR = EarthquakeMonitor()
LAST_VALID_PLAN: Optional[Plan] = None


def _load_panoramas() -> list[dict]:
    """Scan-point metadata (id, position, room) from the read-only data file."""
    data = json.loads((Path(__file__).parent.parent / "data" / f"{GRAPH.model_id}.json").read_text())
    out = []
    for p in data.get("sections", {}).get("panoramas", {}).get("panoLocations", []):
        room = (p.get("anchor") or {}).get("room") or {}
        rid = room.get("id")
        pos = p.get("position") or {}
        out.append({
            "id": p["id"],
            "x": pos.get("x"), "y": pos.get("y"), "z": pos.get("z"),
            "roomId": rid,
            "roomType": GRAPH.rooms[rid].type if rid in GRAPH.rooms else None,
            "label": p.get("label"),
            "neighbors": (p.get("anchor") or {}).get("neighbors") or [],
            "rotation": p.get("rotation"),
        })
    return out


PANORAMAS = _load_panoramas()
PANO_IDS = {p["id"] for p in PANORAMAS}
PANO_DIR = Path(__file__).parent.parent / "ios" / "SafeSpot" / "SafeSpot" / "Resources" / "panoramas"


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


@app.get("/house")
def house():
    """Read-only house geometry for the (tinker) web client: room polygons."""
    return {
        "modelId": GRAPH.model_id,
        "rooms": [
            {
                "roomId": rid,
                "type": r.type,
                "navigable": r.navigable,
                "polygon": [{"x": p.x, "y": p.y} for p in r.polygon],
            }
            for rid, r in GRAPH.rooms.items()
        ],
    }


_NO_CACHE = {"Cache-Control": "no-store"}


@app.get("/app", response_class=HTMLResponse)
def web_app():
    """Serve the self-contained 2D LAN web client (tinker only)."""
    page = Path(__file__).parent / "web" / "index.html"
    return HTMLResponse(page.read_text(encoding="utf-8"), headers=_NO_CACHE)


@app.get("/app3d", response_class=HTMLResponse)
def web_app_3d():
    """Serve the 3D walkthrough client (tinker only)."""
    page = Path(__file__).parent / "web" / "walk.html"
    return HTMLResponse(page.read_text(encoding="utf-8"), headers=_NO_CACHE)


@app.get("/tour", response_class=HTMLResponse)
def web_tour():
    """Serve the photoreal 360 panorama tour client (tinker only)."""
    page = Path(__file__).parent / "web" / "tour.html"
    return HTMLResponse(page.read_text(encoding="utf-8"), headers=_NO_CACHE)


@app.get("/panoramas")
def panoramas():
    """Scan-point metadata for the tour (id, position, room)."""
    return {"panoramas": PANORAMAS}


def _pano_by_id() -> dict:
    return {p["id"]: p for p in PANORAMAS}


def _pano_route(start_id: str, target_id: str) -> list[str]:
    """BFS over scan-point neighbours from start pano to target pano."""
    by_id = _pano_by_id()
    if start_id == target_id:
        return [start_id]
    prev: dict[str, str] = {}
    seen = {start_id}
    queue = [start_id]
    while queue:
        cur = queue.pop(0)
        if cur == target_id:
            break
        for nb in by_id.get(cur, {}).get("neighbors", []):
            if nb in by_id and nb not in seen:
                seen.add(nb)
                prev[nb] = cur
                queue.append(nb)
    if target_id not in seen:
        return [start_id]
    path = [target_id]
    c = target_id
    while c != start_id:
        c = prev[c]
        path.append(c)
    return list(reversed(path))


class WalkRequest(BaseModel):
    hazard: Hazard
    startPanoId: str


@app.post("/walkthrough")
def walkthrough(req: WalkRequest):
    """Guided step-by-step route (as scan points) + spoken instructions."""
    by_id = _pano_by_id()
    start = by_id.get(req.startPanoId)
    if not start:
        raise HTTPException(status_code=404, detail="unknown startPanoId")
    start_room = start["roomId"]

    # Earthquake: take cover in place, no walking.
    if req.hazard == Hazard.earthquake:
        return {
            "hazard": req.hazard.value,
            "takeCover": True,
            "reason": "Take cover now; move only after the shaking stops.",
            "steps": [{
                "panoId": start["id"], "roomType": start["roomType"],
                "x": start["x"], "y": start["y"],
                "instruction": f"Earthquake. You're in the {start['roomType']}. "
                               "Take cover right here, away from windows. Do not run.",
                "isDestination": True,
            }],
        }

    plan = make_plan(GRAPH, current_room=start_room, hazard=req.hazard,
                     room_states=STORE.snapshot(), shaking=False)
    target_room = plan.target.roomId if (plan.target and plan.target.roomId) else start_room
    if target_room == start_room:
        route_ids = [start["id"]]
    else:
        target = next((p for p in PANORAMAS if p["roomId"] == target_room), start)
        route_ids = _pano_route(start["id"], target["id"])

    single = len(route_ids) == 1
    steps = []
    prev_room = None
    for i, pid in enumerate(route_ids):
        p = by_id[pid]
        rt = p["roomType"] or "room"
        last = i == len(route_ids) - 1
        if single:
            instr = (f"You're in the {rt}. The exit is right here - leave now."
                     if req.hazard == Hazard.fire
                     else f"You're already in the safe spot, the {rt}. Get down and cover up, away from windows.")
        elif last:
            instr = (f"You've reached the {rt}. Leave through the exit here."
                     if req.hazard == Hazard.fire
                     else f"You've reached the {rt}, the safe spot. Get down and cover up, away from windows.")
        elif i == 0:
            nxt = by_id[route_ids[1]]["roomType"] or "the next room"
            instr = f"You're in the {rt}. Head toward the {nxt}."
        elif rt != prev_room:
            instr = f"Go into the {rt}, then keep going."
        else:
            instr = f"Continue through the {rt}."
        steps.append({
            "panoId": pid, "roomType": rt, "x": p["x"], "y": p["y"],
            "instruction": instr, "isDestination": last,
        })
        prev_room = rt

    return {
        "hazard": req.hazard.value,
        "takeCover": False,
        "reason": plan.reasons[0] if plan.reasons else "",
        "steps": steps,
    }


@app.get("/pano/{pano_id}")
def pano_image(pano_id: str):
    """Serve one local 360 panorama jpg (validated id; no traversal)."""
    if pano_id not in PANO_IDS:
        raise HTTPException(status_code=404)
    f = PANO_DIR / f"{pano_id}.jpg"
    if not f.is_file():
        raise HTTPException(status_code=404)
    return FileResponse(f, media_type="image/jpeg")


@app.get("/web/{path:path}")
def web_asset(path: str):
    """Serve files under backend/web/ (e.g. the vendored three.min.js). Guards
    against path traversal."""
    base = (Path(__file__).parent / "web").resolve()
    target = (base / path).resolve()
    if base != target and base not in target.parents:
        raise HTTPException(status_code=404)
    if not target.is_file():
        raise HTTPException(status_code=404)
    return FileResponse(target)


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
    # Earthquake: the shaking state is owned by the sensor state machine, not the
    # request. Arming defaults to take-cover; the /ws/sensors stream flips it.
    if req.hazard == Hazard.earthquake:
        if not MONITOR.armed:
            MONITOR.arm(now=time.monotonic())
        shaking = MONITOR.shaking
    else:
        MONITOR.disarm()
        shaking = req.shaking

    SESSION.set_context(req.position, req.hazard, shaking)
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


async def _push_if_changed() -> Optional[Plan]:
    """Re-plan from current state; push over /ws/plan only if the route changed."""
    if not SESSION.active():
        return None
    plan = _safe_plan()
    signature = plan_signature(plan)
    if signature == SESSION.last_signature:
        return None
    SESSION.last_signature = signature
    await WS.broadcast(plan)
    return plan


async def _apply_events_and_replan(events: list[DamageEvent]) -> Optional[Plan]:
    """Apply damage events to the store, re-plan, push over WS if changed."""
    for event in events:
        if event.roomId in GRAPH.rooms:
            STORE.apply_event(event)
    return await _push_if_changed()


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


@app.websocket("/ws/sensors")
async def ws_sensors(ws: WebSocket) -> None:
    """Phone -> backend motion stream for earthquakes.

    Each message: {"rms": float (G), "activity": str, "ts": str}. Feeds the
    earthquake state machine; when shaking flips (take-cover <-> exit), re-plan and
    push the new Plan over /ws/plan. The phone only samples; all logic is here.
    """
    await ws.accept()
    try:
        while True:
            raw = await ws.receive_text()
            try:
                msg = json.loads(raw)
                rms = float(msg.get("rms", 0.0))
                activity = str(msg.get("activity", "unknown"))
            except (ValueError, TypeError, json.JSONDecodeError):
                continue  # ignore malformed samples
            if not MONITOR.armed:
                continue
            changed = MONITOR.update(rms, activity, now=time.monotonic())
            if changed is not None:
                SESSION.shaking = MONITOR.shaking
                await _push_if_changed()
    except WebSocketDisconnect:
        pass
    except Exception:  # noqa: BLE001 - any socket error ends the connection
        pass


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
