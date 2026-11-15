# House summary — model `zyzG7fqtBDv`

> Derived read-only from `data/zyzG7fqtBDv.json` (Matterport export). The source data is not modified. Interior/exterior walls, door-to-room connectivity and exterior exits are **derived** per the rules in CLAUDE.md (edge shared by two rooms = interior; edge in one room = exterior; doorway/window on a single-room edge = exterior).

- Address: `7950 Bellfort St, Houston, TX, 77061, US`
- Units: `metric` (meters)

## Geolocation & north

- Latitude: `29.673020556450794`
- Longitude: `-95.26936479085387`
- Altitude: `12.017842292785645` m (source: `processing`)
- Rotation quaternion (model→geo/true-north): `w=0.9730262401913105, x=0.0, y=0.0, z=0.23069446438777466`
- **North heading (derived):** rotation about +z = **26.676°** (model +Y rotated by this angle aligns to geographic north).
- Translation (model→geo): `x=5.781711676992045, y=1.8946868902203136, z=0.0`

## Floors & ceiling heights

| Floor id | Label | Sequence |
|---|---|---|
| `tsmq1wak12rhgn0mawksxcwcd` | Floor 1 | 0 |

Per-room ceiling heights are listed in the room table below (`ceiling.minHeight/maxHeight`; two zero-height rooms have an empty `ceiling`).

## Rooms

| id | label | confidence | floor | area (m²) | ceiling min/max (m) |
|---|---|---|---|---|---|
| `m8npxsuk79xy21dd09x9wtped` | Closet | 1.000 | Floor 1 | 0.496 | — (empty) |
| `19ab05tns5h6y4qm42esqqpea` | Void | 1.000 | Floor 1 | 0.222 | — (empty) |
| `613htqkzf66zz7hf7n8kzszed` | Living Room | 1.000 | Floor 1 | 25.736 | 2.448 / 2.448 |
| `9hauvfhwiqt` | Hallway | 1.000 | Floor 1 | 4.084 | 2.122 / 2.122 |
| `cdz3fkt38kae7tapstpt0eaeb` | Bedroom | 1.000 | Floor 1 | 13.099 | 2.433 / 2.433 |
| `xy2x8mpaaqknp7q2c3nnbw1ma` | Bedroom | 0.997 | Floor 1 | 11.567 | 2.429 / 2.429 |
| `tt6gm2a0463x9wmnx7rn6gugc` | Kitchen | 1.000 | Floor 1 | 6.454 | 2.160 / 2.160 |
| `h26t7ky77ew74yb0pg8qqf5rd` | Bathroom | 1.000 | Floor 1 | 4.804 | 2.153 / 2.153 |
| `3m54yff1z7crxaywd8if9rb0d` | Closet | 1.000 | Floor 1 | 3.917 | 2.126 / 2.126 |
| `2qdmc5i9byxi79ry1pxdkqzea` | Bathroom | 0.825 | Floor 1 | 3.930 | 2.428 / 2.428 |
| `a5f9age4zzxewres6iqux2emc` | Closet | 0.892 | Floor 1 | 1.797 | 2.458 / 2.458 |

## Room boundary vertices (meters)

Each room's boundary as its ordered edges; vertex coordinates are model-space `x,y` in meters.

### Closet — `m8npxsuk79xy21dd09x9wtped`

| edge id | type | v0 (x,y) | v1 (x,y) |
|---|---|---|---|
| `52311kt27a2ruqa6zicx97pyc` | wall | (-7.702, -0.222) | (-7.698, 0.885) |
| `5k16pried47cxfb2p9869mktd` | wall | (-8.288, 0.887) | (-8.292, -0.220) |
| `mqc6wp8i431336kcdtipxzb2c` | wall | (-8.288, 0.887) | (-7.698, 0.885) |
| `n04c8cky9zprew1gd3c9hx4qc` | wall | (-7.702, -0.222) | (-8.292, -0.220) |

### Void — `19ab05tns5h6y4qm42esqqpea`

| edge id | type | v0 (x,y) | v1 (x,y) |
|---|---|---|---|
| `2mx31sz7cdytri0skpssgbetc` | wall | (-2.373, -0.777) | (-2.983, -0.774) |
| `txnrfetqhc6teeh5zk2fk0sxa` | wall | (-2.373, -0.777) | (-2.371, -0.241) |
| `bph7wug7bw3xesx1xm9s04pab` | wall | (-2.983, -0.774) | (-2.981, -0.239) |
| `7h0fwxrw8anwxf8kr1u1ny51d` | wall | (-2.981, -0.239) | (-2.371, -0.241) |

