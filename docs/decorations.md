# Decorations, plants and rocks

The tank is populated at launch from a library: a random assortment of species and props
drawn from everything committed under `Savers/Aquarium/Assets/`. A model therefore has to
carry enough information about itself for the runtime to place it sensibly without knowing
what it is — how much floor it needs, which way up it goes, whether two of them may sit
next to each other, and what it does once it is there.

That information is authoring data, not geometry, so it lives in a manifest committed
beside the `.usdz` rather than in Swift. Adding a decoration must not require touching the
saver's source.

## Coordinates and units

- **Metres, and Blender's Z-up, verbatim.** The USD export applies no axis conversion, so
  a hinge authored at `z = 0.10` arrives in SceneKit at `z = 0.10`. The tank is Y-up and
  the correction is a `-π/2` rotation on the pivot node, exactly as `AquariumScene` already
  does for fish.
- **The model sits on the floor at `z = 0`**, centred on X and Y. The runtime should not
  have to guess where the bottom is. `build_prop.py` enforces this by seating the *lowest
  vertex* on the floor, which has a consequence worth knowing before you design: a
  part-buried prop cannot be made by sinking geometry below zero, because the whole model
  is simply lifted back up. Burial has to be a mound of seabed rising over the model.
- **Never leave scale on an object.** Build dimensions into the mesh. Scale left on a
  parent object stretches the space its children live in, so their positions arrive in the
  wrong units and rotating them shears the mesh. See `spikes/004-articulated-decor/`.

## Node naming — the interface to the runtime

| Prefix | Meaning |
|---|---|
| `decor_<name>` | the model root |
| `part_<name>` | a rigid part that moves; **its origin is its pivot** |
| `emit_<name>` | an empty marking a particle emission point |
| `swim_<name>` | an empty marking a waypoint on a route a fish may swim through |

Anything not prefixed is static geometry and the runtime ignores it. A part's origin
becoming its pivot is free — Blender writes the origin as the prim transform and the mesh
arrives as a child node — so a lid hinges correctly if and only if its origin is on the
hinge line.

## Manifest

`Savers/Aquarium/Assets/<name>.json`, next to `<name>.usdz`.

```json
{
  "name": "treasure_chest",
  "asset": "treasure_chest.usdz",
  "category": "decoration",

  "placement": {
    "anchor": "floor",
    "footprint": 0.22,
    "height": 0.16,
    "yawRange": [-180, 180],
    "tiltRange": [-6, 6],
    "scaleRange": [0.85, 1.20],
    "weight": 1.0,
    "maxPerScene": 1,
    "minSpacing": 0.40
  },

  "parts": [
    { "node": "part_lid", "axis": [1, 0, 0], "openDegrees": -64.0 }
  ],

  "emitters": [
    { "node": "emit_bubbles", "rate": 40, "radius": 0.012,
      "size": [0.002, 0.005], "speed": 0.09 }
  ],

  "passages": [
    { "nodes": ["swim_breach_port", "swim_hold", "swim_breach_star"], "radius": 0.18 }
  ],

  "cycle": [
    { "phase": "idle", "duration": [7.0, 16.0] },
    { "phase": "move", "duration": 0.8, "part": "part_lid", "to": 1.0, "ease": "easeOut" },
    { "phase": "emit", "duration": 2.4, "emitter": "emit_bubbles" },
    { "phase": "move", "duration": 1.6, "part": "part_lid", "to": 0.0, "ease": "easeInOut" }
  ]
}
```

- `category` is one of `decoration`, `coral`, `plant`, `rock`. It drives how many of a
  thing the scene wants: a reef needs a lot of coral and one sunken ship.
- `footprint` is a radius in metres and `minSpacing` a centre-to-centre distance, which is
  all the placement pass needs to avoid interpenetration without collision geometry.
- **`footprint` is the untilted radius at scale 1.0, and the runtime is what adds the rest.**
  Tilting a prop swings its top out by `height * sin(maxTilt)`, so the placement pass must
  space by `(footprint + height * sin(maxTilt)) * scale`, not by `footprint * scale`. This is
  deliberately the runtime's job rather than each author's: every value it needs is already in
  the manifest, and the alternative is a rule that every author must remember and that no
  render can catch. It is not a small correction — a 1.35 m prop tilted 2.5° gains 59 mm of
  reach, and two of them at maximum scale overlap by 14 cm if it is ignored.
