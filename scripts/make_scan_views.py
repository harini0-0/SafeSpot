#!/usr/bin/env python3
"""Cut phone-camera-sized reference views out of the house's panorama scans.

`locate` matches the live camera view against these to tell which room the user is
in (CLAUDE.md: "Camera tracking + match against scan photos").

Input (read-only, never modified):
  data/zyzG7fqtBDv.json                       panorama ids, positions, rooms
  data/assets/skybox/<panoId>/face{0..5}.jpg   cube faces from scripts/fetch_assets.py
    face0 = ceiling, face5 = floor, faces 1-4 = walls, going clockwise
    (verified: face i's right edge meets face i+1's left edge on all 19 panoramas)

Output (derived):
  <out>/<panoId>_<yaw>.jpg   portrait 3:4 perspective views, every 30 degrees
  <out>/scan_views.json      index: file, panoId, panoLabel, roomId, x, y, panoYaw

panoYaw is degrees clockwise from the centre of face1, in the panorama's own frame.
It is NOT a model-space heading (the cube face convention vs model axes isn't in
the data), so it's recorded but not used for heading.

Usage:
  scripts/.venv/bin/python scripts/make_scan_views.py \
      [--out ios/LocateTest/LocateTest/ScanViews] [--hfov 55] [--step 30] [--offset 0]
"""
import argparse
import json
import math
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
MODEL = "zyzG7fqtBDv"
FACE_RES = 1024          # faces are 4096 px; 1024 is plenty for 300x400 views
OUT_W, OUT_H = 300, 400  # portrait, like a phone held upright


def load_faces(pano_dir: Path):
    return [np.asarray(Image.open(pano_dir / f"face{i}.jpg").convert("RGB")
                       .resize((FACE_RES, FACE_RES), Image.BILINEAR)) for i in range(1, 5)]


def render_view(faces, yaw_deg: float, hfov_deg: float) -> Image.Image:
    """Perspective view looking at yaw_deg (clockwise from face1 centre), level."""
    t = math.tan(math.radians(hfov_deg) / 2)
    xs = (2 * (np.arange(OUT_W) + 0.5) / OUT_W - 1) * t
    ys = (1 - 2 * (np.arange(OUT_H) + 0.5) / OUT_H) * t * OUT_H / OUT_W
    x, y = np.meshgrid(xs, ys)                       # camera: right, up, forward=1
    ray_yaw = yaw_deg + np.degrees(np.arctan2(x, 1.0))
    horiz = np.sqrt(x * x + 1.0)
    k = np.round(ray_yaw / 90.0).astype(int) % 4     # which wall face
    beta = np.radians(ray_yaw - 90.0 * np.round(ray_yaw / 90.0))
    u = np.tan(beta)                                 # face-local right/forward
    v = y / (horiz * np.cos(beta))                   # face-local up/forward
    col = np.clip(((u + 1) / 2 * FACE_RES).astype(int), 0, FACE_RES - 1)
    row = np.clip(((1 - v) / 2 * FACE_RES).astype(int), 0, FACE_RES - 1)
    out = np.zeros((OUT_H, OUT_W, 3), dtype=np.uint8)
    for f in range(4):
        m = k == f
        out[m] = faces[f][row[m], col[m]]
    return Image.fromarray(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="ios/LocateTest/LocateTest/ScanViews")
    ap.add_argument("--hfov", type=float, default=55.0)
    ap.add_argument("--step", type=float, default=30.0)
    ap.add_argument("--offset", type=float, default=0.0, help="yaw offset (for test sets)")
    ap.add_argument("--quality", type=int, default=80)
    args = ap.parse_args()

    model = json.loads((REPO / "data" / f"{MODEL}.json").read_text())
    panos = model["sections"]["panoramas"]["panoLocations"]
    out = (REPO / args.out) if not Path(args.out).is_absolute() else Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    index = []
    skipped = []
    for p in panos:
        pid = p["id"]
        room_id = ((p.get("anchor") or {}).get("room") or {}).get("id")
        pano_dir = REPO / "data" / "assets" / "skybox" / pid
        if not room_id or not pano_dir.exists():
            skipped.append({"panoId": pid, "reason": "no room" if not room_id else "no skybox files"})
            continue
        faces = load_faces(pano_dir)
        n = int(round(360 / args.step))
        for i in range(n):
            yaw = (args.offset + i * args.step) % 360
            name = f"{pid}_{int(round(yaw)):03d}.jpg"
            render_view(faces, yaw, args.hfov).save(out / name, quality=args.quality)
            index.append({"file": name, "panoId": pid, "panoLabel": p.get("label"),
                          "roomId": room_id, "x": p["position"]["x"], "y": p["position"]["y"],
                          "panoYaw": yaw})

    (out / "scan_views.json").write_text(json.dumps(
        {"modelId": MODEL, "hfov": args.hfov, "step": args.step, "offset": args.offset,
         "width": OUT_W, "height": OUT_H, "views": index, "skipped": skipped}, indent=1))
    print(f"{len(index)} views from {len(panos) - len(skipped)} panoramas -> {out}")
    if skipped:
        print("skipped:", skipped)


if __name__ == "__main__":
    main()
