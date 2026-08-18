# Spike 001 — Blender → SceneKit fish pipeline

**Question:** can a parametric Blender model reach SceneKit intact, and can a fish
undulate without a skeleton?

**Answer:** yes to both. Materials are the one part that does not survive.

## Reproduce

```bash
tools/blender/run.sh Savers/Aquarium/Models/build_fish.py -- \
    --species clownfish --render --preview
tools/blender/run.sh Savers/Aquarium/Models/build_fish.py -- \
    --species clownfish --export build/assets/clownfish.usdz

swiftc -O spikes/001-fish-pipeline/SceneKitProbe.swift -o /tmp/scnprobe \
    -framework SceneKit -framework AppKit -framework Metal
/tmp/scnprobe --input build/assets/clownfish.usdz --out-dir build/scenekit \
    --frames 4 --top --amplitude 0.10
```

## What held

- **Geometry survives cleanly.** 55,700 verts, correct bounds, correct silhouette.
- **Skeleton-free swimming works.** A geometry shader modifier applying a travelling
  sine wave with a `tailward²` envelope produces convincing undulation. One geometry can
  serve a whole school, each fish with its own phase — no rig, no export risk, no
  per-fish animation state.
- **Modelling as code is viable at quality.** The clownfish went from "soap carving" to
  recognisable in five iterations, each one driven by looking at a render.

## What did not

- **Procedural materials do not export.** Every generated material arrives as flat white
  (`colour(0.906, 0.906, 0.906)`). UsdPreviewSurface cannot represent Voronoi, ColorRamp
  or noise nodes, so all banding, countershading, scales, mouth and roughness variation
  is lost. **The pipeline needs a texture-bake step** (Cycles bake to image, export with
  textures) before any of the look reaches the screensaver. This is the largest open item.

## Traps found, and why the code looks the way it does

- **Lights must scale with subject size.** Fixed wattage aimed at a 10 cm model blows the
  render out, and AgX then desaturates the highlights — which reads as a broken material.
  Two full iterations were spent on the material before the cause turned out to be
  exposure. `_rig()` scales energy by distance².
- **View transform is not cosmetic.** AgX turned saturated orange into pale salmon.
  Standard is the default here because SceneKit tone-maps close to linear→sRGB, so it
  previews what the screensaver will actually show.
- **Units matter twice.** Subsurface radius left at a human-skin default (2 cm) exceeded
  the whole fish and bled it to pastel. Voronoi cells specified in absolute metres gave
  5 mm scales that read as low-poly faceting. Both are now expressed relative to body
  size (`scale_count`, `body_length`).
- **Blender exports subdivision as a *scheme*, not as geometry**, and SceneKit ignores
  the scheme — an unbaked export arrives as the coarse control cage. `_bake_modifiers()`
  evaluates the depsgraph before export.
- **`u_modelTransform` inside a geometry shader modifier produced shredded geometry and a
  magenta surface**, with no diagnostic even under `SCN_DEBUG_SHADERS`. Not a syntax
  issue — GLSL `vec4` and Metal `float4` failed identically. Joining the fish into one
  mesh removes the need for world space entirely, and is better anyway: one draw call.
- **A lateral deformation is invisible to a side-on camera.** The swim wave displaces
  along Y; a camera on the Y axis looks straight down the axis of motion and shows
  nothing. This cost real time and looked exactly like a broken shader. Use `--top`.
- **Periodic textures are the wrong model for markings.** Clownfish bands sit at
  particular places and do not repeat; tuning a wave frequency to land three bars
  correctly is guesswork. Bands are now placed explicitly with a softened outline. The two
  exceptions are the markings that genuinely repeat on the animal — an angelfish's ruling
  and a seahorse's bony rings — and both still say where the repeats go rather than at what
  frequency.
- **A texture coordinate has to be asked for by name, and this one cost the whole library.**
  `bake_atlas` unwraps into a layer of its own and marks it for render, so
  `ShaderNodeTexCoord`'s `UV` output means *the atlas* during a bake and *the authored layer*
  at every other moment. Nothing errors. Fin rays and a fin's root-to-tip gradient are drawn
  against the fin's own UV, and for as long as this went unnoticed every fish in the library
  baked them as a flat wash — a fin's island covers a fraction of atlas space, so three
  cycles of a ray wave across the whole square is a fraction of one cycle across the fin. It
  is invisible in a preview render, which never bakes, and it looks like a *design* problem
  in the tank: the seahorse's dorsal was written up as "large and very pale, it reads a
  little like a wing". Read authored coordinates through a `ShaderNodeUVMap` naming the
  layer. `saverlib/bake.py`'s module docstring is the standing rule.

## Not addressed here

Texture baking, plants and rocks, the caustics/god-ray environment, depth lanes and
fish AI, and the `.saver` bundle itself.
