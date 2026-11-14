# Test fixtures — DERIVED, read-only

`zyzG7fqtBDv.json` is a **verbatim copy** of the real Matterport export
`data/zyzG7fqtBDv.json` (CoStar demo house, 7950 Bellfort St, Houston).

- Derived from: `data/zyzG7fqtBDv.json`
- sha256: `5e452776a423309dd0b1b7eb6458b111a44450472a616a7c810d2be9aae1b93f`
- Do not edit, clean or reshape it. It exists only so `swift test` can run against
  the real data without the app bundle or a simulator. Per CLAUDE.md, the source data
  is read-only; this copy is identical to the source (checksum above matches).

To refresh it if the source ever changes:
`cp data/zyzG7fqtBDv.json ios/SafeSpotCore/Tests/SafeSpotCoreTests/Fixtures/`
