# Spike 009 — a per-vertex part channel through Blender, USDZ, and SceneKit

**Question:** can a part id and a root-to-tip fraction authored on separate Blender meshes
survive modifier evaluation, join, atlas bake, USDZ export, SceneKit import, and a geometry
shader modifier?

**Answer:** not as vertex colour on macOS 26. Blender preserves the colour data and writes a
correct `primvars:displayColor`, but both SceneKit import paths drop it. The working channel is
a second UV set, with one important qualification: `bake_atlas` deliberately deletes every UV
set, so the pre-join colour attribute is the authoring/source-of-truth channel and it must be
transcoded to a new UV layer named exactly `st1` **after** the bake. SceneKit then exposes it as
`_geometry.texcoords[1]` with 32-bit float components. That path works in the real saver's
`SCNScene(url:)` loader and in the ModelIO bridge.

This is therefore a strict refutation of the direct colour proposal and a proof of the practical
fallback. The information is authored before modifier evaluation and join, survives those plus
the bake in a `FLOAT_COLOR`/`POINT` attribute, and reaches SceneKit after the post-bake UV
transcode.

## Reproduce

Blender 4.5.12 LTS and the repository's real `saverlib` build the body and pectoral fin, evaluate
modifiers the same way as `build_fish._bake_modifiers`, join with `bpy.ops.object.join`, call the
real `bake_atlas`, and use the same USD export arguments as `build_fish.py`:

```bash
tools/blender/run.sh spikes/009-part-channel/build_probe.py 2>&1 \
    | tee spikes/009-part-channel/output/blender.log

grep -E 'Error|Traceback' spikes/009-part-channel/output/blender.log
```

The script makes five independent assets:

- `point_complete`: `FLOAT_COLOR`/`POINT`, explicitly authored on body and fin.
- `point_missing_active_body`: only the fin has the attribute; body is active for join.
- `point_missing_active_fin`: only the fin has the attribute; fin is active for join.
- `corner_complete`: `FLOAT_COLOR`/`CORNER`, explicitly authored on body and fin.
- `uv_fallback`: the complete POINT case, then a post-bake `st1` transcode.

Inspect the exported USD and build the SceneKit probe:

```bash
for variant in point_complete point_missing_active_body \
    point_missing_active_fin corner_complete uv_fallback
do
    usdcat "spikes/009-part-channel/output/$variant/$variant.usdz" \
        > "spikes/009-part-channel/output/$variant/scene.usda"
done

.venv/bin/python spikes/009-part-channel/inspect_usd.py

swiftc -O spikes/009-part-channel/SceneKitProbe.swift \
    -o spikes/009-part-channel/output/scenekit-probe \
    -framework SceneKit -framework AppKit -framework Metal -framework ModelIO

for variant in point_complete corner_complete uv_fallback
do
    mkdir -p "spikes/009-part-channel/output/$variant/scenekit"
    SCN_DEBUG_SHADERS=YES spikes/009-part-channel/output/scenekit-probe \
        --input "spikes/009-part-channel/output/$variant/$variant.usdz" \
        --out-dir "spikes/009-part-channel/output/$variant/scenekit" \
        > "spikes/009-part-channel/output/$variant/scenekit.log" 2>&1
done

.venv/bin/python spikes/009-part-channel/inspect_render.py
```

`tools/build-library.py` is not involved.

## What Blender and USD preserve

The evaluated and joined probe has 2,120 points, 8,464 loops, and 2,116 quads. Of those points,
1,622 are body and 498 are fin. The fin starts as 63 control points; Solidify plus subdivision
produce 498 points. The colour gradient is authored before those modifiers, and modifier
evaluation interpolates it to 222 distinct fin values.

When every source mesh carries the attribute, every stage inside Blender agrees:

| domain | joined attribute values | after `bake_atlas` | USD declaration |
| --- | ---: | ---: | --- |
| POINT | 2,120 | 2,120 | `color3f[2120]`, `interpolation = "vertex"` |
| CORNER | 8,464 | 8,464 | `color3f[8464]`, `interpolation = "faceVarying"` |

