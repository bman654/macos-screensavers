# Aquarium — build plan

Status: the asset pipeline is validated end to end except for materials, and the `.saver`
shell is built and confirmed running under the real screensaver engine. See
`spikes/001-fish-pipeline/README.md` and `spikes/002-saver-shell/README.md` for what each
proved and the traps found along the way.

**Texture baking is done** (§1), so models now reach SceneKit with their real colours,
markings and scale relief instead of as flat white geometry. The active work is building
out the model library — species, reef, and decorations — and then populating the tank.

## Decisions already made (do not relitigate)

- **SceneKit, not RealityKit or raw Metal.** Soft-deprecated but not slated for removal,
  and it supplies PBR, particles, depth fog and post-processing that would otherwise be
  weeks of Metal work. RealityKit is AR-oriented and awkward inside an NSView screensaver.
- **No WebKit.** `WKWebView` content blanks after ~3s inside `legacyScreenSaver` on macOS
  26.4, so the existing web aquarium cannot be wrapped. It is a reference, not a shortcut.
- **Fish are one joined mesh, not a parented hierarchy.** One draw call per fish, and —
  load-bearing — every vertex shares one object space, so the swim deformation works in
  local coordinates. `u_modelTransform` inside a geometry shader modifier produces
  shredded magenta geometry.
- **Swim animation is a shader modifier, not a skeleton.** A travelling sine wave with a
  `tailward²` envelope. No rig to survive export, and one geometry can serve a whole
  school with a per-fish phase offset.
- **Models are parametric Python, not sculpted binaries.** See the root `CLAUDE.md`.

## 1. Texture baking — retired

Nothing procedural survives USD export: UsdPreviewSurface cannot represent
Voronoi/ColorRamp/noise nodes, so every generated material arrived in SceneKit as flat
white and all banding, countershading, scales, mouth and roughness variation was lost.

`saverlib/bake.py` now bakes those materials into an atlas and swaps in a single material
that reads it. See `spikes/005-texture-bake/README.md`. Two results worth carrying
forward:

- **Baking is cheap, not slow.** The plan below budgeted for a slow authoring-time step.
  A 2048² three-map bake runs in about 5.6s once Cycles' Metal kernels are cached, so
  re-baking fits inside the normal edit-render-look loop.
- **A mesh with live modifiers must never be baked.** Unwrapping sees the base mesh while
  baking sees the evaluated one, so a Solidify shell silently shares texels with the faces
  it grew from. `bake_atlas` refuses rather than warns.

What it does, which is what was planned here:

1. `ensure_cycles()` — enable the Cycles addon and select a Metal GPU. EEVEE cannot bake,
   so this is required, not optional. It takes any Metal device and refuses to fall back
   to the CPU; pinning one machine's device name would make shared library code refuse to
   run anywhere else.
2. Join first, then Smart UV Project the joined mesh so all three material slots share
   one non-overlapping atlas.
3. Bake three maps into that atlas:
   - base colour — `DIFFUSE` with `use_pass_direct/indirect = False`, colour pass only,
     so the result is albedo and not baked-in lighting
   - roughness — `ROUGHNESS`
   - normal — `NORMAL`, which is what carries the scale relief
4. Save PNGs, set roughness and normal images to Non-Color.
5. Replace the three materials with a single Principled material reading the atlas, so a
   fish becomes one material, one draw call, one texture set.
6. Export with `export_textures_mode="NEW"` — the older `export_textures` bool is a
   retained alias that drives nothing — and re-run `SceneKitProbe`, whose material summary
   now reads `texture` rather than `colour(0.906, 0.906, 0.906)`.

Settled at 2048² with a 32px bake margin, which keeps the clownfish's black band outlines
crisp — they are the highest-frequency feature and alias first — and shows no seam
fringing underwater.

## 2. Remaining aquarium work, in dependency order

- **The model library.** A roster of reef species, plus coral, plants, rocks and
  decorations, each committed with a manifest so the tank can place and animate it without
  knowing what it is. A species states its body one of two ways: lofted along a straight X
  axis from `width`/`top`/`bottom`, which suits anything shaped like a fish, or swept along a
  `path` for an animal that doubles back on itself — the seahorse's bent neck and curled tail
  are not functions of a monotone X. `saverlib/curved.py` holds the second one and the caveat
  that comes with it. A species may also be **more than one colour**: `Species.colorways` names
  repaints of one animal, restricted to colour fields because every scheme shares the one baked
  mesh, and each ships as a single extra base-colour PNG that the runtime swaps onto an
  individual fish. That is what stops two seahorses in a tank being two copies — a wild one's
  colour is a fact about the weed it is gripping rather than about its species. See `docs/decorations.md` for that contract and
  `spikes/004-articulated-decor/` for how the animated bubblers hinge. This is also the
  test of whether the primitives generalize past fish: a plant frond is a fin membrane
  with different numbers, a rock is a lofted body with noise, and coral is a branching
  swept tube.
- **Water look.** Caustics as an animated gobo on a spotlight; god rays as additive
  drifting planes; marine snow as an `SCNParticleSystem`; exponential depth fog. The fog
  is what sells the 2.5D depth more than anything else.
