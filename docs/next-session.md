# Where to pick up

Rewritten 2026-08-13, at the end of the session that populated the tank and art-directed
its three looks; extended the same day by the sessions that ran it on a Retina display, built
its settings sheet, rebuilt the aquarium's substrate as real gravel, and then relit the tank
and gave it caustics and god rays.

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

**The light moves now, and the tank is lit warm.** Three things landed together because they are
one problem — `docs/water-looks.md` §"Caustics and god rays" and §"The relight for colour" argue
all of it:

- **A warm key and a warm accent lamp.** The gravel read dull whatever colour the bag was, and
  the deficit was in the illuminant rather than the palette: red was 57% of blue in the light
  actually landing on the bed. The key is the lever because of *where* it lands — at elevation 78
  it hits the floor at N·L 0.98 and a flank at 0.21, so warming it warms the gravel five times as
  hard as the fish. The near band went blue-dominant to red-dominant with flank chroma unmoved.
  The accent is its complement, low and warm, for the things standing up in the tank.
- **Caustics**, as a gobo on the key, in the reef and the aquarium. Deep ocean gets none: at
  twenty metres the surface's focus has diffused away.
- **God rays**, as additive shafts, in the deep ocean only. The complement of the caustics, not a
  second helping — a caustic is the light still focused when it lands, a shaft is the light
  scattered out on the way down, so they want opposite water.

Everything holds its measurements: reef 0.68, deep ocean 0.58, aquarium 0.78 on river. GPU is
3.6 ms and 60 fps is unchanged.

**The caustics are signed off and the god rays are not.** Judged on the installed build, at full
screen, by the user:

- **Caustics: keep.** Both looks, and the difference between them reads as intended — the
  aquarium's larger, sparser and slower, the reef's finer and denser. The thing singled out as
  best was not on the floor at all: the net playing across the decorations and over the backs of
  the fish, which is what riding the key light buys and would have cost per-object work any other
  way.
- **God rays: still wrong after three passes.** They have gone from "awful" to "a little better",
  which is not the same as good. See below before touching them.

## The god rays, and what has already been tried

Three passes, each fixing something real and none of them finishing the job. **Read this before
changing a number, because two plausible-looking approaches have already been measured and
rejected and the third was a wrong diagnosis that cost a whole pass.**

What is in the build now: a Gaussian cross-section, colour weighted 0.72 to the water rather than
the lamp, swell along the length that may only widen, shafts fanned from a virtual source 7.5 m
overhead, and each shaft fading in and out on its own period from a 9-26 s range. The deep look's
`surface` ramp was strengthened at the same time and for the same reason.

Rejected, with the reason, so it is not re-tried:

- **Dimming them does not fix it.** Six settings from 0.20 down to 0.055 in one pass and 0.50 down
  to 0.07 in another: the failure changes intensity and never character. That is the tell that
  brightness was never the fault.
- **Widening the quads made it worse**, not softer — wide beams overlap and additive light stacks,
  so contrast went *up*.
- **A symmetric swell made the edges sharper.** A narrower Gaussian is a steeper one, so the thin
  part of every shaft carried the hardest edge in the frame. It may only widen.

The last user feedback, still only partly addressed, and the most useful thing on this page:

1. **Overlapping shafts stack and the overlap is where it looks worst.** Fewer are present at once
   now, which dissolves some of it and does not solve it. Additive light genuinely does sum; if
   this is still the complaint, the answer is probably fewer shafts rather than fainter ones, or
   some form of soft-max rather than a sum.
2. **Is the deep ocean still *deep*?** The `surface` ramp is much brighter than the one that look
   was signed off with. It is the only place this work changed a look the user had already
   approved, and it is a real change of character. Unanswered.
3. **Is the fan too strong?** `GodRays.sourceHeight`, one number, lower fans harder. Unanswered.

Both open questions want a *look at the installed build*, not a measurement.

**And a warning about measuring any of this.** Three separate metrics lied here in one session,
each in the direction of saying a broken thing was fine:

- A contrast reading across a row of open water is dominated by the **vignette**, not by the
  shafts.
- Detrended, it still carries a **noise floor of about 0.0112** from the marine snow — so a sweep
  appeared to show brightness having almost no effect when in truth three settings had all fallen
  below the floor and become invisible. Render at `brightness: 0` to measure the floor before
  trusting a reading.
- Comparing a *vertical* profile against a reference photograph has to be restricted to the water
  above the horizon, or this tank's lit seabed decides the number.

The reference photograph the current values are matched against is worth having beside any further
work: lateral amplitude ~36% of the local water at every height, and the water itself falling to
0.20 of its top-of-frame brightness by the horizon.

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

1. **Finish the god rays**, which are the only thing in the tank the user has looked at and not
   accepted. See the section above for the three passes already spent, what was measured and
   rejected, and the two questions that need an answer from a real display rather than a metric.
