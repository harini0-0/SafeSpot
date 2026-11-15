"""NWS active-alerts feed (tornado and other warnings) for a point.

Public API (api.weather.gov), no key; NWS requires a descriptive User-Agent.
Returns structured, validated alerts. This is `hazard`-side code only: it does
no judgment — the `damage` agent interprets these alerts downstream.
"""

from __future__ import annotations

from datetime import datetime
from typing import Optional

import httpx
from pydantic import BaseModel

NWS_ENDPOINT = "https://api.weather.gov/alerts/active"
# Generic client name only. Never put the user's name/email in an outbound header.
USER_AGENT = "SafeSpot/0.1 (HackPrinceton project)"


class NwsAlert(BaseModel):
    """One active NWS alert, flattened from a GeoJSON feature's properties."""

    id: str
    event: str  # e.g. "Tornado Warning", "Flood Watch"
    severity: Optional[str] = None
    certainty: Optional[str] = None
    urgency: Optional[str] = None
    headline: Optional[str] = None
    description: Optional[str] = None
    instruction: Optional[str] = None
    area_desc: Optional[str] = None
    onset: Optional[datetime] = None
    effective: Optional[datetime] = None
    expires: Optional[datetime] = None
    ends: Optional[datetime] = None
    sender_name: Optional[str] = None


def fetch_active_alerts(lat: float, lon: float, timeout: float = 30.0) -> list[NwsAlert]:
    """Return all active NWS alerts covering the given point, newest first."""
    headers = {"User-Agent": USER_AGENT, "Accept": "application/geo+json"}
    resp = httpx.get(
        NWS_ENDPOINT,
        params={"point": f"{lat},{lon}"},
        headers=headers,
        timeout=timeout,
    )
    resp.raise_for_status()
    features = resp.json().get("features", []) or []

    alerts: list[NwsAlert] = []
    for feature in features:
        props = feature.get("properties", {}) or {}
        alerts.append(
            NwsAlert(
                id=feature.get("id") or props.get("id"),
                event=props.get("event", "Unknown"),
                severity=props.get("severity"),
                certainty=props.get("certainty"),
                urgency=props.get("urgency"),
                headline=props.get("headline"),
                description=props.get("description"),
                instruction=props.get("instruction"),
                area_desc=props.get("areaDesc"),
                onset=props.get("onset"),
                effective=props.get("effective"),
                expires=props.get("expires"),
                ends=props.get("ends"),
                sender_name=props.get("senderName"),
            )
        )
    return alerts
