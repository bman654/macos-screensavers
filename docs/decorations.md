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
  have to guess where the bottom is.
- **Never leave scale on an object.** Build dimensions into the mesh. Scale left on a
  parent object stretches the space its children live in, so their positions arrive in the
  wrong units and rotating them shears the mesh. See `spikes/004-articulated-decor/`.

## Node naming — the interface to the runtime

| Prefix | Meaning |
|---|---|
| `decor_<name>` | the model root |
| `part_<name>` | a rigid part that moves; **its origin is its pivot** |
| `emit_<name>` | an empty marking a particle emission point |

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
- `weight` biases random draw; `maxPerScene` caps the showpieces.
- `parts[].openDegrees` defines what `to: 1.0` means, so the cycle stays in normalized
  terms and the angle can be retuned without rewriting the timing.
- A `duration` may be a number or a `[min, max]` range sampled per cycle. Ranges matter:
  several chests on screen opening in lockstep is the single most mechanical-looking
  failure available here.
- Omit `cycle` for a static prop. For something that bubbles continuously — a thermal vent
  — give the emitter `"continuous": true` and omit `cycle`.

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

**Plants:** kelp, seagrass, red macroalgae.

**Terrain:** boulders, rubble, gravel patches.

## Bake interaction — unresolved

Texture baking joins a model into a single mesh so it becomes one material and one draw
call. An articulated model cannot be joined, because its parts have to move. So a
decoration must either be baked per-part into a shared atlas, or unwrapped and baked
without joining. Settle this before authoring the bubblers, not after.
