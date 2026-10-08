# Origami Dogfight — build plan

A handful of folded paper planes dogfight over a folded-paper landscape, seen from above. They
shoot spitballs, paper clips, staples and crumpled paper at each other. A plane that is shot down
spirals into the ground and burns as a little origami fire for a while before it fades, and a
replacement flies in from off-screen, so the number in the air stays constant. Sometimes it is a
free-for-all, sometimes two or three small teams.

Status: **v2 is built, installed and signed off by eye** (`tools/build-origami-library.py`, then
`tools/build-saver.sh OrigamiDogfight -i`). Brandon ran it in the installed host on the Retina
display on 2026-10-07: the scoreboard reads, and pencils read as ballistic. Not yet released —
it reaches `main` by a release merge, like the Aquarium.
Everything under "Decisions" is a starting point chosen so the whole thing could be built and
watched; **look, feel and balance are judged on the running saver, not on paper**, and any of it
can move once it has been seen.

What v1 measured: in a 30-minute headless soak per seed and mode, 6–9 kills a minute, a plane's
centre off-screen for about 0.3% of its fighting time, no non-finite pose, and an identical event
log for the same seed. GPU cost is 1.0–1.1 ms a frame at 2056x1329 and 2.4 ms at 4K. Still
unverified: two displays at once, and a run of hours in the installed host.

Where v1 departed from the decisions below, and why:

- **The glider has scissor cuts.** Folds alone left a plain rectangle that read as a sheet of
  paper, not a plane; real tailed paper gliders are cut too.
- **The landscape is a triangular lattice with every point nudged**, coloured per face. The first
  square grid made every colour boundary a staircase and read as a pixel-art tile map.
- **The fourth team colour is violet, not green**, because a green team disappears over meadow.
- **The picker tile is a crop of a frozen frame**, because the whole arena at 108x71 shows the
  planes as specks. Any change to the simulation moves the fight, so the tile's frame has to be
  re-chosen after one (`tools/build-origami-thumbnail.sh`).

## v3: more life (2026-10-07)

Brandon picked from a list of ideas and asked for all of them, in whatever order works. His own
words decided several details; the rest are calls made for him (*call*).

**Atmosphere**
- **Seasons**, one per session: summer (today's look), autumn (orange and red trees, golden
  fields) and winter (white paper ground, snow on roofs, frozen lakes). *Call:* a frozen lake is
  ground for everything — ammunition lies on the ice, a wreck burns on it, a tank may cross it,
  and the boats are frozen in place.
- **Time of day**, one per session — morning, midday or evening — drifting slowly toward evening
  over a long session; house windows light up in the evening.
- *Call:* both are settings (surprise me by default), alongside the existing four.

**The fight**
- **Aces earn stickers** on their wings at kill milestones — "a range of stickers: gold stars,
  silver stars, smiley faces" — and the scoreboard shows them.
- **Damage shows on the paper**: smudges and scorch marks that deepen as a plane's or tank's
  health drops. Torn edges and crumpled noses would be better still but are much more work;
  smudges and scorches suffice for now.
- **Mid-air collisions**: two planes that touch both crumple and fall. *Call:* rare — about one
  every few minutes at most — so the AI does not look clumsy.
- **Scorch marks on the ground** where things died, fading when a new match begins.
- **Fire spreads** to a nearby tree now and then; a burnt tree stays charred until the next match,
  then folds back to green.
- **Supply drops**: a paper crate drifts down on a tissue-paper parachute; the first plane through
  it gets a better weapon for a while (*call:* triple shot or rapid fire, about 15 s); one that
  lands just fades.

**Around the fight**
- **A flock of paper cranes** crosses now and then, ignoring the fight.
- **A livelier landscape**: windmills turning, sheep wandering in the fields, boats bobbing and
  drifting; paper roads between villages with little cars on them if it fits.
- **Team bases**, only in team matches with two to four teams — "more than that and we'd need to
  fall back to the current mechanism or else the landscape would be all airfields". Each team gets
  an airfield (a runway and a hangar) on clear, flat ground on its side of the view; replacement
  planes take off from it and tanks roll out of it. Free-for-all uses today's edge entry.

