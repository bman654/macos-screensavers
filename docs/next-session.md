# Where to pick up

**Read first if you touch audio: the session gate has two halves now, and shipping only one of
them put sound on the user's desktop while they were working.** A saver is audible only when the
screensaver session is running **and** its own window is still below the desktop level — the
level the host returns to `.normal` the moment it is finished with a view. `SoundSession.swift`
carries the rule, `docs/tank-sound.md` §"The gate has two halves" the summary, and
`spikes/006-saver-audio/README.md` §"Phase 0 was not enough" the measurements and the three
plausible theories that were refuted on the way. It is verified on the installed build over five
consecutive activations.

**Open with the user, not blocking anything:** `AudioProbe.saver` is installed on purpose and
is to be left installed. The user will log out at some point, leave the login screen idle until
the screensaver starts, and report what the on-screen readout says. That is the last untested
case in the audio spike, and `spikes/006-saver-audio/README.md` §"Still to test" holds the four
lines to read and what each outcome means. It does not block the bubble bed.

Rewritten 2026-08-13, at the end of the session that populated the tank and art-directed
its three looks; extended the same day by the sessions that ran it on a Retina display, built
its settings sheet, rebuilt the aquarium's substrate as real gravel, and then relit the tank
and gave it caustics and god rays.

Extended 2026-08-15 by the session that added seed pinning and the on-screen seed badge, and
then fixed the fish behaviour the user had judged wrong on the installed build: the eel that
would not go near the floor, the swim-throughs that were counted but never seen, a wide fish
clipping the arch it was passing through, and the twirl at the mouth of a passage. **All four
are fixed and signed off by the user on the installed build.** Start at "The eel lies on the
floor now" if you are touching the school; the section after it is the one open art question.

## State

**The voice is now heard in the tank, and the audible is tied to the visible.** Signed off on the
installed build at full screen: *"Yes now I can see the fish dashing and hear the noise associated
with it. And yes I can hear the more dense bubbles when a bubbler activates. Sounds pretty good."*
Two things came out of getting there and both are in `docs/tank-sound.md`:

- **A prop letting go is an event now** (`tools/audio/soundlib/puff.py`), not a rise in bed
  density. One every ten seconds on a two-emitter tank, panned at the prop.
- **A dart is visible, and is the only thing that makes a fish sound.** The old dart held its
  heading and was over in half a second, which nobody ever saw. It turns 26–66° now, which buys a
  bank for free. Dart entries went 4 → 20 per 150 s, and swishes 19 played against **1** refused
  where it had been 36 against 29 — that ratio was the cooldown talking, not the fish.

**The tank has a voice, it is off by default, and the sound is signed off.** Phase 1 of the
audio track landed: a bubble bed and a swish when a fish works. Judged by the user on the
rendered preview — *"the aq-4-tank sample now sounds pretty realistic. The bubbles are nice and
I can hear the occasional swish sound of fish moving around."* `docs/tank-sound.md` is where all
of it is argued; read that before touching any of it, and `spikes/006-saver-audio/README.md`
before touching the plumbing.

**It took three passes and the first two were rejected outright**, both for the same verdict —
"sounds completely like it's in the air". That history is kept in `tank-sound.md` rather than
deleted, because each pass was a plausible piece of reasoning that only measurement refuted.
The three things that actually mattered:

- **What a hydrophone in a tank mostly hears is not bubbles, it is the cloud.** A bubbly liquid
  carries the water's inertia on the gas's compressibility, so sound speed collapses and a plume
  a few centimetres across gets a *collective* resonance in the low hundreds of hertz. The
  reference recording peaks at 160–320 Hz, where nothing an aerator makes could possibly ring —
  so no adjustment of the radius distribution could ever have produced it. `soundlib/plume.py`.
- **A fish moving water is a burst of bubbles, not a whoosh.** Two attempts at a swept band of
  noise were rejected; the user supplied three "underwater movement bubble motion" samples and
  the fix was to rebuild `swish.py` as a scheduler over `bubble.ping`. A swept band cannot be
  granular at any centre frequency.
- **Nothing continuous.** An earlier build had a stationary noise layer and a fixed-frequency
  resonator, and the verdict was "a steady background hum or bass bed... I don't know what
  that's supposed to represent". Nothing was the honest answer. The bed is *only* arrivals now,
  and the collective mode is noise-excited rather than struck, so it has no pitch.

The rest of the shape:

- **Sounds are code, the same as models.** `tools/build-audio.py` bakes a grain library from
  `Savers/Aquarium/Sounds/*.py` into `Assets/audio/` — untracked build output, 31 files, 3.8 MB.
- **The library is short because a resample is the *correct* transform, not a cheap one.**
  Radiation damping is independent of bubble radius, so ring-down time is exactly inversely
  proportional to frequency — playing a baked 1.5 mm bubble 20% fast *is* a 1.25 mm bubble. A
  fish's movement is a pure time-scale too, by construction, so one reference fish covers all.
- **There is no loop.** What repeats is the statistics.
- **It follows the tank.** Bed density is the declared birth rate of whichever emitters are
  emitting this frame; a swish comes from a fish exceeding its effort *or* lateral-acceleration
  threshold.
- **`tools/audio-match.py` is the scoreboard**, and it is the thing that turned this from
  guesswork into a loop: it scores any WAV band-by-band against the reference recording
  (`--target bed`) or the movement samples (`--target dart`). The first pass was only ever
  checked against *itself* — saver against preview — and the two agreed perfectly while both
  were wrong.

**The aquarium renders as a tank.** A random assortment of fish and decorations is drawn per
launch, placed on a substrate, lit by one of three art-directed looks, and every model is
textured. Nothing is blocked.

**A user can now choose the look.** `AquariumSettingsSheet` is the saver's `configureSheet`:
three looks plus "Surprise me", each with a live preview of the tank it selects, persisted to
`ScreenSaverDefaults` under the saver bundle's own identifier. OK reloads the running view's
host so the thumbnail behind the sheet adopts the choice; Cancel leaves nothing behind.

**And a user can now pin a seed, because the tank tells them what it is.** The sheet has a Seed
field (empty means a fresh tank every launch) and a "Show the seed on screen" switch, and
`SeedBadge` prints the seed faintly in the top-left corner of the full-size tank — never in the
thumbnail, which is too small to carry it. The two halves are one feature: read the number off a
tank you liked, type it back in, get that tank. `AQUARIUM_SEED` still wins over the stored value,
and `AQUARIUM_SHOW_SEED=0` turns the badge off so a doc screenshot does not carry one.

