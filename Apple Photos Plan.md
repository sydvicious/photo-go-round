# Summary

Apple Photos as a source kind: albums and smart albums from the system Photos library, enumerated and materialized by the agent, added from the Mac app. Subordinate to `PLAN.md`, which places this in Phase 3, and to `app/mac/FEATURES.md`, which owns what the panel looks like.

# Rationale

The window is showing a test folder. Every architectural claim this project has made about a source that is *not* a path — that a new kind is a new provider rather than a migration, that the source endpoint exists for kinds the app cannot see, that every privacy grant lives on the agent's bundle — is unproven until one exists, and Apple Photos is the only such kind before Phase 11. It is also the kind that decides whether "give me the bytes for this identifier" survives contact with an asset whose bytes are on somebody else's computer. Google Photos inherits whatever this settles, so getting it wrong here is a mistake that is made twice.

# Phases

- **Phase 1 — the spike.** — **run 2026-08-25. The approach holds; four things in this document do not.** `pgr_ctl photos-spike`, and no change to the kit at all. PhotoKit stays out of `PhotoGoRoundKit` until the measurements say the approach holds.
  - Request authorization; list albums and smart albums with identifier, title, subtype, and image count.
  - Time the fetch against the largest album, with `phys_footprint` sampled, so laziness is observed rather than assumed.
  - Pull N originals and compare each written file's `CGImageSource` pixel dimensions against `PHAsset.pixelWidth`/`pixelHeight`.
  - Classify each asset local or iCloud-optimized by attempting `isNetworkAccessAllowed = false` first, then retrying with `true`.
  - Print an edited photo's `.photo` and `.fullSizePhoto` side by side; print a Live Photo's whole resource list.
  - **Exit gate: the numbers exist and say the design works.** A written original that matches the asset's own pixel dimensions on an iCloud-optimized asset, a throughput figure split into local and downloaded, and a peak footprint that does not track the largest file pulled.
  - **Met.** Every written file matched its asset's dimensions, including downloaded ones. Footprint moved 16 kB writing 3.4 MB and nothing at all writing 2.9 MB — it does not track file size. Latency does not follow size either, but what governs it is not yet established. Numbers in *What Phase 1 measured*.
- **Phase 2 — the provider.** `PhotosCollectionSourceProvider` in the kit for `SourceKind.photosCollection`, behind a `PhotoLibrary` protocol seam the way `FolderSourceProvider` sits behind `FileAccess`.
  - `enumerate`, streaming; `existence`; `availability` from authorization status; `materialize` via `PHAssetResourceManager`.
  - Tests against a fake `PhotoLibrary`, so provider logic is exercised with no library and no TCC grant.
  - **Exit gate: `pgr_ctl` adds an album and the pool fills from it.**
- **Phase 3 — admitting a source that is not a path.** The only part of this work that is not additive.
  - `SourceStore.add` stops refusing every kind that is not `isFileBacked`.
  - `SourceRequest.resolve` gains a branch that validates a collection identifier by asking the provider, inside the same all-or-none batch rule.
  - `SourceSpec.init` stops appending a trailing slash to things that are not paths.
  - **Exit gate: a bad album identifier is refused at the door, naming itself, and changes nothing.**
- **Phase 4 — the service surfaces.** What the app needs and cannot get for itself.
  - `GET /v1/photos/albums` — identifier, title, subtype, image count.
  - `GET /v1/photos/authorization` and `POST /v1/photos/authorization` — read the state, and raise the prompt.
  - `SourceEndpoint.Wire` gains `title`, because a Photos locator has no last path component to name it by.
  - **Exit gate: `curl` lists the albums and adds one, and the agent is the only process that touched PhotoKit.**
- **Phase 5 — the picker in the app.** `Add from Photos Library…` stops being disabled.
  - A sheet: unauthorized state with an Allow button, then the album list, multiple selection, one `POST /v1/sources`.
  - Photos sources join the existing single list rather than waiting for *Sources by kind, in sections*.
  - **Exit gate: a person who has never opened a terminal can put their Favorites on their screen.**
- **Deliberately not here.** `PHPhotoLibraryChangeObserver`; pinned individual assets (`SourceKind.photosAsset`); the whole library as one source; the panel's per-kind sections. Each is argued below.

# Design Decisions