Both carry `R = 0, G = 0` on the body and `R = 1, G = 0...1` on the pectoral fin. Values such as
`0.004881`, `0.500736`, and `1.0` remain floating point in the exported USDA; there is no 8-bit
quantisation in the tested `FLOAT_COLOR` path. `bake_atlas` replaces UVs and materials but does
not remove colour attributes.

The complete numbers and sampled values are in:

- `output/*/blender-report.json`
- `output/usd-report.json`
- each variant's `scene.usda`

### A missing attribute does not become zero

Blender join does preserve an attribute that exists on only one input, but its fill value for an
input without that colour attribute is **white**, `(1, 1, 1, 1)`, not zero. This did not depend on
which object was active for the join:

| case | joined R range | nonzero R | nonzero G |
| --- | --- | ---: | ---: |
| explicit zero on body | 0...1 | 498 / 2,120 | 495 / 2,120 |
| body missing, body active | 1...1 | 2,120 / 2,120 | 2,117 / 2,120 |
| body missing, fin active | 1...1 | 2,120 / 2,120 | 2,117 / 2,120 |

The 2,117 nonzero G values are the 1,622 white-filled body points plus 495 non-root fin points.
After the UV transcode and SceneKit's V flip, that white default becomes `(U=1, V=1)`: exactly
the probe's pectoral-id/full-tip code point and therefore its maximum displacement. The recipe
must create the attribute on **every** mesh entering the join, including body, eyes, and every
fin, and production should assert that invariant before joining. Reserve U=0 for ordinary or
unlabelled geometry and do not assign U=1 to a real part id, so an omission is conspicuous rather
than silently selected.

## Where colour fails

`usdcat` proves Blender's exporter did its part. The POINT asset contains a 2,120-value
`primvars:displayColor` with vertex interpolation; the CORNER asset contains an 8,464-value
version with face-varying interpolation. The values and ranges are correct.

SceneKit then drops both:

| loader | POINT `.color` sources | CORNER `.color` sources |
| --- | ---: | ---: |
| `SCNScene(url:options:)` | 0 | 0 |
| `MDLAsset(url:)` → SceneKit | 0 | 0 |

The real saver uses the first path in `ModelCache.model(named:)`, so ModelIO is not a production
escape hatch anyway. It was tested because it could have imported the USD primvar differently;
it did not.

`SCNScene(url:)` retains 2,120 position vectors and separate 8,464-vector normal/UV sources for
both colour domains. The tested ModelIO-to-SceneKit bridge de-indexes positions to 8,464
vectors in both cases; the
probe does not establish which imported source forces that conversion. CORNER colour therefore
increases the raw USD colour payload
from 2,120 to 8,464 values, but it cannot be assigned a SceneKit de-indexing cost because the
colour source never reaches SceneKit.

A shader modifier may still mention `_geometry.color` when no colour source exists. It does not
read zero. On the atlas-textured fish,
`_geometry.color.g * 0.10` rigidly translated the complete 14,613-pixel silhouette from
y=242...339 to y=193...289 with the pixel count unchanged, proving G=1 rather than merely a
successful compile. A source-less triangle using
`dot(_geometry.color, float4(0.25)) * 0.10` gave the corroborating 28.580-pixel calibrated shift.
Together these are consistent with SceneKit's white `float4(1)` default; the load-bearing direct
measurement is that G=1. Using `_geometry.color.g * k` on these USDZs therefore moves the entire
fish by `k`; it does not select the fin.

## The working recipe

### 1. Author one POINT colour attribute on every part

POINT is the source-of-truth domain. It uses one value per model point and survives evaluated
Solidify/subdivision, join, and bake. The name is not important for the later transcode, but
`displayColor` makes USD inspection direct.

```python
attribute = mesh.color_attributes.new(
    name="displayColor", type="FLOAT_COLOR", domain="POINT"
)
mesh.color_attributes.active_color = attribute
mesh.color_attributes.render_color_index = mesh.color_attributes.find("displayColor")

# Every object gets the attribute. Body/eyes/non-animated parts:
attribute.data[vertex.index].color = (0.0, 0.0, 0.0, 1.0)

# Pectoral fin: R is its normalized part id; G is root=0 through tip=1.
# Reserve 0 for no part and 1 for invalid/missing join input.
attribute.data[vertex.index].color = (0.25, root_to_tip, 0.0, 1.0)
```