### Living Room — `613htqkzf66zz7hf7n8kzszed`

| edge id | type | v0 (x,y) | v1 (x,y) |
|---|---|---|---|
| `hb1x5sz2m1252ct7y3bsykd4c` | wall | (-3.572, 4.280) | (0.390, 4.266) |
| `8mcwmbj2prn` | wall | (-3.588, -0.237) | (-2.981, -0.239) |
| `txnrfetqhc6teeh5zk2fk0sxa` | wall | (-2.373, -0.777) | (-2.371, -0.241) |
| `2xx7kdxfni2d2ctpe6aet14wc` | wall | (-2.379, -2.691) | (-2.382, -3.496) |
| `ppcw8gq5qcqumrzacayyxqeyb` | wall | (-2.373, -0.777) | (-2.379, -2.691) |
| `r6bq3ft32xq2umw4n19x2humc` | wall | (-3.578, 2.573) | (-3.572, 4.280) |
| `2e1wiqcbuds5hkesrsnmxwy1b` | wall | (-3.578, 2.573) | (-3.584, 0.870) |
| `m872ugyri48xxdxsudk6rz8db` | wall | (0.362, -3.506) | (0.390, 4.266) |
| `as9qzfixea6rkpss24y8n97ad` | wall | (0.362, -3.506) | (-2.382, -3.496) |
| `0pvw97vy8rm` | invisible | (-3.584, 0.870) | (-3.588, -0.237) |
| `7h0fwxrw8anwxf8kr1u1ny51d` | wall | (-2.981, -0.239) | (-2.371, -0.241) |

### Hallway — `9hauvfhwiqt`

| edge id | type | v0 (x,y) | v1 (x,y) |
|---|---|---|---|
| `senfcw3i001` | wall | (-4.736, -0.233) | (-3.588, -0.237) |
| `52311kt27a2ruqa6zicx97pyc` | wall | (-7.702, -0.222) | (-7.698, 0.885) |
| `xcwpf5sndcs3yexpfaixszmpa` | wall | (-6.116, 0.880) | (-7.698, 0.885) |
| `6y1phyhrm7ggarn9r2xw0a9pa` | wall | (-7.702, -0.222) | (-6.404, -0.227) |
| `28r4kkhg88wewgmby5smic5nd` | wall | (-3.584, 0.870) | (-6.116, 0.880) |
| `d1y02epwaq89zk2uns6m7ehpb` | wall | (-4.736, -0.233) | (-6.404, -0.227) |
| `0pvw97vy8rm` | invisible | (-3.584, 0.870) | (-3.588, -0.237) |

### Bedroom — `cdz3fkt38kae7tapstpt0eaeb`

| edge id | type | v0 (x,y) | v1 (x,y) |
|---|---|---|---|
| `xcwpf5sndcs3yexpfaixszmpa` | wall | (-6.116, 0.880) | (-7.698, 0.885) |
| `rue17w6x9hzcpbnh6tkkbwpyb` | wall | (-6.104, 4.289) | (-6.110, 2.582) |
| `k53qrauguyc6m7yb8u7fh98ad` | wall | (-6.110, 2.582) | (-6.116, 0.880) |
| `xpgyhy80hkfn4qaipyar4kb6d` | wall | (-10.160, 4.304) | (-6.104, 4.289) |
| `mqc6wp8i431336kcdtipxzb2c` | wall | (-8.288, 0.887) | (-7.698, 0.885) |
| `t80ruu4w6u5muc0eg336ge2rd` | wall | (-8.288, 0.887) | (-10.172, 0.894) |
| `fswu9yp4uzqufg5k1czen91fb` | wall | (-10.160, 4.304) | (-10.172, 0.894) |

### Bedroom — `xy2x8mpaaqknp7q2c3nnbw1ma`

