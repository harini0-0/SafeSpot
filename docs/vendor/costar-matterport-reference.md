# CoStar × Matterport — vendor reference

> Compiled for the `house` and `guide` modules. The hackathon site itself
> (`beta-app.matterport.com/2026-princeton-hackathon`) is a JavaScript shell that
> returns no readable content without a logged-in browser, so almost everything below
> comes from Matterport's public developer docs. Each item cites its source page.
> **Verbatim** = quoted from the page; everything else is paraphrased. Items marked
> **(needs manual save)** could not be read and should be saved by hand.

## 0. TL;DR for Safe Spot
- **We already have the MatterPak bundle locally** (`data/assets/mp_matterpak_2BR-2BA-933SF_zyzG7fqtBDv.zip`): textured OBJ + MTL + 20 texture atlases + point cloud (`cloud.xyz`) + floorplans. **This is the photoreal "Option A" asset — no further API/mutation needed to render it.**
- The **Model API is server-side only** with admin keys; keys must **not** be embedded in the iOS app. Our `scripts/fetch_assets.py` (server-side) is the right pattern.
- **Cost / "is bundle generation free?" is NOT documented anywhere we could read** (the pricing article is gated). Not confirmed free or paid.

## A. Hackathon site — gated (needs manual save)
Source: `https://beta-app.matterport.com/2026-princeton-hackathon/` (and `#resources`)
- HTTP 200 but only a 77-char JS shell. Title (**verbatim**): "Inside and Out: AI for the Built World · CoStar × Matterport at HackPrinceton".
- Every sub-path tried returned the same shell (no content): `/api-docs, /api-reference, /sdk, /sdk-guide, /quickstart, /quick-start, /models, /model-playground, /playground, /splats, /resources, /event`, and `/resources.json, /config.json, /manifest.json`. `/api` → 404.
- **Needs manual save** (open in a logged-in browser and paste): API docs, model list, API reference, model playground, SDK guide, splats, quick start, event info/rules. None were machine-readable.

## B. Matterport Model API (the one we use)
Source: `https://matterport.github.io/showcase-sdk/api_home.html`, `https://developers.matterport.com/api/`
- **Endpoint:** `https://api.matterport.com/api/models/graph` (GraphQL, all accounts). Account API (`/accounts/graph`) and Import API (`/import/graph`) are Enterprise-only.
- **Reference & console:** `https://api.matterport.com/model/docs/reference`, GraphiQL `https://api.matterport.com/model/graphiql` *(needs manual save / login)*.
- **Auth:** HTTP Basic — username = Token ID, password = Token Secret, preemptive auth on. **Verbatim:** "Our APIs only accept requests from server side scripting." → do not put a token in the app; use a backend/script.
- **Keys:** my.matterport.com → Settings → Developer Tools → API Token Management; up to 5 keys; secret shown once; keys are "admin"/"all-access" and can archive models and **purchase floorplans and Matterpaks**.
- **Sandbox:** default accounts are Sandbox; `models()` is limited to the demo model in Sandbox.
- **Coordinates:** Model API is **Z-up**. SDK↔API conversion: `fromSdkToApi(x,y,z) = [x, -z, y]`, inverse `[x, z, -y]`. *(Confirms our `CoordinateTransform` handling — our model space is Z-up.)*
- **Errors:** `request.unauthenticated, request.unauthorized, request.invalid, error.internal, not.found, not.unique, quota.exceeded`.
- **Support contact (public):** `MP-developer@costar.com`.

## C. Model queries (models, assets, meshes, textures, skyboxes, floorplans, tags)
Source: `.../modelapi_models_ref.html`, `.../modelapi_snippets.html` (second half is a model-extracted summary — re-verify in GraphiQL)
- **Search:** `models(include:, query:, sortBy:, pageSize:, offset:): ModelSearchResultList` → `totalResults, nextOffset, results`. Defaults: 10, created_time desc. `pageSize` 1–1000. `include`: `demo, inactive`.
  - Searchable fields incl.: `id, name, description, visibility, demo, address.*, floors.count, rooms.count, mattertags.count, measurements.count, assets.panos.count, assets.photos.count, assets.meshes.count, assets.textures.count, assets.locations.count, assets.panoLocations.count, assets.panoLocations.placement`.
  - Example (**verbatim**): `models(query: "assets.panoLocations.placement: \"UNPLACED\"")`.
- **Per-model:** `model(id: $modelId)` with snippets `getModelDetails`, `getSweeps` (locations, panos, **skybox**), `getTags` (`mattertags(includeDisabled: true)`), `getDimensions` (model, floors, rooms).
- **Skybox:** `skybox(resolution: "2k")`. Resolutions: 512×512 (low), 1024×1024 (high), 2048×2048 (2k). **4096×4096 requires the "Advanced Imagery Bundle" add-on** (business/Enterprise). Fields: `id, status, format, children` (6 cube-face URLs). *(We already pulled 4k faces for this model, so the add-on is enabled for it.)*
- **Mattertags:** fields `id, floor, label, description, icon, keywords, media, mediaType, position, anchorPosition, discPosition, stemNormal, stemLength, stemEnabled, stemDirection(deprecated)`.
- **Floorplans (summary, re-verify):** `getColoredRooms` (floorplan assets filtered by a `photogramy` flag).
- **Defurnished view:** `views(types:["matterport.model.defurnished"])`.

