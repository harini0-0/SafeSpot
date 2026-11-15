# Scan views — DERIVED, read-only

228 phone-camera-sized views (portrait 300×400, 55° wide, every 30°) cut from the
19 panorama scans of the demo house, for `locate`'s scan-photo matching
(`Locate/ScanMatcher.swift`). `scan_views.json` tags each view with its panorama's
room id and position, taken from `data/zyzG7fqtBDv.json`.

- Source (read-only, never modified): `data/assets/skybox/<panoId>/face1..4.jpg`
  from `scripts/fetch_assets.py` (checksums in `data/assets/MANIFEST.json`).
- Regenerate: `scripts/.venv/bin/python scripts/make_scan_views.py`
- `panoYaw` is relative to each panorama's face 1, not a model-space heading.
