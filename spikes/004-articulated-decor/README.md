# Spike 004 — articulated decorations

**Question:** the decorative bubblers (a treasure chest whose lid opens, a clamshell that
gapes, a skeleton that raises a jug) need parts that move independently. Fish are joined
into a single mesh precisely so that nothing has to move independently. Can a decoration
keep a hierarchy through USD and arrive in SceneKit as named nodes that rotate about the
right pivots?

**Answer:** yes, on one condition — every object's scale must be applied into its mesh
before export.

## Reproduce

```bash
tools/blender/run.sh spikes/004-articulated-decor/hinge_probe.py -- /tmp/hinge.usdz
swiftc -O spikes/004-articulated-decor/HingeProbe.swift -o /tmp/hingeprobe \
    -framework SceneKit -framework AppKit
/tmp/hingeprobe --input /tmp/hinge.usdz --out-dir /tmp/hinge-out
```

Add `--object-scale` to the Blender command to reproduce the failure described below.

## What held

- **Named nodes survive.** `childNode(withName:recursively:)` finds `part_lid` and
  `emit_bubbles`. Node names come straight from Blender object names, so the naming
  convention below is the whole interface.
- **Empties export as transform nodes.** A Blender empty arrives as a geometry-less
  `SCNNode`, which means a bubble emission point can be authored as part of the model and
  read back by name rather than hard-coded as a magic offset in Swift.
- **Object origin becomes the pivot, for free.** Blender writes an object's origin as its
  prim transform, and the mesh arrives as a *child* node of it. So the object node is a
  pure transform: setting `eulerAngles` on it rotates about the origin with no pivot
  metadata to carry across. Put a lid's origin on its hinge line and hinging is just a
  node rotation.
- **Emitters inherit their parent's motion.** With the emitter parented to the lid,
  `convertPosition(_:to: nil)` tracks the lid as it opens — so bubbles leave from wherever
  the moving part currently is, which is what the chest and the skeleton's jug both need.

## The trap: never leave scale on an object

With a non-uniform scale left on the parent object, children live in a stretched space.
Two symptoms, both of which look like modelling mistakes rather than transform mistakes:

- Child node positions arrive in the parent's *scaled* units, not metres. The lid hinge
  authored at `z = 0.10 m` under a parent scaled `0.10` in Z arrived as `z = 0.5`.
- Rotation inside that space **shears** instead of turning. The emitter's distance from
  the hinge was not preserved across the sweep, so the lid visibly deformed as it opened.

With scale applied into the mesh data, `part_lid` arrives at exactly `(0, 0.07, 0.10)` —
real metres — and the emitter holds a constant radius of `0.0447 m` about the hinge at
every angle. So: build dimensions into the mesh (`mesh.transform(...)`), and leave object
transforms as translation and rotation only.

## Conventions this establishes

Node names are the interface between a model and the runtime, so they are fixed:

| Prefix | Meaning |
|---|---|
| `decor_<name>` | the model root |
| `part_<name>` | a rigid part; its origin is its pivot |
| `emit_<name>` | an empty marking a particle emission point |

Everything a decoration needs beyond geometry — which axis a part turns about, how far,
how long each phase lasts, how fast a vent bubbles — is authoring data, not geometry, and
belongs in a manifest committed next to the `.usdz`. See `docs/decorations.md`.

## Not addressed here

Whether the same hierarchy survives the *texture bake* path (baking joins meshes; an
articulated model must be baked per-part or unwrapped without joining), and the runtime
side that reads a manifest and plays the cycle.
