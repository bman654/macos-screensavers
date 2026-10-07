# Origami Dogfight — build plan

A handful of folded paper planes dogfight over a folded-paper landscape, seen from above. They
shoot spitballs, paper clips, staples and crumpled paper at each other. A plane that is shot down
spirals into the ground and burns as a little origami fire for a while before it fades, and a
replacement flies in from off-screen, so the number in the air stays constant. Sometimes it is a
free-for-all, sometimes two or three small teams.

Status: **v1 is built and installable** (`tools/build-origami-library.py`, then
`tools/build-saver.sh OrigamiDogfight -i`), awaiting a first look on the real screensaver.
Everything under "Decisions" is a starting point chosen so the whole thing could be built and
watched; **look, feel and balance are judged on the running saver, not on paper**, and any of it
can move once it has been seen.

What v1 measured: in a 30-minute headless soak per seed and mode, 6–9 kills a minute, a plane's
centre off-screen for about 0.3% of its fighting time, no non-finite pose, and an identical event
log for the same seed. GPU cost is 1.0–1.1 ms a frame at 2056x1329 and 2.4 ms at 4K. Two things
are unverified: a session in the installed host (only the harness has run it), and two displays
at once.

Where v1 departed from the decisions below, and why:

- **The glider has scissor cuts.** Folds alone left a plain rectangle that read as a sheet of
  paper, not a plane; real tailed paper gliders are cut too.
- **The landscape is a triangular lattice with every point nudged**, coloured per face. The first
  square grid made every colour boundary a staircase and read as a pixel-art tile map.
- **The fourth team colour is violet, not green**, because a green team disappears over meadow.
- **The picker tile is a crop of a frozen frame**, because the whole arena at 108x71 shows the
  planes as specks. Any change to the simulation moves the fight, so the tile's frame has to be
  re-chosen after one (`tools/build-origami-thumbnail.sh`).

## v2: after the first look (2026-10-07)

Brandon watched v1 and liked the overall design, the terrain and the lake banks. What he asked
for next, and the calls made on his behalf where he left a detail open (marked *call*):

- **Ammunition that lands in a lake splashes and sinks**, the way a crashed plane does, instead of
  lying on top of the water.
- **Planes read slightly too large, which makes them feel fast.** The fix is scale, not camera:
  each match picks a plane count, and the more planes, the smaller the planes *and* everything
  that belongs to them — their speed, turning circle, weapon range, ammunition, confetti, smoke,
  fire and wrecks. The landscape and its props never change size, and the camera never moves, so
  no extra landscape is rendered. *Call:* the scale is self-similar (a smaller plane flies the same
  number of body lengths per second), and the baseline drops a little even at today's count.
