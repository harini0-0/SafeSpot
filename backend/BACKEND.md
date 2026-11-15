# Safe Spot — Backend

The Python backend for **Safe Spot**: when a disaster hits, the app walks you, in
first person, to the safest spot in your own home and reroutes the instant part of
the house is damaged. This service is the brain behind that — it turns live hazard
signals into a safe target and a route, and pushes a new route the moment a room
becomes unsafe.

Owner: **Lavanya**. Scope: everything under `backend/` — hazard feeds, the house
graph, the safety planner, the router, the agents, and the API. The iOS app
(`house`/`guide`, Harini) and on-device positioning (`locate`, Sanjana) are
separate; they talk to this service over the wire contract in
[`docs/interfaces.md`](../docs/interfaces.md).

---

## What it does

```
CoStar / Matterport house data (read-only)          Live inputs
  rooms, walls, doors, windows, coords                • NWS alerts (tornado)
        │ loaded once                                 • USGS feed (earthquake)
        ▼                                             • phone impact / one-tap reports
  House graph (rooms, doorways, exits, adjacency)     • phone motion stream (earthquake)
        │                                                     │
        ▼                                                     ▼
  Safety planner (deterministic code)  ◄─── room states ─── Damage agent (Deep Agents)
  safe room → safe object → exit                              turns alerts/reports into
        │                                                     validated room states
        ▼
  Router (A* on the room graph, blocked rooms removed)
        │
        ▼
  Plan (target + waypoints)  ──►  pushed to the app, spoken by voice
```

**Design principle (from `CLAUDE.md`): code does the math, the agent does the
judgment.** All position, geometry, routing and distance work is deterministic
Python. The LLM only (a) turns messy alert text into structured room states and
(b) phrases answers — and **every id it emits is validated against the real house
data**; on failure the app keeps the last valid plan. This keeps the model small,
fast, and hard to make hallucinate.

---

## Quick start

Requires **Python 3.11+** (developed on 3.13). From `backend/`:

```bash
python -m venv .venv
.venv/Scripts/python -m pip install -r requirements.txt   # Windows
# source .venv/bin/activate && pip install -r requirements.txt   # macOS/Linux

cp .env.example .env            # fill in keys as needed (see Configuration)

# verify external access (NWS + USGS are public; Bedrock only if configured)
python check_access.py

# run the server (bind 0.0.0.0 so the iPhone can reach it on the LAN)
uvicorn main:app --host 0.0.0.0 --port 8000
```

Then `GET http://<this-machine-ip>:8000/health` from the phone to confirm reachability.

### Local model (free, offline) for the agents