- **The agent owns the Photos grant, and the app never links PhotoKit.** `Scripts/make-agent-bundle.sh` already writes `NSPhotoLibraryUsageDescription` into `com.sydpolk.photogoround.server` and says why. One bundle, one consent, one entry in the Settings privacy list.
- **The album list comes over HTTP, for that reason and no other.** It would be trivial for the app to fetch its own `PHAssetCollection`s, and doing so would be a second TCC grant on a second bundle — which is the thing `PLAN.md`'s *TCC: unsandboxed does not mean unrestricted* decided against.
- **The spike changes nothing in the kit.** A measurement that requires a schema, a provider, and a registration to run is not a spike, it is Phase 2 with a worse name.
- **`.readWrite` authorization, because there is no read-only level.** `PHAccessLevel` has exactly `.addOnly` and `.readWrite`, and `.addOnly` grants writing only. Reading an album requires `.readWrite`; the usage string is where the asymmetry gets explained.
- **Storage is always `.materialized`.** There is no path to reference. A Photos asset's bytes are ours only once we have copied them. **Re-examined after the spike found that Photos retains downloaded originals, and upheld: the double storage cost is worth paying.**
- **A collection that stops resolving is `.offline`, never `.gone`.** `PLAN.md` is explicit: switching system libraries fails every stored identifier at once, and answering `.gone` would delete a library over it.
- **`.fullSizePhoto` when present, `.photo` otherwise, matched on exact resource type.** The first is the edited render, the second the original. Measured against a real Live Photo, the resource to avoid is **`.fullSizePairedVideo`** rather than `.pairedVideo`: it sits immediately before `.fullSizePhoto` in the list and is called `FullSizeRender.mov` against the photo's `FullSizeRender.heic`, so any prefix, position, or filename heuristic takes a movie.
- **Videos are excluded at the fetch**, by `PHFetchOptions.predicate` on `mediaType == PHAssetMediaType.image.rawValue`, so they never enter the row set at all.
- **`requestData` rather than `writeData` for materialize.** Both stream. Only `requestData` returns a request id and can be cancelled — an abandoned `writeData` keeps running in the daemon and may still deliver its file, so a source that times out repeatedly accumulates work we can neither see nor stop.
- **A fetch may stall for five minutes, and that is designed around rather than explained.** Three of five downloads paid a fixed 300-second toll before transferring normally. The cause is not pursued; every decision below assumes it can happen to any asset at any time.
- **No materialize timeout below 305 seconds.** A bound that sounds generous — sixty seconds, two minutes — would have failed three of the five measured downloads, each of which then succeeded at 301.5 s. The bound exists to stop a fetch holding a slot forever, not to make it quick.
- **`downloadConcurrency` above one for Photos, whether or not stalls overlap.** With one in flight, a single stalled asset idles the whole source for five minutes and nothing says why. Several in flight keeps the queue moving past it, which holds even if `photosd` serialises the work.
- **A stalled asset goes to the back of the queue, not into a retry.** There are thousands of others and some fraction of them are in the fast mode.
- **The panel never estimates time remaining for a Photos fill.** The distribution is bimodal — the measured mean of 181.5 s described no fetch that actually happened. Progress is reported as a count.
- **A Photos photo enters the pool at scan time and the deck only once its bytes are cached.** The rule videos already follow. It deletes the skip-and-re-deal machinery, and gives the deck the invariant that everything in it can be served now.
- **A dealt card that cannot be served burns its place in the pass.** It is not returned. Gating deck membership on the cache keeps that population near zero, which is what makes burning affordable.
- **The album list is not counted by fetch on every request.** 439 collections cost 34 seconds, at a flat ~78 ms each regardless of size, and `estimatedAssetCount` is `NSNotFound` for every smart album. Neither documented route survives this library.
- **The allowlist has a size test as well as a usefulness test.** At ~3 MB an original, Favorites is 25 GB against a 50 GB ceiling and Recents is 288 GB. An album that cannot fit would churn the cache — though **corrected on the second run**: that churn costs disk, not latency, because a Photos eviction is a 3 ms re-materialize and not a network fetch.
- **`requestData`, cancelled on its first chunk, is the availability probe.** 13.9 ms median, and right about all six assets that were then fetched. `PHImageResultIsInCloudKey` answers about a rendition rather than the original resource, and disagreed 3 times in 45 across two albums — every one in the same direction.
- **A `PhotoLibrary` seam, mirroring `FileAccess`.** PhotoKit cannot be exercised in a unit test without a real library and a TCC grant, so the provider's logic goes behind a protocol and the PhotoKit binding stays thin enough to read in one sitting.
- **Albums and smart albums only, for now.** Favorites is a smart album, so the kind the user actually asks for is covered. Pinned assets and a whole-library source are additions rather than completions, and both are argued below.
- **Photos joins the existing single list in the panel.** Sections are a real improvement and a separate piece of work; making this feature depend on reworking rows that already work would be the third time scope discipline got spent on presentation.
- **Watching is separable and is held.** `PHPhotoLibraryChangeObserver` is Phase 3 work in `PLAN.md`, but it is a change to how the pool *notices*, not to how a source is added, and folding it in would mean two unproven mechanisms failing at once.

# Background

`PLAN.md` Phase 3 asks for the Apple Photos provider alongside the Mac app's window, and asks for a spike first: confirm `PHAssetResourceManager` returns true originals for iCloud-optimized assets, and measure throughput. Nothing about it has been built. The kit imports Foundation and nothing else.

The scaffolding, however, is all there and has been since the first commit. `SourceKind.photosCollection` and `.photosAsset` exist as constants. `SchemaV1`'s comments name `PHAssetCollection` and `PHAsset` identifiers as things `locator` and `external_id` will hold. `SourceProvider` is `async` on both operations specifically because PhotoKit suspends and the folder provider does not — the doc comment says so. `SourceStore.EditFailure.unsupportedKind` names "a Photos album, today" as the case it exists for. The agent's bundle script carries the usage string. What is missing is one provider and the branch that lets a non-path source through the door.

The app is a client and stays one: it reads `servicePort` from preferences, asks the agent, and draws the answer. It is unsandboxed and links the kit, which is why it can answer *where a folder source stands* without a round trip — and precisely why it cannot answer the same question about an album, which `app/mac/FEATURES.md` records as the reason the source endpoint is not going away.

# Detailed discussions

## What Phase 1 measured

_Three runs, 2026-08-25, against a 95,901-photo library on one Mac: `-n 6` at 16:42; `-n 6 --probe 30` five hours later at 22:12; and `-n 1 --probe 10 --album "Live Photos"` at 22:19. Small samples, one library, one connection, one day; read every number that way. What is **not** yet measured is listed at the end._

### The exit gate is met

Every one of the six written files matched the pixel dimensions its `PHAsset` reported, **including the five that had to be downloaded**. `PHAssetResourceManager.writeData` returns true originals for iCloud-optimized assets, which is the claim the whole design rests on and the one that could have invalidated it. The fallback to `PHImageManager.requestImageDataAndOrientation` is not needed.

### `.readOnly` authorization does not exist

`PHAccessLevel` has two values, `PHAccessLevelAddOnly = 1` and `PHAccessLevelReadWrite = 2`. There is no read-only level: `.addOnly` grants saving into the library and nothing else, so reading an album at all requires `.readWrite`. The Design Decision that said otherwise could not be implemented as written. `NSPhotoLibraryUsageDescription` remains the right key, and the usage string is the only place the asymmetry can be explained to the person being asked.

### A command-line tool cannot raise a TCC prompt without an embedded `Info.plist`

The first attempt to run the spike returned `denied` **instantly, with no prompt**, which on a console is indistinguishable from a user clicking Don't Allow. A bare Mach-O carries no `Info.plist` and therefore no usage string, and TCC refuses rather than prompting. `Package.swift` now `-sectcreate`s one into `__TEXT,__info_plist`.

The responsible-process question is sharper than this plan anticipated. TCC attributes the request to whatever launched the tool, so the grant lands on Terminal — or on whatever other application's shell it was run from, which in practice made the difference between the request being promptable and not. The Phase 4 check against the installed agent bundle is not a formality.

### Listing albums costs half a minute, and the cost is per album

439 collections took **34,005 ms** to count, and **31,392 ms** on the second run five hours later — so this reproduces, and it is a property of the library rather than of a moment. The cost is flat and has nothing to do with album size:

| collection | photos | counted in |
|---|---|---|
| Recents | 95,901 | 116.8 ms |
| Favorites | 8,477 | 31.3 ms |
| any `albumRegular` | 1 to 3,071 | ~78–90 ms |
| any `albumCloudShared` | 10 to 4,804 | ~50 ms |
| most smart albums | — | 2–6 ms |

A one-photograph album costs 80.6 ms and a 95,901-photograph album costs 116.8 ms, so this is not a scan. It is a fixed toll paid ~440 times, which points at a round trip rather than computation.

