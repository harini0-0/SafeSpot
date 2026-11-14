# Safe Spot: build plan

> Put this file in the repo root as `CLAUDE.md` so Claude Code reads it at the start of every session. It is the single source of truth between this chat and Claude Code.

## STRICT: do not change this plan

- **Do not change the plan, the architecture, the module split, the safe-spot logic or the repo layout.** This is how the project is meant to be built.
- **Do not substitute, simplify or work around any part of it.** No placeholder approaches, no "simpler alternative", no swapped libraries or services.
- **If any data or detail is missing or unclear, stop and ask Harini.** She will provide it. Do not invent data, field names, coordinates, rooms or objects.
- **The CoStar house data is read-only.** Never edit, clean or reshape the source data.
- Only Harini can change this file.

## Mission

When a disaster hits, no one should be stuck wondering where to go. Safe Spot opens on your phone, you tap **Tornado**, **Earthquake** or **Fire**, and it walks you, in first person, to the safest spot in your own home. It reroutes the moment part of the house is damaged.

## MVP scope (this weekend)

**In**
- One real Houston house from CoStar data, loaded exactly as delivered.
- Native iPhone app with three buttons: Tornado, Earthquake, Fire.
- Live position in the house: camera tracking, motion-sensor tracking, GPS for the building, tap-to-correct.
- First-person 3D view at eye level with arrows on the floor and turn-by-turn instructions.
- Live damage map. A damaged room is marked blocked as a whole, and the route avoids it.
- Safe-spot logic: safe room, then safe object (table, tub, interior corner), then exit.
- Voice: spoken instructions plus "Where do I go next?" questions.

**Out (pitch as "what's next")**
- Multiple houses and buildings, accessibility routes, phone-to-phone tracking, home-device sensors, building-manager dashboard, responder view.

## Rules

1. **The CoStar house data is never modified.** We only read it and add navigation on top of it.
2. **Code does the math, the agent does the judgment.** Position, geometry, routing and distances are deterministic code. The agent never invents coordinates, rooms or objects.
3. **Every agent output is validated.** Room and object IDs must exist in the house data, and the schema must parse. If validation fails, the app falls back to the last valid plan.
4. **A damaged corner blocks the whole room.**
5. **Earthquake: no running during shaking.** Take cover nearby first, then exit when the shaking stops.

## Architecture

```
CoStar house data (rooms, walls, doors, windows, objects, materials, lat/long)
        │  loaded once, read-only
        ▼
House graph  ──────────────────────────────────────────────┐
(rooms, doorways, exits, objects, navmesh)                  │
        │                                                   │
Live inputs                                                 ▼
  • NWS alerts API (tornado)        ─┐            Safety planner (code)
  • USGS feed (earthquake)           ├─► Damage    safe room → safe object → exit
  • Phone impact (motion spike)      │   agent     │
  • One-tap reports ("blocked here") ┘   (live     ▼
                                         room       Router (A* on navmesh,
Phone position ─────────────────────►    states)    blocked rooms removed)
  camera + motion + GPS + tap                        │
                                                     ▼
                                         First-person 3D guidance + voice
```

### Modules

| Module | Does | Built with |
|---|---|---|
| `house` | Loads CoStar data into a scene and a graph of rooms, doors, exits and objects. Read-only. | Swift, RealityKit |
| `locate` | Fuses camera tracking, step counting, compass and GPS. Snaps the position to the floor plan so it can't pass through walls. | ARKit, CoreMotion, CoreLocation |
| `hazard` | Polls weather and quake alerts for the house's coordinates. | NWS API, USGS feed |
| `damage` | Keeps each room's state (safe / at risk / blocked) from alerts, phone impacts and taps. | Backend agent |
| `planner` | Picks the safe target with the fallback order and the per-hazard rules. | Deterministic code |
| `router` | Shortest path on the navmesh with blocked rooms removed. Re-plans on every change. | A* (code) |
| `guide` | First-person view, floor arrows, "go forward / turn left / take cover", voice Q&A. | RealityKit, AVSpeech, Speech |

### Positioning: what's used when

