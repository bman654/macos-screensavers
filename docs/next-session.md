# Where to pick up

Rewritten 2026-08-13, at the end of the session that populated the tank and art-directed
its three looks; extended the same day by the sessions that ran it on a Retina display, built
its settings sheet, and rebuilt the aquarium's substrate as real gravel.

## State

**The aquarium renders as a tank.** A random assortment of fish and decorations is drawn per
launch, placed on a substrate, lit by one of three art-directed looks, and every model is
textured. Nothing is blocked.

**A user can now choose the look.** `AquariumSettingsSheet` is the saver's `configureSheet`:
three looks plus "Surprise me", each with a live preview of the tank it selects, persisted to
`ScreenSaverDefaults` under the saver bundle's own identifier. OK reloads the running view's
host so the thumbnail behind the sheet adopts the choice; Cancel leaves nothing behind.

**It is installed and confirmed in System Settings.** Every option worked, the thumbnail
changed on each selection, and full-screen Preview ran — so the sheet, the live preview inside
it, `reloadHost` and the real full-screen path are all exercised in the host that matters, not
just through `run-saver`.

**It runs on Retina.** Full screen at 4112x2658 — a 2056x1329-point built-in display at 2x —
all three styles render at 5.4 ms of GPU time per frame, and ten minutes of continuous running
covered 62,254 frames with no drift. The composition, the preview threshold, a live reshape and
a live *scale* change are all correct at 2x. It could hold 120 fps and is deliberately capped
at 60: half the energy, and nothing in a tank of drifting fish reads differently.

Two things came out of that testing. `SAVERKIT_STATS` now reports frame and GPU timing from any
run. And the bloom radius was in pixels, so every look lost half its glow width on a Retina
display — fixed, though see the trap below for why you cannot yet see it.

**The aquarium's floor is gravel now, and it is seen through the glass.** Three changes, and
`docs/water-looks.md` §"The gravel" is where they are argued:

- The bed is a packed field of separate stones splatted through a height buffer, with a normal
  map the tank's lamp actually lights. The old floor was flat-shaded ellipses, which no palette
  could rescue.
- The bottom 11% of the frame is the bed **in section**, pressed against the front pane, the way
  the bottom of an aquarium photograph is. This needed a camera move rather than a texture: the
  viewer now stands outside the glass, because a camera sitting on the pane can never see a bed
  in section however deep the bed is.
- Twenty-eight palettes, drawn per launch — naturals, single-hue beds, two-tone contrast mixes,
  and the fluorescent bag. Every tile is normalised so the look's floor-versus-water ratio holds
  whatever colour was drawn, and the correction for the tank's blue wash is made entirely in
  chroma, where the coherence rule has nothing to say.

```
14 fish species        Savers/Aquarium/Models/species/<name>.py
16 props               Savers/Aquarium/Models/props/<name>.py
   the library build   tools/build-library.py      -> Savers/Aquarium/Assets/ (36.8 MB)
   the tank            Savers/Aquarium/Sources/*.swift
   the three looks     docs/water-looks.md
   the substrate       Substrate.swift, GravelPalette.swift, SubstrateTexture.swift,
                       TankFloor.swift
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
tools/crop.py /tmp/tank.png --out /tmp/band.png --band     # the substrate, at 1:1
tools/gallery.py --out /tmp/sheet.png --columns 4 'build/props/*/water_00_side.png'
SAVERKIT_STATS=5 tools/run-saver.swift Aquarium --size 2056x1329 --seconds 30 \
    --screenshot /tmp/tank.png                             # frame and GPU timing
tools/run-saver.swift Aquarium --configure --seconds 3 --screenshot /tmp/sheet.png
```

**The Python tools need an interpreter this repo does not track.** `water-luminance.py`,
`crop.py` and `build-library.py` want numpy, scipy and Pillow, and the machine's `python3` has
none of them — the failure is a bare `ModuleNotFoundError` that reads like a broken tool:

```bash
uv venv --python 3.14.3 .venv
uv pip install --python .venv/bin/python numpy scipy pillow
.venv/bin/python tools/water-luminance.py /tmp/tank.png
```

`AQUARIUM_STYLE` is one of `shallowReef` (default), `deepOcean`, `aquarium`, `random`, and
overrides the saved setting. `AQUARIUM_GRAVEL` pins which of the twenty-eight gravel palettes the
aquarium wears — `river`, `neon`, `monochrome`, `arctic`, … see `GravelPalette.all` — and an
unknown name falls back to the draw rather than failing. `AQUARIUM_SEED` pins the layout; without
it every launch draws a different tank.