**And the documented cheap answer is unavailable exactly where it is needed.** `PHAssetCollection.estimatedAssetCount` returned `NSNotFound` for *every* smart album — Recents, Favorites, Live Photos, all of them — and a usable number only for `albumRegular` and `albumCloudShared`. Favorites is the album a person actually asks for, and it is in the half with no estimate.

So `GET /v1/photos/albums` cannot count on demand by either documented route. Whatever Phase 4 does, it is not this.

### Enumeration is lazy on the fetch and not on the walk

```
fetch  111.6 ms    footprint 23.1 MB   (+0 bytes)
walk   3,281.4 ms  footprint 165.7 MB  (+142.7 MB)  · 95,901 assets
```

`PHAsset.fetchAssets` returns in milliseconds and costs nothing, exactly as documented and as `PLAN.md`'s *Cold start* assumes. Walking the result retained **142.7 MB** — about 1.5 kB per asset — and did not give it back.

It scales linearly and reproduces: 141.5 MB over 95,901 assets is 1.48 kB each, and a separate walk of the 6,898-asset Live Photos album retained 12.1 MB, or 1.75 kB each. This is per-asset retention, not a fixed cost.

This lands on `PLAN.md` rather than on this document. The constant-memory scanner does not survive a full walk of a large album as written. Whether the retention is `PHFetchResult`'s own object cache or undrained autoreleased objects is **not measured**, and the two have different fixes: batched `enumerateObjects` over index ranges in the first case, a drain per batch in the second. Guessing between them is exactly what a spike exists to prevent.

### The resource-selection rule holds, and the trap is not the one named

In an ordinary album:

```
edited     .photo (014_14.JPG) · .adjustmentData (Adjustments.plist) · .fullSizePhoto (FullSizeRender.jpeg)
unedited   .photo (IMG_0023.JPG)
```

`.fullSizePhoto` appeared only alongside `.adjustmentData`, so it does track a real edit.

A third run aimed at the `smartAlbumLivePhotos` album reached the case the rule most needed to survive. An **edited** Live Photo carries five resources, two of them QuickTime movies, in this order:

```
.photo                public.heic                 IMG_2650.HEIC
.adjustmentData       com.apple.property-list     Adjustments.plist
.pairedVideo          com.apple.quicktime-movie   IMG_2650.MOV
.fullSizePairedVideo  com.apple.quicktime-movie   FullSizeRender.mov
.fullSizePhoto        public.heic                 FullSizeRender.heic
```

An **unedited** one carries two, `.photo` (`IMG_3309.JPG`) and `.pairedVideo` (`IMG_3309.MOV`).

The rule picks correctly — the pull returned `.fullSizePhoto`, 1.7 MB, 4032×3024, matching the asset's dimensions — but **the hazard this document names is the wrong one**. `.pairedVideo` is easy to avoid. `.fullSizePairedVideo` is not:

- It sits **immediately before** `.fullSizePhoto`, so scanning for a "full size" variant and taking the first match yields the movie.
- It is named **`FullSizeRender.mov`** against the photo's **`FullSizeRender.heic`**, so a filename heuristic yields the movie too.
- Two of the five resources are movies, and the one that most resembles what we want is one of them.

Matching on exact `PHAssetResourceType` is the only formulation that survives this. The symptom of getting it wrong is the one this document already describes — photographs vanishing three deals at a time — and the near-miss is far closer than "never `.pairedVideo`" implies.

**Originals are a mix of HEIC and JPEG.** `.photo` was `public.heic` on the edited asset and `public.jpeg` on the unedited one, so the cache holds both. `CGImageSource` read the HEIC without special handling, which the dimension check confirms.

### `writeData` streams

| file | peak footprint | retained |
|---|---|---|
| 76 kB | +246 kB | +246 kB |
| 596 kB | 0 | −49 kB |
| 1.9 MB | 0 | 0 |
| 2.7 MB | +49 kB | +49 kB |
| 2.9 MB | 0 | 0 |
| 3.4 MB | +16 kB | +16 kB |

Across a 45× range of file sizes the footprint does not follow the file. A 2.9 MB original was written with **no measurable change at all**. The 246 kB against the first pull is `PHAssetResourceManager` waking up for the first time in the process, which is why the verdict excludes the first pull — the spike's original rule judged on the worst *ratio*, which is dominated by fixed costs on the smallest file, and it duly reported "buffered" against data that says the opposite.

The second run, with every asset local, is cleaner still: **the largest write moved the footprint by nothing at all while writing 3.4 MB** — 0.000× the file, and zero was also the worst of any write in the run.

`PLAN.md`'s case for `PHAssetResourceManager` over `requestImageDataAndOrientation` — that a large original is never held whole in the agent's address space — holds, and now holds on evidence from both directions: the streaming write costs nothing, and the alternative was measured costing 3.6 MB.

One incidental confirmation. A 596 kB original reported **full resolution (rotated)**: 3264×2448 written against an asset reporting the axes the other way round. The spike counts a swap as a match, and without that it would have been flagged as a downscale and chased.

Peak footprint across the whole run was 172.2 MB, essentially all of it the enumeration walk above rather than anything the writes did.

### iCloud latency does not follow file size, and is not yet explained

| file | pixels | elapsed |
|---|---|---|
| 76 kB | 640×480 | 301,456.5 ms |
| 3.4 MB | 3504×2336 | 301,588.4 ms |
| 2.7 MB | 2336×3504 | 1,530.2 ms |

Across all five downloads — 11.5 MB in 907.5 s, min 1.5 s, median 301.5 s, max 301.6 s — the outcomes are **bimodal, not distributed**: approximately 1.5 s, 1.4 s, 301.5 s, 301.5 s, 301.6 s. Nothing lands in between, and the slow mode is the fast mode plus 300.0 s to within a tenth of a second. Three of five fetches paid it.

So the picture is a ~1.5 s transfer with a fixed five-minute stall in front of it, taken or not taken. `writeData`'s `progressHandler` on the slow ones reported 70% and 90% in the same second the transfer completed: dead wait, then an instant transfer.

**The aggregate rate is meaningless and should never be quoted.** "13 kB/s across five assets" describes the stall, not the network; when bytes actually move they move at ~1.8 MB/s.

**What decides whether a fetch pays the toll is not established**, and it is now the most consequential open question in this plan, because it is the difference between a first fill of hours and one of weeks:

| assumption | Favorites, 8,477 originals, serial |
|---|---|
| every fetch fast (1.5 s) | ~3.5 hours |
| measured mean (181.5 s) | ~17.8 days |