- `weight` biases random draw; `maxPerScene` caps the showpieces.
- `parts[].openDegrees` defines what `to: 1.0` means, so the cycle stays in normalized
  terms and the angle can be retuned without rewriting the timing.
- A `duration` may be a number or a `[min, max]` range sampled per cycle. Ranges matter:
  several chests on screen opening in lockstep is the single most mechanical-looking
  failure available here.
- Omit `cycle` for a static prop. For something that bubbles continuously — a thermal vent
  — give the emitter `"continuous": true` and omit `cycle`.
- `passages` is what makes a hole worth modelling. A wreck's hull is a closed mesh whether
  or not there is a way through it, and nothing downstream can infer a route from geometry,
  so the model states it as ordered `swim_` waypoints. `radius` is the **tightest**
  clearance along the route, because it decides which species fit — under-declare it, since
  a fish clipping through a hull is much worse than a fish declining a gap it would have
  made. An arch is one passage of two waypoints; a wreck may have several.

## Roster

**Bubblers** (the animated ones, in the order they are worth building):

| Prop | Movement | Bubbles |
|---|---|---|
| Treasure chest | lid hinges open and falls shut | from inside the chest while open |
| Clamshell | upper valve gapes and closes | from between the valves |
| Skeleton with jug | arm and jug rotate together to the mouth | from a hole in the jug's base while raised |

The skeleton is one part, not two: parenting the jug to the arm means a single rotation
lifts both, and the emitter parented to the jug then rides along with no extra machinery.

**Static props:** sunken ship, old-fashioned diving suit, thermal vent (continuous
emitter), amphorae, anchor, portholes, scattered coins.

**Reef:** staghorn / table / brain / mushroom coral, sea fan, tube sponge, anemone.

**Plants:** kelp, giant kelp (tall stalks reaching most of the frame), seagrass, red
macroalgae.

**Terrain:** rock arch and pillars, boulders, rubble, gravel patches.

The arch and the wreck exist to be swum *through*, not past. A tank of things a fish
routes around is flat; one opening a fish commits to crossing gives the depth axis
something to prove. Both declare `passages`.

## Looking at a moving prop

A bubbler is authored closed, because closed is what the tank places — but closed is exactly
the pose in which its most interesting geometry is hidden. Render the open pose to judge it:

```bash
tools/blender/run.sh Savers/Aquarium/Models/build_prop.py -- \
    --prop clamshell --preview --pose part_upper_valve=-24
```

`--pose` is repeatable and is refused alongside `--export`, since exporting a posed model
would ship a chest frozen open.

**One part means a fixed distance.** A single rigid part holds its payload at a fixed distance
from its pivot, so the rest pose is never a free choice: author the *contact* pose and swing it
back by the cycle's own angle to discover where the part must idle. Do it the other way round —
posing the idle by eye and then tuning the swing until the jug reaches the mouth — and the two
disagree again every time the angle is retuned.

For the skeleton this drove the entire silhouette, not just the arm: low shoulders, a high
skull, a ribcage starting well up the spine, and the jug resting on a thigh rather than on
the sand, all so that one rotation lands the jug at the lips.

## Bake interaction

`build_prop.py --export <asset.usdz> --bake` is the production path. It evaluates every live
modifier before unwrapping; `bake_atlas` deliberately refuses modifiers because generated
faces would otherwise overlap the base mesh's UVs and silently corrupt the result.

Static props are evaluated, joined, unwrapped, and baked exactly like fish. The result is one
mesh with one atlas material and base-colour, roughness, and tangent-space normal textures.
Joining is correct even for a large source hierarchy: staghorn's thicket plus holdfast and
anemone's crown plus column both bake this way.

Articulated props are not joined. Each mesh is Smart UV Projected, and those layouts are
scaled into disjoint tiles in one shared UV space. Tile gutters are derived from the pixel bake
margin so one object's dilation cannot overwrite another's seam padding. Blender bakes the
complete selected object set to each image in one call; every mesh then receives the same atlas
material while named nodes, parenting, origins, and pivots remain unchanged. Linked mesh data
must first be made single-user. A two-part hinge probe arrived in SceneKit with textures on
both pieces, and `part_lid` still rotated correctly about its hinge. One shared atlas is the
settled path for articulated props; per-part texture sets are unnecessary.

Custom vertex attributes need not survive USD export. Cycles evaluates them as part of the
procedural material and writes the resulting colour into the atlas. This was visually verified
for staghorn's pale `tipness` growth tips and anemone's `tentacle_t` base-to-tip gradient in
both their atlas PNGs and SceneKit renders.
