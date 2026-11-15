#!/usr/bin/env python3
"""Block 0 access check for the Safe Spot backend.

Verifies the external inputs the backend depends on, independently of the rest
of the app:

  1. NWS alerts API   (tornado warnings)  -- public, no key, needs User-Agent
  2. USGS earthquake feed                 -- public, no key
  3. AWS Bedrock                          -- needs sponsor credentials in .env

House coordinates are read from the real CoStar/Matterport export under data/
(never invented). Run from the repo root with the venv active:

    python backend/check_access.py

Each check prints PASS / FAIL / SKIP with a one-line reason. Exit code is
non-zero only if a check that actually ran failed (SKIP does not fail).
"""

import json
import os
import sys
from pathlib import Path

import httpx

REPO_ROOT = Path(__file__).resolve().parent.parent
GEO_FILE = REPO_ROOT / "data" / "zyzG7fqtBDv_geo.json"

# Generic client name only. Never put the user's name/email or other personal
# info in an outbound header, per project privacy rules.
USER_AGENT = "SafeSpot/0.1 (HackPrinceton project)"


def load_env():
    """Read .env from the repo root into a dict (no extra dependency)."""
    env = dict(os.environ)
    path = REPO_ROOT / ".env"
    if path.exists():
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env.setdefault(k.strip(), v.strip().strip('"').strip("'"))
    return env


def house_coords():
    """Latitude/longitude of the demo house from the read-only data export."""
    data = json.loads(GEO_FILE.read_text())
    geo = data["data"]["model"]["geocoordinates"]
    return geo["latitude"], geo["longitude"]


def check_nws(lat, lon):
    url = f"https://api.weather.gov/alerts/active?point={lat},{lon}"
    r = httpx.get(
        url,
        headers={"User-Agent": USER_AGENT, "Accept": "application/geo+json"},
        timeout=30,
    )
    r.raise_for_status()
    n = len(r.json().get("features", []))
    return f"PASS  NWS: {n} active alert(s) for {lat:.4f},{lon:.4f}"


def check_usgs(lat, lon):
    url = (
        "https://earthquake.usgs.gov/fdsnws/event/1/query"
        f"?format=geojson&latitude={lat}&longitude={lon}"
        "&maxradiuskm=500&limit=5&orderby=time"
    )
    r = httpx.get(url, headers={"User-Agent": USER_AGENT}, timeout=30)
    r.raise_for_status()
    n = len(r.json().get("features", []))
    return f"PASS  USGS: {n} recent quake(s) within 500 km of the house"


def check_bedrock(env):
    region = env.get("AWS_REGION")
    model_id = env.get("BEDROCK_MODEL_ID")
    if not (
        env.get("AWS_ACCESS_KEY_ID")
        and env.get("AWS_SECRET_ACCESS_KEY")
        and region
        and model_id
    ):
        return (
            "SKIP  Bedrock: set AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, "
            "AWS_REGION and BEDROCK_MODEL_ID in .env to test"
        )
    import boto3

    client = boto3.client(
        "bedrock-runtime",
        region_name=region,
        aws_access_key_id=env["AWS_ACCESS_KEY_ID"],
        aws_secret_access_key=env["AWS_SECRET_ACCESS_KEY"],
    )
    resp = client.converse(
        modelId=model_id,
        messages=[{"role": "user", "content": [{"text": "Reply with the single word: ok"}]}],
        inferenceConfig={"maxTokens": 10},
    )
    text = resp["output"]["message"]["content"][0]["text"].strip()
    return f"PASS  Bedrock: {model_id} replied {text!r}"


def main():
    env = load_env()
    lat, lon = house_coords()
    checks = [
        ("NWS", lambda: check_nws(lat, lon)),
        ("USGS", lambda: check_usgs(lat, lon)),
        ("Bedrock", lambda: check_bedrock(env)),
    ]
    failed = False
    for name, fn in checks:
        try:
            print(fn())
        except Exception as e:  # noqa: BLE001 - report any failure per check
            failed = True
            print(f"FAIL  {name}: {type(e).__name__}: {e}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
