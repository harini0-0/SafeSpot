"""Damage agent (LangChain Deep Agents): turn hazard alerts into room states.

Used for AMBIGUOUS feed inputs (NWS/USGS alert text) — one-tap reports and phone
impacts already carry an explicit state and go straight through /report with no
model. This agent is "judgment only": code computes the candidate rooms (which
rooms have windows / exterior walls — the predicted-risk math), the agent only
decides which candidates to flag and how severely. Every room id it emits is
validated against the real house graph (CLAUDE.md rule 3); anything unknown is
dropped. On any agent failure we fall back to the deterministic predicted-risk
assignment, so a flaky/small model never breaks the flow.

Deep Agents is used with real house-graph tools so the model must ground its
output in actual rooms rather than invent them.
"""

from __future__ import annotations

from typing import Literal, Optional

from langchain_core.tools import tool
from pydantic import BaseModel

from agents.model import get_agent_model
from house_graph import HouseGraph
from schemas import DamageEvent, DamageSource, Hazard, RoomState


class _AssessedRoom(BaseModel):
    roomId: str
    state: Literal["safe", "at_risk", "blocked"]
    confidence: float
    reason: str


class DamageAssessment(BaseModel):
    """Structured response the agent must return."""

    events: list[_AssessedRoom]


_SYSTEM = (
    "You assess which rooms of a house are at risk from a hazard alert.\n"
    "Rules:\n"
    "- Call list_rooms to see the real rooms and predicted_risk_rooms to see the "
    "rooms the building code has already flagged as physically exposed.\n"
    "- Only return roomIds that exist (from the tools). Never invent rooms.\n"
    "- state: blocked = impassable/structural failure; at_risk = exposed/likely "
    "damage but passable now; safe = no concern.\n"
    "- For a tornado/severe-wind warning, mark the predicted_risk_rooms at_risk.\n"
    "- Keep it minimal: only return rooms whose state actually changes.\n"
    "Return a DamageAssessment."
)


def predicted_risk_rooms(graph: HouseGraph, hazard: Hazard) -> list[str]:
    """Deterministic 'math': rooms physically exposed to the hazard.

    Tornado/severe wind: rooms with windows or exterior walls. Fire/earthquake
    have no pre-event predicted room set here (handled by reports/feeds), so this
    returns an empty list for them.
    """
    if hazard == Hazard.tornado:
        exposed = graph.rooms_with_windows() | graph.rooms_on_exterior_wall()
        return sorted(r for r in exposed if graph.rooms[r].navigable)
    return []


def build_damage_agent(graph: HouseGraph, model=None):
    """Build the Deep Agent with house-graph tools bound to this graph."""

    @tool
    def list_rooms() -> list[dict]:
        """List the real navigable rooms as {roomId, type}."""
        return [
            {"roomId": rid, "type": r.type}
            for rid, r in graph.rooms.items()
            if r.navigable
        ]

    @tool
    def predicted_risk(hazard: str) -> list[str]:
        """Room ids the building code flags as physically exposed to the hazard."""
        try:
            return predicted_risk_rooms(graph, Hazard(hazard))
        except ValueError:
            return []

    @tool
    def validate_room_id(room_id: str) -> bool:
        """True if room_id is a real room in this house."""
        return room_id in graph.rooms

    return create_deep_agent_safe(
        model or get_agent_model("DAMAGE_MODEL", "qwen2.5:7b"),
        [list_rooms, predicted_risk, validate_room_id],
    )


def create_deep_agent_safe(model, tools):
    from deepagents import create_deep_agent

    return create_deep_agent(
        model,
        tools,
        system_prompt=_SYSTEM,
        response_format=DamageAssessment,
    )


def _state_in_text(line: str) -> RoomState:
    low = line.lower()
    if "blocked" in low:
        return RoomState.blocked
    if "safe" in low and "at_risk" not in low and "at risk" not in low:
        return RoomState.safe
    return RoomState.at_risk


def _parse_events_from_text(
    graph: HouseGraph, text: str, source: DamageSource
) -> list[DamageEvent]:
    """Recover the agent's judgment when it answers in prose, not the schema.

    Scans each line for a real room id and the nearest state keyword. Only real
    ids survive (rule 3). Deduped, keeping the last mention per room.
    """
    found: dict[str, DamageEvent] = {}
    for line in text.splitlines():
        rid = next((r for r in graph.rooms if r in line), None)
        if rid is None:
            continue
        found[rid] = DamageEvent(
            roomId=rid, state=_clamp_feed_state(_state_in_text(line)), source=source, confidence=0.6
        )
    return list(found.values())


def _clamp_feed_state(state: RoomState) -> RoomState:
    """A forecast/feed can predict risk but never confirm a room is impassable.
    Only human reports / phone impacts (via /report) may mark a room blocked."""
    return RoomState.at_risk if state == RoomState.blocked else state


def interpret(
    graph: HouseGraph,
    hazard: Hazard,
    alert_text: str,
    source: DamageSource,
    model=None,
) -> list[DamageEvent]:
    """Interpret a feed alert into validated DamageEvents (agent, with fallbacks).

    Order: (1) the agent's structured response; (2) parse the agent's prose for
    real room ids (small models often answer in text); (3) deterministic
    predicted-risk. Every id is validated against the real graph, and feed-sourced
    states are clamped to at_risk (a forecast cannot confirm impassability).
    """
    try:
        agent = build_damage_agent(graph, model)
        result = agent.invoke(
            {
                "messages": [
                    {
                        "role": "user",
                        "content": f"Hazard: {hazard.value}. Alert: {alert_text}",
                    }
                ]
            }
        )

        # (1) structured response, if the model conformed.
        assessment: Optional[DamageAssessment] = result.get("structured_response")
        if assessment is not None:
            events = [
                DamageEvent(
                    roomId=a.roomId,
                    state=_clamp_feed_state(RoomState(a.state)),
                    source=source,
                    confidence=max(0.0, min(1.0, a.confidence)),
                )
                for a in assessment.events
                if a.roomId in graph.rooms  # rule 3
            ]
            if events:
                return events

        # (2) parse the agent's final message prose.
        messages = result.get("messages") or []
        if messages:
            text = str(getattr(messages[-1], "content", "") or "")
            events = _parse_events_from_text(graph, text, source)
            if events:
                return events
    except Exception:  # noqa: BLE001 - never let a flaky model break the flow
        pass

    # (3) deterministic fallback: mark predicted-risk rooms at_risk.
    return [
        DamageEvent(
            roomId=rid, state=RoomState.at_risk, source=DamageSource.predicted, confidence=0.5
        )
        for rid in predicted_risk_rooms(graph, hazard)
    ]
