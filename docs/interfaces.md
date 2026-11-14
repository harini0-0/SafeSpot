# Safe Spot — shared interfaces

> The single contract the three modules code against: `guide`/app (Harini, Swift),
> `locate` (Sanjana, Swift), `backend` (Lavanya, Python). Shapes are given as JSON
> (the wire format) plus the Swift type names that live in `SafeSpotCore`.
>
> **Rules that bind every shape here** (from CLAUDE.md):
> - Every `roomId`, opening id and `objectId` MUST exist in the real data
>   (`data/zyzG7fqtBDv.json`, or `data/derived/objects.json` for objects). Unknown
>   ids are rejected; the app falls back to the last valid plan.
> - Code does the math; the agent only classifies/judges. Coordinates, geometry and
>   routes are never invented.
>
> All interface decisions below are resolved (heading frame, re-plan transport, naming).

## Coordinate & units conventions

- All positions and waypoints are in **Matterport model space, meters**, as a 2D
  floor point `{x, y}` (same axes as `boundary.edges[].vertices[].position`).
- The app converts model space → RealityKit scene space internally (Phase B C-transforms);
  **the wire format is always model space**, never scene space.
- `heading` is **degrees in model space, 0° = model +Y axis, increasing clockwise,
  range 0–360**. `locate` emits model-space heading (converting from compass with the
  offset below), so `guide` and `backend` never handle raw compass.
  **Helper:** true-north heading = model heading + 26.676° (wrap into 0–360). Conversely,
  model heading = compass heading − 26.676°. The 26.676° is derived from the geo rotation
  quaternion (see CLAUDE.md data contract). `SafeSpotCore` exposes it via
  `CoordinateTransform.northHeadingDegrees(geo)`.
- Timestamps are **ISO-8601 UTC strings** (e.g. `2026-11-14T21:13:08Z`).
- Confidence is a float **0.0–1.0**.

## 1. Position — from `locate` → app/`guide`

Where the user is right now.

```json
{
  "roomId": "cdz3fkt38kae7tapstpt0eaeb",
  "x": -7.12,
  "y": 2.03,
  "heading": 142.5,
  "confidence": 0.82,
  "source": "camera",
  "timestamp": "2026-11-14T21:13:08Z"
}
```

| field | type | notes |
|---|---|---|
| `roomId` | string \| null | a real room id; `null` when `locate` can't resolve the room yet |
| `x`, `y` | number | model-space meters |
| `heading` | number | degrees, model-space (see conventions) |
| `confidence` | number | 0–1 |
| `source` | enum | `camera` \| `motion` \| `gps` \| `tap` |
| `timestamp` | string | ISO-8601 UTC |

Swift: `SafeSpotCore.Position`.

## 2. DamageEvent — app or feeds → `backend` (`POST /report`)

One room's state change, from a one-tap report, a phone impact, or a feed/prediction.

```json
{
  "roomId": "9hauvfhwiqt",
  "state": "blocked",
  "source": "tap",
  "confidence": 1.0,
  "timestamp": "2026-11-14T21:14:00Z"
}
```

| field | type | notes |
|---|---|---|
| `roomId` | string | real room id (a damaged corner blocks the whole room — CLAUDE.md rule 4) |
| `state` | enum | `safe` \| `at_risk` \| `blocked` |
| `source` | enum | `nws` \| `usgs` \| `phone_impact` \| `tap` \| `predicted` |
| `confidence` | number | 0–1 |
| `timestamp` | string | ISO-8601 UTC |

Swift: `SafeSpotCore.DamageEvent`.

## 3. Plan — `backend` → app/`guide`

The target and the route to it. Produced by `planner` + `router`; the agent only picks
among code-computed candidates.

```json
{
  "planId": "a3f1c2e0-...",
  "hazard": "tornado",
  "target": { "kind": "room", "roomId": "a5f9age4zzxewres6iqux2emc" },
  "waypoints": [
    { "x": -3.20, "y": -1.10, "roomId": "tt6gm2a0463x9wmnx7rn6gugc" },
    { "x": -6.90, "y": -0.20, "roomId": "9hauvfhwiqt" },
    { "x": -8.40, "y": 0.30, "roomId": "a5f9age4zzxewres6iqux2emc" }
  ],
  "reasons": [
    "Interior room, no windows, no exterior walls",
    "No safe object data available (objects.json empty)",
    "Route avoids blocked room: Hallway"
  ],
  "takeCover": false,
  "generatedAt": "2026-11-14T21:14:01Z"
}
```

| field | type | notes |
|---|---|---|
| `planId` | string | uuid; changes on every re-plan |
| `hazard` | enum | `tornado` \| `earthquake` \| `fire` |
| `target` | Target | see below |
| `waypoints` | Waypoint[] | ordered start→target, model-space meters |
| `reasons` | string[] | human-readable, shown/spoken; from code, not invented coords |
| `takeCover` | bool | earthquake: `true` means cover in place now, exit after shaking (CLAUDE.md rule 5) |
| `generatedAt` | string | ISO-8601 UTC |