All three are independent of the tank's own stream: the style, the gravel and the layout each
take a stream of their own off the same seed, so every seeded render made before any of them
existed still names the same tank it always did. **Anything else drawn per launch must be added
the same way** — a draw taken from the launch stream reshuffles everything drawn after it, and
the failure is silent because both tanks are plausible.

**Look at the PNG, at the size it will be seen.** This repo's hardest-won rule, and it held
again all session: every art problem found this session was visible in an image and invisible
in the parameters. The user caught a floating wreck, an oversized diving suit, a skeleton
inside a rock and a white seam on the clam by looking at renders.

**Never pipe a build through `tail`.** A run dying with a `NameError` still exits past a
`| tail -2`, and the PNGs you then open are the previous run's. Grep for `Error|Traceback`.

## Next, in order

1. **Caustics and god rays.** Deliberately held back so the lighting pass did not sprawl.
   The shallow reef is now good enough that dappled light on the sand would sell it hard;
   a ripple gobo is a spotlight cookie, not new infrastructure.

   The substrate was done first on purpose, and it changed what this phase inherits. The floor
   the gobo lands on is now a normal-mapped bed of stones rather than a flat wash, so a caustic
   pattern has something to break over — and the aquarium has a *second* substrate surface, the
   cross-section band, which faces the room rather than the lamp. Decide deliberately whether
   caustics reach it: they should not, or barely, because the light making them is above the bed
   and the band is a cut through it. `docs/water-looks.md` still holds the two warnings from
   before — the deep look's key at 520 is faint for a gobo, the aquarium's 1350 from near
   overhead is exactly the light a caustic belongs on — plus a new one: the substrate's crevice
   shading is baked into the albedo and its directional shading deliberately is not, so a gobo
   modulating the key is already correct and must not be compensated for twice.
2. **Fish AI and depth lanes**, including the clownfish's anemone affinity — see
   `docs/aquarium-plan.md` §2. Site-attached fish are *cheaper* than crossing fish, and give
   the tank a second kind of motion.
3. **The audio spike.** `spikes/006-saver-audio/`. See `docs/saver-backlog.md` for the
   direction and the three hazards that will not be obvious later.
4. **Lionfish and seahorse.** Deferred all along; each needs a spec extension the other
   twelve did not (independent dorsal spines; a curled prehensile tail).
5. **The picker thumbnail.** The saver's tile in the Screen Saver list is blank. Deliberately
   last: the picture should be a frame of the finished tank, so shooting it before the
   caustics and the fish AI land means shooting it twice.

   What is known, from what ships on this machine rather than from documentation: Apple's
   `/System/Library/Screen Savers/Random.saver` carries `Contents/Resources/thumbnail.png` at
   90x58 and `thumbnail@2x.png` at 180x116, and its `Info.plist` names neither — so it is a
   filename convention, not a declared key. `FloatingMessage.saver` ships no thumbnail at all.
   Unknown, and worth establishing first with a throwaway image: whether Tahoe's picker honours
   those files for a third-party saver, and whether it will take an image larger than 90x58,
   because the tiles in that list are much bigger than 90 points wide. `build-saver.sh` would
   grow a step that copies them, and the frame itself should come from `run-saver --screenshot`
   at the tile's aspect ratio so the picture is the saver rather than a painting of it.

## Known gaps, deliberately left

- **The gravel palette is not in the settings sheet.** It is drawn per launch and pinnable from
  the environment, which is what the tank needed; letting a user *choose* their gravel is a
  different feature and a fourth control on a sheet that currently asks one question. If it is
  ever added, note that the sheet rebuilds a whole tank per click at 234–354 ms, so a
  twenty-eight-item picker with a live preview is not the shape it should take.
- **A palette's brightness is derived from the bag, not authored.** `GravelPalette.brightness`
  compresses the in-air luminance so a white bed reads white and a black bed reads black without
  breaking the coherence rule. It is one curve over twenty-eight palettes and it will be wrong
  for some of them before it is wrong for the curve — prefer nudging a palette's declared
  colours over adding a per-palette override.