Candidates, none tested: that the stall is shared rather than per-asset; that it is an artifact of an unbundled process talking to `cloudphotod`; that the preceding `isNetworkAccessAllowed = false` probe provokes it; or that `requestData` behaves differently from `writeData` here.

One of them can be argued down from the data already in hand. The slow fetches were not front-loaded — the first download paid the toll, the second ran in 1.5 s, and slow ones recurred after it. A shared resource waking up would produce one slow fetch and then a fast tail. **The stall is per-asset, not per-session.**

**Decided: the cause is not pursued.** Divining it would mean instrumenting somebody else's daemon to explain behaviour that may not survive the next OS release, and the design has to tolerate the stall whether or not we understand it. It is recorded as a constraint, and the Design Decisions above are what tolerating it costs:

- no timeout below 305 s, because a shorter one converts the slow mode into a failure;
- `requestData`, because a bound on an uncancellable `writeData` buys back only our own control;
- more than one fetch in flight, so a stalled asset does not idle the source;
- stalled assets to the back of the queue rather than into a retry;
- and no time estimates anywhere, because the mean of a bimodal distribution describes neither mode.

What makes all of this survivable is a decision taken before the stall was known about: deck membership is gated on the bytes being cached, so nothing a person is looking at ever waits on a fetch.

The classification probe itself works. `isNetworkAccessAllowed = false` succeeded in 2.6 ms on a genuinely local asset and failed in about 2.5 s on a remote one, so the two-call scheme in *Classifying without private API* is sound.

**Downloads persist.** An asset fetched in one run came back `local` in 2.6 ms in the next, which means the spike is not repeatable in the direction that matters: re-running over the same album converges to all-local and the latency figures evaporate.

### Photos retains downloaded originals, and our cache is a second copy

The second run re-pulled the identical six assets five hours later. **Every one came back local, at full resolution, in 1.8–3.7 ms** — including a 5712×4284 original. Photos keeps what it downloads, and keeps the original rather than a derivative, which was the failure mode that would have been easiest to miss.

The probe's wider sample is the control, and it rules out the obvious confound. The Mac's own wallpaper and screensaver were running from Photos throughout those five hours, so "all six are local" could have meant the system had warmed the library generally. It had not:

- **8 of 35 assets already here, 27 in iCloud.**
- Six of those eight are the ones we downloaded.
- So of the 29 nobody has touched, **two are local — about 7%**, against 100% of the six we fetched.

Retention is ours, not ambient. Incidentally that 7% is also the first honest estimate of how cloud-optimized this library is, and it makes first fill a mostly-download proposition rather than a mixed one.

**This corrects a Design Decision made earlier the same day.** Eviction from *our* cache does not cost a network fetch, because Photos still has the original; it costs a 3 ms re-materialize. The churn argument behind the allowlist's size test survives only as an argument about disk space.

### Retention reopened the storage decision, and it was upheld

*Storage is always `.materialized`* was decided before any of this was measured, on the reasoning that a Photos asset's bytes are ours only once copied. The retention finding genuinely complicates that: if Photos holds the original locally and hands it over in single-digit milliseconds, a Photos asset resembles a `.referenced` file — bytes that live elsewhere, cheaply checked, fetched when wanted — more than it resembles something that must be copied. Not copying would save a second copy of a 25 GB album.

**Decided: we copy anyway, and the double storage cost is worth paying.** The reasons, in the order they matter:

**Photos' retention is not a promise.** "Optimize Mac Storage" evicts local originals under disk pressure, with no notification and no change to the asset's identifier. A `.referenced` Photos source could therefore go dark in bulk at a moment of the system's choosing — the same shape of failure as the library switch that `.offline` exists for, but arriving quietly and partially.

**It would put the probe in the serving path.** Deck membership is gated on the bytes being cached precisely so that everything in the deck can be served now. If the bytes are Photos' rather than ours, that invariant becomes a 13.9 ms question asked per deal, on an answer that can have changed since enumeration — which is the skip-and-re-deal machinery this plan already deleted once.

**Renderings have to be cached regardless.** The cache exists for them whatever happens to originals, so `.referenced` would not remove a mechanism, only shrink what passes through it.

**`.referenced` means something narrower than "the bytes exist somewhere".** In `PLAN.md` it means a stable path on a volume that can be `stat`ed. A Photos local identifier is not that, and stretching the mode to cover it would put a second meaning inside one storage value.

The cost is real and should be stated plainly: a 25 GB Favorites album occupies about 25 GB in the Photos library and about 25 GB again in our cache, against a 50 GB ceiling. That makes the allowlist's size test load-bearing rather than cautionary, and it is the strongest argument this plan has for a Photos source needing a reserved cache floor.

### The availability probe, measured

Thirty-five assets, both probes on each:

| probe | median | what it answers |
|---|---|---|
| `requestData`, cancelled on first chunk | **13.9 ms** | is the original resource here |
| `requestImageDataAndOrientation` | 4.9 ms | is *a rendition* here |

`requestData` was right about every asset subsequently fetched. Across two albums the two probes disagreed **3 times in 45**, every one in the same direction: `requestData` found the original present while `PHImageResultIsInCloudKey` was set. That is the rendition-versus-resource distinction showing up in real data, and it decides the choice.

The rate was higher in the Live Photos album — 2 of 10 against 1 of 35 — which is what one would expect if a Live Photo's components can differ in availability, the still being here while the paired video is not. That would make `PHImageManager`'s answer true about the asset and useless to us, since the only resource we ever fetch is the still. The probe asking about the resource we would actually take is not incidental to the choice; it is the whole of it.

Extrapolated at 13.9 ms:

| album | assets | probing cost |
|---|---|---|
| Favorites | 8,477 | ~2 minutes |
| Recents | 95,901 | ~22 minutes |

Affordable for an agent on a timer, impossible for a picker, which is the same shape as every other per-asset cost here.

The cheaper probe also put a number on the thing `PLAN.md` rejected it for: **`requestImageDataAndOrientation` held up to 3.6 MB of a single asset in our address space**. On a local asset it hands back the whole original as `Data`. Real, and measured.

### Subtypes this document does not know about

Six subtypes fell outside the documented enumeration, two of them large:

| raw | name | photos |
|---|---|---|
| 1000000218 | Recently Saved | 37,550 |
| 1000000220 | Captured by Me | 8,797 |
| 219 | Spatial | 0 |
| 220 | Screen Recordings | 0 |
| 1000000219 | Recovered | 0 |
| 221 | Dual Capture | 0 |

The allowlist has to say something about the first two, and cannot do it by naming a `PHAssetCollectionSubtype` case that does not exist in the SDK.

### Album titles are not unique

