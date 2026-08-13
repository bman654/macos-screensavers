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
  knowing what it is. See `docs/decorations.md` for that contract and
  `spikes/004-articulated-decor/` for how the animated bubblers hinge. This is also the
  test of whether the primitives generalize past fish: a plant frond is a fin membrane
  with different numbers, a rock is a lofted body with noise, and coral is a branching
  swept tube.
- **Water look.** Caustics as an animated gobo on a spotlight; god rays as additive
  drifting planes; marine snow as an `SCNParticleSystem`; exponential depth fog. The fog
  is what sells the 2.5D depth more than anything else.
- **Depth lanes and fish AI.** 5–7 discrete z-lanes, fish swim within a lane and
  occasionally change lanes; boids-ish separation within a school. Real 3D depth gives
  clean occlusion behind plants and rocks for free.
  - **Clownfish should be tied to an anemone.** They are site-attached in the wild rather
    than free-roaming, so a clownfish that patrols the whole tank like a tang is wrong.
    Give them a host anemone from the placed props and have them stay within about a body
    length or two of it, retreating into it rather than crossing open water. This is the
    one species-specific behaviour worth the exception; everything else can share one
    swimming model. If no anemone was drawn, fall back to ordinary crossings.
- **Camera.** Narrow FOV (~22°) for a near-orthographic 2.5D read with a little parallax.
- **Population.** Each launch draws a random assortment from the library, weighted and
  spaced by each model's manifest, so the tank is a different tank every time.
- **`.saver` shell.** See below — independent of everything above.

## 2a. Two tank styles

The tank ships two selectable looks, chosen in the screensaver's own settings sheet
(`ScreenSaverView.configureSheet` with `ScreenSaverDefaults` for persistence — note that a
legacy saver's defaults are keyed by bundle identifier, not by `Bundle.main`).

- **Aquarium.** Reads like a lit glass tank: a bright, cool, fluorescent-blue key from
  directly overhead, water tinted a noticeably more saturated blue than the ocean look, and
  **coloured aquarium gravel** underfoot instead of sand.
- **Real ocean.** What exists today: sand, muted blue-green water, daylight filtering down
  from the surface.

The two differ only in lighting, water tint and substrate appearance. Geometry, placement,
population and fish behaviour are shared — the split must not reach past the surface into
the scene's structure, or every later feature pays for it twice.

Worth stating because the first render made it obvious: the current water is too dark and
too green to read as an aquarium. That is correct for the ocean style and wrong for the
other one, which is what motivated the split.

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
