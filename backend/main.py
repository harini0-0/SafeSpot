"""Safe Spot backend — FastAPI app entry point.

Run (from the backend/ directory, with the venv active):

    uvicorn main:app --reload --host 0.0.0.0 --port 8000

The house graph is loaded once at startup (read-only) and reused for every
request, per CLAUDE.md. Wire shapes follow docs/interfaces.md. Damage reports
(POST /report), the re-plan WebSocket (/ws/plan) and voice Q&A are added in
Block 3.
"""

from __future__ import annotations

from typing import Optional

from fastapi import FastAPI
from pydantic import BaseModel

from house_graph import HouseGraph, house_coords, load_house_graph
from planner.rules import plan
from schemas import DamageEvent, Hazard, Plan, Position, RoomState

app = FastAPI(title="Safe Spot backend", version="0.1.0")

# Loaded once, read-only, reused for every request.
GRAPH: HouseGraph = load_house_graph()


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
    room_states: dict[str, RoomState] = {
        d.roomId: d.state for d in req.knownDamage
    }
    return plan(
        GRAPH,
        current_room=req.position.roomId,
        hazard=req.hazard,
        room_states=room_states,
        shaking=req.shaking,
    )