"VHS Band 2024-2025" exists twice — once `albumRegular` at 3,071 photographs and once `albumCloudShared` at 4,804 — and a dozen other titles repeat the same way. The Phase 5 picker will show visible duplicates with nothing to tell them apart, and any lookup by title silently takes the first match.

### The cache ceiling is an allowlist constraint

At roughly 3 MB an original — thin, from this run's two largest files, and low, since the cache holds renderings as well — against the 50 GB `byteCeiling`:

| album | photos | originals |
|---|---|---|
| Favorites | 8,477 | ~25 GB |
| Captured by Me | 8,797 | ~26 GB |
| Recently Saved | 37,550 | ~113 GB |
| Recents | 95,901 | ~288 GB |

A curated album fits with room. The large smart albums do not, and under cache-gated deck membership an album that cannot fit thrashes: download, deal, evict, download again. For a folder source an eviction costs a millisecond re-read; for a Photos source it costs a network fetch. The largest offender is `smartAlbumUserLibrary`, which this document already excludes on other grounds.

### A Swift 6 trap the provider will hit

The second run crashed on its first probe, before any of the above existed to be measured: `dispatch_assert_queue` → `_swift_task_checkIsolatedSwift`, inside `PHAssetResourceRequest`'s data handler.

PhotoKit invokes these blocks on a dispatch queue of its own. Written as bare closures inside actor-isolated code, against block parameters the importer does not mark sendable, Swift infers them as isolated to the enclosing actor and emits an isolation assertion into each — which trips the moment PhotoKit calls back off-main. A hard crash on the first chunk of the first fetch, not a warning.

`PhotosCollectionSourceProvider` will live in `PhotoGoRoundKit`, which builds in Swift 6 language mode, and will call these same APIs from isolated code. **No test against a fake `PhotoLibrary` would catch it**, because a fake never delivers a callback from a dispatch queue. The fix is to annotate each handler's type `@Sendable` explicitly, which removes the inference rather than suppressing the check. Which imported blocks the compiler happens to treat as sendable is not something to rely on: `writeData`'s single completion never tripped it and `requestData`'s two-block form did.

### Still unmeasured

_The 300-second stall is deliberately not on this list. Its distribution is measured and its cause is closed as a constraint rather than a question — see above._

- **Whether the walk's per-asset retention is a fetch-result cache or undrained autoreleases.** Confirmed linear across two album sizes; the mechanism is still a guess, and the two have different fixes.
- **Everything about TCC from the installed agent bundle**, which is Phase 4's and was always going to be.
- **How long Photos' retention lasts.** Five hours, confirmed. What "Optimize Mac Storage" does to it under real disk pressure is the question a `.referenced` design would rest on.

## Why the spike is the whole of the first phase

`PLAN.md` asks for two things before the provider is written, and they are not the same question.

The first is **whether we can get originals at all**. `PHAssetResourceManager.writeData(for:toFile:options:)` with `isNetworkAccessAllowed = true` is documented to stream the original resource to a file. What is not documented, and what has burned people, is what comes back for an asset whose full-resolution copy lives in iCloud and whose local copy is a downscaled derivative. The failure mode is quiet: you get a file, it is a valid JPEG, it opens, and it is 2048 pixels wide instead of 8064. Nothing in the pipeline downstream would notice — the renderer would happily produce a 1000×1000 thumbnail from it, the cache would store it, and the window would show a slightly soft picture. So the check has to be made explicitly, at the one place where the truth is knowable.

The comparison to make is the written file's `CGImageSource` pixel dimensions against `PHAsset.pixelWidth` and `PHAsset.pixelHeight`, which the asset reports without any fetch. Equal means we got the original. Smaller means the design in `PLAN.md`'s *Getting full-resolution originals out of Photos* does not hold and the fallback — `PHImageManager.requestImageDataAndOrientation` with `.highQualityFormat` and `.version(.original)`, which returns `Data` and therefore reintroduces the address-space problem the whole approach exists to avoid — has to be weighed.

The second is **throughput**, and the number that matters is not an average. A library where a third of the assets are optimized behaves completely differently from one where none are, and averaging the two produces a figure that describes neither. So the spike classifies before it measures.

### Classifying without private API

There is no public "is this asset locally available". `PHAssetResource` has a `locallyAvailable` value that is only reachable through `value(forKey:)`, which is private API by another name and not something to build on.

The public probe is better anyway, because it measures the thing rather than asking about it: attempt `writeData` with `PHAssetResourceRequestOptions.isNetworkAccessAllowed = false`. If it succeeds, the asset was local, and the elapsed time is the local read. If it fails, the asset was optimized; retry with `true`, and the elapsed time is the download. One classification and two timings out of two calls, with no guessing.

This also incidentally tests the option that the provider will depend on. If `isNetworkAccessAllowed = false` does *not* fail on an optimized asset — if it silently hands back the derivative instead — that is a far more important finding than the throughput numbers, because it means the flag is not the guard we think it is and every materialize needs a dimension check of its own.

### The edited-photo question, which `PLAN.md` leaves open

*Getting full-resolution originals out of Photos* records the cost of `PHAssetResourceManager` honestly: it gives the original, not the edited render, so a photo cropped in Photos comes back uncropped. It proposes `.fullSizePhoto` when present with a fallback to `.photo`, and says explicitly that this "needs the Photos provider's spike to measure it against a real library."

So the spike prints, for a photograph known to have been edited, the full resource list with type, UTI, and — after writing each — bytes and dimensions. Three things become visible at once: whether `.fullSizePhoto` is present for an edited asset and absent for an unedited one, whether it is the edited render or something else, and whether it is full resolution or a display-sized convenience. The answer decides the provider's resource-selection rule, and it is two lines of code once known and an afternoon of guessing until then.

There is a subtlety worth stating: `.fullSizePhoto` is the adjusted render, but `.adjustmentData` is what actually indicates an edit exists. An asset can carry `.fullSizePhoto` for reasons other than a user edit. Printing the whole list rather than probing for one type is what keeps this honest.

### Live Photos

A Live Photo is `mediaType == .image` with `.photoLive` in its subtypes, so it passes the image predicate — correctly, since it *is* a photograph with a movie attached. Its resource list contains both a `.photo` (or `.fullSizePhoto`) and a `.pairedVideo`, and possibly `.fullSizePairedVideo`.

Taking the wrong one is not a subtle failure. It writes a `.mov` into the cache under a key the renderer will hand to `CGImageSourceCreateThumbnailAtIndex`, which returns nil, which retires the photo after three attempts as unrenderable — so the symptom is *photographs quietly disappearing from the library*, three deals at a time, with a log line about a render failure and nothing pointing at Live Photos. Printing the resource list in the spike costs nothing and makes the rule obvious before it can be got wrong.