- **Depth lanes and fish AI — done.** Six lanes; a fish holds one and eases between them, which
  is what a lane change is. `FishBehavior` (the limits), `FishDecision` (the taste) and `School`
  (the loop). The clownfish's anemone affinity landed with it, and falls back to ordinary
  swimming on a launch that drew no anemone.

  Boids-ish separation was **not** built and is not obviously wanted. The reason is the lanes:
  a school layered into six discrete depths already reads as spaced, and separation forces
  between ten fish spread over that volume would almost never fire. Revisit it if a species is
  ever given a large enough school to crowd its own lane.

  The one structural thing to know before touching any of it: a fish has *state* now. The old
  model handed out a launch vector and nothing could turn, so "change lane", "change height",
  "pause" and "change speed" were not features that could be added to it — they are all one
  missing thing, which is steering. Anything else the school should do belongs in the weighted
  draw in `FishDecision`, not in a new special case.

- **The aquarium's walls — done, and they are the frustum.** A fish cannot leave the frame in a
  glass tank. `Tank.isEnclosed` is the switch and it is the same fact as `substrateBand`: the
  look seen through a pane is the look that has walls. Open sea keeps crossings and respawn,
  because a fish there is passing through rather than living there. See `Tank.wallX` for why the
  box is a trapezoid rather than a rectangle, and `docs/next-session.md` for why its ceiling is
  not a waterline.
- **Camera.** Narrow FOV (~22°) for a near-orthographic 2.5D read with a little parallax.
- **Population.** Each launch draws a random assortment from the library, weighted and
  spaced by each model's manifest, so the tank is a different tank every time.
- **`.saver` shell.** See below — independent of everything above.

## 2a. Three tank styles — the looks and their sheet, both done

The tank ships three selectable looks, chosen in the screensaver's own settings sheet:
`AquariumSettingsSheet`, returned from `ScreenSaverView.configureSheet` and persisted to
`ScreenSaverDefaults` keyed by the *saver bundle's* identifier — `SaverView.saverDefaults`,
never `Bundle.main`, which inside `legacyScreenSaver` is the host appex.

The sheet carries a live preview of the selected look, because the three differ in light,
water colour and substrate and a name conveys none of that. A fourth option, "Surprise me",
draws one of the three per launch. OK rebuilds the running view's host so the thumbnail the
sheet was opened from adopts the new look immediately; Cancel leaves nothing behind.
`tools/run-saver.swift --configure` opens the sheet outside System Settings, and the sheet has
been confirmed working inside it.

Selecting a look throws the preview away and builds a new tank, which measured 234–354 ms of
blocked main thread per click — the model imports dominate. That is a hitch and not a freeze,
and it is the reason the preview is not cached per style: three live tanks in a settings sheet
is three copies of the library in memory to save a third of a second.

- **Aquarium.** Reads like a lit glass tank: a bright, cool, fluorescent-blue key from
  directly overhead, water tinted a noticeably more saturated blue than the ocean look, and
  **coloured aquarium gravel** underfoot instead of sand — a packed bed of separate stones with
  real relief, in one of twenty-eight palettes drawn per launch, and cut open in section across
  the bottom of the frame where it meets the front pane. That last part is the one place a style
  reaches into the tank's geometry rather than its surface, and it is unavoidable: seeing a bed
  in section requires the viewer to stand *outside* the glass, which is a camera fact rather
  than a texture one. `Tank.substrateBand` is the whole of the reach, and the ocean passes nil.
- **Real ocean.** What exists today: sand, muted blue-green water, daylight filtering down
  from the surface. This became **two** styles once it was art-directed — `shallowReef` and
  `deepOcean` — because the depth the water is seen from changes everything about it and
  nothing about the tank: the two draw the same dimensions and differ only in the water
  block and the sand it has to agree with. `docs/water-looks.md` has all three, and the
  rule that keeps a substrate and its water coherent.

The three differ only in lighting, water tint and substrate appearance. Geometry, placement,
population and fish behaviour are shared — the split must not reach past the surface into
the scene's structure, or every later feature pays for it twice.

The split was motivated by a render: the water as first written was too dark and too green to
read as an aquarium, which was correct for the ocean and wrong for a lit glass tank. Both have
since been art-directed; `docs/water-looks.md` is where the numbers and their reasons live.

## 3. The shell — retired

Done and verified in the real host. `Shared/SaverKit` supplies both hosts, and both a
SceneKit saver (Aquarium) and a raw Metal saver (`spikes/002-saver-shell`) were installed
and rendered correctly under Tahoe's `legacyScreenSaver`. See `Shared/SaverKit/README.md`
for the hazard list and how to write a saver, and `spikes/002-saver-shell/README.md` for
what the Metal probe proved.

The result that mattered most was not on the original risk list: **Command Line Tools ship
no offline Metal compiler**, so shaders must be compiled at runtime from source shipped in
the bundle — and that turns out to be permitted inside the sandbox. Had it not been, every
shader-based saver in `saver-backlog.md` would have needed a Metal toolchain first.

Still unverified: multi-display and Retina 2x (this machine has one 1x display), and
long-run stability.
