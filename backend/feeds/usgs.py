"""USGS earthquake feed for a point (recent quakes + shaking intensity).

Public FDSN event API (earthquake.usgs.gov), no key. Returns structured,
validated quakes. `hazard`-side code only: no judgment — the `damage` agent
interprets shaking intensity downstream.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Optional

import httpx
from pydantic import BaseModel

USGS_ENDPOINT = "https://earthquake.usgs.gov/fdsnws/event/1/query"
# Generic client name only. Never put the user's name/email in an outbound header.
USER_AGENT = "SafeSpot/0.1 (HackPrinceton project)"


class UsgsQuake(BaseModel):
    """One earthquake event, flattened from a GeoJSON feature."""

    id: str
    magnitude: Optional[float] = None
    place: Optional[str] = None
    time: Optional[datetime] = None
    longitude: Optional[float] = None
    latitude: Optional[float] = None
    depth_km: Optional[float] = None
    felt: Optional[int] = None  # count of "did you feel it?" reports
    cdi: Optional[float] = None  # community (felt) intensity, MMI scale
    mmi: Optional[float] = None  # instrumental (ShakeMap) intensity, MMI scale
    alert: Optional[str] = None  # PAGER alert level: green/yellow/orange/red
    tsunami: Optional[int] = None
    url: Optional[str] = None


def fetch_recent_quakes(
    lat: float,
    lon: float,
    maxradiuskm: float = 500.0,
    minmagnitude: Optional[float] = None,
    limit: int = 20,
    timeout: float = 30.0,
) -> list[UsgsQuake]:
    """Return recent quakes within `maxradiuskm` of the point, newest first."""
    params: dict[str, object] = {
        "format": "geojson",
        "latitude": lat,
        "longitude": lon,
        "maxradiuskm": maxradiuskm,
        "limit": limit,
        "orderby": "time",
    }
    if minmagnitude is not None:
        params["minmagnitude"] = minmagnitude

    resp = httpx.get(
        USGS_ENDPOINT,
        params=params,
        headers={"User-Agent": USER_AGENT},
        timeout=timeout,
    )
    resp.raise_for_status()
    features = resp.json().get("features", []) or []

    quakes: list[UsgsQuake] = []
    for feature in features:
        props = feature.get("properties", {}) or {}
        geom = feature.get("geometry", {}) or {}
        coords = geom.get("coordinates") or [None, None, None]
        epoch_ms = props.get("time")
        when = (
            datetime.fromtimestamp(epoch_ms / 1000, tz=timezone.utc)
            if isinstance(epoch_ms, (int, float))
            else None
        )
        quakes.append(
            UsgsQuake(
                id=feature.get("id"),
                magnitude=props.get("mag"),
                place=props.get("place"),
                time=when,
                longitude=coords[0],
                latitude=coords[1],
                depth_km=coords[2],
                felt=props.get("felt"),
                cdi=props.get("cdi"),
                mmi=props.get("mmi"),
                alert=props.get("alert"),
                tsunami=props.get("tsunami"),
                url=props.get("url"),
            )
        )
    return quakes