Author before production's evaluated modifier pass. This lets Solidify and subdivision propagate
the data just as they propagate geometry. Before `bpy.ops.object.join()`, fail the build if any
mesh lacks the attribute:

```python
missing = [obj.name for obj in meshes if "displayColor" not in obj.data.color_attributes]
if missing:
    raise RuntimeError(f"part channel missing on: {', '.join(missing)}")
```

### 2. Apply modifiers, join, and bake exactly as production already does

The relevant production order is:

```text
build body/fins/eyes
→ evaluate each object's modifiers
→ join_parts(...)
→ bake_atlas(joined, ...)
```

Do not create the second UV before the bake. The spike created an `st1` layer immediately before
`bake_atlas` and measured `["st1"]` before the call and only `["AtlasUV"]` after it. This is
intentional in `bake._unwrap`, which removes every old UV layer before generating the atlas.

### 3. After the bake, transcode the surviving POINT attribute to a CORNER UV named `st1`

```python
mesh = joined.data
source = mesh.color_attributes["displayColor"]
atlas = mesh.uv_layers.active       # bake_atlas created AtlasUV
channel = mesh.uv_layers.new(name="st1")

for loop in mesh.loops:
    value = source.data[loop.vertex_index].color
    # SceneKit's USD importer flips UV V. Pre-flip it so the shader receives G.
    channel.data[loop.index].uv = (value[0], 1.0 - value[1])

mesh.uv_layers.active = atlas
atlas.active_render = True          # exports the material UV as st; channel follows as st1
mesh.update()

# Keep displayColor out of the shipping asset after its data has moved to st1.
mesh.color_attributes.remove(source)
```

The proof asset deliberately retains `displayColor` so `usdcat` can establish where that path
fails. A shipping build should perform the final removal shown above.

The two details here are part of the contract:

- Name the second layer exactly `st1`, keep `AtlasUV` active for rendering, and follow the USDZ
  `st`/`st1` convention. This measured combination exports `primvars:st` followed by
  `primvars:st1` and arrives as texcoord indices 0 and 1 on Blender 4.5.12 / macOS 26 SceneKit.
  Arbitrary primvar names and their ordering are outside what this spike proves.
- Store `1 - G` in Blender. Blender writes that value unchanged into USD; SceneKit's USD
  importer then flips V. Without compensation the body arrives with G=1 and the fin gradient is
  reversed. With compensation, SceneKit samples were body
  `(0, 0)`, fin middle `(1, 0.500736)`, and fin tip `(1, 1)`.

### 4. Export exactly as `build_fish.py` does

```python
bpy.ops.wm.usd_export(
    filepath=export_path,
    export_materials=True,
    export_textures_mode="NEW",
    overwrite_textures=True,
    evaluation_mode="RENDER",
    generate_preview_surface=True,
)
```

The USD contains the ordinary atlas as `primvars:st` and the part channel as a face-varying
`primvars:st1`. Each has 8,464 values in this probe.

### 5. Read the second texcoord in the SceneKit geometry modifier

```metal
#pragma body
float2 part = _geometry.texcoords[1];
float pectoralID = 0.25; // example: reserve 0 for none and 1 for invalid/missing
float isPectoral = 1.0 - step(0.01, abs(part.x - pectoralID));
_geometry.position.z += part.y * isPectoral * k;
```

The direct SceneKit loader reports both texcoord sources as `float2`, two components, four bytes
per component, `usesFloatComponents = true`. Values are not quantised to bytes. The same format
and samples arrive through ModelIO.

The proof asset uses U=0/1, but production should allocate real part ids strictly inside (0, 1),
select a small range around each id, reserve U=0 for no part, reserve U=1 for an invalid/missing
attribute, and reject missing attributes before join. V remains the root-to-tip fraction. Verify
the chosen production encoding rather than depending on exact float equality. `BYTE_COLOR`,
which Blender's UI may create by default, was not tested; request `FLOAT_COLOR` explicitly.

## Shader proof

