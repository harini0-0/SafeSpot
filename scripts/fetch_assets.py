#!/usr/bin/env python3
"""Fetch fresh signed URLs for a Matterport model and download its binary assets.

Downloads (into data/assets/, which is gitignored):
  - every available textured-mesh OBJ (all resolutions offered)
  - every available texture (all qualities)
  - every panorama skybox, all 6 faces, at the highest resolution offered
  - every floorplan file (DXF + images)
  - any available resource bundle (matterpak / obj zip / point cloud) -- only if the
    API reports it 'available'; unavailable ones are recorded, not invented

The fresh GraphQL response (with signed URLs) is saved to
data/fresh/<modelId>.json. The original data/<modelId>.json is NEVER touched.

A data/assets/MANIFEST.json records, per downloaded file: asset type, resolution,
byte size, sha256, fetch time, and the source URL with its query string stripped
(so no time-limited signature token is committed).

Repeatable: anyone with a valid .env can re-run this and rebuild the same folder.

Usage:
    scripts/.venv/bin/python scripts/fetch_assets.py [modelId]   # default zyzG7fqtBDv

Auth: HTTP Basic, MATTERPORT_API_KEY + MATTERPORT_API_TOKEN from .env (repo root).
"""
import hashlib
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

import requests
from dotenv import dotenv_values

ENDPOINT = "https://api.matterport.com/api/models/graph"
REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MODEL = "zyzG7fqtBDv"
SKYBOX_RES_PREFERENCE = ["4k", "high", "2k", "low"]  # highest first


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def load_auth():
    env = {**dotenv_values(REPO_ROOT / ".env"), **os.environ}
    key, tok = env.get("MATTERPORT_API_KEY"), env.get("MATTERPORT_API_TOKEN")
    if not key or not tok:
        sys.exit("Missing MATTERPORT_API_KEY / MATTERPORT_API_TOKEN in .env or environment")
    return (key, tok)


def post(auth, query, variables=None):
    r = requests.post(ENDPOINT, json={"query": query, "variables": variables or {}},
                      auth=auth, headers={"Content-Type": "application/json"}, timeout=180)
    if r.status_code == 401:
        sys.exit("401 Unauthorized: check credentials in .env")
    r.raise_for_status()
    body = r.json()
    if body.get("errors"):
        sys.exit("GraphQL errors:\n" + json.dumps(body["errors"], indent=2))
    return body["data"]


# One query: metadata (for the fresh JSON) + every download-bearing field.
QUERY = """
query($id: ID!, $skyres: [String!]) {
  model(id: $id) {
    id name
    units: dimensionEstimates(units: metric) { area areaIndoor }
    geocoordinates { latitude longitude altitude source
        rotation { w x y z } translation { x y z } }
    floors { id label sequence }
    assets {
      meshes { id format resolution filename status url downloadUrl validUntil }
      textures { id format resolution quality textures status url downloadUrl urlTemplate validUntil }
      floorplans { id format resolution width height status url downloadUrl validUntil }
      resources { id format status filename url ... on Resource { downloadUrl s3Path contentType } }
      sizeEstimates { scanCount scanBytes manifestBytes }
    }
    panoLocations {
      id label position { x y z } rotation { w x y z }
      anchor { room { id } floor { id } }
      skyboxes(resolutions: $skyres) {
        id resolution format status url downloadUrl urlTemplate children validUntil
      }
    }
    objectAnnotations { id label confidence enabled classification { label }
                        room { id } keywords }
    mattertags { id label }
    measurements { id label }
    labels { id label }
  }
}"""


def strip_query(url):
    if not url:
        return url
    p = urlsplit(url)
    return urlunsplit((p.scheme, p.netloc, p.path, "", ""))


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download(url, dest, manifest, asset_type, resolution, extra=None):
    """Stream a URL to dest; append a manifest entry. Skips empty URLs."""
    if not url:
        return False
    dest.parent.mkdir(parents=True, exist_ok=True)
    log(f"  -> {dest.relative_to(REPO_ROOT)}")
    with requests.get(url, stream=True, timeout=300) as r:
        r.raise_for_status()
        with open(dest, "wb") as f:
            for chunk in r.iter_content(1 << 20):
                f.write(chunk)
    entry = {
        "file": str(dest.relative_to(REPO_ROOT / "data" / "assets")),
        "assetType": asset_type,
        "resolution": resolution,
        "bytes": dest.stat().st_size,
        "sha256": sha256_of(dest),
        "fetchedAt": datetime.now(timezone.utc).isoformat(),
        "source": strip_query(url),
    }
    if extra:
        entry.update(extra)
    manifest.append(entry)
    return True


def skybox_face_urls(sb):
    """Return the 6 face URLs for a skybox: prefer 'children', else expand urlTemplate."""
    children = [c for c in (sb.get("children") or []) if c]
    if children:
        return children
    tmpl = sb.get("urlTemplate")
    if tmpl and "<face>" in tmpl:
        return [tmpl.replace("<face>", str(i)) for i in range(6)]
    if sb.get("url"):
        return [sb["url"]]
    return []