Two things changed underneath it. **Launch seeds are now six digits, drawn rather than derived
from the clock** — the old value was thirteen digits of milliseconds, which is a number people
transcribe wrongly, and on a multi-display machine every screen drew the *same* tank because they
all launch within the same millisecond. Any `UInt64` is still accepted, so `AQUARIUM_SEED=42` and
`=4` name exactly the tanks they always did. And **`AQUARIUM_STYLE` no longer discards the rest of
the stored settings** — it overrides the style and leaves the seed alone.

The badge is a **SpriteKit overlay** (`SCNRenderer.overlaySKScene`), which is verified to
composite over a manually-encoded `render(atTime:viewport:commandBuffer:passDescriptor:)` pass —
so it is untouched by the water's fog, the camera's HDR tone mapping and the bloom.

**`showsSeed` defaults on, and that is settled — it ships as an option rather than as a debugging
aid to be removed.** Judged by the user: "it's an option, if people want to see it they can, it
costs a millisecond or two out of the budget, and if they don't want to see it they can turn it off
and save the budget for other things." The measured cost is 2.0 ms of GPU at 2056x1329 with 60 fps
unaffected — see the overlay trap below — and turning the switch off removes all of it, because the
overlay is not built at all when it is off.

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
- **God rays**, as an additive curtain, strongest in the deep ocean and faint over the reef. The
  complement of the caustics, not a second helping — a caustic is the light still focused when it
  lands, a shaft is the light scattered out on the way down. The deep gets only shafts, the reef
  gets a strong net and a faint shimmer, the aquarium gets only the net.

Everything holds its measurements: reef 0.68, deep ocean 0.72 (after the darkening the curtain
brought — see below), aquarium 0.78 on river. GPU is 5.5 ms at 4112x2658 and 60 fps is unchanged.

**The caustics and the god rays are both signed off now.** Judged on the installed build, at
full screen, by the user:

- **Caustics: keep.** Both looks, and the difference between them reads as intended — the
  aquarium's larger, sparser and slower, the reef's finer and denser. The thing singled out as
  best was not on the floor at all: the net playing across the decorations and over the backs of
  the fish, which is what riding the key light buys and would have cost per-object work any other
  way.
- **God rays: the curtain rewrite is accepted.** Judged on the installed build: "much closer
  matched to the reference images and videos, the motion is nice — slow, mesmerizing, subtle but
  visible." The user's own diagnosis of pass three drove the rewrite and is worth restating
  because it named the structure, not a number: the quads were flat across their width with a
  findable edge, and the real thing is *a curtain* — a continuous ripple of hills and valleys of
  brightness fanning from an overhead point, folds exchanging and dying rather than travelling.
- **The reef's curtain is accepted too.** Added at the user's request after the deep ocean
  landed, and confirmed on the installed build. Tuned to about half the deep's relative
  modulation (13% of local water at the top of the frame against 29%), riding over the caustics,
  with the reef's `surface` ramp trimmed so the top-of-frame sum stays at the signed-off
  brightness. Quads could never survive this backdrop — that verdict was real but it was about
  objects, not about the look. Only the aquarium has no rays, and its reason stands: filtered
  water has nothing for a shaft to light.

## The god rays: the curtain rewrite (pass four)

`GodRays.swift` no longer draws N shaft quads. It draws **two frame-spanning additive quads** at
different depths, each carrying a fragment shader modifier that evaluates one continuous
brightness field: six sinusoids in fan-angle space, exp-sharpened so crests are narrower than
valleys with no corner anywhere, an envelope easing toward the frame edges, and a vertical
fall-off reaching exactly zero at the quad's bottom edge. Paired components at nearby fold counts
run in opposite directions, so the folds pulse, exchange and die by interference — no per-shaft
clocks, no fades, and nothing for additive overlap to stack because the field is its own sum.
The full argument is in the file's header; `docs/water-looks.md` §"The shafts are one curtain"
holds the history and the measurements.

Matched against the reference photograph (a 4K stock frame of real god rays; the numbers are in
water-looks.md): fold modulation ~29% of local water at the top of the frame against the
photograph's ~25%, easing with height on the photograph's own taper; dominant fold width 11% of
the frame against 11–12%; the water's vertical profile now tracks the photograph closely to the
horizon. Motion, measured on seeded renders: recognisably the same pattern 4 s apart, turned over
in place by 8 s (correlation ≈ 0 at a lateral shift of 0.3% of the frame), slow ~6% drift under
the turnover by 16 s.

**The deep look was darkened at the same time, deliberately.** The user judged the bottom of the
frame too bright — the answer to the "is the deep ocean still deep?" question this file used to
carry. The tint (which is the fog and the whole lower half's brightness) went from (0.043, 0.128,
0.205) to (0.030, 0.090, 0.144), all three lights followed it down (~×0.75), and the `surface`
ramp was trimmed so ramp-plus-curtain at the top of the frame sums to the brightness that was
already approved. The lower half now reaches ~11% of top-of-frame against the ~20% shelf it used
to flatten at; `water-luminance` reads floor/backdrop 0.72, still inside the rule.

**Knobs, if the user wants adjustments:** `GodRays.brightness` (fold contrast — currently 1.35,
tuned to the photograph), `sourceHeight` (fan hardness, lower fans harder), `drift` (how hard the
curtain is shaken — scales every component speed at once), the `0.85` exp sharpening constant and
the `3.5` fall-off exponent in `GodRayField.curtainShader`.

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
- Rows at and below mid-frame cross the rocks and the diver, so a "modulation" reading there is
  mostly prop edges surviving the detrend. Trust the top-band rows.

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
than an event. On a fresh clone run `tools/build-library.py` (about 10 minutes) **and
`tools/build-audio.py` (about 15 seconds)** before `tools/build-saver.sh`. Skipping the audio
bake fails quietly in the way that wastes an afternoon: `SoundLibrary` returns nil by design, so
the tank simply has no voice and nothing anywhere says why.

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
AQUARIUM_SCHOOL_STATS=10 tools/run-saver.swift Aquarium --seconds 120 --screenshot /tmp/t.png
AQUARIUM_PASSAGE_MARKERS=1 AQUARIUM_SEED=5 tools/run-saver.swift Aquarium --seconds 1 \
    --screenshot /tmp/routes.png                           # a ball on every swim waypoint
AQUARIUM_BUBBLER_RUSH=1 AQUARIUM_SEED=1 tools/run-saver.swift Aquarium --seconds 9 \
    --screenshot /tmp/bubbles.png                          # collapses the 11-26 s idle