**Target** (exactly one `kind`):
```json
{ "kind": "room",   "roomId": "<real room id>" }
{ "kind": "object", "objectId": "<id from data/derived/objects.json>" }
{ "kind": "point",  "x": -8.4, "y": 0.3, "roomId": "<real room id>" }
```
Note: `object` targets require Phase O output; until `objects.json` exists the
planner emits only `room`/`point` targets.

**Waypoint:** `{ "x": number, "y": number, "roomId": string }` (roomId = the room that
segment lies in; used for "go through the door into <room>" instructions).

Swift: `SafeSpotCore.Plan`, `.Target`, `.Waypoint`.

## 4. Endpoints

Base URL from a gitignored config (`BackendConfig`, Phase E); `.example` committed.

### `POST /plan`
Request:
```json
{ "position": <Position>, "hazard": "tornado", "knownDamage": [ <DamageEvent>, ... ] }
```
Response: `<Plan>`. `knownDamage` is optional (the backend also keeps its own room-state map).

### `POST /report`
Request: `<DamageEvent>`.
Response:
```json
{ "ok": true, "replan": <Plan> | null }
```
If the report changes the active route, the backend may return the new `Plan` inline
**and** push it (below).

### Re-plan push  `backend` → app
When a room becomes blocked and the active route must change, the backend pushes a fresh
`<Plan>` so the app swaps arrows/instructions immediately (CLAUDE.md Block 3).

- **Transport: WebSocket at `/ws/plan`** (FastAPI WebSocket server; `URLSessionWebSocketTask`
  on iOS). Each message is a `<Plan>` JSON object.
- **Fallback:** if the socket drops, the app polls `POST /plan` (with the latest `Position`
  and `hazard`) **every 2 seconds** until the WebSocket reconnects.

## 5. Canonical IDs (from the real data — do not hand-edit)

Display names in parentheses are a **convention** for UI/tests only; the data labels both
bedrooms/baths/closets identically, so we disambiguate by area.

### Rooms (11)
| roomId | type | display name | area m² |
|---|---|---|---|
| `613htqkzf66zz7hf7n8kzszed` | Living Room | Living Room | 25.7 |
| `cdz3fkt38kae7tapstpt0eaeb` | Bedroom | Bedroom 1 (north side) | 13.1 |
| `xy2x8mpaaqknp7q2c3nnbw1ma` | Bedroom | Bedroom 2 (south side) | 11.6 |
| `tt6gm2a0463x9wmnx7rn6gugc` | Kitchen | Kitchen | 6.5 |
| `h26t7ky77ew74yb0pg8qqf5rd` | Bathroom | Bathroom (hall) | 4.8 |
| `2qdmc5i9byxi79ry1pxdkqzea` | Bathroom | Bathroom (ensuite, off Bedroom 1) | 3.9 |
| `9hauvfhwiqt` | Hallway | Hallway | 4.1 |
| `3m54yff1z7crxaywd8if9rb0d` | Closet | Closet (off Bedroom 1) — no windows, no exterior walls | 3.9 |
| `a5f9age4zzxewres6iqux2emc` | Closet | Closet (off Bedroom 2) — 1 exterior wall | 1.8 |
| `m8npxsuk79xy21dd09x9wtped` | Closet | Closet (off Hallway) | 0.5 |
| `19ab05tns5h6y4qm42esqqpea` | Void | — (non-walkable) | 0.2 |

**Always reference rooms by `id` in code and on the wire; the names above are display-only.**
Full connectivity is in `docs/house_summary.md`.

### Doorways (9) — openingId → connects
| openingId | connects |
|---|---|
| `0s3c7t6b07uzr0yizazsri18c` | **EXTERIOR EXIT** (Living Room) |
| `8m2z4z3diycq9rdkm3n1cedea` | Living Room ↔ Kitchen |
| `88sf4qk72ndeemgtz7mi48sib` | Hallway ↔ Closet (off Hallway) |
| `zpiasxdrw5uug355sgtb6r1bd` | Hallway ↔ Bedroom |
| `3inp1mcm5s9c2611z7k2ypydd` | Hallway ↔ Bedroom |
| `qyurp6811uru46e2741m77urc` | Hallway ↔ Bathroom |
| `n11hdn73c1aer39054z5zef3b` | Bedroom ↔ Bathroom |
| `hczati4p8zruyqgk9rrb9qgqd` | Bedroom ↔ Closet |
| `nh53f9p699bq3fatzq6fsic8a` | Bedroom ↔ Closet |

### Windows (4) — openingId → room (all exterior)
`i29m24u412efazaacs1rminta` (Living Room), `5bmtziqpc4ey2rhpem0a66gka` (Living Room),
`bezuarud8mhf0up7yzm2dn4gb` (Bedroom), `9ds7syes8t5hca0g4dtdm6qed` (Bedroom).

### Panoramas (19) — panoId → room
See `data/assets/MANIFEST.json` and `docs/house_summary.md` for the full list with positions.
Used by `locate` (scan-photo matching) and the optional panorama view.

### Objects
`objectId` values come from `data/derived/objects.json` (Phase O, gitignored). Types are
limited to `table, bed, bathtub, sofa, counter`. Until Phase O runs, there are **no**
object ids and the planner emits no `object` targets.