def main():
    model_id = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_MODEL
    auth = load_auth()
    assets_dir = REPO_ROOT / "data" / "assets"
    fresh_dir = REPO_ROOT / "data" / "fresh"
    assets_dir.mkdir(parents=True, exist_ok=True)
    fresh_dir.mkdir(parents=True, exist_ok=True)

    log(f"Querying model {model_id} ...")
    data = post(auth, QUERY, {"id": model_id, "skyres": SKYBOX_RES_PREFERENCE})
    model = data["model"]

    fresh_path = fresh_dir / f"{model_id}.json"
    fresh_path.write_text(json.dumps(
        {"modelId": model_id, "fetchedAt": datetime.now(timezone.utc).isoformat(),
         "source": ENDPOINT, "model": model}, indent=2))
    log(f"Saved fresh JSON: {fresh_path.relative_to(REPO_ROOT)}")

    a = model.get("assets") or {}
    manifest = []

    # --- meshes (all resolutions) ---
    log("Meshes:")
    for m in a.get("meshes") or []:
        if m.get("status") != "available":
            log(f"  (skip {m.get('id')} status={m.get('status')})"); continue
        fn = m.get("filename") or f"{m['resolution']}.obj"
        dest = assets_dir / "mesh" / m["resolution"] / fn
        download(m.get("url") or m.get("downloadUrl"), dest, manifest, "mesh",
                 m.get("resolution"), {"format": m.get("format"), "meshId": m.get("id")})

    # --- textures (all qualities) ---
    log("Textures:")
    for t in a.get("textures") or []:
        if t.get("status") != "available":
            log(f"  (skip texture {t.get('id')} status={t.get('status')})"); continue
        res = f"{t.get('resolution')}-{t.get('quality')}"
        # a texture asset may expose a single url, children, or a urlTemplate with a
        # <texture> tile placeholder expanded 0..(textures-1).
        urls = []
        tile_count = t.get("textures") or 1
        if t.get("children"):
            urls = [c for c in t["children"] if c]
        elif t.get("url"):
            urls = [t["url"]]
        elif t.get("downloadUrl"):
            urls = [t["downloadUrl"]]
        elif t.get("urlTemplate") and "<texture>" in t["urlTemplate"]:
            # texture atlas tiles are zero-padded 3-digit: _000.jpg, _001.jpg, ...
            urls = [t["urlTemplate"].replace("<texture>", f"{i:03d}") for i in range(tile_count)]
        elif t.get("urlTemplate") and "<face>" in t["urlTemplate"]:
            urls = [t["urlTemplate"].replace("<face>", str(i)) for i in range(6)]
        if not urls:
            log(f"  (texture {t.get('id')} has no direct url; urlTemplate={t.get('urlTemplate')})")
        for i, u in enumerate(urls):
            dest = assets_dir / "texture" / res / f"{t.get('id','tex')}_{i}.jpg"
            download(u, dest, manifest, "texture", res,
                     {"quality": t.get("quality"), "tileCount": t.get("textures")})

    # --- skyboxes: all panos, 6 faces, highest resolution offered ---
    log("Skyboxes:")
    for p in model.get("panoLocations") or []:
        sbs = [s for s in (p.get("skyboxes") or []) if s.get("status") == "available"]
        if not sbs:
            continue
        # pick highest available per preference
        chosen = min(sbs, key=lambda s: SKYBOX_RES_PREFERENCE.index(s["resolution"])
                     if s["resolution"] in SKYBOX_RES_PREFERENCE else 99)
        faces = skybox_face_urls(chosen)
        for i, u in enumerate(faces):
            dest = assets_dir / "skybox" / p["id"] / f"face{i}.jpg"
            download(u, dest, manifest, "skybox", chosen.get("resolution"),
                     {"panoId": p["id"], "panoLabel": p.get("label"), "face": i})

    # --- floorplans (all) ---
    log("Floorplans:")
    for i, fp in enumerate(a.get("floorplans") or []):
        if fp.get("status") != "available":
            continue
        ext = fp.get("format") or "bin"
        dest = assets_dir / "floorplan" / f"floorplan_{i}.{ext}"
        download(fp.get("url") or fp.get("downloadUrl"), dest, manifest, "floorplan",
                 fp.get("resolution"), {"format": ext, "width": fp.get("width"),
                                        "height": fp.get("height")})

    # --- resources (only if available) ---
    log("Resources:")
    for r in a.get("resources") or []:
        if r.get("status") != "available":
            log(f"  (unavailable: {r.get('id')} {r.get('format')})"); continue
        fn = r.get("filename") or f"{r.get('id','res').replace('/','_')}"
        dest = assets_dir / "resource" / fn
        download(r.get("url") or r.get("downloadUrl"), dest, manifest, "resource",
                 None, {"format": r.get("format"), "resourceId": r.get("id")})

    # --- MANIFEST ---
    manifest_doc = {
        "modelId": model_id,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "sizeEstimates": a.get("sizeEstimates"),
        "counts": {
            "objectAnnotations": len(model.get("objectAnnotations") or []),
            "mattertags": len(model.get("mattertags") or []),
            "measurements": len(model.get("measurements") or []),
            "labels": len(model.get("labels") or []),
        },
        "unavailable": [
            {"id": r.get("id"), "format": r.get("format"), "status": r.get("status")}
            for r in (a.get("resources") or []) if r.get("status") != "available"
        ],
        "files": sorted(manifest, key=lambda e: e["file"]),
    }
    (assets_dir / "MANIFEST.json").write_text(json.dumps(manifest_doc, indent=2))
    total = sum(e["bytes"] for e in manifest)
    log(f"\nDownloaded {len(manifest)} files, {total/1e6:.1f} MB total")
    log(f"Manifest: {(assets_dir / 'MANIFEST.json').relative_to(REPO_ROOT)}")


if __name__ == "__main__":
    main()
