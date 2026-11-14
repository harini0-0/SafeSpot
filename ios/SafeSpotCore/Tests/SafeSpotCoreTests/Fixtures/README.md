# Test fixtures — DERIVED, read-only

`zyzG7fqtBDv.json` is a **verbatim copy** of the real Matterport export
`data/zyzG7fqtBDv.json` (CoStar demo house, 7950 Bellfort St, Houston).

- Derived from: `data/zyzG7fqtBDv.json`
- sha256: `5e452776a423309dd0b1b7eb6458b111a44450472a616a7c810d2be9aae1b93f`
- Do not edit, clean or reshape it. It exists only so `swift test` can run against
  the real data without the app bundle or a simulator. Per CLAUDE.md, the source data
  is read-only; this copy is identical to the source (checksum above matches).

`out_res_50k.obj` is a **verbatim copy** of the full-house 50k mesh
`data/assets/mesh/50k/out_res_50k.obj` (downloaded by `scripts/fetch_assets.py`).

- Derived from: `data/assets/mesh/50k/out_res_50k.obj`
- sha256: `6e2c220fdafba5163d891e481bc097904f7a11b53d073914291f8d50566ffd97`
- Geometry only (no UVs/material), used to test mesh segmentation. Do not edit.

To refresh them if the source ever changes:
`cp data/zyzG7fqtBDv.json data/assets/mesh/50k/out_res_50k.obj ios/SafeSpotCore/Tests/SafeSpotCoreTests/Fixtures/`