| edge id | type | v0 (x,y) | v1 (x,y) |
|---|---|---|---|
| `6y1phyhrm7ggarn9r2xw0a9pa` | wall | (-7.702, -0.222) | (-6.404, -0.227) |
| `6bd43dw17gn3ufmrs6ugpa0db` | wall | (-6.415, -3.480) | (-6.404, -0.227) |
| `afi1z231xn7y5dp4etzdga81b` | wall | (-10.176, -0.213) | (-8.292, -0.220) |
| `n04c8cky9zprew1gd3c9hx4qc` | wall | (-7.702, -0.222) | (-8.292, -0.220) |
| `3gm46e36zfrwkceurd0e23mkb` | wall | (-10.176, -0.213) | (-10.188, -3.466) |
| `f95keie94xqn95kkztkunwked` | wall | (-10.188, -3.466) | (-6.415, -3.480) |

### Kitchen — `tt6gm2a0463x9wmnx7rn6gugc`

| edge id | type | v0 (x,y) | v1 (x,y) |
|---|---|---|---|
| `senfcw3i001` | wall | (-4.736, -0.233) | (-3.588, -0.237) |
| `aucwirnxgthxdhd5ft0gnar0c` | wall | (-4.736, -0.233) | (-4.748, -3.486) |
| `xk775c0y1zn0h2ngxhad90ytd` | wall | (-4.748, -3.486) | (-2.683, -3.493) |
| `8mcwmbj2prn` | wall | (-3.588, -0.237) | (-2.981, -0.239) |
| `2mx31sz7cdytri0skpssgbetc` | wall | (-2.373, -0.777) | (-2.983, -0.774) |
| `bph7wug7bw3xesx1xm9s04pab` | wall | (-2.983, -0.774) | (-2.981, -0.239) |
| `ppcw8gq5qcqumrzacayyxqeyb` | wall | (-2.373, -0.777) | (-2.379, -2.691) |
| `7fstrpq9ppw15p4ggyq0cr8yb` | wall | (-2.680, -2.690) | (-2.379, -2.691) |
| `y8n2xp8agny7uiy20wzhtp7kc` | wall | (-2.680, -2.690) | (-2.683, -3.493) |

### Bathroom — `h26t7ky77ew74yb0pg8qqf5rd`

| edge id | type | v0 (x,y) | v1 (x,y) |
|---|---|---|---|
| `aucwirnxgthxdhd5ft0gnar0c` | wall | (-4.736, -0.233) | (-4.748, -3.486) |
| `d1y02epwaq89zk2uns6m7ehpb` | wall | (-4.736, -0.233) | (-6.404, -0.227) |
| `6bd43dw17gn3ufmrs6ugpa0db` | wall | (-6.415, -3.480) | (-6.404, -0.227) |
| `9ectf8fk1r8aq5kc1it8g3bca` | wall | (-4.748, -3.486) | (-6.415, -3.480) |

### Closet — `3m54yff1z7crxaywd8if9rb0d`

| edge id | type | v0 (x,y) | v1 (x,y) |
|---|---|---|---|
| `2e1wiqcbuds5hkesrsnmxwy1b` | wall | (-3.578, 2.573) | (-3.584, 0.870) |
| `28r4kkhg88wewgmby5smic5nd` | wall | (-3.584, 0.870) | (-6.116, 0.880) |
| `k53qrauguyc6m7yb8u7fh98ad` | wall | (-6.110, 2.582) | (-6.116, 0.880) |
| `9rennx0f7b1fkz13zaupezakb` | wall | (-3.578, 2.573) | (-6.110, 2.582) |

### Bathroom — `2qdmc5i9byxi79ry1pxdkqzea`

| edge id | type | v0 (x,y) | v1 (x,y) |
|---|---|---|---|
| `r6bq3ft32xq2umw4n19x2humc` | wall | (-3.578, 2.573) | (-3.572, 4.280) |
| `rue17w6x9hzcpbnh6tkkbwpyb` | wall | (-6.104, 4.289) | (-6.110, 2.582) |
| `9rennx0f7b1fkz13zaupezakb` | wall | (-3.578, 2.573) | (-6.110, 2.582) |
| `11qhqtug09p4uf2b5phnh6mad` | wall | (-6.104, 4.289) | (-3.572, 4.280) |

### Closet — `a5f9age4zzxewres6iqux2emc`

| edge id | type | v0 (x,y) | v1 (x,y) |
|---|---|---|---|
| `5k16pried47cxfb2p9869mktd` | wall | (-8.288, 0.887) | (-8.292, -0.220) |
| `bprcix10dd8q1atkiu4m21k5c` | wall | (-10.176, -0.213) | (-10.172, 0.894) |
| `afi1z231xn7y5dp4etzdga81b` | wall | (-10.176, -0.213) | (-8.292, -0.220) |
| `t80ruu4w6u5muc0eg336ge2rd` | wall | (-8.288, 0.887) | (-10.172, 0.894) |