The agents run on a local model via [Ollama](https://ollama.com) by default:

```bash
ollama pull qwen2.5:7b    # damage agent (quality)
ollama pull qwen2.5:3b    # voice agent (speed)
pip install langchain-ollama
```

The model provider is swappable with one env var — see **Configuration**.

---

## Architecture / modules

| File | Responsibility |
|---|---|
| `main.py` | FastAPI app; loads the house graph once; all endpoints; wires the earthquake monitor + re-plan push |
| `house_graph.py` | Loads the read-only house data into rooms/walls/doors/windows; derives room adjacency (shared edge ids + invisible walls) and exterior exits |
| `feeds/nws.py` | NWS active-alerts feed → structured `NwsAlert`s (tornado warnings) |
| `feeds/usgs.py` | USGS earthquake feed → structured `UsgsQuake`s (events + shaking intensity) |
| `planner/rules.py` | Per-hazard safe-spot rules + the fallback order (room → object → exit) |
| `planner/router.py` | A* shortest path over the room graph, blocked rooms removed |
| `schemas.py` | Wire models matching `docs/interfaces.md` (Position, DamageEvent, Target, Waypoint, Plan) |
| `state.py` | In-memory room-state store, active session, WebSocket connection manager |
| `earthquake.py` | `EarthquakeMonitor` — the shaking↔stopped state machine (take cover vs exit) |
| `agents/model.py` | Provider-agnostic model factory (`get_chat_model` / `get_agent_model`) |
| `agents/damage.py` | **LangChain Deep Agents** damage agent — alerts → validated room states |
| `agents/voice.py` | Voice Q&A — deterministic answer from route state (Deep Agent opt-in) |
| `check_access.py` | Block-0 access check: NWS, USGS, Bedrock |
| `e2e_check.py` | End-to-end check of the whole demo flow (24 assertions) |

---

## Safe-spot logic (per hazard)

Fallback order is always **safe room → safe object → exit**. The router builds the
waypoint path; the plan is re-computed and pushed on every change.

- **🌪️ Tornado — go *in and down*, away from glass.** Target the nearest
  reachable **interior, windowless, lowest-floor** room; if none qualify strictly,
  relax to the room with the fewest exterior walls/windows. Then a sturdy object
  inside it (table/tub/interior corner — see Phase O). Exit only as a last resort.
- **🌍 Earthquake — *don't run*; cover, then exit.** While shaking: **take cover
  in place** (never route during shaking — `CLAUDE.md` rule 5). When shaking stops:
  route to the nearest exit. The shaking/stopped decision is the earthquake state
  machine (below).
- **🔥 Fire — get *out* now, around the fire.** Nearest exterior **exit** whose
  route avoids the fire/blocked rooms; second exit as backup; reroute if the path
  is cut.

A damaged corner blocks the **whole** room (`CLAUDE.md` rule 4); blocked rooms are
removed from the graph before routing.

---

## The agent design (Deep Agents)

Two agents, built on **LangChain Deep Agents**, both kept deliberately small.

### Damage agent — `agents/damage.py`
Turns an **ambiguous feed alert** (e.g. an NWS tornado warning) into structured
`{roomId, state, source, confidence}` events. It is *judgment only*:

- **Code computes the candidates** (`predicted_risk_rooms`: which rooms have
  windows / exterior walls). The agent decides which to flag and how severely.
- Built with `create_deep_agent` + **real house-graph tools** (`list_rooms`,
  `predicted_risk`, `validate_room_id`) so it must ground its output in rooms that
  actually exist.
- **Three layers of robustness:** (1) the structured response; (2) if the model
  answers in prose, parse real room ids from it; (3) a deterministic
  predicted-risk fallback. Every id is validated (unknown → dropped), and a
  forecast is **clamped to `at_risk`** (a warning can't confirm a room is
  impassable — only a human report / phone impact can mark `blocked`).

One-tap reports and phone impacts already carry an explicit state, so they go
straight through `POST /report` **with no model**.

### Voice Q&A — `agents/voice.py`
Answers "Where do I go next?" **only from the current route state**. The live path
is **deterministic** (instant, always correct — e.g. "Head to the Hallway");
the Deep Agents version (with a `current_route_state` tool) is available behind
`VOICE_USE_AGENT=1` for when a fast, reliable model is configured.

### Model — `agents/model.py`
All model access goes through one factory, so the provider is a single env var:

```
MODEL_PROVIDER=ollama   OLLAMA_MODEL=qwen2.5:7b          (free, local, default)
MODEL_PROVIDER=gemini   GEMINI_MODEL=gemini-2.5-flash-lite
MODEL_PROVIDER=bedrock  BEDROCK_MODEL_ID=...   AWS_REGION=...
```

`get_agent_model` lets the damage and voice agents use different models
(`DAMAGE_MODEL`, `VOICE_MODEL`). Imports are lazy, so a missing provider package
never breaks the app.

---

## The earthquake trigger

Earthquakes have no nationwide *early* warning (USGS **ShakeAlert** covers only the
US West Coast — not Texas). So the trigger combines two sources:

1. **Arming** — the user taps *Earthquake*, or the **USGS** feed reports a quake
   near the house. Arming defaults immediately to **take cover** (safe direction).
2. **The shaking↔stopped flip** — the phone streams a 1 Hz motion summary to
   `WS /ws/sensors`; the backend's `EarthquakeMonitor` decides:
   - **stop → exit** only after a **minimum cover time** *and* either sustained
     calm (when the phone is `stationary`) or a conservative timeout (when the
     phone is `walking`/`automotive` and can't be read as a seismometer);
   - **aftershock** → snap back to take cover;
   - hysteresis (separate on/off thresholds) prevents flapping.

The phone only *samples* (RMS of user-acceleration in G + Apple's activity label);
**all logic is server-side**. False "earthquake" alarms are prevented structurally:
the accelerometer only acts *within* an already-armed quake, never to raise one.

---

## Data

Source: a real Houston house — Matterport model `zyzG7fqtBDv`
(`7950 Bellfort St, Houston, TX`). **Read-only.** The backend never modifies it.
Room adjacency, interior/exterior walls and exits are **derived** from the
geometry (an edge id shared by two rooms is interior; an edge in one room is
exterior; a doorway on a single-room edge is an exit).

**Objects (furniture)** are not in the Matterport data; they are produced
separately into `data/derived/objects.json` ("Phase O"). Until that exists, the
planner's safe-*object* step is gated and the fallback flows room → exit.

---

## API

Base: `http://<host>:8000`. Full shapes in [`docs/interfaces.md`](../docs/interfaces.md).

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/health` | Liveness + house info (model id, room count, lat/long) |
| `POST` | `/plan` | `{position, hazard, knownDamage?}` → a `Plan` (target + waypoints) |
| `POST` | `/report` | A `DamageEvent` → `{ok, replan?}`; rejects unknown room ids (422); reroutes if the route changed |
| `POST` | `/interpret` | `{hazard, alert, source?}` → damage agent → `{events, replan?}` (backend-internal; feeds are server-side) |
| `POST` | `/voice` | `{question}` → `{answer}` from the current route state |
| `WS` | `/ws/plan` | Server pushes a fresh `Plan` whenever the route changes |
| `WS` | `/ws/sensors` | Phone → backend motion stream `{rms, activity, ts}` @1 Hz (earthquake) |

---

## Configuration (`.env`)

| Var | For |
|---|---|
| `MATTERPORT_API_KEY`, `MATTERPORT_API_TOKEN` | pulling house data (`scripts/fetch_model.py`) |
| `MODEL_PROVIDER` | `ollama` (default) / `gemini` / `bedrock` |
| `OLLAMA_MODEL`, `DAMAGE_MODEL`, `VOICE_MODEL` | per-agent local models |
| `GEMINI_MODEL` / `AWS_*`, `BEDROCK_MODEL_ID` | cloud model options |
| `VOICE_USE_AGENT` | `1` to use the Deep Agents voice path instead of deterministic |
| `PREWARM_MODELS` | `1` to load the damage model at startup (avoids a cold first call in a demo) |

Secrets live in `.env` (git-ignored). Never commit keys.

---

## Testing

```bash
python house_graph.py     # loads the house; self-checks counts against the data contract
python earthquake.py      # earthquake state-machine self-test (shake/calm/aftershock/min-cover)
python e2e_check.py       # full demo flow x3 + fire + earthquake(sensors) + robustness + latency
```

`e2e_check.py` exercises the headline moment end to end: **tap hazard → route →
room reported blocked → instant reroute (pushed over the WebSocket) → ask "where
next?" → spoken answer**, and asserts the earthquake sensor flow
(arm → cover → calm → exit → aftershock → cover). Live report+voice path is a few
milliseconds per cycle.

---

## Known limitations / what's next

- **Objects**: safe-object selection waits on Phase O (`data/derived/objects.json`).
- **Local model latency**: a 7B model on CPU is slow in the agent loop (the damage
  agent runs off the live path, so this doesn't affect the live reroute/voice);
  swap to a cloud provider via `MODEL_PROVIDER` for speed.
- **Earthquake coverage**: no pre-shaking early warning outside the US West Coast
  (ShakeAlert); on-device detection that survives network loss is a future upgrade.
