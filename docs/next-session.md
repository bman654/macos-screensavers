# Where to pick up

Rewritten 2026-08-13, at the end of the session that populated the tank and art-directed
its three looks; extended the same day by the session that ran it on a Retina display.

## State

**The aquarium renders as a tank.** A random assortment of fish and decorations is drawn per
launch, placed on a substrate, lit by one of three art-directed looks, and every model is
textured. Nothing is blocked.

**It runs on Retina.** Full screen at 4112x2658 — a 2056x1329-point built-in display at 2x —
all three styles render at 5.4 ms of GPU time per frame, and ten minutes of continuous running
covered 62,254 frames with no drift. The composition, the preview threshold, a live reshape and
a live *scale* change are all correct at 2x. It could hold 120 fps and is deliberately capped
at 60: half the energy, and nothing in a tank of drifting fish reads differently.

Two things came out of that testing. `SAVERKIT_STATS` now reports frame and GPU timing from any
run. And the bloom radius was in pixels, so every look lost half its glow width on a Retina
display — fixed, though see the trap below for why you cannot yet see it.

```
14 fish species        Savers/Aquarium/Models/species/<name>.py
16 props               Savers/Aquarium/Models/props/<name>.py
   the library build   tools/build-library.py      -> Savers/Aquarium/Assets/ (36.8 MB)
   the tank            Savers/Aquarium/Sources/*.swift
   the three looks     docs/water-looks.md
```

**The generated library is not tracked.** Models are code; the `.usdz` and `.json` under
`Savers/Aquarium/Assets/` are its outputs, and a re-bake is part of the normal loop rather
than an event. On a fresh clone run `tools/build-library.py` (about 10 minutes) before
`tools/build-saver.sh`.

## Loops

```bash
tools/build-library.py --only clownfish --only boulder     # rebuild specific assets
tools/build-saver.sh Aquarium
AQUARIUM_STYLE=aquarium AQUARIUM_SEED=42 tools/run-saver.swift Aquarium \
    --size 1600x900 --seconds 4 --screenshot /tmp/tank.png
tools/water-luminance.py /tmp/tank.png                     # floor-vs-water coherence
tools/gallery.py --out /tmp/sheet.png --columns 4 'build/props/*/water_00_side.png'
SAVERKIT_STATS=5 tools/run-saver.swift Aquarium --size 2056x1329 --seconds 30 \
    --screenshot /tmp/tank.png                             # frame and GPU timing
```

`AQUARIUM_STYLE` is one of `shallowReef` (default), `deepOcean`, `aquarium`. `AQUARIUM_SEED`
pins the layout; without it every launch draws a different tank.

**Look at the PNG, at the size it will be seen.** This repo's hardest-won rule, and it held
again all session: every art problem found this session was visible in an image and invisible
in the parameters. The user caught a floating wreck, an oversized diving suit, a skeleton
inside a rock and a white seam on the clam by looking at renders.

**Never pipe a build through `tail`.** A run dying with a `NameError` still exits past a
`| tail -2`, and the PNGs you then open are the previous run's. Grep for `Error|Traceback`.

## Next, in order

1. **A settings sheet.** The three looks exist but **a real user cannot choose one** — the
   style is selected by an environment variable, which is a developer affordance. This wants
   `ScreenSaverView.configureSheet` with `ScreenSaverDefaults`, keyed by the *bundle's*
   identifier rather than `Bundle.main`. It is also where the audio toggle belongs.
2. **Caustics and god rays.** Deliberately held back so the lighting pass did not sprawl.
   The shallow reef is now good enough that dappled light on the sand would sell it hard;
   a ripple gobo is a spotlight cookie, not new infrastructure.
3. **Fish AI and depth lanes**, including the clownfish's anemone affinity — see
   `docs/aquarium-plan.md` §2. Site-attached fish are *cheaper* than crossing fish, and give
   the tank a second kind of motion.