## Edges (unique) — interior/exterior derived

| edge id | type | thickness | rooms touched | interior/exterior |
|---|---|---|---|---|
| `52311kt27a2ruqa6zicx97pyc` | wall | 0.1 | Closet (`m8npxsuk`), Hallway (`9hauvfhw`) | interior |
| `5k16pried47cxfb2p9869mktd` | wall | 0.1 | Closet (`m8npxsuk`), Closet (`a5f9age4`) | interior |
| `mqc6wp8i431336kcdtipxzb2c` | wall | 0.09 | Closet (`m8npxsuk`), Bedroom (`cdz3fkt3`) | interior |
| `n04c8cky9zprew1gd3c9hx4qc` | wall | 0.1 | Closet (`m8npxsuk`), Bedroom (`xy2x8mpa`) | interior |
| `2mx31sz7cdytri0skpssgbetc` | wall | 0.1 | Void (`19ab05tn`), Kitchen (`tt6gm2a0`) | interior |
| `txnrfetqhc6teeh5zk2fk0sxa` | wall | 0.1 | Void (`19ab05tn`), Living Room (`613htqkz`) | interior |
| `bph7wug7bw3xesx1xm9s04pab` | wall | 0.1 | Void (`19ab05tn`), Kitchen (`tt6gm2a0`) | interior |
| `7h0fwxrw8anwxf8kr1u1ny51d` | wall | 0.1 | Void (`19ab05tn`), Living Room (`613htqkz`) | interior |
| `hb1x5sz2m1252ct7y3bsykd4c` | wall | 0.16 | Living Room (`613htqkz`) | exterior |
| `8mcwmbj2prn` | wall | 0.1 | Living Room (`613htqkz`), Kitchen (`tt6gm2a0`) | interior |
| `2xx7kdxfni2d2ctpe6aet14wc` | wall | 0.16 | Living Room (`613htqkz`) | exterior |
| `ppcw8gq5qcqumrzacayyxqeyb` | wall | 0.1 | Living Room (`613htqkz`), Kitchen (`tt6gm2a0`) | interior |
| `r6bq3ft32xq2umw4n19x2humc` | wall | 0.09 | Living Room (`613htqkz`), Bathroom (`2qdmc5i9`) | interior |
| `2e1wiqcbuds5hkesrsnmxwy1b` | wall | 0.09 | Living Room (`613htqkz`), Closet (`3m54yff1`) | interior |
| `m872ugyri48xxdxsudk6rz8db` | wall | 0.16 | Living Room (`613htqkz`) | exterior |
| `as9qzfixea6rkpss24y8n97ad` | wall | 0.16 | Living Room (`613htqkz`) | exterior |
| `0pvw97vy8rm` | invisible | 0.02 | Living Room (`613htqkz`), Hallway (`9hauvfhw`) | interior |
| `senfcw3i001` | wall | 0.1 | Hallway (`9hauvfhw`), Kitchen (`tt6gm2a0`) | interior |
| `xcwpf5sndcs3yexpfaixszmpa` | wall | 0.1 | Hallway (`9hauvfhw`), Bedroom (`cdz3fkt3`) | interior |
| `6y1phyhrm7ggarn9r2xw0a9pa` | wall | 0.1 | Hallway (`9hauvfhw`), Bedroom (`xy2x8mpa`) | interior |
| `28r4kkhg88wewgmby5smic5nd` | wall | 0.1 | Hallway (`9hauvfhw`), Closet (`3m54yff1`) | interior |
| `d1y02epwaq89zk2uns6m7ehpb` | wall | 0.1 | Hallway (`9hauvfhw`), Bathroom (`h26t7ky7`) | interior |
| `rue17w6x9hzcpbnh6tkkbwpyb` | wall | 0.1 | Bedroom (`cdz3fkt3`), Bathroom (`2qdmc5i9`) | interior |
| `k53qrauguyc6m7yb8u7fh98ad` | wall | 0.1 | Bedroom (`cdz3fkt3`), Closet (`3m54yff1`) | interior |
| `xpgyhy80hkfn4qaipyar4kb6d` | wall | 0.16 | Bedroom (`cdz3fkt3`) | exterior |
| `t80ruu4w6u5muc0eg336ge2rd` | wall | 0.1 | Bedroom (`cdz3fkt3`), Closet (`a5f9age4`) | interior |
| `fswu9yp4uzqufg5k1czen91fb` | wall | 0.16 | Bedroom (`cdz3fkt3`) | exterior |
| `6bd43dw17gn3ufmrs6ugpa0db` | wall | 0.11 | Bedroom (`xy2x8mpa`), Bathroom (`h26t7ky7`) | interior |
| `afi1z231xn7y5dp4etzdga81b` | wall | 0.1 | Bedroom (`xy2x8mpa`), Closet (`a5f9age4`) | interior |
| `3gm46e36zfrwkceurd0e23mkb` | wall | 0.16 | Bedroom (`xy2x8mpa`) | exterior |
| `f95keie94xqn95kkztkunwked` | wall | 0.16 | Bedroom (`xy2x8mpa`) | exterior |
| `aucwirnxgthxdhd5ft0gnar0c` | wall | 0.18 | Kitchen (`tt6gm2a0`), Bathroom (`h26t7ky7`) | interior |
| `xk775c0y1zn0h2ngxhad90ytd` | wall | 0.16 | Kitchen (`tt6gm2a0`) | exterior |
| `7fstrpq9ppw15p4ggyq0cr8yb` | wall | 0.16 | Kitchen (`tt6gm2a0`) | exterior |
| `y8n2xp8agny7uiy20wzhtp7kc` | wall | 0.16 | Kitchen (`tt6gm2a0`) | exterior |
| `9ectf8fk1r8aq5kc1it8g3bca` | wall | 0.16 | Bathroom (`h26t7ky7`) | exterior |
| `9rennx0f7b1fkz13zaupezakb` | wall | 0.09 | Closet (`3m54yff1`), Bathroom (`2qdmc5i9`) | interior |
| `11qhqtug09p4uf2b5phnh6mad` | wall | 0.16 | Bathroom (`2qdmc5i9`) | exterior |
| `bprcix10dd8q1atkiu4m21k5c` | wall | 0.16 | Closet (`a5f9age4`) | exterior |

