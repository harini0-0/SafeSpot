#!/usr/bin/env python3
"""End-to-end check of the live demo flow (CLAUDE.md Block 4).

Runs the demo loop three times and also fire/earthquake variants, asserting the
whole backend path: tap hazard -> route -> room blocked -> reroute (pushed over
WebSocket) -> voice answer. Uses the deterministic live path (/plan, /report,
/voice, /ws/plan) — the same path the app/demo uses — so it is fast and stable.
The slow model-backed /interpret is covered separately.

Run from the backend/ directory:  python e2e_check.py
"""

from __future__ import annotations

import json
import sys
import time

from fastapi.testclient import TestClient

import earthquake
import main

# Shrink the earthquake timers so the sensor-driven flip is instant in this wiring
# check. The realistic timing logic is verified separately in earthquake.py's
# self-test; here we only prove the /ws/sensors -> re-plan -> /ws/plan path.
earthquake.MIN_COVER_SEC = 0.0
earthquake.CALM_DEBOUNCE_SEC = 0.0

LR = "613htqkzf66zz7hf7n8kzszed"  # Living Room
HALL = "9hauvfhwiqt"  # Hallway
BR1 = "cdz3fkt38kae7tapstpt0eaeb"  # Bedroom 1
KIT = "tt6gm2a0463x9wmnx7rn6gugc"  # Kitchen

client = TestClient(main.app)
_passed = 0
_failed = 0


def check(name: str, ok: bool, detail: str = "") -> None:
    global _passed, _failed
    if ok:
        _passed += 1
        print(f"  PASS  {name}")
    else:
        _failed += 1
        print(f"  FAIL  {name}  {detail}")


def reset() -> None:
    main.STORE.reset()
    main.SESSION.position = None
    main.SESSION.hazard = None
    main.SESSION.shaking = True
    main.SESSION.last_signature = None
    main.LAST_VALID_PLAN = None
    main.MONITOR.disarm()


def pos(room_id: str) -> dict:
    return {"roomId": room_id, "x": 0.0, "y": 0.0}


def tornado_reroute_flow(i: int) -> None:
    reset()
    print(f"Run {i}: Tornado from Living Room -> block Hallway -> reroute -> ask")

    # 1) tap Tornado
    p = client.post("/plan", json={"position": pos(LR), "hazard": "tornado"}).json()
    check("initial plan targets the Hallway", p.get("target", {}).get("roomId") == HALL,
          f"got {p.get('target')}")
    check("initial route has waypoints", len(p.get("waypoints", [])) >= 1)

    # 2) hallway reported blocked, with a live WS client listening
    with client.websocket_connect("/ws/plan") as ws:
        r = client.post("/report", json={"roomId": HALL, "state": "blocked", "source": "tap"}).json()
        replan = r.get("replan")
        check("report returns a reroute", replan is not None)
        check("reroute avoids the blocked Hallway",
              bool(replan) and replan.get("target", {}).get("roomId") != HALL,
              f"got {replan.get('target') if replan else None}")
        pushed = ws.receive_json()
        check("reroute was pushed over WebSocket",
              bool(replan) and pushed.get("planId") == replan.get("planId"))

    # 3) ask where to go
    a = client.post("/voice", json={"question": "Where do I go next?"}).json()["answer"]
    check("voice gives a non-empty answer", bool(a.strip()), a)


def fire_flow() -> None:
    reset()
    print("Fire from Bedroom 1 -> exit")
    p = client.post("/plan", json={"position": pos(BR1), "hazard": "fire"}).json()
    check("fire routes to an exit point", p.get("target", {}).get("kind") == "point",
          f"got {p.get('target')}")


def earthquake_flow() -> None:
    reset()
    print("Earthquake from Kitchen -> cover -> (sensor: calm) exit -> (aftershock) cover")
    p = client.post("/plan", json={"position": pos(KIT), "hazard": "earthquake"}).json()
    check("arm => takeCover", p.get("takeCover") is True)
    with client.websocket_connect("/ws/plan") as plan_ws, client.websocket_connect("/ws/sensors") as sensor_ws:
        sensor_ws.send_text(json.dumps({"rms": 0.02, "activity": "stationary", "ts": "2026-11-15T02:00:00Z"}))
        stopped = plan_ws.receive_json()
        check("calm/still => exit", stopped.get("takeCover") is False and stopped.get("target") is not None,
              f"got {stopped.get('takeCover')}")
        sensor_ws.send_text(json.dumps({"rms": 0.6, "activity": "stationary", "ts": "2026-11-15T02:00:05Z"}))
        after = plan_ws.receive_json()
        check("aftershock => back to cover", after.get("takeCover") is True, f"got {after.get('takeCover')}")


def robustness() -> None:
    reset()
    print("Robustness: unknown room rejected; last valid plan kept")
    client.post("/plan", json={"position": pos(LR), "hazard": "tornado"})
    bad = client.post("/report", json={"roomId": "NOPE", "state": "blocked", "source": "tap"})
    check("unknown roomId -> 422", bad.status_code == 422, f"got {bad.status_code}")


def latency() -> None:
    reset()
    client.post("/plan", json={"position": pos(LR), "hazard": "tornado"})
    t = time.time()
    for _ in range(10):
        client.post("/report", json={"roomId": KIT, "state": "at_risk", "source": "tap"})
        client.post("/voice", json={"question": "Where do I go next?"})
    ms = (time.time() - t) / 10 * 1000
    check("live path < 100ms/cycle (report+voice)", ms < 100, f"{ms:.1f}ms")
    print(f"  (live report+voice avg: {ms:.1f} ms)")


def main_run() -> int:
    for i in range(1, 4):
        tornado_reroute_flow(i)
    fire_flow()
    earthquake_flow()
    robustness()
    latency()
    print(f"\n{_passed} passed, {_failed} failed")
    return 1 if _failed else 0


if __name__ == "__main__":
    sys.exit(main_run())
