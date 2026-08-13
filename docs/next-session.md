# Where to pick up

Rewritten 2026-08-13, at the end of the session that built the model library.

## State

**The asset pipeline is finished end to end**, and the model library is most of the way
there. Nothing is blocked.

```
14 fish species        Savers/Aquarium/Models/species/<name>.py
 7 reef props          Savers/Aquarium/Models/props/<name>.py
   the bake            tools/blender/saverlib/bake.py
   primitives          tools/blender/saverlib/{tube,hardsurface,surfaces,markings}.py
```

Texture baking is **done** and is no longer a blocker for anything — fish, static props and
articulated props all bake. See `spikes/005-texture-bake/README.md`. Baking is cheap (about
5–6s for a 2048² three-map bake once the Metal kernels are cached), so it belongs inside the
authoring loop rather than as a batch step at the end.

## Loops

```bash
tools/blender/run.sh Savers/Aquarium/Models/build_fish.py -- --species clownfish --render --preview
tools/blender/run.sh Savers/Aquarium/Models/build_prop.py -- --prop staghorn_coral --render --preview
tools/blender/run.sh Savers/Aquarium/Models/build_prop.py -- --prop boulder --export /tmp/b.usdz --bake
tools/gallery.py --out /tmp/reef.png --columns 4 'build/props/*/water_00_side.png'
```

**Look at the PNG.** This is the repo's hardest-won rule and it held all session: the numbers
never tell you whether a model reads. Every species took four to seven render-and-adjust
iterations, and in every case the thing that fixed it was visible in an image and invisible in
the parameters.

## Next, in order

1. **Decorations.** `docs/decorations.md` has the roster and the manifest contract. The three
   bubblers (treasure chest, clamshell, skeleton with a jug) are unblocked — articulated props
   bake with their hierarchy intact and hinge correctly in SceneKit.
2. **Tank population.** Draw a random assortment per launch, placed and spaced from each
   model's manifest. `props/_spec.py` already emits everything the placement pass needs.
3. **Baking the committed library.** No model has been baked into `Savers/Aquarium/Assets/`
   yet; only probes have run. That is a mechanical pass once the library settles.
4. The rest of `docs/aquarium-plan.md` §2: water look, depth lanes and fish AI, camera.

## Known gaps, deliberately left

- **`mouth` should probably fold into `patches`.** Now that `mouth_color` is settable it is
  just a patch with frozen softness and weaker validation. Deferred because it touches all
  fourteen species files.
- **`cap_rings` is not exposed by `build_branching`**, and rounded tip caps are ~40% of a
  branching prop's vertices. A passthrough is the cheapest geometry win available.
- **`BranchingResult` reports no generation or arc position**, so the staghorn recovers
  generation by inverting the radius decay. It works; it is fragile-adjacent.
- **The boulder is the weakest prop** — faceted, and its own worked-example origins show.
- **Scale relationships between props have never been checked in one scene.** Each was
  authored to real metres independently.
- **`studio_lights` runs about a stop hot for large matte props**; `build_prop.py` compensates
  with `exposure=-2.0` rather than falsifying albedos. A calibration pass would be better.
- **`gallery.build_sheet` fails on a single tile** (`xstack` "Result too large").
- **`SceneKitProbe.worldBounds` over-reports a rotated hierarchy**, transforming each child's
  *local* AABB corners and so returning the AABB of a rotated AABB — it called a
  2.38 x 1.47 x 0.86 m wreck 2.66 x 2.26. Harmless as a diagnostic, wrong if placement ever
  derives extents from geometry instead of the manifest.
- **`rock(flatten=1.0)` still only squashes about 0.4x**, which is a boulder, not a drift. A
  sand drift needs roughly 0.15x and it has to be a mesh-space scale. The wreck does it
  locally; a second prop needing it should push a `drift()` into `saverlib`.
- **`SceneKitProbe` frames on X extent**, so it crops a tall prop to its middle. Harmless for
  fish, wrong for the 1.65 m diving suit and the 2.6 m kelp. It wants a `--fit` flag.
- **`studio.render_views` cannot frame a height band**, so tall props need a throwaway detail
  render to judge anything but the whole silhouette. Two prop authors wrote one independently.

## Traps that cost real time this session

Each is commented where it happens; this is the index.

- **Never leave scale on an object.** A non-uniform parent scale puts children in a stretched
  space: their positions arrive in the wrong units and rotating them *shears* instead of
  turning. Fatal for anything hinged. `spikes/004-articulated-decor/`.
- **Never bake a mesh with live modifiers.** Unwrapping sees the base mesh, baking sees the
  evaluated one, so a Solidify shell silently shares texels with the faces it grew from. No
  error, no visual tell. `bake_atlas` refuses.
- **Custom vertex attributes need not survive export** — Cycles evaluates them during the bake
  and writes the result into the atlas.
- **A positive `diagonal_stripes` angle rises rearward.** The algebra says otherwise; a
  rendered pair settled it and is now a permanent swatch.
- **A caudal lobe's width comes from `flare`, not `span`.** Span spike → needles, flat span →
  paddles, monotone falloff into the cut → tapered points.
- **A ColorRamp holds 32 stops**, so roughly three outlined bands per ramp. It now raises.
- **Colours render about twice as bright as written** under the studio key, and accents clip
  harder than ground colours. Black markings read as charcoal — do not compensate, the
  exporter bakes albedo.
- **Cosine ring spacing puts the first ring a fraction of a millimetre from the pole**, so on a
  long body an end control point sized like a compact fish's builds a flat disc across the
  snout.
- **A small eye vanishes into a narrow head** — `_build_eyes` seats it at `abs(y) * 0.62`.
- **Branching density is not what makes coral read as coral.** Internode length is: a tree's
  shortens at every fork, a gorgonian's stays constant.
- **`obj.matrix_world` is lazy, so `obj.matrix_world = m @ obj.matrix_world` silently discards
  a `.location` set in the same tick.** It collapsed four boot pieces into a flat stack at
  z = 0. Same trap as spike 003's note about `scene_bounds` seeing stale matrices: force the
  depsgraph, or compose the transform rather than reading back what you just wrote.
- **`rock_material` has a brightness floor around 0.19 median luminance**, so albedo stops
  buying darkness long before black. Measured through the prop builder's own `exposure=-2.0`:
  base 0.050 renders at 0.440, 0.010 at 0.258, and 0.002 still at 0.192 — a 25x albedo range
  compressed into barely 2x. The residual is the fixed dielectric specular response, which is
  achromatic, so it desaturates as well as lightens. `speckle` is *not* the cause: sweeping it
  0.10 to 0.80 changed aggregate luminance immeasurably, because the flecks are too sparse to
  matter. Anything meant to read near-black must earn it by contrast with a brighter
  neighbour, not by driving base toward zero.

## Unverified — do not assume these work

- **Retina 2x and multi-display.** Still never executed; this machine has one 1x display.
  Opening the laptop and previewing is a five-minute test that would de-risk every saver.
- **Long-run stability.** Proven numerically to a week, but nothing has run for more than
  seconds.
- **The `default.metallib` path**, for lack of a Metal toolchain on this machine.