### Peak footprint, and why it is in the spike rather than assumed

The claim that justifies `PHAssetResourceManager` over `requestImageDataAndOrientation` is that it streams to a file and never holds the resource in memory. That claim is the reason a 100 MB ProRAW is not a 100 MB `Data` in the agent's address space, and it has never been tested here.

Sampling `phys_footprint` from `task_vm_info` across the run costs about a dozen lines and turns the claim into a measurement. What we want to see is a footprint that does not track the largest file pulled. What would be alarming is a peak that rises with file size, which would mean the write is buffered somewhere and the memory discipline the whole scanner was built around does not survive the Photos provider.

The folder provider's enumeration has an equivalent story already recorded in its own comments — 94 MB across 80,000 files against 12 MB, and the fix that removed the allocation rather than draining it. That number exists because somebody measured. This is the same discipline applied to the one operation whose memory behaviour is a library dependency rather than our own code.

### Enumeration laziness

`PLAN.md`'s *Cold start* asserts that `PHAsset.fetchAssets` is lazy, and the whole constant-memory scanner design depends on that being true for a hundred-thousand-asset library. `PHFetchResult` is documented to fetch lazily, and in practice it does — but "in practice it does" is what the spike is for.

The check: fetch the largest album, sample the footprint immediately after the fetch returns and again after enumerating every object, and time both. A fetch that returns in milliseconds with a flat footprint and an enumeration that costs the time is the answer we want. A fetch that takes seconds and moves the footprint means `PHFetchResult` materialized, and the provider needs a different enumeration strategy — most likely `enumerateObjects` with a batched range rather than index access.

## TCC, and the thing the spike cannot answer

Two processes, two bundles, and only one of them ever touches the library. That is settled and this plan does not reopen it. What it does have to name is that **the spike runs in the wrong process on purpose**, and what that costs.

`pgr_ctl` invoked from a terminal is not a bundle. TCC attributes its Photos request to the responsible process, which is Terminal — so the prompt says Terminal would like to access your photos, the grant lands on Terminal, and `com.sydpolk.photogoround.server` is not mentioned. For the measurements this is irrelevant: PhotoKit does not care which bundle got the grant, only that one did. For the *product* it is the entire question, and the spike answers none of it.

That is the right trade for Phase 1. Reaching the numbers quickly is the point, and the numbers are what could invalidate the design. But it means a separate check belongs to Phase 4 rather than being assumed away: run the same authorization request from the installed `Photo-Go-Round Server.app`, launched by launchd, and confirm the prompt names the server bundle and that the grant persists across a rebuild. That last part is the one with a real trap in it — TCC records the grant against the code signature, and `make-agent-bundle.sh` defaults to ad-hoc signing, which produces a *different* signature on every build. A grant given to one ad-hoc build will not necessarily be honoured for the next, and the symptom is the Photos prompt reappearing, or worse, an agent that silently reports unavailable after a rebuild. The script already warns about this in its `--sign` help text. It is worth confirming rather than trusting.

There is a further wrinkle in the same family. A launchd agent with `ProcessType Background` and `LSUIElement` raising a TCC prompt is a legitimate thing to do, but the prompt arrives with no window behind it to explain itself. `app/mac/FEATURES.md`'s TCC section already worked out the answer for folders — the picker buys timing, and a prompt two seconds after the user chose something in a dialog is legible where an unprompted one is baffling. The same shape applies here, and it is why authorization is a `POST` triggered by the app's Allow button rather than something the agent does at launch or on its own initiative. `PLAN.md`'s *Photos is optional, and there is exactly one of it* is explicit: `requestAuthorization` is called when a Photos source is added, never at launch and never speculatively, and a user who never adds one never sees the prompt.

## What the provider actually does, per operation

### enumerate

Fetch the collection by local identifier via `PHAssetCollection.fetchAssetCollections(withLocalIdentifiers:options:)`. An empty result is the library-switch case, not an empty album — return `.unavailable` and let the source go dark as a unit, which is what `PLAN.md` requires.

Then `PHAsset.fetchAssets(in:options:)` with `PHFetchOptions.predicate` set to `mediaType == PHAssetMediaType.image.rawValue`, and push each asset into the sink as a `DiscoveredPhoto`:

- `externalID` is `asset.localIdentifier`. It is library-scoped and not stable across devices, which `PLAN.md`'s *Why nothing syncs between devices* already accounts for; nothing here needs `PHCloudIdentifier`.
- `mediaType` is `.image` by construction.
- `storage` is `.materialized`, always. There is no file to point at.
- `byteSize` is `nil`. This deserves its own note, below.

The sink contract — never build a collection of the whole source — is satisfied naturally by a `PHFetchResult` walk, provided the laziness check passes.

### The byte-size problem

`DiscoveredPhoto.byteSize` is `Int64?`, and for a Photos asset the honest answer at enumeration time is nil. `PHAsset` does not report a byte size. `PHAssetResource` has `value(forKey: "fileSize")`, which is private API. The only public way to learn the size is to fetch the resource, which is the expensive thing enumeration exists not to do.

Nil is therefore correct rather than lazy, and the question is what depends on it. The cache is bounded by bytes, so the byte accounting has to be right somewhere — but it is right at *materialize* time, where `MaterializedFile` carries the actual size of the file we wrote. What a nil at enumeration costs is the ability to predict, before fetching, how much a source will occupy. Nothing in the current design uses that prediction. Worth confirming during Phase 2 that no path treats a nil `byteSize` as zero in a way that matters to eviction; if one does, that is a bug the folder provider can also hit, on a file whose resource values could not be read.

### existence

Fetch by local identifier. A result means present, an empty result means absent — with one caveat that decides the whole answer: **an empty result also means the library was switched.** Distinguishing them is what `availability` is for, and `SourceProvider`'s contract already handles this correctly. `existence` returns `.absent` and the scanner then asks `availability`; if the source says it cannot be reached, the removal does not happen.

`.unknown` is returned only when authorization is not granted, which is a genuine claim about reachability rather than about effort. The doc comment on `existence` is unusually pointed about this — answering `.unknown` when the truth is `.absent` shows the photo, and some reasons a person deletes a photograph are not benign.

The latency budget is generous, and it is worth using. `PHAsset.fetchAssets(withLocalIdentifiers:)` is a local database query, so this is fast anyway — but the contract says take the time to be right, and if a future version of this needs a network round trip to answer honestly, it should take it.

### availability

