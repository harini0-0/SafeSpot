# Demo checklist

## The night before

- [ ] App installed and launching on the **demo iPhone** (real device — not the Simulator).
- [ ] Walk the full **▶︎ Demo** (Tour mode) end to end at least 3 times.
- [ ] **Fallback video recorded** and saved offline (phone + laptop), in case the live demo fails. Link in the README.
- [ ] Phones charged to 100%; bring a battery pack and cable.
- [ ] Permissions already granted on the demo phone (camera, location, motion, microphone, speech) so no prompts appear mid-demo.
- [ ] Developer Mode on and the developer certificate trusted (Settings → Privacy & Security).
- [ ] Volume up — the voice guidance is part of the pitch.

## If showing the live backend (optional, higher risk)

- [ ] Backend running: `uvicorn main:app --host 0.0.0.0 --port 8000`.
- [ ] `BackendConfig.plist` `BaseURL` set to the laptop's current IP (`ipconfig getifaddr en0`), app rebuilt.
- [ ] Phone and laptop on the **same Wi-Fi**; confirm from the phone: `curl`/browser to `http://<ip>:8000/health` returns JSON (use `http://`, not `https://`).
- [ ] If venue Wi-Fi blocks device-to-device traffic: fall back to the **iPhone hotspot** — laptop joins it, update the IP, rebuild.

## Which demo path to show

1. **Primary: the ▶︎ Demo button (Tour mode).** Deterministic — no sensors, Wi-Fi, or backend. This is what you show by default.
   - Tornado warning → routes to a safe interior room → hallway blocked → reroutes → arrives, all with voice.
2. **Optional add-on:** tap **🎤 Ask**, say "Where do I go next?", get a spoken answer.
3. **Optional (only if backend is confirmed reachable):** use **📍 Live** tracking and the **⚠︎ Blocked here** button to show the real backend reroute.

## During the demo

- [ ] Start inside the app already in **Tour** mode.
- [ ] Narrate the scripted run; don't fight the live sensors on stage.
- [ ] Keep the pitch to 2 minutes (see `docs/PITCH.md`).

## If something fails

- **App won't route / freezes:** relaunch; re-tap **▶︎ Demo**. It needs nothing external.
- **Backend unreachable:** don't debug on stage — the scripted demo doesn't use it. Say "the backend's live too, here's the recording" and show the fallback video.
- **Voice silent:** check the ringer/volume; the on-screen route still carries the story.
- **Phone misbehaves:** play the **fallback video**.