## D. Meshes, MatterPak bundles, point cloud, generation/cost
Source: `.../api_home.html` FAQ + live-schema introspection we ran earlier (`scripts/introspect.py`)
- **FAQ (paraphrased):** the Model API covers "the OBJ mesh file, the point cloud file, panoramic imagery" plus Tags; it "can only currently get and set model details, assets, Mattertags, labels, and bundles."
- **MatterPak unlock (verbatim):** "Once the unlock is requested, please allow up to 15 minutes before querying for the MatterPak™ Bundle."
- **Mutations:** docs mention `unlockModelBundle` (e.g. `bundleId: "floorplan:schematic"`) and `activateAndPurchase` (which runs `updateModelState` + `updateModelAccessVisibility` + `unlockModelBundle`). `generateBundleAssets` is **not in the docs**, but **it IS in the live schema** we introspected (`generateBundleAssets(bundleId, id, ...)`, `unlockModelBundle(...)`). For this model the `matterpak`/`obj` resources read `status: unavailable` via the API.
- **Cost:** **NOT stated** in any readable page. Admin keys "can purchase floorplans and Matterpaks," implying a purchase step, but no price or hackathon-free confirmation was found. Pricing article `support.matterport.com/s/article/Developer-Tools-Pricing-and-Availability` is **gated (needs manual save)**.
- **Bottom line:** we don't need any of this right now — the MatterPak zip is already downloaded locally.

## E. Showcase SDK (browser only — not for native iOS)
Source: `https://developers.matterport.com/`, `.../sdkbundle_home.html`
- Two SDKs: **Showcase Embed SDK** (iframe) and **SDK Bundle** (self-hosted). Both are **browser JavaScript / iframe** — **not usable in a native iOS app** (reference only).
- SDK Bundle latest: `26.5.4_webgl-708-g332adb66f5` (May 30 2026); download `https://static.matterport.com/showcase-sdk/bundle/26.5.4_webgl-708-g332adb66f5/showcase-bundle.zip`.
- Needs an **SDK key** (Account Settings → Developer Tools → SDK Key Management; allow-list your domains). Connect (**verbatim**): `await showcaseWindow.MP_SDK.connect(showcaseWindow)`.
- **Splats (3D Gaussian splats):** not mentioned in any page we could read. **(needs manual save** from the hackathon "splats" resource.)

## F. Not fetched / gated (save by hand)
- `https://support.matterport.com/` and the pricing article (JS shell / CSS error).
- `https://api.matterport.com/model/docs/reference`, `.../model/graphiql` (login).
- Showcase-SDK pages not read: quick-starts (`sdk_quickstart.html`, `sdkbundle_quickstart.html`), Postman collection, Views and Layers, GeoCoordinates, Ordering Add-Ons, Property Intelligence, Webhooks, Import/Account/OAuth.
- `matterport.github.io/platform-api-docs/` → 404 (dead link).

---

## The 5 most useful things for `house` + `guide`
1. **The MatterPak zip is the photoreal unlock, already in hand.** `…/mp_matterpak_…zyzG7fqtBDv.zip` has the textured **OBJ + MTL + 20 texture atlases + point cloud + floorplans**. Converting OBJ+MTL+textures → USDZ makes the 3D walkthrough **photoreal and continuous** (fixes the "clay"). No API call needed.
2. **Keep all Matterport API calls server-side.** Admin keys can purchase/modify and must never ship in the app (docs: server-side only). Our `scripts/fetch_assets.py` pattern is correct; the app bundles the already-fetched assets.
3. **Coordinate convention confirmed: Model API is Z-up**, and SDK↔API is `[x,-z,y]` / `[x,z,-y]`. This matches our `CoordinateTransform` (model Z-up → scene y-up), so our mesh/pano/room alignment is on the right basis.
4. **4K skyboxes need the Advanced Imagery add-on — and it's already enabled for our model** (we downloaded 4k faces). So Photo mode's high-res panoramas are legitimately available; no further unlock needed.
5. **The Showcase SDK is browser-only — not a shortcut for our native app.** We correctly build rendering ourselves in RealityKit; the SDK is only a web reference. (And `mattertags`/`measurements`/`objects` queries exist if we ever want object data, though this model has none — Phase O remains the path.)

**Open gaps to confirm by hand (logged-in browser):** hackathon event rules & quick-start, whether bundle generation/download is free for the hackathon, and whether "splats" (Gaussian splats) are offered for our model.
