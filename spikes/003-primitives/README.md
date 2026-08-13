# Spike 003 — modelling primitives

## Swept tubes and branching

`tools/blender/saverlib/tube.py` builds a tube from either a point list or a callable path.
The source path is first sampled as a polyline and then resampled at uniform arc-length
intervals, so a `Profile` radius and the generated rings do not bunch up with the original
control points. Cross-sections may be elliptical or superelliptical, may change scale along
the path, and may receive an explicit twist. Flat and rounded caps can be selected
independently at the two ends.

The sweep uses a rotation-minimizing parallel-transport frame. A Frenet frame was not usable
here: its normal flips at path inflections, which rotates a non-circular section by 180
degrees and can shred adjacent faces even though the path itself is smooth. The generated
`SweptTube` retains its resampled path, tangents, frames and radius profile and exposes
center, tangent, frame, radius and surface queries over normalized arc position.

`BranchSpec` and `build_branching` recursively place swept tubes with deterministic local
randomness. The controls cover split count and positions, angle and jitter, generation decay,
curvature, gravity-like droop, planarity and alternating side shoots. Child roots start below
the parent surface and grow from a narrow buried radius; their start cap is flat while their
visible tip can be rounded. That avoids the capsule-shaped ridge produced when a rounded
child root intersects the parent.

`BranchingResult.join()` has two junction modes. Its fast default joins the objects but leaves
the intersecting shells intact; those intersections read as solid at normal screensaver
scale but are still visible in an extreme close-up or edge-on view. Supplying
`weld_voxel_size` performs a true voxel union and adds one subdivision level, producing a
single closed-looking surface at the cost of more geometry and render time. The voxel size
must be comfortably smaller than the thinnest terminal radius or fine fan branches will be
lost.

Render all five labelled proof sheets with:

```bash
tools/blender/run.sh spikes/003-primitives/tube_demo.py -- \
    --case all --out build/tube-demo
```

The sheets are written to `build/tube-demo/{curved,section,staghorn,sea_fan,kelp}_contact.png`.
The curved tube stays smooth through repeated inflections, the flattened superellipse keeps a
continuous deliberate twist, and the three seeded branch specs produce a blunt staghorn,
near-planar fine sea fan, and alternating plant shoots respectively.

## Hard surfaces and non-organic materials

`tools/blender/saverlib/hardsurface.py` holds the primitives that wrecks, chests, helmets
and stone are built from — `beveled_box`, `revolve`, `plank`, `displace` and `rock` — plus
a seeded `Noise` class. `tools/blender/saverlib/surfaces.py` holds the six materials they
wear: `wood_material`, `metal_material`, `bone_material`, `rock_material`, `sand_material`
and `glass_material`. Every random choice takes an explicit `seed`, so a wreck rebuilt
tomorrow is the same wreck.

Render all twelve labelled proof sheets with:

```bash
tools/blender/run.sh spikes/003-primitives/hardsurface_demo.py -- --set all
```

They land in `build/hardsurface/`. Each sheet builds its subject two to four times with
different arguments, so the parameter range is visible in one image; material sheets are
rendered under studio *and* `studio.underwater_lights`, and `tank_sheet.png` puts all six
materials in one scene, which is the only honest test of a palette.

### Overgrowth is one shared helper, not six implementations

Every material takes an `algae` amount and hands it to a single private `_biofilm` helper.
Biofilm is substrate-independent — the same slick of diatoms grows on oak, brass, bone and
glass — so one implementation means one place to tune how colonised the whole tank looks.
It also has to be the *last* thing in a material's colour chain while overriding roughness
and adding its own bump, which a wrapper applied to a finished material could not do
without unpicking links it does not own. Its mask is the **world** normal's Z times a
patch noise, so growth lands on upward faces and undersides stay bare; that is what makes
overgrowth look grown rather than painted, and it needs no per-object tuning.

### Traps

- **The studio rig is about a stop hot for large matte props.** A fish is small, curved
  and saturated, so it survives; a seabed is a big flat surface square-on to the key. At
  the repo-default exposure of `-1.15` the sand measures sRGB `0x86` — dry-beach pale —
  and the only way to fix it in the material is to falsify the albedo downward until it
  would be black in the real scene. The demo therefore renders at `-2.0` (`0x65`, wet
  sand) and takes `--exposure` to compare like for like. Two rounds of material edits were
  spent before measuring the pixels instead of trusting the eye: against a black
  background, sRGB compression makes a full stop of exposure look like almost nothing.
- **A row of samples must be looked at from the X axis.** `studio.DEFAULT_VIEWS` orbits
  from azimuth -90, which looks straight *down* a row laid out along Y and shows one
  sample plus a lot of foreshortening.
- **`scene_bounds` sees stale matrices.** Object `matrix_world` is lazy, so without
  `bpy.context.view_layer.update()` after building, every prop still reads as being at the
  origin and the shot is framed for one of them.
- **Corrosion is not rough metal, it is chalk.** Leaving the dielectric specular at a
  polished 0.55 lays a white sheen over every bump of a rusted plate and desaturates a
  brown into pink putty. `metal_material` mixes specular down to 0.10 where the patina is.
  For the same reason the two ends of the rust tone variation both stay close to the
  patina's own hue: mixing far toward cream to get "bright flaking rust" pulls the average
  up until the whole plate is pink.
- **The fish spike's subsurface-radius trap has a second form.** `size` is a prop's
  *length*, but light scatters across its *thickness*, and a bone is far longer than it is
  thick. A radius that looks modest against the length bleeds through and gives pastel.
- **A `Wave` texture is the wrong model for seabed ripples** for the same reason a
  periodic texture was the wrong model for clownfish bands: it is perfectly straight and
  perfectly evenly spaced, and a floor made of one reads as corduroy. Ripples are noise
  stretched along one axis, which wanders and forks for free.
- **`displace` on an unsubdivided box silently does nothing useful** — a cube has no
  interior vertices to move, and the result looks like a broken noise function rather than
  a missing `subdivide` argument.
- **Fracture before texture is backwards.** `rock` applies its fine noise *before* the
  planar cuts, so a cut face stays perfectly flat. Cutting first puts noise on a face that
  should be glassy, which is what makes a shard read as a lumpy potato with edges.
- **`mesh.use_auto_smooth` is gone in 4.1+** and its replacement is an operator needing a
  valid context. Smooth shading plus an `EdgeSplit` modifier is the portable equivalent,
  and it has to sit *after* subdivision or the split vertices are pulled into cracks.

### Not addressed here

These materials are procedural, so — exactly as spike 001 found — none of them will reach
SceneKit until the texture-bake step exists. Nothing here has been exported.
