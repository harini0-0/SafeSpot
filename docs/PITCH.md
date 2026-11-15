# Safe Spot — pitch

## 2-minute table pitch

**Hook — 0:00–0:15**
> "When a tornado or fire hits, people freeze. They don't know the safest spot in their own home — and the safe route changes the moment the house starts taking damage. Safe Spot fixes that. You tap one button, and it walks you there."

**Problem — 0:15–0:35**
> "In the 2024 Houston derecho, over 2,500 downtown windows blew out. In Hurricane Beryl, most deaths were older people stuck at home. In the 2023 Turkey earthquake, trapped people shared their address — but an address doesn't tell anyone which room you're in. An address gets help to the building. It doesn't get you to the safe spot."

**Live demo — 0:35–1:30**
> "This is a real Matterport scan of a Houston home. I'm standing inside it, in first person." *(Tour mode.)*
> "I tap **Tornado**." *(Route + arrows appear; voice: 'Move to the closet — interior, away from windows.')*
> "It routes me to the safest interior room — no windows, no outside walls."
> "Now the hallway gets reported blocked." *(Reroute happens live.)* "Watch — it instantly reroutes around it. No dead ends."
> "And I can just ask it." *(Voice: 'Where do I go next?' → spoken answer.)*
> "I arrive at the safe spot. In an earthquake it's different — it tells me to take cover first and only move once the shaking stops."

**How the AI and data work — 1:30–1:45**
> "Code does the math — position, geometry, routing are all deterministic. The AI only does judgment: turning messy weather alerts into 'which rooms are at risk,' and answering questions. Every answer is checked against the real rooms in the scan, and if the model ever fails we keep the last good plan. It can't send you through a wall."

**What's next — 1:45–2:00**
> "CoStar and Matterport have already scanned millions of buildings. No new hardware — every one of those could have this tomorrow. Hotels, hospitals, campuses, and a responder view that shows exactly which room someone's in. No one should ever have to wonder where to go."

---

## 30-second version (special-track judges)

> "Safe Spot turns a building scan into a first-person escape guide. Tap Tornado, Earthquake, or Fire and it walks you — in 3D, in your own home — to the safest spot, and reroutes the moment a room is damaged. It runs on a real CoStar/Matterport scan of a Houston house. The routing is deterministic code; a LangChain agent only does judgment — reading hazard alerts and answering questions — and every answer is validated against the real rooms, with a safe fallback. The same app works for any of the millions of buildings these companies have already scanned."

---

## Likely judge questions (honest answers)

**"How do you know where I am indoors? GPS doesn't work inside."**
> We fuse ARKit camera tracking, step-counting and compass from the phone, GPS just to confirm the building, and tap-to-correct — all snapped to the floor plan so you can't drift through a wall. It's approximate, so for this demo we also ship a deterministic scripted path. Live tracking is in and working, just not pixel-perfect yet.

**"What if the AI is wrong or hallucinates a room?"**
> It can't add rooms. Routing and geometry are plain code, not the model. The agent only classifies risk and answers questions, and every room id it returns is checked against the actual scan — unknowns are dropped. If the model fails or is slow, we fall back to deterministic logic and keep the last valid plan.

**"Is the damage real-time?"**
> Three ways in: live NWS and USGS feeds, a sudden phone motion spike, and a one-tap 'blocked here' report. Any of them marks a room blocked, and the route re-plans and pushes to the phone over a WebSocket. In the demo we trigger it with the one-tap report so you can see it clearly.

**"Where's the furniture — 'get under the table'?"**
> Honest answer: this scan has no furniture data, so the 'safe object' step isn't built yet. We route to the safest interior room and the exit. Matterport can annotate objects, and that's a drop-in next step — the logic is already specified.

**"Which model are you using — is it Amazon Bedrock?"**
> It's a one-line switch: Ollama runs locally by default so the demo needs no keys, and Bedrock turns on as soon as we have the sponsor credentials. The agent code doesn't change either way.

**"Why does it need a real phone? Can I try it in a simulator?"**
> ARKit camera tracking and the motion sensors only exist on a real device, so the walkthrough runs on an iPhone. The scripted demo and the backend all run without a phone if you want to see the logic.