| Situation | Position comes from |
|---|---|
| All sensors work | Camera tracking + match against scan photos + motion + floor-plan snapping |
| Camera broken or covered | Step counting + gyroscope + compass + floor-plan snapping, GPS for the starting guess |
| Phone in a pocket | One tap on the current room, then motion takes over |
| Everything unreliable | Tap the room at each move; instructions switch to landmarks ("door next to the fridge") |

### Live damage: what's used

1. **Predicted risk:** windows, glass, roof span and wall orientation from the scan, combined with the warning's wind speed and direction.
2. **Alert feeds:** NWS warning area, storm direction and confirmed tornado; USGS shaking intensity.
3. **Phone impact:** a sudden jolt on a family member's phone flags their room.
4. **One-tap reports:** "blocked here" or "roof down" marks that whole room blocked.

Aerial imagery is used for the before-event roof and footprint only. It can't be live during the event.

### Safe-spot logic

| Hazard | Order |
|---|---|
| Tornado | Interior room, lowest floor, no windows, no outside walls → sturdy object nearby (table, tub, interior corner) → exit |
| Earthquake | Take cover where you are (table big enough for this person, interior wall, away from glass) → exit after shaking stops |
| Fire | Nearest exit whose path avoids the fire room and blocked rooms → second exit |

### What the agent does (and doesn't)

**Does:**
- Turns alerts and reports into structured damage events, for example `{room_id, state, source, confidence}`.
- Chooses among candidates the code already computed when signals conflict.
- Answers voice questions ("Where do I go next?") using only the current route state.

**Doesn't:** compute position, geometry or routes; invent rooms, objects or coordinates.

This keeps it small, fast and hard to make hallucinate.

## Tools and access checklist

| Item | Why | Who provides |
|---|---|---|
| CoStar data access (API keys, MCP server, SDK/OpenAPI docs) | The house: geometry, objects, materials, coordinates | Team (from the CoStar workshop) |
| CoStar / Matterport MCP added to Claude Code | So Claude Code can read the data directly | Team |
| NWS API (`api.weather.gov`) | Tornado warnings for the house's coordinates. No key; send a User-Agent header. | Public |
| USGS earthquake feed | Earthquake events and shaking intensity. No key. | Public |
| AWS Bedrock credentials | Model for the damage and voice agent (Amazon track) | Amazon sponsor |
| LangChain Deep Agents | Agent framework (LangChain prize) | `pip install deepagents` |
| Mac with Xcode + an iPhone | Required to build and run a native iOS app | Team |
| Apple ID | Needed to install the app on your own iPhone from Xcode | Team |

No extra MCPs are needed for weather or quakes; they are plain HTTP calls.

## Data contract (filled from the real CoStar / Matterport data)

Source: Matterport model export, `modelId` `zyzG7fqtBDv`, address `7950 Bellfort St, Houston, TX, 77061, US`. Three files in `data/` (read-only):
- `zyzG7fqtBDv.json` — full model (sections: `details`, `address`, `geolocation`, `floors`, `rooms`, `panoramas`, `assets`).
- `zyzG7fqtBDv_geo.json` — geocoordinates only (`data.model.geocoordinates`).
- `zyzG7fqtBDv_rooms.json` — rooms summary (`data.model.floors[].rooms[]` with `classifications`, `dimensionEstimates`).

Paths below are within `zyzG7fqtBDv.json` unless noted. All lengths are **metric (meters)**.

- [x] **Coordinate system:**
  - Units: top-level `units` = `"metric"`; per-item `dimensionEstimates.units`.
  - Model space: right-handed, meters. Floor geometry is 2D `x,y` in `sections.rooms.rooms[].boundary.edges[].vertices[].position`; 3D points (panoramas) are `x,y,z` in `sections.panoramas.panoLocations[].position`.
  - Origin: the model's internal `(0,0,0)`. **No explicit origin field.** Model→geographic mapping is `sections.geolocation.geocoordinates.rotation` (quaternion) + `.translation` (`x,y,z`).
  - Lat/long/alt of origin: `sections.geolocation.geocoordinates.{latitude, longitude, altitude, source}` (29.67302, -95.26936, 12.018 m, source `"processing"`); string copies in `sections.geolocation.geolocation.{lat, long, altitude}`; also `zyzG7fqtBDv_geo.json` → `data.model.geocoordinates`.
  - North direction: **no explicit field.** Derived from `geocoordinates.rotation` quaternion (w 0.97303, z 0.23069 → ≈26.68° about z).