**Where the two halves met** (built separately, then integrated):
- *Call:* an airfield is never built across a road, rather than cars stopping short of a runway.
  The roads are therefore the sim's (`Sim/Roads.swift`), a pure function of the seed's terrain
  and props, never of the season. It costs some sites: about 77% of team sides get an airfield
  over a broad soak, against about 78% before (a narrow team-match sample fell to 70%, mostly
  where the road out of the view runs along a team's edge).
- Sheep clear an airfield's ground. The next match is drawn as the two-second intermission begins
  rather than as it ends — nothing draws from the match stream in between, so it is the same
  match — which gives a flock time to trot off before the runway unrolls.
- The scoreboard card skips a corner an airfield stands in.
- Winter has its own dawn and dusk light colours (`DayLight`): the shared keys turned snow
  peach-mauve at dusk and lilac at dawn. Hangars take the season as they are built; sheep take no
  snow and wear cream fleece in winter; stage-1 damage is crisp graphite scuffs, since a soft grey
  wash was invisible on yellow and pink paper.

**After the v3 review** (fixes, and calls made for the user):
- **A landscape must never trap at startup** — that is a black screen every time the seed is
  drawn. `tools/origami-seed-sweep.swift` builds the whole world (sim, countryside, both team
  matches' airfields) for the first 200,000 seeds and 100,000 sampled from the saver's range,
  each a few seconds in, in a child process per batch so a trap names its seed. Run it after any
  change to what the landscape is built from.
- **Roads are checked at their full width** against every lake face they overlap, frozen ones
  included, at every stage of building them; a road that still crossed water would be dropped.
- **A wreck on a runway holds the take-offs** — burning, folding or fading, anywhere a plane
  would roll through it or climb out through its fire. *Call:* after 8 s the waiting plane or
  tank gives up the airfield and comes on from the edge. A wreck that falls in front of a plane
  already rolling cannot be helped; the soak reports those without failing.
- **The countryside steps with the sim**, step by step, never per frame: sheep and cars are the
  same at any frame rate, and are drawn a step behind, between their last two positions.
- **Winter's bare trees are snow-laden**: white on top, shading into a twig-laced violet-brown
  underside. A plain brown crown read as a boulder on the snow, whole white facets as a cut gem.
- **Scorches are smudges, not discs**: round marks with near-black hearts read as holes in
  bright paper.

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
  a match, a side has at most two. *Call (after the review):* tanks shrink with the planes but by
  less — the square root of the planes' scale — since a tank shrunk fully with a "lots" crowd came
  out the size of a house on a landscape that never shrinks.
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
- **Moving parts turn about their own X.** A model whose root is a mesh with children (the
  crane, the windmill) arrives as an Xform named for the model holding the root's mesh and each
  child as sibling Mesh prims. A child keeps Blender's axes as its own frame under the runtime's
  -90° X pivot, so "about its own X" is `node.simdOrientation = rest * simd_quatf(angle:,
  axis: (1, 0, 0))`, which with the prop unturned is the world's +X, the model's forward axis.
- **Birds** — kind `bird` (`crane`). The body is the root mesh; `wing_l` (+Y) and `wing_r` (-Y)
  are child meshes whose origins sit on their hinge lines along X, each wing's root edge on that
  line. At zero both wings are level; a positive turn lifts `wing_l` and lowers `wing_r`, so a
  flap of `a` degrees is `+a` on one and `-a` on the other. Everything is `paper`, tinted per
  bird, its UVs the bird seen from above on a square sheet. The body is centred on its bounds.
- **Turning blades** — a landmark's child `blades` (the windmill's sails, stocks, hub and
  windshaft) has its origin at the hub, faces +X and turns about its own X; at zero the sails
  stand as a "+". A positive turn is counter-clockwise seen from in front, the way the sails
  are pitched for the wind to drive them.
- **Supply drops** — `supply_crate` (kind `crate`) stands on z = 0. `parachute` (kind
  `parachute`) hangs from its origin: its lowest point is the knot where its strings meet, on
  its vertical axis, so the runtime ties the origin to the middle of the crate's lid, the top of
  the crate's bounds.
- **Landscape life** — `windmill` (`landmark`), `sheep` (`animal`), `car` (`vehicle`) and
  `hangar` (`building`) are authored at landscape scale like the houses, stand on z = 0 and face
  +X. The car's body and roof, and the hangar's ridge stripe, are `paper`, tinted at runtime per
  car or per team and UV-mapped as nets like a tank's. The hangar's open end faces +X, where the
  runtime's runway begins.
- **Material names are the seasons' handles.** The runtime recolours scenery by material name,
  so a name says what a part is: foliage ends `_leaf`, roofs `_roof` (`paper_roof_red`,
  `paper_windmill_roof`, `paper_hangar_roof`), and `paper_window` is every window that lights up
  in the evening (houses, windmill, hangar) and nothing else. A car's glass is
  `paper_windscreen`, which never lights.
- **Manifest** — at least `name`, `kind` (`plane` / `projectile` / `tree` / `rock` / `house` /
  `boat` / `fire` / `smoke` / `tank` / `bird` / `crate` / `parachute` / `landmark` / `animal` /
  `vehicle` / `building`), `asset`, and `bounds` (min and max in metres, in the authored
  Blender axes). Planes add `sheetAspect`. Tanks add `sheetAspect` and `turret: {node, pivot,
  muzzles}` — the pivot in Blender axes, the barrel tips in the turret's own space, which is
  where the runtime spawns a shot. Every other kind with `paper` (bird, vehicle, building) adds
  `sheetAspect`. A bird adds `wings: {axis: [1, 0, 0], nodes: [{node, pivot, lift}, ...],
  range: [down, up]}` — `lift` is the sign of a turn about +X that raises that wing (`wing_l`
  1, `wing_r` -1), `range` the degrees of lift a wing may swing through without meeting the
  body. A model with turning blades adds `blades: {node, hub, axis: [1, 0, 0], radius, turn}` —
  `radius` is how far from the axis the sails reach at any angle (the rest pose's bounds do not
  show it), `turn` the sign of the turn the wind drives them in. A building adds `opening:
  {centre, width, height}` — the middle of its open end on the floor, and the clear width and
  height there.

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