## Openings (doors & windows)

Position: `relativeCenter` (0–1 along the parent edge) and `lowerElevation` (m). Connectivity derived from the parent edge's rooms.

| opening id | type | label | parent edge | width (m) | height (m) | relCenter | lowerElev (m) | connects / exterior |
|---|---|---|---|---|---|---|---|---|
| `88sf4qk72ndeemgtz7mi48sib` | doorway | door-unknown | `52311kt2` | 0.682 | 2.075 | 0.515 | -0.002 | connects Closet (`m8npxsuk`) ↔ Hallway (`9hauvfhw`) |
| `8m2z4z3diycq9rdkm3n1cedea` | doorway | door-unknown | `8mcwmbj2` | 0.891 | 2.077 | 0.103 | -0.013 | connects Living Room (`613htqkz`) ↔ Kitchen (`tt6gm2a0`) |
| `i29m24u412efazaacs1rminta` | window | window-unknown | `m872ugyr` | 1.863 | 1.801 | 0.207 | 0.247 | **exterior** (only Living Room `613htqkz`) |
| `5bmtziqpc4ey2rhpem0a66gka` | window | window-unknown | `m872ugyr` | 1.840 | 1.797 | 0.821 | 0.276 | **exterior** (only Living Room `613htqkz`) |
| `0s3c7t6b07uzr0yizazsri18c` | doorway | door-unknown | `m872ugyr` | 1.006 | 2.054 | 0.442 | -0.023 | **exterior** (only Living Room `613htqkz`) |
| `zpiasxdrw5uug355sgtb6r1bd` | doorway | door-unknown | `xcwpf5sn` | 0.788 | 2.065 | 0.396 | -0.004 | connects Hallway (`9hauvfhw`) ↔ Bedroom (`cdz3fkt3`) |
| `3inp1mcm5s9c2611z7k2ypydd` | doorway | door-pivot | `6y1phyhr` | 0.794 | 2.067 | 0.516 | -0.006 | connects Hallway (`9hauvfhw`) ↔ Bedroom (`xy2x8mpa`) |
| `qyurp6811uru46e2741m77urc` | doorway | door-unknown | `d1y02epw` | 0.681 | 2.071 | 0.668 | -0.006 | connects Hallway (`9hauvfhw`) ↔ Bathroom (`h26t7ky7`) |
| `n11hdn73c1aer39054z5zef3b` | doorway | door-pivot | `rue17w6x` | 0.585 | 2.074 | 0.690 | -0.008 | connects Bedroom (`cdz3fkt3`) ↔ Bathroom (`2qdmc5i9`) |
| `hczati4p8zruyqgk9rrb9qgqd` | doorway | door-unknown | `k53qraug` | 1.151 | 2.159 | 0.632 | -0.011 | connects Bedroom (`cdz3fkt3`) ↔ Closet (`3m54yff1`) |
| `bezuarud8mhf0up7yzm2dn4gb` | window | window-unknown | `fswu9yp4` | 1.241 | 1.799 | 0.503 | 0.269 | **exterior** (only Bedroom `cdz3fkt3`) |
| `nh53f9p699bq3fatzq6fsic8a` | doorway | door-pivot | `afi1z231` | 0.722 | 2.077 | 0.524 | -0.008 | connects Bedroom (`xy2x8mpa`) ↔ Closet (`a5f9age4`) |
| `9ds7syes8t5hca0g4dtdm6qed` | window | window-unknown | `3gm46e36` | 1.244 | 1.806 | 0.503 | 0.267 | **exterior** (only Bedroom `xy2x8mpa`) |

