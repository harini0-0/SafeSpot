"""Voice Q&A (answer "Where do I go next?") from the current route state.

Per the agreed design: the LIVE voice path is deterministic (Option 3) — instant
and always correct, phrased straight from the route state (CLAUDE.md: the agent
answers "using only the current route state"). The LangChain Deep Agents version
(build_voice_agent) is kept and can be switched on with VOICE_USE_AGENT=1 (e.g.
when a fast, reliable model like a cloud provider is configured); on the local
CPU model it is too slow/unreliable for a live voice turn, so it is off by
default. The damage agent remains fully agent-driven (agents/damage.py).
"""

from __future__ import annotations

import os
from typing import Callable

from langchain_core.tools import tool

from agents.model import get_agent_model

_SYSTEM = (
    "You are a calm emergency evacuation guide speaking to a person inside a home. "
    "First call the current_route_state tool, then answer in ONE short, natural "
    "spoken sentence addressed to the person.\n"
    "- Use ONLY the information from the route state; never invent rooms, objects "
    "or directions.\n"
    "- Speak plainly, like a person. NEVER mention tools, JSON, variables, or field "
    "names such as 'next_room', 'targetRoom' or 'current_route_state'.\n"
    "- If takeCover is true, tell them to take cover where they are and not run.\n"
    "- If the answer isn't in the route state, say you don't have that information."
)


def deterministic_answer(state: dict, question: str = "") -> str:
    """Instant, reliable answer phrased from the route state."""
    if not state.get("active"):
        return "There is no active route yet. Choose a hazard to begin."
    if state.get("takeCover"):
        return "Take cover where you are now and do not run until the shaking stops."

    target = state.get("targetRoom")
    nxt = state.get("nextRoom")
    kind = state.get("targetKind")
    dest = "the exit" if kind == "point" else (f"the {target}" if target else None)

    if not dest:
        return "Stay where you are; I don't have a next step yet."
    if nxt and (kind == "point" or (target and nxt != target)):
        return f"Head to the {nxt}, toward {dest}."
    return f"Head to {dest}."


def build_voice_agent(route_provider: Callable[[], dict], model=None):
    """LangChain Deep Agents voice agent (opt-in via VOICE_USE_AGENT)."""

    @tool
    def current_route_state() -> dict:
        """The current evacuation plan: hazard, target room, next room, takeCover, reasons."""
        return route_provider()

    from deepagents import create_deep_agent

    return create_deep_agent(
        model or get_agent_model("VOICE_MODEL", "qwen2.5:3b"),
        [current_route_state],
        system_prompt=_SYSTEM,
    )


def _use_agent(flag: bool | None) -> bool:
    if flag is not None:
        return flag
    return os.getenv("VOICE_USE_AGENT", "").lower() in ("1", "true", "yes")


def answer(
    question: str,
    route_provider: Callable[[], dict],
    use_agent: bool | None = None,
    model=None,
) -> str:
    """Answer a spoken question. Deterministic by default; Deep Agent if opted in."""
    state = route_provider()
    if _use_agent(use_agent):
        try:
            agent = build_voice_agent(route_provider, model)
            result = agent.invoke({"messages": [{"role": "user", "content": question}]})
            messages = result.get("messages") or []
            if messages:
                text = str(getattr(messages[-1], "content", "") or "").strip()
                if text:
                    return text
        except Exception:  # noqa: BLE001 - fall back to the deterministic answer
            pass
    return deterministic_answer(state, question)
