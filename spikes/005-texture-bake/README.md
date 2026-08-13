# Spike 005 — procedural material texture bake

Procedural fish materials can be reduced to one UV atlas and survive Blender's USDZ export
as SceneKit textures. The clownfish arrives as one geometry, one material, and three texture
maps; its markings, roughness breakup, and scale normals render in SceneKit.

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
ensure_cycles(device_name=DEFAULT_METAL_DEVICE)

bake_atlas(
    obj,
    output_dir,
    *,
    atlas_name=None,
    resolution=DEFAULT_RESOLUTION,
    margin=DEFAULT_MARGIN,
    uv_margin=DEFAULT_UV_MARGIN,
    device_name=DEFAULT_METAL_DEVICE,
)
```

`obj` must already be the joined mesh. `bake_atlas` creates a fresh Smart UV Project atlas,
bakes base colour, roughness, and tangent-space normal PNGs, replaces every material slot
with one atlas-backed Principled material, and returns absolute paths keyed by `base_color`,
`roughness`, and `normal`.

The defaults are 2048×2048, a 32-pixel bake margin, a 0.02 Smart UV island margin, and the
`Apple M1 Max (GPU - 32 cores)` Metal device. The black band outlines remain crisp at this
resolution. The pixel and island margins leave enough dilation around the many Smart UV
islands that no bright seam appears in the SceneKit render.

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