The SceneKit probe renders the imported, atlas-textured fish twice. It switches the material to
constant lighting only for these proof images so the blue body and orange fin are unambiguous;
the geometry sources and modifier are unchanged.

- Baseline: `output/uv_fallback/scenekit/baseline.png`
- `_geometry.texcoords[1].y * 0.10`: `output/uv_fallback/scenekit/texcoord1-displaced.png`

Only the fin moves. At 900×600, 2,112 pixels changed, all inside `(x: 412...483,
y: 288...339)`. That box is the union of the hue-selected orange fin before movement
(`x: 413...483, y: 303...339`) and after it (`x: 413...482, y: 288...308`); no changed pixel
falls outside the fin region. The body foreground bounds stay `x: 330...569, y-min: 242`; only
the fin-side y maximum changes from 339 to 320. `output/render-report.json` holds the
measurement.

As a control, `_geometry.texcoords[0].y` visibly shreds/displaces the whole surface according to
the atlas unwrap (`texcoord0-displaced.png`). This confirms that the successful image is reading
the authored second channel, not merely compiling a modifier which defaults to a constant.

## Runtime fit

`ModelCache` in `Savers/Aquarium/Sources/ModelLibrary.swift` loads USDZ with
`SCNScene(url:options: nil)`. That exact loader retained `st1`. `School.makeFish` copies each
geometry and material before attaching `swimModifier`. A material has one `.geometry` shader
modifier string, so the pectoral term and any new uniforms must be merged into the existing
`swimModifier` source; it cannot be installed as a second independent modifier. The probe uses
the same material-level `shaderModifiers[.geometry]` path. No ModelIO conversion or runtime
buffer rewrite is needed.

The production model-building insertion points are consequently:

1. create and fill the POINT attribute while body/fins/eyes are still separate;
2. leave modifier evaluation, join, and `bake_atlas` in their current order;
3. transcode the still-present colour attribute to `st1` immediately after `bake_atlas` and
   before `usd_export`;
4. merge the `_geometry.texcoords[1]` pectoral term into the existing material geometry modifier.

## Scope of the probe

The pipeline calls are production-equivalent: evaluated `new_from_object`, join, 256px atlas,
32px production bake margin, `bake_atlas`, and identical USD export arguments. The test model is
deliberately smaller: two meshes rather than a production fish's body, eyes, and many fins; its
fin uses subdivision to stress interpolation while production fins currently use Solidify only;
and it does not create production's disposable pre-bake fin UV. Those differences do not change
the measured join/bake/import contracts, but the shipping implementation should assert the
attribute on every production mesh and validate one generated species before applying it to the
whole library.

## Traps settled by measurement

- **`displayColor` in USD does not imply `.color` in SceneKit.** Both direct SceneKit and
  ModelIO drop it on Tahoe.
- **Absent `_geometry.color` is white, not zero.** A modifier using it silently affects every
  vertex.
- **Missing Blender colour attributes join as white.** Create explicit zero data on every part.
- **POINT and CORNER both export correctly.** POINT is smaller and is the appropriate authoring
  domain, but neither colour domain imports into SceneKit.
- **`bake_atlas` removes every pre-existing UV set.** Build `st1` after baking by copying the
  surviving authoring attribute.
- **SceneKit's USD importer flips UV V.** USD stores the authored value unchanged; write
  `1 - root_to_tip` in Blender so SceneKit supplies `root_to_tip` to the shader.
- **Use the measured `st`/`st1` convention.** Keeping AtlasUV active-render and naming the
  second layer `st1` gives `_geometry.texcoords[1]`; arbitrary primvar ordering is not proved.
- **The fallback is full float.** SceneKit reports two 4-byte float components; no 8-bit
  quantisation occurred.
- **The tested ModelIO bridge changes topology but not the verdict.** It de-indexes this mesh
  from 2,120 to 8,464 positions, still drops colour, and still retains both float UV channels.
  This does not claim that every lower-level `MDLMesh` inspection path drops colour. The real
  saver should stay on its current direct loader.
- **The authoring colour should not ship.** After transcoding, remove it before export so USD's
  `displayColor` fallback cannot render the fish black/red in another consumer.
