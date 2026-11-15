#!/usr/bin/env python3
"""Stand-in for the backend's /ws/sensors, for testing the phone's earthquake
motion stream before the real endpoint exists.

It only receives, checks and prints messages. It makes NO earthquake decisions
(that's the backend's job). Each message must be exactly:
    {"rms": <number>, "activity": <string>, "activityConfidence": <string>, "ts": <string>}

Usage (Mac on the same Wi-Fi as the phone):
    scripts/.venv/bin/pip install websockets
    scripts/.venv/bin/python scripts/mock_sensors_server.py
Then enter this Mac's IP as the backend host in LocateTest → Earthquake.
"""
import asyncio
import json
import socket

import websockets

PORT = 8000
PATH = "/ws/sensors"
KEYS = {"rms": (int, float), "activity": str, "activityConfidence": str, "ts": str}
ACTIVITIES = {"stationary", "walking", "running", "automotive", "cycling", "unknown"}
CONFIDENCES = {"low", "medium", "high"}


def check(msg: dict) -> list[str]:
    problems = []
    if set(msg) != set(KEYS):
        problems.append(f"keys {sorted(msg)} != {sorted(KEYS)}")
    for k, t in KEYS.items():
        if k in msg and (not isinstance(msg[k], t) or isinstance(msg[k], bool)):
            problems.append(f"{k} has type {type(msg[k]).__name__}")
    if msg.get("activity") not in ACTIVITIES:
        problems.append(f"activity {msg.get('activity')!r} not in {sorted(ACTIVITIES)}")
    if msg.get("activityConfidence") not in CONFIDENCES:
        problems.append(f"activityConfidence {msg.get('activityConfidence')!r}")
    return problems


async def handler(ws):
    path = getattr(getattr(ws, "request", None), "path", None) or getattr(ws, "path", "")
    if path != PATH:
        print(f"rejected connection to {path!r} (expected {PATH})")
        await ws.close(code=1008, reason="wrong path")
        return
    peer = ws.remote_address[0] if ws.remote_address else "?"
    print(f"phone connected from {peer}")
    try:
        async for raw in ws:
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                print(f"  NOT JSON: {raw!r}")
                continue
            problems = check(msg)
            bar = "#" * min(40, int(float(msg.get("rms", 0)) * 40))
            status = "OK " if not problems else "BAD"
            print(f"  {status} {msg.get('ts')}  rms={msg.get('rms'):<6} {msg.get('activity')}/"
                  f"{msg.get('activityConfidence'):<6} {bar}")
            for p in problems:
                print(f"      problem: {p}")
    except websockets.ConnectionClosed:
        pass
    print(f"phone disconnected ({peer})")


def local_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))   # no packet is sent; picks the Wi-Fi interface
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


async def main():
    async with websockets.serve(handler, "0.0.0.0", PORT):
        print(f"Listening on ws://{local_ip()}:{PORT}{PATH}")
        print(f"In LocateTest → Earthquake, set backend host to: {local_ip()}")
        await asyncio.Future()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