4. **The audio spike.** `spikes/006-saver-audio/`. See `docs/saver-backlog.md` for the
   direction and the three hazards that will not be obvious later.
5. **Lionfish and seahorse.** Deferred all along; each needs a spec extension the other
   twelve did not (independent dorsal spines; a curled prehensile tail).

## Known gaps, deliberately left

- **Brass cannot glint in the aquarium.** Reflection is `baseColour x environment` and the
  aquarium's environment is strongly blue, so a red-orange alloy has no red to return. A warm
  accent lamp in that look is the fix; the shallow reef already has enough warmth.
- **No screen-space occlusion test in placement.** World spacing is respected, but a far
  anchor can still end up behind a near cluster.
- **A live reshape keeps the layout it was born with.** Only the floor height follows;
  redrawing would mean re-importing mid-run.
- **`mouth` should probably fold into `patches`** — it is a patch with frozen softness.
- **`cap_rings` is not exposed by `build_branching`**; rounded tip caps are ~40% of a
  branching prop's vertices.
- **The boulder is the weakest prop.**
- **`studio_lights` runs about a stop hot for large matte props**; `build_prop.py` compensates
  with `exposure=-2.0` rather than falsifying albedos.
- **`SceneKitProbe.worldBounds` over-reports a rotated hierarchy** — same bug class as the one
  fixed in `_drop_to_floor`, still present in the diagnostic.
- **`SceneKitProbe` frames on X extent**, so it crops a tall prop to its middle.

## Traps that cost real time. Each is commented where it happens; this is the index

- **`scene_bounds` returns the box of a rotated box.** It transforms local bounding-box
  corners, so for anything rotated it is a superset. Right for framing a camera, wrong for any
  number that becomes a contract — a listing wreck exported hanging 0.65 m above the seabed.
  Use `studio.world_mesh_bounds` where exactness matters.
- **The bake only keeps what `UsdPreviewSurface` can express.** Coat, iridescence, sheen and
  transmission are all discarded. A material authored as a pale substrate under an iridescent
  coat arrives as just the pale substrate — the clam's interior baked to near-white. Put the
  colour in the albedo, because it is the only channel that travels.
- **The Blender preview is not the shipped material.** It still shows the coat, so a fix of
  the kind above is invisible there. Measure the atlas.
- **A metal has almost no diffuse component**, so a `DIFFUSE` bake loses its albedo entirely —
  the diving suit's brass measured 0.000 warm texels against a declared red-orange. Base colour
  bakes through an emission pass for this reason.
- **Nothing is metal unless metalness is baked and wired.** Without it every material is a
  dielectric and cannot return a coloured reflection whatever its albedo.
- **Metal needs an environment to reflect.** With no `scene.lightingEnvironment`, PBR metal
  collapses toward its dark specular response and reads as wet stone. Three directional lights
  give highlights, not an environment.
- **The ground must not out-brighten the water it is seen through.** Light on the seabed and
  light scattering in the column come from one budget. The old tank had the floor at 4.87x the
  backdrop *and* darkening with distance, which reads as a lit shelf dropping into an abyss.
  `tools/water-luminance.py` checks it.
- **An acceptance metric calibrated on one tank silently lies about another.** The
  fish-colour check discarded every fish in the aquarium as scenery, because its size filter
  predated fish being 3x the frame fraction — it reported a frame of vivid tangs as colourless.
  Reject props by whether they stand on the floor, not by size.
- **Decorations are sized in screen fractions; fish are sized in metres.** A 0.4 m angelfish
  beside a 0.6 m wreck is *correct* in the aquarium and looks wrong by ocean logic. Do not
  "fix" it — the asymmetry is what makes a small tank read as a tank.
- **A texture tuned for one floor depth is wrong at another.** Gravel tiled for a floor
  entering at 6.2 m read as boulders at 2.25 m.