- [x] **Rooms:** `sections.rooms.rooms[]` (11 rooms, single floor).
  - ID: `id`. Name/type: `classifications[].label` (Living Room, Bedroom ×2, Kitchen, Bathroom ×2, Closet ×3, Hallway, Void) with `classifications[].confidence` and `classifications[].id`. Free-text `label` is mostly empty.
  - Floor: `floor.{id, label, sequence}`; also `sections.floors.floors[]`.
  - Outline: `boundary.edges[]` (ordered wall segments, see Walls); `holes` (present, empty in this house).
  - Also: `dimensionEstimates.{area, areaIndoor, areaIndoorWithWalls, depth, width, height, units}`; `ceiling.{minHeight, maxHeight}` (empty `{}` for the two zero-height rooms); `keywords`, `tags`.
- [x] **Walls:** `sections.rooms.rooms[].boundary.edges[]`.
  - Start/end: `vertices[0].position.{x,y}` and `vertices[1].position.{x,y}`.
  - `type`: `"wall"` or `"invisible"` (open boundary between rooms); `thickness`; `centerLineBias`; `id`.
  - Height: **NOT FOUND per wall.** Use room `dimensionEstimates.height` / `ceiling.{minHeight,maxHeight}`.
  - Material: **NOT FOUND.**
  - Exterior vs interior: **no explicit flag.** Derivable — an edge `id` shared by two rooms is interior; an edge belonging to only one room is exterior (25 of 39 edges are shared here).
- [x] **Doors:** `boundary.edges[].openings[]` where `type` == `"doorway"` (17 total; labels `door-unknown`, `door-pivot`).
  - Position: `relativeCenter` (0–1 along the parent edge) + `lowerElevation`; parent edge `vertices` give world placement.
  - Width: `width`. Height: `height`. Also `id`, `label`, `metadata` (empty).
  - The two rooms connected: **no explicit field.** Derivable — the doorway's parent edge `id` appears in the two rooms it joins.
  - Exterior exits: **no explicit flag.** Derivable — a doorway on an edge that belongs to only one room is an exterior exit.
- [x] **Windows:** `boundary.edges[].openings[]` where `type` == `"window"` (4 total; label `window-unknown`).
  - Position: `relativeCenter` + `lowerElevation` on parent edge. Size: `width`, `height`. Also `id`, `metadata` (empty).
  - Glass type: **NOT FOUND.**
- [ ] **Objects:** **NOT FOUND.** No furniture/objects anywhere in the data (no table, tub, bed, etc.). This blocks the "safe object" step of the safe-spot logic — see open questions. Not in CoStar/Matterport data (0 annotations). Derived from panorama photos via Phase O: data/derived/objects.json.

- [x] **Textures and photos:** under `sections.assets.assets`.
  - Textures: `textures[]` — `format` `"jpg"`, `resolution`, `quality`, `urlTemplate`, nested `textures[]`, `id` (e.g. `50k-high`). Applied to the OBJ meshes below.
  - Meshes (geometry textures attach to): `meshes[]` — `format` `"obj"`, `resolution` (`500k`, `50k`), `url`/`downloadUrl`, `filename`, `status`.
  - Panorama scan photos (for `locate`): `sections.panoramas.panoLocations[]` (19) — `id`, `label`, `position.{x,y,z}`, `rotation` (quaternion), `anchor.{room.id, floor.id, neighbors[]}`, `skyboxes[].{resolution, format, urlTemplate, status}`.
  - Floorplans: `floorplans[]` (8) — raster (`format` jpg/png, `width`, `height`, `resolution` px/m, `origin.{x,y}` image→model meters, `floor.id`, `url`) and vector `format` `"dxf"`.
  - **Note:** every asset `url`/`urlTemplate` is a time-limited remote Matterport CDN link (`validUntil`); none of these binaries are in `data/`.