- **A wider range of plane counts**, chosen per match: a few (3–4), some (5–7, today's), lots
  (8–12). *Call:* lots tops out at 12, subject to the frame-cost budget.
- **A settings sheet in words, not numbers.** *Call:* Teams — free-for-all / teams / surprise me;
  Planes — a few / some / lots / surprise me; Tanks — off / sometimes / always; Scoreboard — on or
  off. Defaults: surprise me, surprise me, sometimes, on. Surprise me re-rolls every match.
- **A scoreboard** showing kills by colour and the time until the match ends, in **a different
  corner each match** so nothing sits in one place long enough to burn in. *Call:* it is part of
  the paper world — a small card drawn in the corner — not a UI overlay.
- **Paper tanks on the ground that shoot at planes.** *Calls:* tanks belong to a side like a plane
  does and are killable; planes attack them with shallow strafing dives and the bomber also drops
  its crumpled paper balls on them; a destroyed tank burns like a crashed plane and a replacement
  rolls in from the edge. Tanks fire **pencil stubs** steeply upward, which rise toward the camera
  and fall back if they miss. Tanks keep to dry, gentle ground inside the view. When tanks are in
  a match, a side has at most two.
- **Sound: not yet.** v1's question was what an origami dogfight should sound like; ideas are
  offered rather than built.

## Decisions (v1 defaults)

- **SceneKit through `SceneKitHost`, like the Aquarium.** Real 3D models, real shadows. The
  overhead view is a perspective camera looking almost straight down with a slight tilt, so hills
  read as relief and a plane's altitude reads as size and as the distance to its own shadow.
  **Shadows on the terrain are the main depth cue** and are not optional.
- **The camera is fixed for a session.** The fight is the motion.
- **The landscape is generated at runtime from a seed**, not modelled in Blender: a faceted,
  flat-shaded height field, coloured in paper bands (lake, shore, meadow, hill, rock, snow),
  so every face reads as a separate folded piece. Lakes are flat blue paper. The props on it —
  trees, rocks, houses, paper boats — are Blender models scattered at runtime.
- **The planes, projectiles, props and fire are Blender models** (`Models/`), per the repo rule
  that models are code.
- **A plane's paper is a runtime texture.** A plane is modelled as a folded sheet whose UVs are
  the sheet's own flat coordinates, so any paper — lined notebook, graph, newspaper, plain
  coloured — lands on it with its lines running across the folds the way a real folded sheet's
  would. Teams fly one colour each; a free-for-all gives every plane a different paper.
- **The simulation is a fixed-step, seeded 2.5D sim.** Planes fly on a horizontal band with a
  little altitude play; they cannot stop, turn at a limited rate and bank into turns.
  Projectiles fly at the shooter's height and drop under gravity. Fixed step, because a sim
  integrated against the frame delta is not reproducible from a seed (`next-session.md`, traps).
- **No wrap-around.** The edges of the view are a soft wall the AI steers away from. A
  replacement plane is the only thing that enters from off-screen.
- **Matches.** Each match picks a mode and a roster; after a number of kills (or a time limit)
  the survivors fly off and a new match begins with a new mode. The landscape stays.
- **No sound in v1, and no settings sheet in v1.** Both are easy to add later; sound would follow
  the Aquarium's default-off policy and its session gate (`docs/saver-host.md` §3).

## Roster

Plane stats live in Swift (`Sources/`), not in the model manifests: speed, turn rate and armour
are game design, and the models only promise their geometry. Starting values; balance is tuned by
watching.

| Model | What it is | Flies | Armour | Weapons (one picked per plane) |
| --- | --- | --- | --- | --- |
| `dart` | The classic dart every kid folds first: long, narrow, sharp | fastest, wide turns | light | spitball, thumbtack |
| `glider` | Wide straight wings, blunted nose | slow, very nimble | medium | paper clip, eraser crumb |
| `bomber` | Squat and fat, flat folded-back nose, stubby wide wings | slowest | heavy | crumpled paper ball, hole-punch confetti (spread) |
| `stunt` | Delta wing with upturned winglets | quick, agile | medium | staples (3-round burst) |
| `interceptor` | Needle nose, swept wings, split tail | fast, agile | light | rubber band, thumbtack |

| Projectile | Model | Reads as |
| --- | --- | --- |
| spitball | `spitball` | wet off-white lump |
| thumbtack | `thumbtack` | coloured head on a pin |
| paper clip | `paper_clip` | tumbling silver clip |
| eraser crumb | `eraser` | pink rubber wedge |
| crumpled paper ball | `paper_ball` | big faceted lined-paper ball, slow, falls fast |
| hole-punch confetti | runtime discs | spread of tiny paper dots |
| staple | `staple` | small silver U, in bursts of three |
| rubber band | `rubber_band` | stretched loop, long range |

Misses do not vanish: they fall to the ground and lie there briefly before fading.

## Lifecycle of a plane

1. **Enter** from just outside a random edge, heading inward, ignoring the edge wall until inside.
2. **Fight**: pick a target (nearest enemy in front, sticky), lead-pursue it, fire when it is in
   the weapon's cone and range, break off when an enemy is on its tail, keep off the edges, keep
   clear of its own side.
3. **Hit**: a puff of confetti in the victim's paper; past half armour it trails paper scraps.
4. **Shot down**: loses control, spirals and dives, trailing smoke.
5. **Crash**: nose-down in the ground with an origami fire on it for ~15 s, then the fire folds
   away and the wreck fades. Into a lake it splashes and sinks instead, no fire.
6. **Replaced**: after a short delay a new plane of the same side enters from off-screen.

## Asset contract (Blender → runtime)

Built by `tools/build-origami-library.py` into `Savers/OrigamiDogfight/Assets/` (generated, not
committed — see `.gitignore`), one `<name>.usdz` per model plus `<name>.json`, and an
`index.json` listing them. The runtime survives any of it being missing: a missing model is drawn
as a simple stand-in, never a black screen.

- **Axes** — authored in Blender Z-up, **nose / front toward +X**, up +Z, left toward +Y: the
  same convention as the Aquarium's fish. A prop stands on z = 0, centred on the origin.
- **Size** — authored at real size in metres (a letter-paper dart is about 0.28 m long). The
  manifest records the bounding box; the runtime scales every model to its on-screen size.
- **Flat shading.** Every face its own normal — the folds are what make it read as paper.
- **Planes** — one joined mesh, one material named `paper`, UV map = the unfolded sheet's flat
  coordinates in [0, 1]², u across the sheet's width and v along its length, with the sheet's
  aspect recorded in the manifest (`sheetAspect`, height / width). The runtime replaces the
  material.
- **Everything else** — flat colours from a Principled BSDF base colour (exported as
  `UsdPreviewSurface`), material names describing the part (`paper_leaf`, `paper_trunk`,
  `wire`...). Bake nothing unless a model genuinely needs it.
- **Fire** — each flame tongue its own child object named `flame_<n>`, origin at its base, so
  the runtime can flicker them independently by scaling.
- **Tanks** — kind `tank`. The turret is a child object named `turret`, origin on its vertical
  rotation axis, barrel along +X; the hull is the rest. Hull and turret paper use material
  `paper` (tinted per side at runtime, like a plane); treads and anything else keep authored
  colours.
- **Manifest** — at least `name`, `kind` (`plane` / `projectile` / `tree` / `rock` / `house` /
  `boat` / `fire` / `smoke` / `tank`), `asset`, and `bounds` (min and max in metres, in the authored
  Blender axes). Planes add `sheetAspect`.

## Shared code

The saver subclasses `SaverView` and builds a `SceneKitHost`, exactly as the Aquarium does, so the
leak, idle-release, audience and quality machinery comes for free. `docs/saver-host.md` §2
"Yours to get right" is the checklist the saver must still meet. The seeded RNG (`Rand`) moves
from the Aquarium into SaverKit, since this is the second saver to need it.

## Verifying it

- A headless soak of the sim: minutes of simulated fighting with kills per minute, time spent out
  of view, planes in the air, and the longest stretch with no shot fired, so a degenerate fight —
  planes circling forever, or leaving the screen — is caught by numbers rather than by luck.
- `run-saver` screenshots at several moments, at Retina and 4K sizes, and frame timings from
  `SAVERKIT_STATS`.
- The lifecycle checks in `docs/saver-host.md` §2 "Proving you have not regressed it".
