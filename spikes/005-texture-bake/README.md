# Spike 005 — procedural material texture bake

Procedural fish and prop materials can be reduced to a UV atlas and survive Blender's USDZ
export as SceneKit textures. A static model arrives as one geometry, one material, and three
texture maps. An articulated prop keeps its independently moving geometry nodes, but all of
them reference one shared three-map atlas.

## Reproduce

```bash
tools/blender/run.sh spikes/005-texture-bake/bake_probe.py -- \
    --species clownfish --export /tmp/clownfish_baked.usdz

swiftc -O spikes/001-fish-pipeline/SceneKitProbe.swift -o /tmp/scnprobe \
    -framework SceneKit -framework AppKit -framework Metal
rm -rf /tmp/scenekit-baked
/tmp/scnprobe --input /tmp/clownfish_baked.usdz \
    --out-dir /tmp/scenekit-baked --frames 4 --top --amplitude 0.10
```

The driver writes the atlas maps beside the export by default, in
`/tmp/clownfish_baked_textures/` for the command above. `--textures` selects another output
directory. It exits with an error rather than using the CPU when the requested Metal device
is absent.

## Baking API

```python
ensure_cycles(device_name=None)

bake_atlas(
    obj,
    output_dir,
    *,
    atlas_name=None,
    resolution=DEFAULT_RESOLUTION,
    margin=DEFAULT_MARGIN,
    uv_margin=DEFAULT_UV_MARGIN,
    device_name=None,
)
```

`obj` must already be the joined mesh. `bake_atlas` creates a fresh Smart UV Project atlas,
bakes base colour, roughness, and tangent-space normal PNGs, replaces every material slot
with one atlas-backed Principled material, and returns absolute paths keyed by `base_color`,
`roughness`, and `normal`.

Articulated props use the companion API:

```python
bake_atlas_objects(
    objects,
    output_dir,
    *,
    atlas_name=None,
    resolution=DEFAULT_RESOLUTION,
    margin=DEFAULT_MARGIN,
    uv_margin=DEFAULT_UV_MARGIN,
    device_name=None,
)
```

`objects` are the mesh objects that must remain independent. The function Smart UV Projects
each mesh, then scales those layouts into disjoint tiles in one shared UV space. The tile
gutters are derived from the pixel bake margin, so independently dilated object margins
cannot overwrite each other. Blender bakes the complete selected object set to each image in
one operator call with one clear. Every mesh receives the same atlas material, but no object
is joined or reparented. Linked mesh datablocks are refused; make each articulated object's
mesh data single-user before baking.

The defaults are 2048×2048, a 32-pixel bake margin, a 0.02 Smart UV island margin, and any
available Metal GPU. The black band outlines remain crisp at this resolution. The pixel and
island margins leave enough dilation around the many Smart UV islands that no bright seam
appears in the SceneKit render.

## Verified result

With the Cycles Metal kernels cached, a full-resolution three-map bake took 5.6 seconds;
build, modifier application, baking, PNG writes, and USDZ export took 7.6 seconds on the M1
Max. The first low-resolution smoke bake took 38.5 seconds because it also paid the one-time
Cycles shader compilation cost. SceneKit reported:

```text
material 'clownfish_atlas' diffuse=texture
```

Direct inspection also found textures in SceneKit's diffuse, roughness, and normal material
properties. The rendered fish is orange with white bands and dark outlines, the UVs are not
scrambled, and the scale pattern carried by the normal map is visible under SceneKit's
lighting. The albedo atlas contains the material's intended countershading and mottling but
no illumination or cast-shadow gradient; the diffuse bake explicitly disables direct and
indirect passes. A separate flat-colour sphere baked under a strong point light had zero
variation in every albedo channel, confirming that lighting is excluded rather than merely
subtle in the fish atlas.

Blender 4.5.12 prints `could not copy texture` and `chown: Operation not permitted` warnings
while constructing the temporary USDZ package. They are misleading on this machine: the
resulting archive contains all three PNGs, and SceneKit loads all three as textures.

## Props

`build_prop.py --export <asset.usdz> --bake` applies modifiers before any unwrap, then takes
one of two paths:

- A static prop is joined and passed to `bake_atlas`, matching the fish path. Staghorn coral
  proved this with its thicket and holdfast, anemone with its crown and column, and tube
  sponge with its many-object cluster and live Solidify modifiers evaluated before joining.
- A prop whose manifest declares moving `parts` keeps every mesh separate and passes them to
  `bake_atlas_objects`. The model's named hierarchy and pivots therefore remain the runtime
  animation interface.

Atlas PNGs default to `<asset-stem>_textures/` beside the USDZ. `--textures`, `--resolution`,
`--margin`, `--uv-margin`, and `--device` expose the corresponding bake options. `--bake`
requires `--export`; rendering without export still uses the procedural materials.

### Vertex attributes are resolved by the bake

Cycles evaluates the complete source material inside Blender. A custom vertex attribute is
therefore an input to the bake, not data that USD or SceneKit must preserve. Its evaluated
colour is written into the base-colour atlas, and the replacement material reads only that
texture.

This was checked rather than inferred. At 2048², staghorn's `tipness` still produced distinct
pale growing tips in both the atlas and SceneKit. Anemone's `tentacle_t` still produced dark
roots, a mid-tone transition, and magenta bulbs/tips in both. SceneKit reported
`diffuse=texture` for each model. Exporting the custom attributes themselves is irrelevant
after baking.

### Articulated shared-atlas proof

A two-box chest probe reused spike 004's transform arrangement: `part_lid` remained parented
to `part_base`, its origin remained on the hinge, and `emit_bubbles` remained under the lid.
The base used blue procedural noise and the lid used orange procedural noise so a cleared or
cross-object-overwritten atlas could not look accidentally correct.

After tiled shared-atlas unwrap and group baking, SceneKit reported `diffuse=texture` on both
geometry nodes and rendered both distinct colours. `HingeProbe.swift` still found
`part_lid`, rotated it through 0°, 35°, and 70°, and reported the emitter moving around the
hinge. This settles the implementation on one shared atlas rather than per-part atlases.

### Resolution and timings

2048² remains the default for props. Physical model size does not by itself demand more atlas
pixels; screen footprint, UV island count, and the frequency of visible material features do.
The 28k-vertex staghorn and 28k-vertex anemone are not denser than the verified 56k-vertex
fish, and direct inspection found their tip gradients intact with no visible seam failure.
There is no evidence to pay the fourfold memory and bundle-size cost of 4096².

With Metal kernels cached on the M1 Max, representative three-map 2048² bake times were
5.6 seconds for staghorn, 5.3 seconds for anemone, and 8.6 seconds for the two-object
articulated probe. Articulated authors should still combine rigid geometry that moves as one
part before baking: every extra object receives its own atlas tile, reducing the texel area
available to the other parts even though the bake uses one Cycles call per map.