2. **Fish AI and depth lanes**, including the clownfish's anemone affinity — see
   `docs/aquarium-plan.md` §2. Site-attached fish are *cheaper* than crossing fish, and give
   the tank a second kind of motion. This is now the top of the list: caustics and god rays are
   done, and the one open note carried into that phase — the dull gravel — was the lamp's fault
   and is fixed.

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
- **The bright hues are better and still not the bag.** The warm lamp did what was predicted of
  it — `tangerine`'s near band went from a mauve brick to a real terracotta — but there is still
  no dark yellow that reads as yellow, and the floor's luminance is still capped by the water
  above it, so `sunflower` and `tangerine` sit at the top of the brightness clamp and read closer
  to gold and rust than to the bag. What is left is a real constraint of the look rather than a
  tuning miss, and the illuminant is no longer the thing to reach for: that lever has been pulled.
- **`quartz` has less margin than anything else here — 0.92, and 0.96 before caustics.** The
  brightest bed took the warm accent hardest, and it is the palette that would break the rule
  first if anything else in that look gets brighter. Trimming the accent from 260 to about 200
  restores it, at the cost of some of the warmth the lamp was added for; the shipped choice is to
  keep the warmth. **Re-measure `quartz`, not `river`, after any change to the aquarium's lights.**
- **Brass still cannot glint in the aquarium, but only for two reasons now instead of three.** The
  warm accent lamp means there is finally red light in that tank for a red-orange alloy to return.
  The remaining faults are both upstream in the bake — every baked material arrives
  `metalness = 0`, and the suit's atlas has no warm texels at all — and neither can be fixed from
  the saver's side. See `docs/water-looks.md` §"Unresolved: the brass never reaches SceneKit".
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

- **`SCNLight.gobo` works on a *directional* light**, though Apple documents it as applying to
  spot lights. Worth knowing before anyone converts a key to a spot to get caustics and inherits
  an attenuation they did not want. Measured: a flat lit plane went from sd 0.0000 to 0.1669.
- **A gobo multiplies its light by the tile's own mean.** A 50/50 checker took a plane from
  0.4000 to exactly 0.2000. So hanging any pattern on a light dims the whole scene by however
  dark the pattern averages, and every floor measurement in this saver moves with it. Divide the
  intensity back out — `Caustics.compensation(forMean:)`.
- **SceneKit colour-manages a generated image by the image's own tag**, and neither of the two
  obvious answers is right. Tagged sRGB, generic 2.2 or device RGB it is decoded through a 2.2
  curve; tagged *linear* it arrives exactly as authored. And `NSImage.lockFocus`, which is what
  the rest of this saver uses, produces a calibrated-space image that measured as gamma **1.8**.
  Anything carrying a number rather than a picture goes through `LinearImage`.
- **`SCNMaterial.multiply` is silently ignored once `blendMode` is `.add`.** Scaling the multiply
  colour to zero still drew the god rays at full strength. It looks exactly like a mis-tuned
  constant rather than a property with no effect, and it cost a tuning pass spent cutting a number
  that was doing nothing. Bake colour and brightness into the texture.
- **The near-floor measurement band is the substrate's cross-section, which is a vertical face**,
  so lowering a light's elevation *raises* that reading instead of sparing it. The usual grazing
  light intuition inverts. Dropping the aquarium's accent from 18° to 8° did not move the ratio.
- **Mean-compensating a gobo preserves the mean and lowers the median, and the tool reports a
  median.** A caustic is thin bright filaments over wide dark gaps, so its median sits in the
  gaps: the reef fell 0.77 → 0.68 on adding caustics with the light budget provably unchanged.
  Read a ratio drop after adding anything skewed as a distribution change, not a regression.
- **A caustic's fold lines are true singularities, so one sample per texel makes them beaded.**
  Supersample the pattern; blurring afterwards only blurs the beads.
- **Four concurrent `run-saver` processes all fail to screenshot**, each with "no ScreenCaptureKit
  callback arrived" after 10s. The capture path does not survive being asked for several windows
  at once and the failure reads as a broken build rather than as contention. `tools/render-set.sh`
  is serial for this reason.
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
  glow. The radius itself is verified directly — 24 px at 2x against an authored 12 — because
  measuring it from the image cannot work.
  **"It will start to matter with the god rays" was written here and is wrong.** With the shafts
  in, the deep ocean's brightest pixel is unchanged at Y 0.264 against its own 0.95 threshold.
  Bloom is a no-op in two looks and nearly one in the third: shallow reef peaks at 0.800 under a
  0.88 threshold and never crosses it, and the aquarium clears 0.90 on 0.0012% of the frame. The
  thresholds sit above what these looks can produce, so making bloom do anything means lowering a
  threshold rather than waiting for a brighter feature.
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