```

`AQUARIUM_SCHOOL_STATS=<seconds>` prints what the school is doing at that interval: how many fish
are in each behaviour, how many are meaningfully pitched, **how many are outside the frame — which
in a closed tank must always be zero** — and a cumulative count of how many times each behaviour has
been *entered*. `AQUARIUM_BUBBLER_RUSH=1` shortens only the idle phases of a prop's cycle, so a
short capture exercises several complete cycles without judging a motion at a speed the saver never
plays it at.

**The Python tools need an interpreter this repo does not track.** `water-luminance.py`,
`crop.py` and `build-library.py` want numpy, scipy and Pillow, and the machine's `python3` has
none of them — the failure is a bare `ModuleNotFoundError` that reads like a broken tool:

```bash
uv venv --python 3.14.3 .venv
uv pip install --python .venv/bin/python numpy scipy pillow
.venv/bin/python tools/water-luminance.py /tmp/tank.png
```

`AQUARIUM_STYLE` is one of `shallowReef` (default), `deepOcean`, `aquarium`, `random`, and
overrides the saved style, leaving the rest of the saved settings alone. `AQUARIUM_SHOW_SEED`
forces the corner seed badge on or off regardless of what the sheet has stored. `AQUARIUM_GRAVEL` pins which of the twenty-eight gravel palettes the
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

## The fish think now, and the decorations move

**Fish steer instead of flying straight.** The school used to have no state at all: `place` handed
a fish a constant velocity and it crossed the frame in a dead line at a fixed height. Changing
lane, changing height, turning, pausing and changing speed are not five features on top of that —
they are five symptoms of the one thing missing, which is a fish that can steer. `FishBehavior`
holds the limits (turn rate and acceleration derived from body length, since that is the only
manoeuvrability the manifest states), `FishDecision` holds the taste (which behaviour, how often,
and what makes one unavailable), and `School` turns an intent into a transform.

Six behaviours: cruise, wander (which is what changes direction, height *and* lane — they are one
act), hover, forage, dart, and host. Three things came with it that are not garnish:

- **Pitch, from the whole heading.** A fish changing height while facing dead level reads as a
  model sliding along a wire. Orientation is now a quaternion composition — yaw about world up,
  pitch about the body's lateral axis, roll about the nose — because `eulerAngles` fixes an order
  this does not want and gets silently reinterpreted the moment a second axis is non-zero.
- **Foraging tips the nose *beyond* the path.** Descending toward the gravel and looking at it are
  different poses, so `inspect` is carried apart from pitch and eased in and out. What is under a
  fish comes from `SurfaceField`, which reduces the reef to domes — a flat-topped cylinder gives a
  fish a cliff to fall off at a boulder's rim.
- **The tail follows effort.** A stopped fish still beating at 1.5 Hz is the clearest possible
  statement that the animation and the motion are unrelated systems.

**The aquarium is a closed box, and the box is the frustum.** Its side walls and ceiling are the
edges of the picture — a trapezoid in plan and another in elevation — closed off by the front pane,
the back wall and the floor. A parallel-walled box cannot both stay in frame and use it: sized to
the frustum at the pane it is 47% of the visible width at the back, and sized at the back wall a
fish near the pane is off-screen. The floor is the one exception and stays a true horizontal plane,
because it is the only wall that is actually drawn.

This surfaced a real bug. The aquarium's water starts at `nearDepth` 2.0 m and its glass stands at
2.89 m, and the school was being placed across the whole range — so most of a metre of it was on the
*viewer's* side of the window, over the cross-section band. `Tank.swimNearDepth` is the pane now.

**The animated props are wired.** `parts`, `emitters` and `cycle` were authored in the manifests and
read by nothing; `Bubbler` plays them. A stream's source is the named empty inside the model, which
rides whatever part carries it, and its anchor is an unrotated child of the reef — that separation
is what keeps "up" aligned with the tank after yaw, tilt, Blender's axis correction and instance
scale have all had their say.

Measured on the installed build at 1600x900 and at the Retina invocation: 60.0 fps held, GPU mean
3.5–3.9 ms. Not comparable to the 5.5 ms on record above, which was a look with god rays; the
aquarium has none.

**The Settings button dying was a SaverKit leak, not a settings bug.** User-reported and initially
mysterious — it worked, then later did not, with no crash and nothing in the unified log. The host
process had reached a 5.7 GB footprint. See the trap below; the fix is in `Shared/SaverKit`, it
affects every saver, and the settings sheet itself was never at fault.

**The first pass at the motion was judged on the installed build and had four faults.** All are
fixed and the reasoning is worth keeping, because three of the four were the same mistake:

- **Turn rate ran away at the small end.** `2.2 / (0.35 + length)` gives an 8 cm clownfish 293° per
  second, so it completed a right angle in a third of a second and read as being re-pointed between
  frames rather than turning. Capped, and — the real fix — **turn authority now scales with speed**,
  because a fish turns by pushing water with its body and one that has slowed to a hover cannot whip
  round. That single change fixes the jerk at every size.
- **The intent and the wall formed a limit cycle.** The avoidance push is recomputed every frame
  while the intent went on pointing at the glass for the whole of a behaviour, so a fish was pushed
  off the wall, came back under its own unchanged intent, and alternated about twice a second. It
  reads as an animal changing its mind constantly, and it is — the mind just is not the one making
  the decisions. A deflected fish now **adopts the heading the wall gave it**.
- **Nothing enforced a minimum commitment**, and the wall-proximity interrupt fired unconditionally.
  In a tank this small a fish is within range of some wall nearly always, so it re-decided about
  once a second for its whole life. The interrupt now fires only when the push genuinely *opposes*
  the intent, and no behaviour but a dart may commit for less than 1.6 s.
- **A host orbit was redrawn rather than advanced.** Picking a uniformly random point around the
  anemone every few seconds is not an orbit, it is a sequence of unrelated destinations — and the
  clownfish had the turning authority to snap onto each one, which is why it was the worst offender.

One emergent behaviour is **wanted, not a bug**: a fish occasionally turns through a full circle,
which the user described as a tang chasing its tail. It comes from a run of same-sign turn choices,
and `FishBrain.turnSign` now biases a new heading toward continuing the turn already in progress —
so arcs are the common case and the loop survives as the rare one. Do not "fix" it.

**What a 150-second census says** (`AQUARIUM_SCHOOL_STATS`, below): ten fish, `outside 0` at every
sample — nothing ever leaves a closed tank — and every behaviour entered: wander 168, cruise 145,
hover 52, forage 29, dart 4. Foraging is picked on 7% of decisions against 23% of its weight, which
is right: a fish high in the column is not eligible for it.

## Fish route through the arch and the wreck now

> **Written before the fixes below it.** The design is still the design, but several numbers in
> this section were superseded on 2026-08-15 — each is marked. Read "The eel lies on the floor now"
> for what is true.

`SwimPassage` reads the `swim_` waypoints out of the placed reef, and a `transit` behaviour walks
them. ~~Verified: 4 transits per 120 s in a glass tank, 7 in open water, none stuck.~~ **That
number counted transits *entered*, and every one of them was in fact failing** — see below. Four
things in it exist because of specific failure modes, and none is decoration:

- **Fit is decided by girth, never by length**, measured from the mesh cross-section —
  `ModelCache.LoadedModel.girth`. The moray is 1.5 m end to end and *thinner through the body*
  than a blue tang a sixth its length (0.1015 against 0.0750), so a test on length refuses exactly
  the animal the feature exists for. Measuring it from the bounds rather than declaring it also
  means a species added later is judged correctly with no manifest change.
- **A transit cannot be abandoned partway.** The wall interrupt and the minimum-commitment floor
  both skip it explicitly. A fish halfway inside a hull that changes its mind is a fish embedded
  in the hull.
- **Prop avoidance is suppressed during a transit**, and this one would have been silent: the
  wreck is a prop, so the term that stops fish swimming into hulls is the same term that shoves
  one out of the hole it is aiming at. The route's declared clearance is what keeps it off the
  geometry instead, which is what the declaration is for. *(Not on its own, it turns out — the
  clearance has to exceed the fish's own body by a margin, or it threads the hole and clips it
  anyway. `SwimPassage.fitMargin`.)*
- **A timeout as well as an arrival test**, so a fish that cannot make progress gives up and takes
  the cooldown rather than pressing against geometry for the rest of the launch. *(Per leg now,
  and refreshed by progress; as a flat ceiling it mostly measured the approach.)*

Cooldowns are 35–80 s ordinarily and 7–18 s for a lurker; the eel also gets 2.6x the attraction
range, a 5.0 weight against 1.2, and keeps to the bottom ~~30%~~ **18%** of the column
(`FishBrain.lurkerCeiling`, and it is measured from the floor now rather than from a span). An eel that wanders
the whole tank is a very long tang, and an aquarium with a wreck in it always has something living
inside the wreck.

**The declared radii were already right and the geometry did not need touching.** Worth recording,
because a session was nearly spent proving otherwise. `Tank.propScale` shrinks a prop to hold its
angular size while fish keep their real metres, so the wreck's 0.13 m hold is a 4.3 cm hole in a
glass tank — which sounds fatal and is not. Measured against every species' true girth:

```
sunken_ship    radius 0.13   aquarium  7/14 = 50%   ocean 14/14 = 100%
rock_pillars   radius 0.15   aquarium  7/14 = 50%   ocean 14/14 = 100%
rock_arch      radius 0.21   aquarium  8/14 = 57%   ocean 14/14 = 100%
```

The eel fits all three in a glass tank, because the length cap shrinks it and girth scales with it.

**Those counts are now optimistic and have not been re-measured.** They were taken under `girth <=
radius`, and admission is `girth <= radius * 0.7` since a fish threading a hole with no margin
clips it — so every figure above is an upper bound. Re-measuring means printing each loaded
species' girth against each placed route's radius; there is no standing tool for it.

## The eel lies on the floor now, and fish thread the wreck

Both of the open items below were real, and **neither had the cause the file guessed at**. One
mechanism produced most of both: a clearance stated in body *lengths* for an animal twenty girths
long. It had already been found and fixed once in `Tank`, and it was still live in three other
places. Measured on `AQUARIUM_SEED=4`, aquarium, 120 s:

```
                      before          after