Driven by `PHPhotoLibrary.authorizationStatus(for: .readOnly)`:

- `.authorized` — ask whether the collection still resolves. It does: `.available`. It does not: `.offline`, with a reason naming the library switch as the likely cause.
- `.limited` — this is an iOS concept and macOS does not offer it, but it is expressible and the provider should not crash on it. Treat as `.available`, since a limited grant still returns whatever it returns.
- `.denied`, `.restricted` — `.offline`, with a reason that tells the user where to fix it.
- `.notDetermined` — `.offline`. Notably **not** a place to raise the prompt: `availability` is called from the scanner, on a timer, in a background process, and prompting from there is exactly the baffling unattributed prompt the design avoids.

`.gone` is never returned by this provider. That is deliberate and total. The only thing that would justify it is knowing an album was deleted while the library was demonstrably present and readable — and distinguishing that from a library switch requires knowing which library we are talking to, which `PLAN.md` says there is no public way to ask. So the expensive mistake is unavailable to us by construction, which is a good place to be.

### materialize

`PHAssetResourceManager.writeData(for:toFile:options:)`, with `isNetworkAccessAllowed = true`, into the destination the cache handed us. Resource selection follows whatever the spike settles — the working assumption is `.fullSizePhoto` if present, else `.photo`, and never anything else.

Two things the folder provider does not have to worry about:

**Cancellation and progress.** A network fetch of a 100 MB original over a slow connection is a long operation, and `PHAssetResourceRequestOptions` has a `progressHandler`. The queue filler has no notion of a partial fetch and does not need one, but a fetch that hangs indefinitely would occupy a filler slot forever. Whether that needs a timeout is a Phase 2 question, and the honest answer probably depends on the spike's downloaded-asset timings.

**The completion is a callback.** `writeData` is completion-based, so the provider bridges it with `withCheckedThrowingContinuation`. Straightforward, with the one classic trap: resuming twice if the completion is ever invoked more than once. Worth a defensive guard rather than a comment saying it should not happen.

## Admitting a source that is not a path

This is the only part of the work that is not additive, and it is worth being precise about how small it is.

`SourceStore.add` opens with `if let unsupported = requests.first(where: { !$0.kind.isFileBacked })` and throws. That guard was correct when there was no non-file provider and it is the wrong shape now — it asks "is this a path" when the question it means is "is there a provider for this". Replacing it with a check against the registered provider table both admits Photos and keeps the original protection: a kind with no provider is still refused rather than being accepted, never scanned, and reported unavailable forever, which is exactly what `EditFailure.unsupportedKind`'s doc comment says it exists to prevent.

`SourceRequest.resolve` is the more interesting one. It standardizes a path, `stat`s it, checks directory-ness against the requested kind, and appends a trailing slash. Every one of those is wrong for a collection identifier, and the trailing slash is actively harmful — `SourceSpec.init` applies the same rule (`kind == .file || locator.hasSuffix("/") ? locator : locator + "/"`), so an album identifier would be silently stored with a slash appended and would never again match what PhotoKit returns.

The shape that fits: `resolve` branches on whether the kind is file-backed, and for a Photos request validates by asking the provider whether the collection exists. That means `resolve` needs access to a provider, which today it does not have — it is a static function taking a `FileManager`. The least invasive version passes a validator closure, keeping `SourceRequest` free of any dependency on the provider table while `SourceStore.add` supplies one. The all-or-none rule is preserved either way, and it should be: an album identifier that no longer resolves is exactly the typo case the batch refusal exists for, and it names itself in the refusal.

`SourceSpec`'s normalization needs the same branch. The comment there explains the trailing slash as "one spelling, decided here" — the locator is the identity that preferences, reconciliation, and duplicate detection all match on as a bare string. That argument is entirely correct and applies just as much to a collection identifier; it simply means "one spelling" for a Photos source is *the identifier exactly as PhotoKit gave it*, with nothing appended.

### One thing to verify rather than assume

`PHAssetCollection.localIdentifier` has the form `UUID/L0/040` — it contains slashes. Nothing in the source pipeline should care, since a locator is an opaque string everywhere except where paths are constructed from it, and no path is constructed from a Photos locator. But the cache directory is named by the source's `uuid`, not its locator, so that is safe; and the HTTP member route is `/v1/sources/<uuid>`, also safe. The place to check is anywhere a locator reaches a URL or a filename by a route nobody remembered. Grep for it in Phase 3 rather than trusting this paragraph.

## The service surfaces, and why there are two of them

### Browsing

`GET /v1/photos/albums` returns what a picker needs: identifier, title, subtype, image count. Nothing about it is a source — this is the library, not the library's configuration, which is why it is not under `/v1/sources`.

Counting is the one cost. An album's image count is `PHAsset.fetchAssets(in:options:).count` with the image predicate, per album, which is a fetch per album on every request. For a library with a few dozen albums that is fine. For one with several hundred it may not be, and the answer if so is `PHAssetCollection.estimatedAssetCount` — which is documented as an estimate, includes videos, and can be `NSNotFound`. Worth measuring in the spike, since the spike is already listing every album and can time it for free.

Smart albums need a decision the spike will inform: `PHAssetCollectionSubtype` has a couple of dozen values, and several are useless to us (`smartAlbumVideos`, `smartAlbumSlomoVideos`, `smartAlbumTimelapses`, `smartAlbumAllHidden`). Listing them would offer the user a source that can only ever be empty, and `smartAlbumAllHidden` would offer to put their hidden photos on the wall, which is a product decision nobody should make by omission. An allowlist is right; the spike printing every subtype with its count is how the allowlist gets chosen.

### Authorization

`GET /v1/photos/authorization` reads the status and returns it. `POST` calls `PHPhotoLibrary.requestAuthorization(for: .readOnly)` and returns what the user decided.

The `POST` is the interesting one, because it is a request that blocks on a human. The panel's spinner-and-lockout convention already covers this — any action that goes to the agent disables the controls until it lands — but a TCC prompt can sit unanswered indefinitely, and `SourceService` sets `timeoutInterval = 15`. So the app must either raise its timeout for this one request or treat a timeout as "still deciding" rather than as a failure. The second is better: it keeps the timeout honest for everything else, and "still deciding" is a real state the sheet can show.

A `POST` that is refused is not an error. It is an answer, and the sheet's job is to say where to change it — System Settings › Privacy & Security › Photos — rather than to report a failure. `PLAN.md`'s *Showing unavailability* has the governing principle: denial is a state to display, not an error to handle.

### `Wire.title`

`SourceService.Source.name` is `URL(filePath: locator).lastPathComponent`. For `A1B2C3D4-.../L0/040` that yields `040`, which is worse than showing the raw identifier because it looks like it might mean something.