- [ ] **Roof:** **NOT FOUND.** No roof structure or span. Single floor (`Floor 1`). Closest proxies: per-room `ceiling.{minHeight,maxHeight}` and `dimensionEstimates.height`.

## Repo layout

```
safe-spot/
  CLAUDE.md          ← this file
  ios/               native app (Swift, ARKit, RealityKit)
  backend/           FastAPI + Deep Agents + Bedrock
    agents/          damage agent, voice agent
    feeds/           nws.py, usgs.py
    planner/         safety rules, router
  data/              CoStar export for the demo house (read-only)
  docs/              pitch, demo script, architecture film
```

## Team and ownership

| Person | Owns |
|---|---|
| **Harini (lead)** | CoStar data, repo, Devpost, iOS project setup, `house` module (3D house from the CoStar data), `guide` module (first-person view, floor arrows, turn instructions, voice), and wiring the app to the backend |
| **Sanjana** | `locate` module: camera tracking, scan-photo matching, motion sensors, compass, GPS, floor-plan snapping, tap fallback |
| **Lavanya** | `backend`: `hazard` feeds, `damage` agent, `planner`, `router`, voice Q&A agent, API |

## Fixed event times

| Time | What |
|---|---|
| Sat 11 AM–12 PM | Career Fair (CoStar engineers: ask about data questions here) |
| Sat 1–2 PM | Salesforce technical storytelling (pitch help) |
| Sat 3–4 PM | Amazon talk on agent evals |
| Sat ~7 PM | **Feature freeze** |
| Sun 7:30 AM | **Submit on Devpost** (hard deadline 8:00 AM) |
| Sun 9:30 AM | Round 1 judging |

## Detailed timeline

### Block 0: setup (first 2 hours)

**Everyone**
- [ ] Register for the hackathon on Devpost (needed to join the project).
- [ ] Accept the GitHub invite and the Devpost team invite.
- [ ] Clone the repo. Install Xcode (Harini, Sanjana) or Python 3.11 (Lavanya, who is on Android and works only in `backend/`).
- [ ] Join the team's chat thread for keys and links. Never paste keys into the repo.

**Harini**
- [ ] Create the public GitHub repo with the layout above; add `CLAUDE.md` (this file), `.gitignore` (Xcode: `xcuserdata/`, `DerivedData/`, `*.xcuserstate`; Python: `.venv/`, `__pycache__/`; `.env`).
- [ ] Add Sanjana and Lavanya as collaborators.
- [ ] Create the Devpost project, invite both teammates, paste the repo link.
- [ ] Create the Xcode project in `ios/` (SwiftUI app, RealityKit, ARKit).
- [ ] Add Info.plist permission strings: `NSCameraUsageDescription`, `NSLocationWhenInUseUsageDescription`, `NSMotionUsageDescription`, `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`.
- [ ] Add `arkit` to `UIRequiredDeviceCapabilities`.
- [ ] Set signing to your Apple ID team, run on your iPhone, push.
- [ ] Share the CoStar API keys and MCP details privately with the team.

**Sanjana**
- [ ] Pull the Xcode project, sign with your own Apple ID, run it on your iPhone.
- [ ] Turn on Developer Mode on the iPhone (Settings → Privacy & Security → Developer Mode) and trust the developer certificate.
- [ ] Confirm the camera, location and motion permission prompts appear.

**Lavanya**
- [ ] Create `backend/` with FastAPI, a `requirements.txt` (`fastapi`, `uvicorn`, `deepagents`, `langchain-aws`, `boto3`, `httpx`, `pydantic`) and `.env.example`.
- [ ] Test Bedrock access with one model call.
- [ ] Test one NWS call (`api.weather.gov/alerts/active?point=lat,long`) with a User-Agent header, and one USGS feed call.
- [ ] Decide with Harini where the backend runs so the iPhone can reach it on venue Wi-Fi (see open questions).

### Block 1: data in (next 2 hours)

**Harini**
- [ ] Pull the demo house from CoStar; store it under `data/` or load it at runtime (depends on whether the data may be public).
- [ ] Fill in the data contract above with the real field names.
- [ ] Write `docs/interfaces.md` with Lavanya: room IDs, door IDs, object IDs, the route format and the damage-event format. Everyone codes against this.