- **`SCNCamera.bloomBlurRadius` is documented in points and applied in render-target pixels.**
  One emissive quad of fixed frame fraction, rendered at 512, 1024 and 2048 px, glowed the
  same 24 px at all three — so a look tuned on a 1x display loses half its glow width on a
  Retina one. `adopt(backingScale:)` multiplies it. Assume the same of any other radius
  SceneKit exposes, and of a hand-written post-process kernel.
  **The correction is currently invisible, and that is a fact about the tank, not the fix.**
  Doubling the radius moved the frame no more than two runs of the *same* build differ by:
  under 0.1% of a tank is above the 0.88-0.95 bloom threshold, so there is almost nothing to
  glow. It will start to matter with the god rays. The radius itself is verified directly —
  24 px at 2x against an authored 12 — because measuring it from the image cannot work.
- **A saver's own motion swamps an image diff.** Two captures of the same build at the same
  elapsed time differ by 62/255 in the brightest luminance band, because that band *is* the
  fish. An A/B of a subtle effect therefore needs the same-build noise floor beside it, or it
  will confirm whatever it was pointed at. This cost one wrong conclusion today.
- **A host is built before the view is in a window**, so `CAMetalLayer.contentsScale` is still
  1 at that moment even on a Retina display: host creation was observed at scale 1 and 900x600
  points, corrected to scale 2 and 1800x1200 in the same millisecond. Anything scale-dependent
  must come from `RenderTargets`, which is why `HostContext` deliberately does not carry a
  scale. A value read at creation is wrong precisely where it matters.
- **The capture harness must never surface.** `run-saver.swift` parks its window at desktop
  level during a screenshot: not activating is insufficient, because macOS gives the top window
  focus and this tool runs several times a minute across concurrent agents.
- **Do not let agents research on the web here.** A research fan-out hit a CAPTCHA and one
  subagent escalated to a *headed* browser to defeat it, putting windows on the user's screen.
  Ask the user for a number instead; they are faster and it is their machine.
- **Never leave scale on an object.** A non-uniform parent scale puts children in a stretched
  space and rotating them shears instead of turning. Fatal for anything hinged.
- **Never bake a mesh with live modifiers.** Unwrapping sees the base mesh, baking sees the
  evaluated one. `bake_atlas` refuses.
- **A direct mesh write does not tag the depsgraph**, so a Boolean happily evaluates a stale
  operand. Call `obj.update_tag()` and `view_layer.update()` before `evaluated_get`.
- **The exact boolean does not report failure — it returns a wrong answer**, silently the
  union or an empty mesh. Cut with a clean primitive, erode afterwards, and assert a difference
  can only shrink the bounding box.
- **`displace` along normals tears at silhouette-scale amplitudes**, and facets rather than
  undulates when the feature size nears the mesh's edge length. Reach for broader and weaker
  than instinct suggests; add mesh resolution before adding noise frequency.
- **A ColorRamp holds 32 stops.** It now raises.
- **`rock_material` has a brightness floor around 0.19 median luminance.** Anything meant to
  read near-black must earn it by contrast with a brighter neighbour.
- **Branching density is not what makes coral read as coral** — internode length is.
- **Contrast is fine; contrast aligned with a crease is not.** Strata bands quantised to a
  ring grid read as hazard tape, and the same step landing on the crown seam read as a moss
  beret. The rock pillars took two rounds of this.

## Unverified — do not assume these work

- **Audio from inside a sandboxed `legacyScreenSaver`.** Output needs no entitlement so it
  ought to work, but `WKWebView` also looked fine here and blanked after three seconds.
- **Multi-display.** macOS instantiates a saver per screen, which is also what would make
  audio play three times at once, and each screen gets its own MSAA attachments — about
  350 MB at 4112x2658. This machine *mirrors* rather than extends, so it presents one logical
  display; testing this means turning mirroring off first.
- **The real `legacyScreenSaver` host at 2x.** Everything above was measured through
  `run-saver`, which is the same view in an ordinary window. Installing and running it for
  real is a minute's work and has not been done since the tank was populated.
- **The `default.metallib` path**, for lack of a Metal toolchain on this machine.