lurker@ (column)      0.35 – 0.59     0.15 – 0.24     (target ~0.18)
routes crossed        0               3 per 120 s
waypoints reached     6               18
transits ended by     timeout ×4      arrival ×3, timeout ×1
```

Five changes, and the first is the root cause of most of it:

- **`Avoidance.push`'s vertical margin is stated in girths.** A ramped push settles a fish at
  roughly the margin, so the vertical margin *is* the height the animal flies at. At `length *
  2.4` it asked a length-capped moray for 1.17 m of water under a body 2.4 cm through — ten times
  the 3 girths the decision layer may *name* as a target — so the eel was commanded down by its
  brain and held up by the field for its whole life. Three girths now, which is exactly
  `FishDecision.verticalSpan.low`: **the field must be neutral at the lowest height a behaviour
  may aim at**, or the two systems fight forever. Ordinary fish do not move, because a fish of
  ordinary proportions is about five girths long.
- **The pitch controller's gain is capped against the water available.** Six body lengths is
  2.9 m for the moray in a tank 0.8 m deep, so the largest height error the tank can hold
  commanded 2.4° of pitch and it descended at half a centimetre a second. Its target was right,
  the field had stopped fighting it, and it still took half a minute to fall 12 cm.
- **A waypoint is reached by threading it, not by being near it.** The old sphere of
  `max(radius * 0.9, length * 0.35)` is 17 cm against the wreck's 4.5 cm hole, so a fish flying
  *over* the wreck ticked off the whole route without entering it — which is how the census
  reported this feature working through a session in which nobody saw it. A waypoint now counts
  when the fish is inside the route's declared clearance *of the route axis* and has crossed the
  plane through the waypoint normal to it. That cannot be satisfied from above, which is what the
  user's own diagnosis of the problem said it should not be.
- **The spin is fixed, and it was a singularity.** `targetYaw` came from the *horizontal* part of
  the offset to the waypoint, past a 0.1 mm guard. A fish a few centimetres above a waypoint has a
  horizontal offset whose direction is noise, so the target swung across half a turn between
  frames: measured on the moray, yaw ran -7.2 → -13.1 radians in four seconds while its distance
  to the waypoint barely moved. It could not escape, because a transit may not be abandoned
  partway. Close in, the fish is now handed the *route's* axis, which is the only direction inside
  a passage that means anything.
- **The transit timeout is per leg, and refreshed by progress.** As a flat ceiling on the whole
  behaviour it also had to cover the approach, and the approach is the long part — the moray joins
  a route from a metre away at 6 cm a second, so 15 of its 26 seconds were gone before the first
  waypoint. This is what its own comment always claimed it was.

`FishBrain.lurkerCeiling` is a real control again and is 0.18. At 0.32 it was within 3% of the
0.33 cap in `Avoidance.margin` that was holding the eel up regardless, so **sweeping it could
never have worked** — which is why the sweep this file asked for was not the thing to do.

`AQUARIUM_SCHOOL_STATS` now reports **`waypoints`** (arrivals) and **`crossings`** (routes
finished end to end) alongside the behaviour counts. A run whose `crossings` is zero while
`transit` entries climb is exactly the failure that was live, and no other number here shows it.
`AQUARIUM_PASSAGE_MARKERS=1` puts a coloured ball on every waypoint — green first, red last — and
prints the route in reef space. Both are kept deliberately; see the traps below.

### The exit twirl: a fish is released at the passage's mouth, not asked to arrive at it

Judged on the installed build: the arch "works fairly well", fish and the eel both go through it,
and the wreck is "pretty reliable". The fault left was at the *end* of a crossing — a fish would
come out of the wreck's breach, turn around, start back in, turn again, and spin like that for a
couple of seconds before being released and wandering off. The eel did a smaller version at the
arch and clipped the rock on the 180.

Two causes, both at the last waypoint:

- **The last waypoint was arrived at rather than left by.** It is an approach point in open water,
  not a hole, and the arrival test asked the fish to come within a distance of it — so a fish that
  had already swum clear had to turn round and go back for it, overshoot, and turn again. Crossing
  the *plane* through it is enough now, with no lateral condition: the only way to satisfy that is
  to keep going forward, so the exit can never ask for a reversal however far off-axis the fish
  drifted on the way out.
- **A fresh decision knows nothing about the wreck the fish is standing in the mouth of.** Ending a
  transit dropped straight into `choose`, and about half of its headings pointed the animal back
  the way it came. Prop avoidance does not rescue it either — the term that would push it clear is
  cut to 15% for a passable prop, deliberately, so that fish can get near enough to use the hole.
  A completed route now hands the fish the route's own exit heading and 1.8–3.0 s of commitment to
  it. A timed-out one does not: that fish is pressed against geometry, and driving it further along
  a line it has already failed to follow is the wrong instinct.

Measured over 145 s, total yaw turned in the three seconds after a crossing, and the straightness
of the path in that window:

```
                    before                          after