**Sanjana**
- [ ] Log step counts and heading from CoreMotion on a walk; check step length and drift.
- [ ] Start an ARKit world-tracking session; log the camera position as you walk.

**Lavanya**
- [ ] `feeds/nws.py` and `feeds/usgs.py` return structured alerts for the house's coordinates.
- [ ] Load the house graph (rooms, doors, exits, objects) from the shared data.

### Block 2: core (until about 1 PM Saturday)

**Harini**
- [ ] `house`: render rooms, walls, doors, windows and objects in RealityKit from the real data, in real-world coordinates.
- [ ] Export the house graph for `locate` and `backend`.

**Sanjana**
- [ ] Floor-plan snapping: position can't cross walls; doorways confirm room changes.
- [ ] Tap-to-set room; GPS confirms the building.

**Lavanya**
- [ ] `planner`: tornado, earthquake and fire rules with the fallback order.
- [ ] `router`: A* on the navmesh with blocked rooms removed.
- [ ] `POST /plan` returns the target and route for a position and hazard.

### Block 3: integration (until about 5 PM Saturday)

**Harini**
- [ ] `guide`: first-person camera at eye level, floor arrows along the route, "go forward / turn left / take cover" from route geometry.
- [ ] Re-render the route the moment the backend sends a new one.

**Sanjana**
- [ ] Match the camera view against the scan photos to place the user in the room.
- [ ] Automatic fallback order: camera → motion + snapping → tap.

**Lavanya**
- [ ] `damage` agent (Deep Agents + Bedrock): alerts, phone impacts and taps become room states; validation rejects unknown IDs.
- [ ] One-tap report endpoint; phone impact endpoint.
- [ ] Push re-plans to the app when a room becomes blocked.
- [ ] Voice Q&A endpoint answering only from the current route state.

### Block 4: full flow (until 7 PM feature freeze)

- [ ] **Everyone:** run the full flow end to end at least three times: tap hazard → route → walk → room blocked → reroute → safe spot.
- [ ] **Harini:** spoken instructions (AVSpeech) and voice questions (Speech framework).
- [ ] **Sanjana:** tune drift and snapping in the demo space.
- [ ] **Lavanya:** fix latency; make sure a failed agent call keeps the last valid plan.

### Block 5: Saturday night

- [ ] **Harini:** Devpost write-up, pitch script, select tracks and prizes.
- [ ] **Sanjana:** record the 2-minute demo video, including a fallback recording in case the live demo fails.
- [ ] **Lavanya:** README with setup steps, architecture and the agent design (Amazon requires docs).
- [ ] **Everyone:** rehearse the pitch twice.

### Block 6: Sunday morning

- [ ] 5–7 AM: upload the video, final push, add Discord usernames on Devpost.
- [ ] By 7:30 AM: submit.
- [ ] 8–9 AM: breakfast, watch Discord for your table number.
- [ ] 9:30 AM: judging. Phones charged, app installed on the demo iPhone, backend running.

## Demo script (2 minutes)

1. Open the app inside the scanned house. It knows which room you're in.
2. Tap **Tornado**. A first-person route appears: "Go forward, turn left, bathroom."
3. Mid-route, the hallway is reported collapsed. The route switches instantly: "Turn around, Bedroom 1, get under the table."
4. Ask out loud, "Where do I go next?" and get a spoken answer.
5. Close: "No one should have to wonder where to go."

## Open questions

- [ ] Exact CoStar data format and field names (see data contract)
- [ ] Which Houston house is the demo house?
- [ ] macOS, Xcode and iOS versions on Harini’s and Sanjana’s machines
- [ ] Does anyone on the team already know Swift?
- [ ] May CoStar data be committed to a public repo, or must it load at runtime with the keys?
- [ ] Are Bedrock credentials in hand, and which region and models are enabled?
- [ ] Where does the backend run so the iPhone can reach it on venue Wi-Fi?
- [ ] Where will the live demo be walked (which space stands in for the house)?
- [ ] Which main track and special tracks are we entering on Devpost?