- **The bright hues are still the hard ones.** There is no dark yellow that reads as yellow, and
  the floor's luminance is capped by the water above it, so `sunflower` and `tangerine` sit at
  the top of the brightness clamp and still read closer to gold and rust than to the bag. This is
  a real constraint of the look rather than a tuning miss; the fix, if it is ever wanted, is a
  warmer accent lamp in the aquarium — which is the same fix the brass needs.
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
- **A ground plane is seen almost edge-on, so isotropic mip selection erases its texture.** The
  near floor keeps its full width on screen and is squashed to a fraction of its height, so one
  mip level has to serve both axes and the blurrier one wins. A whole bed of stones and its
  normal map arrived as horizontal smears, and the tile looked like the bug. `maxAnisotropy = 16`
  on both the diffuse and the normal is the entire fix, and it cost 0.35 ms at 4112x2658.
- **A camera sitting on the glass can never see a substrate in section.** The floor meets the
  bottom of the frame at `floorEntryDepth` and everything nearer is below the frame, so no amount
  of bed depth puts the cut in shot. The band across the bottom of every aquarium photograph is a
  statement about where the *viewer* is standing, not about the gravel — `Tank.glassDepth`. The
  same reasoning applies to anything else the tank might press against its front pane.
- **A crest on that band may only rise, never dip.** Every part of the floor that is drawn at all
  projects above the band's nominal top line, so a dip exposes open water behind it. A rise is
  gravel heaped against the pane, which is what it is.
- **Normalising every palette to one luminance makes white and black gravel identical.** It is
  the obvious way to keep the floor-versus-water rule safe for any colour, and a contact sheet of
  all twenty-eight beds is the only thing that shows what it costs: a quartz bed and a basalt bed
  normalise to the same number and arrive as the same mid-grey. Brightness has to follow the bag,
  compressed enough that the rule still holds — see `GravelPalette.brightness`.
- **Warming a whole colour turns neutrals olive.** The blue wash on the near floor is corrected by
  warming the stones, and applied to the colour it also warms the tiny bias in an off-white stone
  and then amplifies it: the quartz bed came out mustard. Warm the *tint* — what is left after
  the colour's own grey is subtracted — and a neutral stays exactly neutral.
- **A luminance cap says nothing about chroma, and chroma is where the room is.** The floor is
  pinned at about 0.7 of the water above it and there is no brightness available at all, which is
  what made every previous gravel read blue-grey. Pushing the stones away from grey at *constant
  luminance* cannot move the floor measurement however far it is taken. Reach for it before
  reaching for the brightness.
- **The repository's Python tools have no interpreter in the repository.** `water-luminance.py`
  and `crop.py` import numpy, scipy and Pillow and the machine's `python3` has none of them, so
  the measuring tools fail with a bare `ModuleNotFoundError` that reads like a broken tool at
  exactly the moment you reached for them. The venv line is in Loops above.
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
- **`NSApplication.terminate` does not terminate while a sheet is attached.** It defers, and
  the process stays up having already done its work — `run-saver --configure --screenshot`
  wrote its PNG and then hung for three minutes with a healthy render loop and an idle main
  thread, which reads as a deadlock and is not one. End the sheet, then terminate.
- **A saver's settings domain is named after the saver's bundle, not `Bundle.main`.** Inside
  `legacyScreenSaver` the main bundle is the host appex, so
  `ScreenSaverDefaults(forModuleWithName: Bundle.main.bundleIdentifier)` writes somewhere
  shared with every other saver and read back by none of them. `SaverView.saverDefaults`.
- **A settings sheet is asked for again on every press of Options.** The window must be
  retained, must not release on close, and must re-read what is stored each time it is
  presented — otherwise the second visit shows what the first one left behind after a Cancel.
- **A sheet that is fetched is not a sheet that is shown.** `configureSheet` is a property,
  and the window it hands back has `isVisible == false`; a host may read it and present
  nothing. A live preview started in that getter therefore never stops, because `isVisible`
  cannot fall from a value it never reached. Tie anything that renders to the window's
  visibility — and use KVO for it, because an ended sheet sends its delegate neither
  `windowWillClose` nor `windowDidEndSheet`. Both halves were measured.
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
- **Long runs in the real host.** It is installed and confirmed working from System Settings —
  the sheet, the thumbnail, and full-screen Preview — but the timing numbers above still come
  from `run-saver`, which is the same view in an ordinary window. Nothing has yet been left
  running for hours as an actual screensaver.
- **The `default.metallib` path**, for lack of a Metal toolchain on this machine.