aquarium/5     159, 107, 10, 4, 4 deg          17, 6, 6, 5, 4, 4 deg
               straightness 0.81 – 0.98        straightness 0.98 – 0.99
```

Two of the five exits before were half-turns, and two more covered 2 and 6 cm in three seconds —
a fish that had effectively stopped. None of that survives.

**Crossings per launch fall on some layouts, and that is the fix working rather than a
regression.** shallowReef/42 went from three crossings to one — but the census shows three
transits *entered* before and one after, so completion is 100% both ways. A fish that leaves
properly ends up further from the prop and comes back into range less often, which is exactly the
"wander off and go somewhere" that was asked for. The completion rate is the number to watch here,
not the count.

**Known and accepted:** fish still ride high through the wreck and clip the plank over the breach,
and sometimes clip the collapsed deck on the way out. Judged as liveable — "can't make this
perfect". The cause is the wreck's route climbing 15 cm over 29 cm of run while the height
controller lags; the arch, whose route is level, does not show it.

### A fish threading a hole may still clip it, and the margin is bought at admission

The user's third report was **a large fish whose belly went through the crown of the rock arch,
with the arch facing the camera and the hole plainly visible** — so it was neither a fish that
never entered nor a viewing-angle problem. It is a fish correctly on the route whose body is wider
than the tolerance the route was steered to.

`admits` was `girth <= radius`, which is the condition for a *stationary* fish to be inside the
tube and says nothing about a moving one. On shallowReef seed 42 a deep-bodied species of girth
0.0884 was admitted to a route of clearance 0.0978 — an 11% margin — while the arrival test let its
centre sit a full radius off the axis, so its body could reach almost twice the clearance. It is
0.7 of the radius now: the body may take 70% of the tube and the remaining 30% is what the steering
is allowed to be wrong by.

Two things were tried first and are worth not repeating:

- **Tightening the arrival test to `radius - girth` is worse, not better.** It is the honest
  statement of containment and the school cannot track a line to two centimetres, so the eel
  satisfied no waypoint at all and crossings on `AQUARIUM_SEED=4` went from three per two minutes
  to none. A fish that cannot tick off a waypoint does not go somewhere better — it sits in the
  hole until the transit times out. Refusing a species a route costs one species one prop;
  tightening arrival costs every fish every route.
- **A lookahead stated in body lengths silently disables pure pursuit.** Half a body length is
  24 cm for the moray against legs 7 cm long, so the carrot pinned to the far end of every segment
  and the follower degenerated into aiming at the waypoint — with no symptom except a measurement
  that did not move. A lookahead has to be a fraction of the *leg*.

Transits are now steered by pursuit along the current leg rather than aimed at its far end, which
is what centres a fish in a hole and stops it cutting the corner into the geometry the route bends
around. Measured over 150 s: aquarium/4 one crossing, aquarium/5 four, shallowReef/42 three, and
the largest fish to cross the arch (girth 0.0597 against clearance 0.0978) is framed by the opening
with daylight around it.

**A correction worth keeping, because it nearly became a change.** An earlier pass concluded from
`AQUARIUM_SEED=5` that the arch reads as solid rock when its passage runs across the frame, and
proposed turning every passable prop broadside. That was a misreading of one render — the opening
is plainly visible on seed 42 — and the change was tried and reverted for a second reason anyway:
it is backwards for the wreck, whose route runs port to starboard, so forcing that axis across the
screen points the ship's keel at the camera and loses the profile that makes it the best-looking
prop in the library. **The user's direct observation beat the render every time this session.**

## Superseded

This file used to carry two open items — "no transit is ever seen" and "the eel still does not
behave" — with a list of suspected causes. **Both are fixed and none of the suspicions was
right**, so the list has been removed rather than left where a fresh reader could act on it. The
sections above hold what actually happened and the numbers behind it; the trap index holds the
mistakes worth not repeating. Two facts from it are still true and still needed:

- **The eel is rare.** Manifest weight 0.2, and of seeds 1–26 only **seed 4** draws one in the
  aquarium. Pin `AQUARIUM_SEED=4` or nothing about lurking behaviour will reproduce.
- **`AQUARIUM_SCHOOL_STATS` prints `lurker@<fraction of column>`** for every lurker, which is the
  measurement every eel number in this file was taken with.

## Next, in order

1. ~~**The audio spike.**~~ **Done — a screensaver can make a sound.** Read
   `spikes/006-saver-audio/README.md` before writing any audio; it is mostly a list of things
   that look like they work and do not. The headline: **gate audio on the screensaver session,
   never on the view.** No property of a saver view separates the real screensaver from the
   picker's thumbnail, because the tile is a *full-screen* view with `isPreview == false`, and an
   abandoned view renders at 60 fps forever with `window=shown` and `animating=true`. The signal
   is `com.apple.screensaver.didstart`/`willstop`/`didstop`, registered `.deliverImmediately`
   (the default withholds them from a process that is never "active"), seeded at startup and
   allowed to settle, because `didstart` is posted before the host process exists.

   **The finding that is not about audio: `isPreview` is wrong in the picker, for every saver.**
   The tile is 2056x1329 on a 2056-point screen, so both `ScreenSaverView.isPreview` and
   SaverKit's width threshold call it a full-screen saver — and the aquarium has therefore been
   rendering five lights, caustics, god rays, bloom and MSAA into a two-inch thumbnail, several
   alive at once in the settings pane. This is its own piece of work, wants the aquarium in front
   of the user, and **the session notification is not the fix for it**: a thumbnail should render
   cheaply whether or not the screensaver is running. Nothing in SaverKit has been changed yet.

2. ~~**Phase 1 of the audio track: the bubble bed.**~~ **Done and signed off.** The sound is
   judged good — see the State section. What is left on this track is small and optional:

   - **The fine fizz is thin.** Measured, the bed sits 18–27 dB under the reference above
     2.5 kHz. In a real tank that top comes from hundreds of tiny bubbles a second; here they
     arrive a dozen a second. **Do not fix it with a noise layer** — that is exactly what was
     removed as "a steady background hum". If it is fixed at all, it is fixed with more
     arrivals: a second, much faster stream of very small radii.
   - ~~**The swish rate has never been judged deliberately.**~~ **Judged, and the answer was
     not a rate.** The verdict was that nothing audible could be tied to anything visible —
     "probably I have never seen a fish dart, the visual change in acceleration is too subtle
     to register" — so the fix was to the *tank*: a dart is longer, faster and now turns 26–66°,
     which buys a visible bank for free, and the gesture is spent on darts only. The props got
     an onset gesture of their own (`puff.py`) so a chest opening is heard as an event rather
     than as a rise in bed density. `docs/tank-sound.md` §"Tying the audible to the visible".
   - **Two spike items are still open and neither belongs to this feature**: the login window,
     and two real displays.

   To hear any of it without building anything:

   ```bash
   .venv/bin/python tools/audio-preview.py --seconds 90 && afplay /tmp/aquarium.wav
   .venv/bin/python tools/audio-preview.py --grains      && afplay /tmp/aquarium.wav
   .venv/bin/python tools/audio-match.py /tmp/aquarium.wav          # score it
   ```

   And from the saver itself, which is the ground truth:

   ```bash
   AQUARIUM_SOUND=1 AQUARIUM_SOUND_SESSION=1 AQUARIUM_AUDIO_STATS=30 \
       AQUARIUM_AUDIO_RECORD=/tmp/tank.wav \
       tools/run-saver.swift Aquarium --size 1200x700 --seconds 95 --screenshot /tmp/t.png
   ```

   **`AQUARIUM_SOUND_SESSION=1` is not optional here**, and leaving it off is the trap this
   loop has: without it the session gate falls back to "is System Settings open", which the
   harness cannot answer for itself — so whether your recording contains anything depends on
   whether an unrelated window happens to be open, and the failure is a valid WAV of silence.
   The stats line names it: `session idle` means the gate, `showing no` means the window level.

3. **Lionfish and seahorse.** Deferred all along; each needs a spec extension the other
   twelve did not (independent dorsal spines; a curled prehensile tail).
4. **The picker thumbnail.** The saver's tile in the Screen Saver list is blank. It was held
   until the tank looked finished so the picture would not have to be shot twice — the caustics,
   the god rays and the fish behaviour have all landed and been signed off, so **that condition is
   now met** and this is only last because it is the smallest. Shoot it with
   `AQUARIUM_SHOW_SEED=0`, or the tile carries a seed badge.

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

- **The sound's one-owner rule is process-local.** `AquariumSound.owner` is a static, so two
  views in one host correctly share one voice, and a stalled owner can now be taken over from
  (it holds a heartbeat, and an owner that has not drawn a frame for 0.75 s is not eligible).
  Two *hosts* would each start an engine. The picker alone provably spawns two, and the session
  gate keeps both silent there — but two real displays are untested on this machine, which
  mirrors rather than extends. If they ever do play at once, the arbiter has to move to
  something cross-process, and the cheapest candidate is a lock file in the container both
  hosts already share.
- **Nothing fades on the way out of `stop()`.** The ramp that matters is the session's, and it
  has normally already run by the time a host tears a view down, because `willstop` arrives
  before the screen comes back. `stop()` sets the gate to zero and stops the engine in the same
  breath, so a host that discards a view *without* the session having ended — which is the
  harness path rather than the screensaver path — would cut rather than fade.
- **`AQUARIUM_AUDIO_RECORD` installs a tap that writes on the audio callback's thread.** It is a
  diagnostic reachable only through an environment variable, and the environment is empty under
  `legacyScreenSaver`, so it cannot fire where it would matter. It is still file I/O near a
  real-time thread and should not grow into anything shipped.

- **Fish ride high through the wreck and clip the plank over the breach**, and sometimes clip the
  collapsed deck on the way out. Judged by the user on the installed build and accepted — "can't
  make this perfect". The cause is the wreck's route climbing 15 cm over 29 cm of run while the
  height controller lags behind it; the rock arch, whose route is level, does not show it. The
  honest fix is either more waypoints on the climb or a feed-forward term on the height
  controller, and neither is worth it for a prop that already reads correctly.
- **The pectoral fins never move.** User-reported, and deliberately deferred. It did not matter
  while every fish did nothing but cruise; now that fish slow, stop, hover and forage it is very
  noticeable, because holding station is exactly what a real fish does *with* its pectorals. The
  swim shader is one travelling lateral wave down the body with a `tailward²` envelope and has no
  term for a fin beating out of phase with it — see `swimModifier` in `School.swift`. Note the
  connection to `SwimLimits.pivotFloor`: a hovering fish is allowed to keep 18% of its turning
  authority precisely because a real one reorients on its pectorals, so the number is standing in
  for the animation that is missing.
- **The aquarium's ceiling is not a waterline.** It follows the frustum like the side walls, so it
  rises toward the back of the tank, which no real water surface does. The alternative costs more
  than it buys: a flat waterline can only sit as high as the frustum allows at the *nearest* depth
  a fish can reach, which is the pane, and that fences off 53% of the usable height at the back
  wall. The eye reads "no fish ever goes above this line" as an organising edge even with nothing
  drawn there, so the flat version trades an untruth nobody can see for an artifact people can. The
  framing is that the surface is not in shot, which is true of most head-on aquarium photography.
  **If a waterline is ever drawn, the ceiling must go flat and the empty upper-back comes with it** —
  and the cheap way to draw one is a band in the aquarium look's existing `surface` background ramp,
  not a rendered water surface. The two changes are one change.
- **Site attachment is a hard-coded species name**, `ModelManifest.isSiteAttached`, exactly like
  `isManmade` and with the same debt: it is authoring data and `docs/decorations.md` is the contract
  for it. A manifest field added for one species before a second needs it costs a pass over the
  whole library to earn nothing.
- **A clownfish whose anemone stands near the frame edge lives near the frame edge.** Host selection
  does not prefer a central anemone. Low risk, since `ReefLayout` places props inside the frame.
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

- **The saver reads `manifest.json` out of the *built bundle*, so editing it under `Assets/`
  changes nothing until you rebuild.** `build-saver.sh` `ditto`s `Assets/` into `Resources/`.
  This ate a whole parameter sweep: three configurations were patched into the source manifest,
  three runs were made, and all three measured the value that happened to be in the bundle —
  two of them returned *identical* counts, which is the only reason it was caught. A sweep must
  rebuild, or patch the bundle's copy.
- **A measurement whose limiter is a cooldown is a measurement of the cooldown.** The fish
  swish was tuned three times against a count per ninety seconds, and for two of those the
  number was set by the per-tank cooldown refusing half the offers rather than by the trigger.
  The `refused` counter beside the `swishes` counter exists so that this is visible; when it is
  comparable to the count, the knob under test is not the one being measured.
- **A `legacyScreenSaver` host outlives its session, keeps its views, and loads several saver
  bundles at once.** Three consequences, each of which cost time: a view from a previous
  activation is still animating at 60 fps ten minutes later and will claim anything a `static`
  arbitrates; the bundle competing with yours may not be yours, so a per-bundle `static` cannot
  see it; and a real session **reuses the picker's existing host and its existing full-screen
  view** rather than spawning one, so "was this view born into the session" is not a question
  with an answer. Measured with a per-second `lsof` sweep across an activation.
- **`willstop` is posted before the host exists, exactly as `didstart` is.** The known trap is
  half a trap: a screensaver dismissed inside its first second is over before the observer is
  installed, so the startup guess is never corrected *in either direction*. Gating on the
  session alone therefore plays into a room after the screensaver has gone.
- **A throwaway `AVAudioEngine()` used only to read its output format crashes.** `AVAudioEngine()
  .outputNode.outputFormat(forBus: 0)` deallocates the engine before the node is used, and the
  dangling node fails a pointer-authentication check — `EXC_BAD_ACCESS`/`SIGKILL`, with a stack
  in `AVAudioIONodeImpl::AUI()` and no message. The device's rate is only knowable from an engine
  you are keeping.
- **`AVAudioFile(forWriting:settings:)` given a mixer's own `format.settings` writes 32-bit
  float in a `WAVE_FORMAT_EXTENSIBLE` container**, which `afplay` plays and which Python's
  `wave` module and the `audio-lens` skill both refuse to open. A recording nothing can measure
  is not a diagnostic. Ask for 16-bit PCM explicitly; `AVAudioFile` converts on write. And the
  header is only finalised when the file object is released — `tools/run-saver.swift` calls
  `stopAnimation()` before it captures, which is what closes it.

- **A ramped avoidance push settles a fish at its own margin, so a margin is a position.** It
  reads like a soft preference and behaves like a command: the equilibrium where the push cancels
  the height controller sits at roughly the margin itself, and the behaviour layer contributes a
  few percent. Stating that margin in body lengths therefore *placed* a moray in mid-water. Any
  clearance that faces the floor is a girth question — `Tank.fishFloorClearance`,
  `Avoidance.clamp`, `verticalSpan.low` and now `Avoidance.push` all agree, and the invariant tying
  them together is that **the field must be neutral at the lowest height a behaviour may name**.
- **A knob within a few percent of a cap upstream of it is not a knob.** `lurkerCeiling` was 0.32
  of the column and `Avoidance.margin` capped the eel at 0.33 of it, so every value of the knob
  produced the same animal. A sweep would have reported "no effect" and been believed. Before
  tuning anything, check what else clamps the same quantity.
- **A sphere test for arriving at a waypoint is satisfied from above.** `length * 0.35` is 17 cm
  for a moray against a 4.5 cm hole, so a fish that never entered the wreck completed the route
  through it, and every instrument agreed the feature worked. Arrival on a route has to be
  measured against the route — lateral distance to the axis, plus the plane through the waypoint.
- **`atan2` of a shrinking horizontal offset is a singularity, and the guard was 0.1 mm.** Steering
  yaw at a point the fish is nearly on top of gives a direction made of noise, and the fish
  pirouettes. It looks exactly like a behaviour bug — an animal "changing its mind" — and it is
  arithmetic. Near a target, steer along the *path* rather than at the point.
- **A timeout that also covers the approach is not a stall detector.** Most of a transit's budget
  went on swimming to the route, so the clock ran out inside the hull. Refresh the patience on
  progress, or the measurement is of the approach rather than of the crossing.
- **A fit test is written for a stationary fish and used by a moving one.** `girth <= radius` says
  the animal is inside the tube if you place it there; it says nothing about an animal steering
  along it, which arrives with some tracking error. Admitted at an 11% margin, a deep-bodied fish
  crossed the rock arch with its belly through the crown. Buy the margin at admission — tightening
  the *arrival* test instead is worse, because a fish that cannot tick off a waypoint does not
  leave, it sits in the hole until the transit times out.
- **The last waypoint of a route must be left by, not arrived at.** Asking a fish to reach a point
  it has already swum past is asking it to turn round, and a transit cannot be abandoned partway,
  so it turns round, overshoots, and repeats until the timeout. Any waypoint with nothing beyond it
  wants a plane test, not a distance test.
- **A fresh decision taken in a doorway does not know it is in a doorway.** `choose` has no term
  for "just came out of a wreck", so half its headings sent the fish back in — and the prop
  repulsion that would have prevented it is deliberately cut to 15% on exactly the props that have
  holes. A behaviour that ends somewhere specific has to hand the next one an intent.
- **A lookahead stated in body lengths silently disables pure pursuit.** Half a body length is
  24 cm for the moray against route legs 7 cm long, so the carrot clamped to the far end of every
  segment and the follower quietly became the thing it replaced — aiming straight at the waypoint.
  There is no symptom but a measurement that does not move. Make a lookahead a fraction of the leg.
- **A SpriteKit overlay costs a full-screen pass whatever is on it.** The seed badge is a few
  characters and measures 2.0 ms of GPU at 2056x1329 — 5.8 ms without it, 7.8 ms with. 60 fps is
  unaffected and the energy is not free. If it ever matters, the cheap version is a quad parented
  to the camera, at the price of having to fight fog, tone mapping and bloom, which is exactly
  what the overlay avoids.
- **A prop's silhouette is a constraint, and it fails at tank scale rather than in the studio.**
  Widening the wreck's hold to admit medium fish hit its clearance target exactly — 0.286 m
  measured against a 0.23 m declaration — by removing the garboard, the starboard sheer strake,
  the frames and the deck across the full beam. The studio render looked like a damaged ship. At
  tank scale it read as **two boat fragments with a gap between them**, and the wreck is one of the
  best-looking props in the library. Reverted, and it turned out no cut was needed at all. Judge a
  prop where it will be seen; a clearance number cannot tell you the hull came apart.
- **Vertical clearance is a girth question too, and getting it wrong pins a fish in mid-water.**
  `Tank.fishFloorClearance` was 1.6 *body lengths*, which is four to five girths for every fish
  whose proportions are ordinary and therefore looked correct for years. A moray is twenty girths
  long, so the same rule demanded 0.78 m of water under an animal 0.49 m long; that collided with
  the "at most half the column" clamp and left the eel unable to descend at all, at any point in
  its life, through any behaviour. Every floor clearance in the school is stated in girths now —
  five for spawning, three for the height a behaviour may aim at, 1.5 for the hard clamp — which
  reproduces the old numbers for normal fish and only moves the ones where length and girth do not
  track each other.
- **A repulsion added for one prop can silently disable a feature on another.** Giving props a
  sideways shove (so fish go *round* kelp rather than being catapulted over it) also gave the rock
  arch a shove of 1.09, comparable to a pane of glass — so fish visibly approached the one prop
  built to be swum through and turned away. A prop that declares a passage is mostly hole, and a
  dome is the wrong model for it: `SurfaceField.passableSideShare` keeps 15% of the repulsion, and
  transits per 90 s roughly doubled the moment it was applied.
- **A fish's fit through a hole is its girth, and girth is not a function of length.** The library
  spans 0.0179 m to 0.1276 m of girth over lengths from 0.07 m to 1.5 m, and the ordering is not
  the same in both: the longest animal is the third *thinnest*. Any sphere test on `bodyLength`
  gets the eel exactly backwards.
- **An animating `SaverView` is immortal, and a leaked one goes on rendering forever.** This is the
  worst bug found in this repo so far and it was invisible for months. `CADisplayLink` retains its
  target and the run loop retains the link; `ScreenSaverView`'s inherited animation timer does the
  same. The only code invalidating the link lived in `deinit`, which therefore could never run. Any
  host that discards a saver view without calling `stopAnimation()` leaked the whole graph — view,
  scene, `ModelCache`, `SCNRenderer`, MSAA and depth attachments, drawables — **and the orphan kept
  drawing at 60 fps into a window nobody could see**, allocating fresh IOSurfaces for as long as the
  process lived. Measured at **161 MB per discarded view** at 2056x1329, which is ~570 MB at
  4112x2658. A dozen Previews in System Settings took the host to a 5.7 GB footprint, at which point
  the settings sheet could no longer allocate its preview tank and the Settings button silently did
  nothing — no crash, nothing in the log. Frames are now tied to *being in a window* rather than to
  `startAnimation()` alone. `SAVERKIT_LIFECYCLE=1` logs every view created and destroyed; counting
  the two lines is the whole regression test.
- **A memory harness that pumps the run loop by hand measures its own autorelease pool.** Objects
  autoreleased outside a run-loop callout land in a top-level pool that never drains, and the
  resulting graph is completely convincing: the first probe reported a steady 445 MB per cycle
  leaking from the settings sheet, which does not leak at all. Call `app.run()`. `leaks <pid>
  --traceTree=<addr>` is what exposed it — the roots were `@autoreleasepool content`.
- **A screenshot tool proves nothing about deallocation.** `run-saver` renders and then exits, and
  process exit does not run `deinit`, so a create/destroy count taken from it is zero-destroyed
  whether or not anything leaks. Lifecycle has to be measured across repeated create-and-discard
  cycles inside one long-lived process.
- **An instantaneous census cannot tell "never happens" from "happens and is brief", and it fails
  toward the first.** Sampling which behaviour each fish was in, once a second for seventy seconds,
  found *zero* darts and read exactly like a dead code path. Nothing was wrong: a state lasting half
  a second and chosen on 1.6% of decisions occupies about two tenths of one percent of the school's
  time, so zero was the expected observation whether or not it worked. Counting **entries** found
  four in 150 s. Anything rare and short has to be counted as it is entered, or the measurement
  sends you tuning a weight that was fine.
- **A fish keeps its real metres while the tank shrinks around it, so a spawn range floored at a
  body length can be wider than the tank.** A long fish was handed a lateral range exceeding the
  glass and started outside it, to be dragged back by the clamp on the first frame. Floor a spawn
  range at a *fraction of the wall*, never at a length.
- **`abs(y)` against the frame half-height is the wrong out-of-frame test once fish can go low.**
  At any depth nearer than `floorEntryDepth` the frustum is shorter than the floor is deep, so a
  fish resting just above the sand there satisfies it. Nothing used to put a fish there; foraging
  does, and it vanished and respawned while sitting on the gravel in shot. Test the top edge and
  the floor separately.
- **`SCNNode.flattenedClone()` would destroy an articulated prop**, merging the hierarchy into one
  node and taking `part_lid` with it. Plain `clone()` is already what is wanted: it copies the node
  *tree* while sharing geometry, so two chests in one tank hinge independently.
- **A state machine integrated against the frame's delta is not reproducible from a seed.** Every
  A/B render in `docs/water-looks.md` depends on `AQUARIUM_SEED=42` naming one exact tank, and a
  variable timestep makes the school reproducible only to within whatever the frame rate did.
  Deriving the step count from absolute time — after t seconds exactly `floor(t / step)` steps have
  run — costs nothing and keeps the workflow.
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
