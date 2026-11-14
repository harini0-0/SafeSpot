#!/usr/bin/env python3
"""Convert each panorama's 6 skybox cube faces into one equirectangular JPEG for the
app to texture a sphere with. Reads data/assets/skybox/<panoId>/face{0..5}.jpg
(produced by fetch_assets.py) and writes ios/SafeSpot/SafeSpot/Resources/panoramas/<panoId>.jpg.

Face order verified against the real data:
  face0=front(+Z) face1=right(+X) face2=up(+Y) face3=back(-Z) face4=left(-X) face5=down(-Y)

Reads only; the source faces are not modified. Repeatable with a valid .env + fetch_assets.
Usage: scripts/.venv/bin/python scripts/build_panoramas.py   (needs numpy+Pillow)
"""
import sys
from pathlib import Path
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "data/assets/skybox"
OUT = ROOT / "ios/SafeSpot/SafeSpot/Resources/panoramas"
# Source cube faces are 4096x4096; use a high-res equirect so the photos stay sharp.
W, H = 4096, 2048
# direction -> face file index
M = {"+Z": 0, "+X": 1, "+Y": 2, "-Z": 3, "-X": 4, "-Y": 5}

def precompute():
    lon = np.linspace(0, 2*np.pi, W, endpoint=False)[None, :].repeat(H, 0)
    lat = np.linspace(0, np.pi, H)[:, None].repeat(W, 1)
    x = np.sin(lat)*np.cos(lon); y = np.cos(lat); z = np.sin(lat)*np.sin(lon)
    ax, ay, az = np.abs(x), np.abs(y), np.abs(z)
    faceidx = np.zeros((H, W), np.int8); sf = np.zeros((H, W)); tf = np.zeros((H, W))
    def put(mask, fi, u, v, axis):
        faceidx[mask] = fi
        sf[mask] = ((u/axis+1)/2)[mask]; tf[mask] = ((v/axis+1)/2)[mask]
    mx = (ax >= ay) & (ax >= az)
    put(mx & (x > 0), M["+X"], -z, -y, ax); put(mx & (x <= 0), M["-X"], z, -y, ax)
    my = (ay > ax) & (ay >= az)
    put(my & (y > 0), M["+Y"], x, z, ay); put(my & (y <= 0), M["-Y"], x, -z, ay)
    mz = (~mx) & (~my)
    put(mz & (z > 0), M["+Z"], x, -y, az); put(mz & (z <= 0), M["-Z"], -x, -y, az)
    return faceidx, np.clip(sf, 0, 1), np.clip(tf, 0, 1)

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    faceidx, sf, tf = precompute()
    panos = sorted(p.name for p in SRC.iterdir() if p.is_dir())
    done = 0
    for pid in panos:
        faces = []
        ok = True
        for i in range(6):
            f = SRC / pid / f"face{i}.jpg"
            if not f.exists(): ok = False; break
            faces.append(np.asarray(Image.open(f).convert("RGB")))
        if not ok:
            print("skip (missing faces):", pid); continue
        fh, fw = faces[0].shape[:2]
        out = np.zeros((H, W, 3), np.uint8)
        for i in range(6):
            m = faceidx == i
            s = (sf[m]*(fw-1)).astype(int); t = (tf[m]*(fh-1)).astype(int)
            out[m] = faces[i][t, s]
        Image.fromarray(out).save(OUT / f"{pid}.jpg", quality=92)
        done += 1
        print("wrote", pid)
    print(f"\n{done}/{len(panos)} panoramas -> {OUT.relative_to(ROOT)}")

if __name__ == "__main__":
    main()
