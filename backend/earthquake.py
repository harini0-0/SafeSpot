"""Earthquake shaking state machine (deterministic, backend-side).

Consumes the phone's 1 Hz motion summary ({rms in G, activity}) and decides the
single thing the planner needs: is it `shaking` (take cover) or stopped (exit)?
No model, no invented data — pure timers + thresholds, with carry-state awareness
and safe defaults (CLAUDE.md rule 5: no running during shaking; cover first, exit
when it stops).

Design (see the agreed flow):
  * Armed by the backend when earthquake mode starts -> defaults to shaking=True
    (take cover) without waiting on the sensor (safe direction).
  * STOP (shaking->False) only when: the minimum cover time has elapsed AND
      - phone is trustworthy (stationary): sustained calm for CALM_DEBOUNCE, or
      - phone is untrustworthy (walking/automotive/unknown): a conservative
        MOVING_TIMEOUT since cover start with current motion below the shake
        threshold (we can't read ground shaking through gait, so we wait it out).
  * Aftershock: once in exit mode, a new strong reading flips back to take cover.
  * Hysteresis (separate ON/OFF thresholds) avoids flapping.

Times are passed in (monotonic seconds) so the machine is fully testable.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

# Thresholds in G (CoreMotion userAcceleration; still phone ~= 0.0).
SHAKE_RMS_ON = 0.30  # at/above -> shaking
SHAKE_RMS_OFF = 0.08  # below -> calm (hysteresis gap avoids flapping)

MIN_COVER_SEC = 12.0  # never flip to exit before this since cover started
CALM_DEBOUNCE_SEC = 7.0  # sustained calm needed to declare stopped (trustworthy)
MOVING_TIMEOUT_SEC = 45.0  # conservative wait when carry state is untrustworthy

_TRUSTWORTHY = {"stationary"}


@dataclass
class EarthquakeMonitor:
    armed: bool = False
    shaking: bool = False
    _cover_start: float = 0.0
    _last_shake: float = 0.0
    _calm_since: Optional[float] = None
    _last_rms: float = 0.0

    def arm(self, now: float) -> None:
        """Enter earthquake mode -> take cover immediately (safe default)."""
        self.armed = True
        self.shaking = True
        self._cover_start = now
        self._last_shake = now
        self._calm_since = None
        self._last_rms = 0.0

    def disarm(self) -> None:
        self.armed = False
        self.shaking = False
        self._calm_since = None

    def update(self, rms: float, activity: str, now: float) -> Optional[bool]:
        """Feed one sample. Returns the new `shaking` value if it changed, else None."""
        if not self.armed:
            return None
        self._last_rms = rms
        trustworthy = activity in _TRUSTWORTHY
        prev = self.shaking

        if self.shaking:
            if rms >= SHAKE_RMS_ON:
                self._last_shake = now
                self._calm_since = None
            elif rms < SHAKE_RMS_OFF:
                if self._calm_since is None:
                    self._calm_since = now
            else:
                self._calm_since = None  # ambiguous mid-band: not calm

            if (now - self._cover_start) >= MIN_COVER_SEC and self._calm_confirmed(now, trustworthy):
                self.shaking = False
        else:
            # Exit mode: watch for an aftershock.
            if rms >= SHAKE_RMS_ON:
                self.shaking = True
                self._cover_start = now
                self._last_shake = now
                self._calm_since = None

        return self.shaking if self.shaking != prev else None

    def _calm_confirmed(self, now: float, trustworthy: bool) -> bool:
        if trustworthy:
            return self._calm_since is not None and (now - self._calm_since) >= CALM_DEBOUNCE_SEC
        # Untrustworthy carry state: wait out a conservative timer and require the
        # current reading to be below the shake threshold.
        return (now - self._cover_start) >= MOVING_TIMEOUT_SEC and self._last_rms < SHAKE_RMS_ON


# ---------------------------------------------------------------------------
# Simulated-stream self-test
# ---------------------------------------------------------------------------
def _simulate() -> int:
    """Run scripted quakes and check the flips. Returns non-zero on failure."""
    failures = 0

    def expect(cond: bool, msg: str) -> None:
        nonlocal failures
        print(("  OK  " if cond else "  !!  ") + msg)
        if not cond:
            failures += 1

    # Scenario 1: stationary phone — shake, calm, aftershock, calm.
    print("Scenario 1: stationary (shake -> calm -> aftershock -> calm)")
    m = EarthquakeMonitor()
    m.arm(now=0.0)
    expect(m.shaking is True, "armed -> take cover immediately")
    flips: list[tuple[float, bool]] = []
    for t in range(1, 60):
        t = float(t)
        if t < 10:
            rms = 0.5  # shaking
        elif t < 25:
            rms = 0.02  # calm
        elif t < 28:
            rms = 0.6  # aftershock
        else:
            rms = 0.02  # calm again
        changed = m.update(rms, "stationary", now=t)
        if changed is not None:
            flips.append((t, changed))
    print(f"    flips: {flips}")
    # Expect: stop ~t=17 (calm@10 +7 debounce, min-cover 12 ok); aftershock True ~t=25;
    # stop again ~t=37 (cover reset @25 + min-cover 12).
    expect(any(f[1] is False and 16 <= f[0] <= 18 for f in flips), "stops ~17s after sustained calm")
    expect(any(f[1] is True and 25 <= f[0] <= 26 for f in flips), "aftershock re-covers ~25s")
    expect(any(f[1] is False and 36 <= f[0] <= 39 for f in flips), "stops again ~37s (min-cover gated)")

    # Scenario 2: walking phone — can't trust the sensor; waits out MOVING_TIMEOUT.
    print("Scenario 2: walking (untrustworthy -> conservative timeout)")
    m2 = EarthquakeMonitor()
    m2.arm(now=0.0)
    stop_t = None
    for t in range(1, 60):
        t = float(t)
        rms = 0.5 if t < 8 else 0.05  # shaking stops early, but phone is walking
        changed = m2.update(rms, "walking", now=t)
        if changed is False:
            stop_t = t
            break
    print(f"    stopped at t={stop_t}")
    expect(stop_t is not None and stop_t >= MOVING_TIMEOUT_SEC, "waits the conservative timeout while walking")

    # Scenario 3: never flips before the minimum cover time.
    print("Scenario 3: min-cover floor")
    m3 = EarthquakeMonitor()
    m3.arm(now=0.0)
    early = [m3.update(0.0, "stationary", now=float(t)) for t in range(1, 11)]  # calm from t=1
    expect(all(c is None for c in early) and m3.shaking is True, "stays in cover through the first 10s")

    print(f"\n{'PASS' if failures == 0 else 'FAIL'} - {failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    import sys

    sys.exit(_simulate())