## Panorama locations

| pano id | label | position (x,y,z) | room |
|---|---|---|---|
| `s2aku4p0w9zrxa8ts25c1h80d` | 10 | (-9.394, -1.858, 1.271) | Bedroom (`xy2x8mpa`) |
| `wasy210urp94nunpefi1whsid` | 1 | (-0.955, -0.664, 1.275) | Living Room (`613htqkz`) |
| `qkgte113ywpz68y5rb8i7w5ud` | 2 | (-1.769, 1.287, 1.278) | Living Room (`613htqkz`) |
| `qcnh773ye5c74yf168aih6rbd` | 7 | (-5.809, -0.622, 1.281) | Bathroom (`h26t7ky7`) |
| `sc8sntzpq7negkpnu6chik7hd` | 14 | (-9.192, 2.594, 1.293) | Bedroom (`cdz3fkt3`) |
| `tc4isetcrb96f87dgbhbcfpib` | 11 | (-9.166, -0.735, 1.269) | Bedroom (`xy2x8mpa`) |
| `dxnchmd4kuyk6edzih4r9pxkb` | 12 | (-9.239, -0.025, 1.274) | Closet (`a5f9age4`) |
| `kdczx7s82gzp8ka44a2dz5yyc` | 6 | (-5.746, 0.307, 1.281) | Hallway (`9hauvfhw`) |
| `8xqd4p9fbp6pnhxxb3qny5yxb` | 18 | (-5.771, 3.134, 1.294) | Bathroom (`2qdmc5i9`) |
| `ae9bx05k91arsenmzqnakxqpa` | 15 | (-7.038, 2.939, 1.286) | Bedroom (`cdz3fkt3`) |
| `f6xt5f00dt57318beh64e5meb` | 13 | (-6.902, 1.266, 1.290) | Bedroom (`cdz3fkt3`) |
| `6y2p9yra1knrxxtciaw40uymd` | 17 | (-5.934, 1.667, 1.279) | Closet (`3m54yff1`) |
| `gfs36hea9yuztmcxutkf38ipa` | 3 | (-1.998, 0.313, 1.274) | Living Room (`613htqkz`) |
| `s7ez34cs191mhxw2sp0mhp6ic` | 0 | (0.000, 0.000, 1.271) | Living Room (`613htqkz`) |
| `m80qarcm1bh3hh6ryfteardeb` | 9 | (-7.137, -0.754, 1.272) | Bedroom (`xy2x8mpa`) |
| `18pgiyek12dyt51p11x9eedkb` | 4 | (-3.359, 0.292, 1.272) | Living Room (`613htqkz`) |
| `whw7m0qh329k22bsnzmkz69nd` | 8 | (-6.781, 0.313, 1.275) | Hallway (`9hauvfhw`) |
| `19g75rmsbnz9hrshfbpynfc0c` | 16 | (-6.516, 2.037, 1.284) | Bedroom (`cdz3fkt3`) |
| `41b9e7kscquqb85y1bp0mazdc` | 5 | (-3.533, -0.861, 1.287) | Kitchen (`tt6gm2a0`) |

