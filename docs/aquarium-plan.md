# Aquarium — build plan

Status: the asset pipeline is validated end to end except for materials, and the `.saver`
shell is built and confirmed running under the real screensaver engine. See
`spikes/001-fish-pipeline/README.md` and `spikes/002-saver-shell/README.md` for what each
proved and the traps found along the way.

**Texture baking (§1) is now the only thing between the aquarium and looking right.** The
fish currently render as flat white geometry — correct shape, correct motion, no markings.

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

## 1. Texture baking — the blocker

Nothing procedural survives USD export. Every generated material arrives in SceneKit as
flat white, so all banding, countershading, scales, mouth and roughness variation is
currently lost. UsdPreviewSurface cannot represent Voronoi/ColorRamp/noise nodes.

Planned `saverlib/bake.py`:

1. `ensure_cycles()` — enable the Cycles addon and select the Metal GPU. Verified
   available: `Apple M1 Max (GPU - 32 cores)` enumerates as a METAL device. EEVEE cannot
   bake, so this is required, not optional.
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
6. Export with `export_textures=True` and re-run `SceneKitProbe` — the material summary
   should read `texture`, not `colour(0.906, 0.906, 0.906)`.

Bake resolution: start at 2048² and check whether the black band outlines stay crisp;
they are the highest-frequency feature and will alias first. Set `render.bake.margin`
generously or seams will show as bright fringes underwater.

Expect this to be slow. That is fine — it runs once per species at authoring time, and
committed assets mean building a saver never requires Blender.

## 2. Remaining aquarium work, in dependency order

- **Tank environment.** Plants and rocks via the same `saverlib` primitives — a plant
  frond is a fin membrane with different numbers, a rock is a lofted body with noise.
  This is the test of whether the primitives generalize past fish.
- **Water look.** Caustics as an animated gobo on a spotlight; god rays as additive
  drifting planes; marine snow as an `SCNParticleSystem`; exponential depth fog. The fog
  is what sells the 2.5D depth more than anything else.
- **Depth lanes and fish AI.** 5–7 discrete z-lanes, fish swim within a lane and
  occasionally change lanes; boids-ish separation within a school. Real 3D depth gives
  clean occlusion behind plants and rocks for free.
- **Camera.** Narrow FOV (~22°) for a near-orthographic 2.5D read with a little parallax.
- **`.saver` shell.** See below — independent of everything above.

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
