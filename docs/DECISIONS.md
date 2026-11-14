# Safe Spot: background and decisions

> Context from the planning chat. Read together with `CLAUDE.md`. `CLAUDE.md` wins if anything conflicts. Do not change either file; only Harini edits them.

## Event

- HackPrinceton Fall 2026, Princeton, Nov 13–15, 2026.
- Targets: CoStar track (real Houston and Los Angeles data: CoStar building data, Matterport 3D scans, Vexcel aerial imagery), Amazon (agentic AI with real-world impact, AWS Bedrock), LangChain (Deep Agents, used properly).
- Devpost submission due Sunday 8:00 AM (team target 7:30 AM): public GitHub repo, tracks, optional 2-minute video, Discord usernames.

## The problem

When a disaster hits, people inside a building don't know where the safest spot is or how to get there, and the safest route changes as the building gets damaged.

Evidence gathered during research:
- 2024 Houston derecho: over 2,500 downtown high-rise windows damaged; towers designed for hurricane-strength winds still failed at cladding and windows.
- Hurricane Beryl (2024): 2.2 million customers lost power in extreme heat; most deaths were older adults stuck in homes and apartments.
- 2025 Los Angeles fires: CoStar estimated about 11,200 properties destroyed and about $30 billion in real estate losses.
- 2023 Turkey earthquake: trapped people shared addresses on social media, but an address doesn't tell rescuers the floor or room.

## Decisions, in order

1. Started as SMS texts telling each person their safe room.
2. **Replaced texts with live first-person 3D guidance** through the scanned home, because texts are hard to follow mid-disaster.
3. **Native iOS app** (not a web app), so we can use ARKit camera tracking and all phone sensors.
4. **MVP: one real Houston house** from CoStar data. Multiple houses come later.
5. **The CoStar house data is complete and accurate. Never modify it.** We only add navigation.
6. Positioning uses camera + motion sensors + GPS + tap fallback, snapped to the floor plan. **No phone-to-phone tracking.**
7. Live damage comes from predicted risk (scan geometry + wind), NWS and USGS feeds, phone impact, and one-tap reports. **Aerial imagery is before-event only; it can't be live.**
8. A damaged corner blocks the whole room.
9. Safe-spot order: safe room → safe object (table sized for the person, tub, interior corner) → exit. Earthquake: take cover first, exit after shaking stops.
10. **Code does the math, the agent does the judgment.** All agent output is validated against real room and object IDs.
11. Voice: spoken instructions plus "Where do I go next?" questions.
12. Lavanya is on Android, so she owns the Python backend and never needs an iPhone. **No Android app in the MVP.**

## Out of scope for the MVP (pitch as "what's next")

Multiple buildings, Android app, accessibility routes, phone-to-phone tracking, home-device sensors, building-manager dashboard, responder view, partnerships with cities, hotels, hospitals and universities.

## Team

- **Harini (lead):** data, repo, Devpost, `house`, `guide`, app-to-backend wiring.
- **Sanjana (iPhone + Mac):** `locate`.
- **Lavanya (Android, Python):** `backend`.