So the wire grows a `title`: the leaf name for a file or folder, the collection's `localizedTitle` for an album. Computed by the agent, which is the only process that can ask PhotoKit what an album is called. The app's `name` becomes `title ?? <existing leaf logic>`, so an older agent talking to a newer panel still produces something readable rather than nothing.

There is a small consequence for `SourcesModel.state(of:)`, which already branches on `SourceKind(source.kind).isFileBacked` and returns the agent's stored answer for anything else. That branch is already correct for Photos and needs no change — worth noting only because it is the kind of thing that looks like it needs one.

## The panel, and what it deliberately does not become

`app/mac/FEATURES.md` describes *Sources by kind, in sections* as replacing the single list, and says Photos gets its own section when the provider arrives. That is the better design and it is not this work.

The reason to separate them is that sections are a rework of rows that already function — multiple selection, per-section `+` and `−`, a batch `DELETE` the endpoint does not yet have — and none of it is required for a Photos source to be addable. Doing both at once means a feature that could have been proven in isolation arrives entangled with a list rework, and when something is wrong there are two candidates.

So Photos joins the list as another row, with an icon and a title and a count, exactly like a folder. The `Add from Photos Library…` button opens the sheet. `Configure` is not offered for a Photos source, for the same reason it is not offered for a file: `canConfigureSelection` reads `selected?.isFolder == true`, and an album has no options today. When it gets some — and `FEATURES.md` predicts it will, which is why Configure is a sheet rather than an inline checkbox — that is the moment sections earn their keep.

One thing the sheet does need that no existing picker does: it is the first dialog in this app that is not `NSOpenPanel`. Everything about the source panel so far has leaned on the system picker doing the work. An album list is ours to draw, and it is also the first place a person sees their own library inside this app, which makes it the first place presentation is visible. `FEATURES.md` already has the answer for how much effort that deserves: the visual language stays plain, and the screensaver is where presentation is the product.

## What is deliberately excluded, and why each

**`PHPhotoLibraryChangeObserver`.** `PLAN.md` puts watching in Phase 3 alongside `FSEventStream`, and it belongs there. It is excluded from *this* plan because it changes how the pool notices a change, not how a source is added, and the two failure modes look nothing alike — a provider that materializes the wrong resource and an observer that fires too often would be debugged together for no reason. It also has a known trap worth writing down before it is built: `photoLibraryDidChange` fires on a background queue for every change to the library, including ones in albums we do not care about, and the batching the doorbell already demands (`PLAN.md`, *The doorbell, and the batching it still demands*) applies with more force here than it does to files.

**Pinned individual assets, `SourceKind.photosAsset`.** `PLAN.md` Phase 3 lists them and they are genuinely wanted. They are excluded here because they are a second provider with a second picker affordance, and because `SourceKind.file` — the exact analogue — already demonstrated that one source per item produces a wall of rows in a panel that has no sections yet. Adding the Photos version of a problem the file version already has, before the fix for it exists, is buying the same debt twice. When sections land, this is the natural next thing.

**The whole library as a source.** Tempting, and not in `PLAN.md`. `smartAlbumUserLibrary` ("Recents") is the closest thing PhotoKit offers, and it is not quite "everything" — it excludes hidden, and its relationship to shared library content varies. More to the point, a source meaning *all my photographs* has a different character from an album: it is unbounded, it changes constantly, and it makes the byte-budget question urgent in a way a curated album does not. It deserves to be asked for rather than to arrive as a side effect of listing smart albums.

**Multiple Photos libraries.** A stated non-goal in `PLAN.md`, not a deferral. PhotoKit talks to the system library and there is no public API to open another.

## Documents this touches, and where they disagree

Recorded rather than acted on — `PLAN.md` and `app/mac/FEATURES.md` are Syd's, and neither has been edited.

- **`PLAN.md`, Phase 3.** Lists the Apple Photos provider, watching, and individually pinned assets together. This plan takes the provider, holds watching and pinned assets, and argues both above. If that split is right, Phase 3's bullet is what would record it.
- **`PLAN.md`, *Getting full-resolution originals out of Photos*.** Says the `.fullSizePhoto`-then-`.photo` rule "needs the Photos provider's spike to measure it against a real library." Phase 1 is that measurement, and its result belongs there when it exists.
- **`app/mac/FEATURES.md`, *Sources in Settings*.** Says `Add from Photos Library…` is "present and disabled, because the provider does not exist yet." Phase 5 falsifies the second clause.
- **`app/mac/FEATURES.md`, *Sources by kind, in sections*.** Says "Photos and Google Photos get their own sections when those providers arrive." This plan arrives without them, deliberately.
- **`Documentation/photogoroundd.md`.** Would gain the two `/v1/photos` routes under SERVICE, and would need a line about the Photos authorization state. Not yet, since a man page describing something unbuilt is worse than one that is behind — which is the rule that document already follows.

# References

- `PLAN.md` — *The source model*; *Photos is optional, and there is exactly one of it*; *Getting full-resolution originals out of Photos*; *Showing unavailability*; *TCC: unsandboxed does not mean unrestricted*; *Why nothing syncs between devices*; Phase 3.
- `app/mac/FEATURES.md` — *TCC, the pickers, and whose grant is whose*; *What the panel could get without the agent*; *Sources by kind, in sections*; *What the panel can show*.
- `Scripts/make-agent-bundle.sh` — the server bundle's `NSPhotoLibraryUsageDescription`, and the `--sign` note on TCC grants recorded against a signature.
- `Sources/PhotoGoRoundKit/Sources/SourceProvider.swift` — the four operations, and the contracts on `existence` and `availability`.
- `Sources/PhotoGoRoundKit/Sources/SourceStore+Editing.swift` — `EditFailure.unsupportedKind`, and the all-or-none batch rule.
- `Sources/PhotoGoRoundKit/Sources/SourceRequest.swift` — `resolve`, and the trailing-slash rule.
- `Sources/pgr_ctl/PhotosSpike.swift` — the spike itself, and the measurements' provenance.
- `Sources/photogoroundd/Service/SourceEndpoint.swift` — the five source routes and the `Wire` shape.
- `app/mac/SourceService.swift` — the client's reading of the wire, and `Source.name`.
- `PHAssetResourceManager.writeData(for:toFile:options:)` and `PHAssetResourceRequestOptions.isNetworkAccessAllowed`.
- `PHFetchOptions.predicate` on `mediaType`; `PHAssetCollectionSubtype`; `PHAssetCollection.estimatedAssetCount`.
