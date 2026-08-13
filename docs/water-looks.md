# Water looks

Three validated lighting-and-water parameter sets for the tank, and the rule that makes them
coherent. The numbers live in `Savers/Aquarium/Sources/WaterLook.swift` and
`Savers/Aquarium/Sources/TankFloor.swift`; this file is why they are what they are.

A look is one half of a tank style — `TankStyle` pairs it with the tank's dimensions, its prop
density and the substrate the look is balanced against, and `AQUARIUM_STYLE` picks the pair.
The ocean is **two** looks over one set of dimensions: `shallowReef` and `deepOcean` draw the
same volume of water and differ only in what that water is doing to the light in it.

```bash
AQUARIUM_STYLE=shallowReef AQUARIUM_SEED=7 \
  tools/run-saver.swift Aquarium --size 1600x900 --seconds 4 --screenshot /tmp/reef.png
tools/water-luminance.py /tmp/reef.png
tools/water-luminance.py --entry-depth 2.25 /tmp/aquarium.png   # the aquarium's own tank
```

`AQUARIUM_STYLE` is `aquarium`, `shallowReef` or `deepOcean`, defaulting to `shallowReef`; it
is an environment override rather than a setting because the settings sheet in
`aquarium-plan.md` §2a is a later phase's job.

## The rule: the ground may not out-brighten the water it is seen through

The tank had a physical incoherence, and naming it is most of the fix. **Light reaching the
seabed and light scattering in the water column come out of one budget.** The old tank spent
that budget twice: the sand was lit as though light were plentiful while the water was tinted
and fogged as though it were not. The eye reconciles that the only way it can — as a lit shelf
of dirt that drops off into an abyss — which is exactly what it was reported as, and is not
what a reef looks like from any depth.

Stated as something a render can be checked against:

> The near floor must be **dimmer** than the open water above the horizon, and the floor must
> then **brighten** with distance as the fog carries it toward that backdrop.

Both halves matter. The first is the light budget. The second is the direction real haze runs:
a distant surface tends toward the sky's radiance, it does not fall away from it. The old tank
had the sign backwards on both counts — a near floor 4.9x the backdrop, falling toward it with
distance — and that inversion is the whole of what read as "a cliff into the abyss".

## How it is measured

`tools/water-luminance.py` reads the delivered PNG. It is not an eyeball substitute; it is
what stops an author from talking themselves into a look that measures wrong.

- **Bands are stated as multiples of the tank's own floor entry depth, not in pixels.** The
  floor's screen position is fixed by the tank's geometry alone: the seabed sits one half-height
  below the eye at `Tank.floorEntryDepth`, so floor at depth *d* lands at NDC y =
  `-floorEntryDepth / d` with the aspect ratio cancelling. A band at *k* x the entry depth
  therefore lands at NDC y = `-1/k` in any tank at any drawable shape, which is what keeps the
  numbers comparable now that the tank's dimensions are drawn per launch and per style — the
  aquarium's floor enters at 2.25 m and a full-reach ocean's at 6.2 m, and the two are being
  compared at the same *place in the frame*. `--entry-depth` only labels the bands in metres;
  it does not move them.
- **The water backdrop band is NDC y 0.02–0.20**, immediately above the horizon. The floor
  plane meets eye height only at infinity, so NDC y = 0 is the horizon and everything above it
  is open water. This is the band the fog is fogging *toward*, which is what makes it the right
  thing to compare the floor against.
- **Every band is sampled from the central 40% of the width.** The vignette darkens the frame
  edges by up to 23%, and bands at different heights would otherwise be compared through
  different amounts of it.
- **Bands are reported as a median, not a mean.** A crop dominated by the wrong pixels has
  misled an author here before; a fish or a prop crossing a band moves a median far less than a
  mean. It is still not immune, and the denser tank has made it less so: at 1600x900 the deep
  ocean's seed 7 puts brain coral across the whole near band and reports 1.78, while the same
  look and seed at 2560x720 reports 0.81. **A single reading that fails is a reason to look at
  the render, not a verdict** — run several seeds and both shapes, and read the band's own
  sRGB colour, which says plainly whether it sampled substrate or coral.
- **Luminance is linear**: sRGB is de-gamma'd before `0.2126R + 0.7152G + 0.0722B`. Comparing
  8-bit values directly would overstate the dark water by a long way.

## The second rule: the fish must keep their own colour

A tank exists to show off vivid fish, and there is a lighting failure that costs exactly that
while improving everything else. A hard key from straight overhead models *terrain* beautifully
— bright horizontal tops, dark undersides — and the aquarium look was first built on precisely
that reasoning, with the dimmest fill of the three so the key would do all the work. But a fish
is seen **side-on**, and its flank is both the entire visible surface and the only part carrying
the markings. Under a vertical key with almost no fill the tangs went blue-grey while the same
fish at the same seed stayed vivid in the reef look.

`fish_flanks()` measures it, and every attempt at the metric has been wrong in a different way:

- **Saturation is the wrong measure.** A tang washed toward the tank's own blue is still a
  saturated blue and scores well — while having lost precisely the thing being measured. The
  metric is distance in **chromaticity** from the water the fish is swimming in, which is
  normalised by brightness: a fish that is merely darker than the water scores zero, and only a
  fish holding a colour of its own scores at all.
- **Fish must be found by difference, not by colour.** They are the pixels in the open water
  that differ from their own row's water colour, because a washed-out fish has to stay in the
  sample or the measurement congratulates itself by discarding its own failure case. The band
  above the horizon is not fish alone, though, so blobs are then filtered twice:
  - **By size, as a fraction of the frame — never in pixels.** On-screen fish size is a property
    of the tank: props hold their angular size while fish keep their real metres, so the
    aquarium's fish are three times the fraction of the frame that the reference tank's are. A
    ceiling of 6000 px, written against the reference tank, threw away *every* aquarium fish
    once the tank was resized; the statistic was then decided by whatever small far fish
    survived and reported 0.004 for a frame of vivid tangs.
  - **By attachment, which is what actually separates a fish from a pillar.** Everything
    standing on the floor enters the band from below and is clipped by the band's bottom row; a
    fish almost never is. It costs the occasional fish swimming exactly at the horizon, which is
    the cheap direction to be wrong in, and it does the job the size ceiling was failing to do —
    the wreck's mast and the rock pillars are large low-chroma regions that once made the *reef*
    look as though its fish had gone grey.
- **The vignette has to be cropped out here too**, for exactly the reason the luminance bands
  crop it. A row's own median cannot describe both its middle and its darkened corners, so at
  full width the two frame edges are the largest not-water regions in the frame by a distance —
  and being water, they carry no chroma at all. They decided the statistic outright the moment
  the size ceiling was widened enough to admit them. Fish are sampled from the central 60%.

## Results

Near floor (1.05–1.29x the floor entry depth) over water backdrop, and fish-flank colour, at
1600x900 and 2560x720, seeds 7, 42 and 1234. Ranges are across those six renders; the ratio is
quoted without deep ocean's seed 7 at 16:9, whose near band is brain coral rather than floor.

| | near floor Y | backdrop Y | ratio | far floor (2.9–4.2x entry) | flank chroma | holding own colour |
|---|---|---|---|---|---|---|
| **before** | 0.0501 | 0.0103 | **4.87** — incoherent | 0.0226, *falling away* from the backdrop | — | — |
| deep ocean | 0.0158 | 0.0200 | **0.79–0.85** | rising to meet it | 0.075–0.180 | 47–98% |
| shallow reef | 0.0956 | 0.1308 | **0.73–0.79** | rising to meet it | 0.035–0.128 | 13–81% |
| aquarium | 0.0576 | 0.0812 | **0.68–0.74** | rising to meet it | 0.052–0.235 | 16–97% |
| *aquarium, first pass* | | | *0.73* | | *0.022* | *29%* |

The ratio went from 4.9 to 0.68–0.85 and the far floor changed sign: it now converges *upward*
into the backdrop instead of dropping away from it. That is the shelf-and-cliff read gone, and
it is visible in the renders as the floor and the water becoming one continuous space.

The aquarium is level with or ahead of the reef on flank colour at every seed measured — 0.100
against 0.060 averaged over the six renders — where the first, vertical-key pass sat at less
than half the reef's. That is what the rework bought, and the floor ratio did not move for it,
which is the point of measuring both.

**Flank chroma is a per-seed number and only barely a per-look one.** Each style draws its own
species, and a look whose seed happens to deal grey-striped cardinalfish scores a third of what
the same look scores on a seed that deals purple anthias. Compare it between builds at a fixed
seed, and across a handful of seeds when comparing looks; a single reading proves nothing.
Deep ocean also flatters itself, because its water is dark and nearly achromatic relative to
any fish at all.

0.7–0.85 rather than 0.95 is deliberate. A substrate that measures just under the backdrop still
reads as bright ground, because it occupies the bottom of the frame where the eye expects
shadow; the looks were tuned by eye and the measurement then confirmed where they landed.

## The lighting environment, and why every look needs its own

Metal in the tank read as rock. `AquariumScene` never set `scene.lightingEnvironment`, and in
SceneKit's PBR a metallic surface takes almost all of its colour from what it reflects — with no
environment it has nothing to reflect, collapses toward its dark specular response, and the
diving suit's helmet comes out the same dull olive as the boulder beside it. The three
directional lights cannot substitute: they give metal *highlights*, not an environment.

Each look now generates its own, as a 256x128 equirectangular image:

| | above | below | intensity |
|---|---|---|---|
| deep ocean | `0.105, 0.270, 0.420` | `0.014, 0.038, 0.066` | 0.85 |
| shallow reef | `0.440, 0.870, 0.940` | `0.045, 0.150, 0.185` | 1.00 |
| aquarium | `0.235, 0.600, 1.000` | `0.022, 0.080, 0.180` | 1.25 |

- **Generated, not shipped.** The bundle is already ~35 MB, and an HDR of somewhere else could
  only ever agree with one look. This costs nothing and is more correct.
- **It must agree with the look's water**, or metal reflects a sea it is not sitting in. Both
  ramps run *to the look's own `water` colour at the horizon* — the same coherence rule the
  substrate obeys, extended to reflections.
- **Two ramps meeting at the horizon, not one running top to bottom.** The knee is the point: a
  helmet's crown reflects the bright surface, its shoulders reflect water of exactly this look's
  colour, and its undersides reflect the dark below. That is what puts polished and tarnished on
  one object without needing two materials. A single ramp puts the water colour nowhere and
  reads as a studio gradient wrapped round the tank.
- **Watch the intensity.** The environment contributes diffuse light to *everything*, not just
  metal, and the matte rock and coral are most of the scene. Adding it raised the floor ratios
  by 0.08–0.20 on its own — deep ocean went 0.80 → 0.88 — so `deepSand` and `reefSand` came down
  and both ocean ambients were trimmed to put the margin back. Anyone retuning the environment
  must re-run the floor measurement; the two are coupled.

## The three looks

Colours are sRGB 0–1. Light `elevation` is degrees above the horizon the light comes *from*;
90 is straight down. Intensities are SceneKit's.

**A look owns the fog's shape, not its distances.** The exponent is scale-free and belongs to
the water; the start and end are the only numbers in this whole rig that would have to be stated
in metres against a tank of a particular size — and the tank's size is drawn per launch. They
come from `Tank.fogStart` / `Tank.fogEnd`, which state them as fractions of the tank's own depth
range, so a close-in ocean draw and a two-metre glass box each get fog that reaches their own
back wall. The metres quoted below are what those fractions produce in each style's tank.

### 1. Deep ocean

Closest to what existed, and the one that had to change most, because it is the look whose
water was already dark: everything else had to come down to meet it.

| | value | why |
|---|---|---|
| water / fog / clear | `0.043, 0.128, 0.205` | Blue above green, unlike the old `0.028, 0.094, 0.112` which was a teal. At depth the red *and* green ends are gone; blue-dominant is what "deep" actually looks like. The rendered backdrop is 1.9x the old one's luminance — a backdrop that dark cannot be the same water a visible seabed sits in. |
| surface ramp | `0.068, 0.196, 0.310` | Subtle. There is a surface up there, but not much of it survives the trip. |
| fog | exponent **1.55**; the tank gives 2.6–4.4 m to 15–26 m | The steepest of the three. Depth is sold by how fast things leave, not by how dark the backdrop is — which is what lets the exponent survive a tank whose reach is redrawn every launch. |
| ambient | `0.21, 0.40, 0.60` @ 285 | Cool, blue-shifted, dim — and trimmed from 330 once the lighting environment started contributing diffuse of its own. |
| **key** | `0.70, 0.86, 1.0` @ **520**, elevation 74°, azimuth 20° | **Was `1.0, 0.97, 0.88` @ 900 at 65.9°.** Twenty metres of water removes the red from daylight long before it reaches this seabed, so a warm key at depth is the single detail that says "studio lamp" loudest. Blue-white, and at little more than half the old intensity because that intensity is most of what over-lit the floor. |
| rim | `0.28, 0.56, 0.88` @ 240, elevation −20°, azimuth 143° | Unchanged in aim, roughly halved: at this backdrop level the old 420 was drawing a hot edge on every fish. |
| camera | bloom 0.25 / 0.95, vignette 0.36 / 1.25 | Vignette down from 0.55. A strong vignette makes the frame edges darker than the middle, which *adds* to the shelf-and-cliff read rather than hiding it. At 0.48 it also completely swamped the surface ramp. |
| snow | rate 46, alpha 0.30 | Densest of the three — open ocean at depth is full of it, and it is free particulate evidence that the water is a volume. |
| substrate | `deepSand`, base `0.168, 0.170, 0.163` | Down from `0.36, 0.33, 0.26` and desaturated toward neutral-cool. Grain contrast 0.105 → 0.055: at this light level the old grain read as noise. Ambient alone would not bring the ratio back after the environment was added — most of this floor's light comes from the key and the IBL — so the albedo is the lever that did it. |

### 2. Shallow reef

The snorkelling look. Everything brighter and more saturated, the water carrying real colour,
and a key that is nearly overhead and still warm.

| | value | why |
|---|---|---|
| water / fog / clear | `0.105, 0.385, 0.470` | Turquoise, blue slightly over green. The rendered backdrop is 12.7x the old one's luminance (0.131 vs 0.010): a few metres of water over pale sand *is* bright, and this is the number the whole look hangs on. |
| surface ramp | `0.225, 0.600, 0.665` | The strongest of the three, and the thing that most directly says "the light source is a surface just overhead" — the top of the frame is visibly brighter than the horizon. |
| fog | exponent **1.05**; the tank gives 2.6–4.4 m to 15–26 m | The flattest of the three. Shallow water is clearer, and the far reef should still be legible rather than dissolved. Same distances as the deep look — the two share a tank, and the whole difference between them is what the water does over them. |
| ambient | `0.42, 0.68, 0.72` @ 440 | A shallow water column really is scattering this much. Pulled back from a first pass at `0.44, 0.74, 0.78` @ 520, which was cyan enough to drain the warmth out of the sand and make it read grey, and trimmed again when the environment added diffuse. |
| **key** | `1.0, 0.97, 0.86` @ 820, elevation **82°**, azimuth 12° | Still warm — at 3–5 m there is not enough water to take the red out — and pitched from 65.9° to 82°, nearly overhead, which is where the sun is when the surface is right above you. |
| rim | `0.46, 0.80, 0.94` @ 300 | Bright and cool, to keep a pale fish off a bright backdrop. |
| camera | bloom 0.45 / 0.88, vignette 0.32 / 1.2 | Most bloom, least vignette: sunny and open. |
| snow | rate 16, alpha 0.20 | Sparse. Clear shallow water. |
| substrate | `reefSand`, base `0.330, 0.296, 0.236` | Noticeably warmer than the original sand and barely darker, yet only 0.74 of the backdrop because the water rose so much further. This is the look where the coherence rule buys brightness rather than costing it. |

### 3. Aquarium

A lit glass tank, and the two things that make it one are the key and the fog.

| | value | why |
|---|---|---|
| water / fog / clear | `0.070, 0.265, 0.560` | Far more saturated blue than either ocean look — blue is double green and eight times red. Measured saturation 0.86–0.87 against the reef's 0.76. |
| surface ramp | `0.105, 0.350, 0.665` | Mild. A tank's backdrop is a lit panel, not a sky. |
| fog | exponent 1.35; the tank gives **1.6 m to 6.5 m** | The shortest by a wide margin, because a tank has a back wall a few metres away rather than an infinite volume, and that is what the fog is standing in for. It comes out of the tank's own 2.0–6.2 m depth range rather than being stated: the look asked for 3.5–21 m against the old seascape-sized aquarium, and a number in metres is exactly what a reshaped tank invalidates. |
| ambient | `0.46, 0.68, 0.94` @ **620** | The **brightest** fill of the three, which is the opposite of the obvious reading and was arrived at the hard way — see below. A small glass box is a bounce environment: every wall returns light, so a generous fill is what a tank actually has. |
| **key** | `0.86, 0.94, 1.0` @ **1350**, elevation **78°**, azimuth 8° | Fluorescent blue-white instead of the old warm `1.0, 0.97, 0.88`, and near-vertical instead of 65.9°. A hood lamp has no warmth and all but no angle. |
| rim | `0.42, 0.68, 1.0` @ **430** | The *strongest* of the three, not the weakest. In a glass box the back and side walls really do throw light back at a fish's far flank, and this is what catches it. |

| camera | bloom 0.40 / 0.90, vignette 0.30 / 1.2 | Least vignette — glass and a lamp, not a diver's mask. |
| snow | rate 8, alpha 0.14 | Nearly none. A maintained tank has a filter. |
| substrate | `gravel` — see below | |

**The relight, and the mistake it corrects.** The first pass took "a hood lamp has no angle" to
its logical end: key straight down at 90°, at 1700, with the dimmest ambient of the three at
300 and a token rim at 220. The terrain was the best of the three looks — and the fish went
blue-grey, measured at 0.022 flank chroma against the reef's 0.054. Everything that made the
rocks read made the fish fail, because a rock is seen from above and a fish is seen from the
side. The correction moves light out of the key and into everything that reaches a flank: key
1700 → 1350 and pitched 12° off vertical so it grazes rather than skims, ambient 300 → 620,
rim 220 → 430, plus the lighting environment. Flank chroma went 0.022 → 0.047 and the floor
ratio did not move. The tank still reads lit-from-above; it simply is not lit *only* from above,
which was never true of a glass box anyway.

#### The gravel

`Substrate` gained a `grainTints` palette, because one base colour plus a monochrome shade
offset can only make a *material*, and coloured gravel is several materials at once. An empty
list means "the grains are the same stuff as the ground between them", which is what sand is,
so the two ocean looks are unaffected.

```
base                 0.135, 0.150, 0.185
tints  cobalt        0.098, 0.145, 0.300
       pale cobalt   0.120, 0.190, 0.265
       terracotta    0.205, 0.160, 0.150
       pale natural  0.215, 0.215, 0.205
       basalt        0.105, 0.112, 0.125
grainContrast 0.030   grainRadius 3.0...6.5   grainCount 1300
tileSize 0.55 m        roughness 0.62
```

Four things had to be pushed much further than the obvious values before it stopped reading as
coloured static, and all four are worth keeping if these numbers are ever revisited:

1. **Coverage, which mattered most.** At 520 grains the stones were isolated bright dots on a
   darker ground, and isolated dots at this scale are the definition of confetti. 1300 grains at
   this radius is about 1.4x overdraw — a complete mosaic, where the ground between the stones
   barely shows and the surface reads as *a bed of stones* rather than as speckle on dirt.
2. **Size, which is the one number the tank rework moved.** Real aquarium gravel is 3–6 mm, and
   at 3 mm a stone is under two pixels — the floor comes back as coloured static. What the eye
   needs is a grain it can resolve, so this is pebble gravel. It was 1.25 m per 256² tile, a
   27–58 mm stone, against an aquarium framed like a seascape; the tank now stands its floor at
   2.25 m rather than 6.2 m, which is 2.3x closer, and the same stones read as boulders. 0.55 m
   per tile puts a 13–28 mm stone back at the *on-screen* size the palette was tuned against,
   and closer to what a large display tank actually holds. It still survives the mip chain
   instead of shimmering through it. Unlike everything else here this is not scale-free: it is
   the aquarium's tank the tile is sized against, which is one more reason gravel is not seabed.
3. **Compress the luminance range.** The first palette ran cream 0.33 down to basalt 0.075,
   four to one, and that range is what the eye first read as noise. Compressed to about two to
   one, the same hues read as different stones.
4. **Compress the hue spread too.** Compressing luminance was not enough on its own: five tints
   spread round the wheel — cobalt, teal, cream, terracotta, basalt — still read as rainbow
   speckle at full frame, because what the eye counts is the *number of distinct hues*, not
   their intensity. Real aquarium gravel is two or three tints plus naturals, so this is one
   blue family in two values, one warm accent, and two naturals. The warm accent is what keeps
   it from looking like blue sand; a second one is what made it confetti.

## Unresolved: the brass never reaches SceneKit

The lighting environment above was added because metal read as rock. It was necessary and it is
not sufficient: **the diving suit and the treasure chest still read as rock, and the cause is
upstream of the scene entirely.** Two independent things are wrong, and neither can be fixed
from the saver's side.

**1. Every baked material arrives with `metalness = 0`.** Probing the shipped assets:

```
diving_suit.usdz    diving_suit_atlas:    metalness=__NSCFNumber 0, roughness=NSURL
treasure_chest.usdz treasure_chest_atlas: metalness=__NSCFNumber 0, roughness=NSURL
```

The bake writes base colour, roughness and normal — three maps, no metalness — and the
replacement Principled material is left at the default 0. A material with metalness 0 is a
*dielectric*: it gets a weak white specular sheen and never the coloured reflection that makes
brass look like brass, because in PBR a metal's base colour *is* its specular colour and that
path is only taken when metalness > 0. No lighting environment can substitute for it.

**2. The brass albedo is not in the atlas either.** `diving_suit_base_color.png` contains no
warm texels at all — the fraction of texels with `r - b > 0.15` is **0.000**, and the warmest
4000 texels average `0.301, 0.264, 0.170`, a dull khaki. The model declares its alloy at
`0.40, 0.265, 0.085`, whose `r - b` is 0.315. The whole 512² atlas is olive.

That is consistent with how the bake is set up rather than with a bad colour choice: it bakes
the `DIFFUSE` pass with direct and indirect off, and **a metal has no diffuse component** — its
colour lives entirely on the specular/metallic path, which that pass does not see. So the more
metallic the material, the less of it survives the bake.

Verified rather than assumed: forcing `metalness = 0.9` on the whole library at load
(`AQUARIUM_FORCE_METALNESS=0.9`, a diagnostic in `ModelCache`, not a fix — it is wrong for coral
and wood, which is the point) makes the suit *darker and bluer* rather than brassy. It is now
correctly reflecting the environment; it just has no brass albedo left to tint that reflection
with.

There is also a third constraint that will bite even after the bake is fixed, and it is worth
knowing before anyone spends effort on it: **brass cannot read as brass in a strongly blue
environment**, because a metal's reflection is `baseColour x environment` and a blue environment
has almost no red for a red-orange alloy to return. `0.40, 0.265, 0.085` against the aquarium's
environment multiplies out to a dark olive. This is physically right and visually useless. The
shallow reef, whose environment tops out at `0.44, 0.87, 0.94`, has much more to give it; the
aquarium look may need its warm accent to come from the lamp rather than from the water — which
is exactly the sort of thing the `BRASS`-versus-duller-alloy decision noted in `surfaces.py`
should be revisited against, now that metals have something to reflect at all.

None of the model or bake files were touched — fixing the bake is where this has to be fixed.

## Things worth knowing before changing any of this

- **The background must be set on the scene**, not as the pass's clear colour: with `wantsHDR`
  the `MTLClearColor` is discarded and the drawable comes back with alpha 0.
- **The fog colour must equal the background**, or the far distance ends in a visible wall of a
  slightly different colour. The surface ramp is built to respect this: it reaches the flat
  water colour exactly at the horizon and holds it below, so everything the fog fogs out does so
  against the colour the fog is actually fogging toward. Only backdrop the fog never touches is
  brightened.
- **A ramp that stops short of the horizon draws a line across the frame.** The aquarium look
  ran one to 0.42 of the frame height and the slope discontinuity read as the seam of a badly
  lit backdrop, plainly visible at full frame. The span is now fixed at the top half rather than
  being a parameter, because there is no value other than "the horizon" that is correct.
- **8-bit banding in the backdrop is pre-existing and unchanged.** The vignette's falloff steps
  through single levels across tens of rows in the dark blues. It is present in the original
  renders at the same magnitude (blue 34 → 23 across the frame) and is a property of an 8-bit
  drawable, not of these values. Raising the water levels made it slightly *less* visible.
- **Judge at full frame.** Every problem found here — the seam, the confetti gravel, the grey
  sand, the vignette eating the ramp — was invisible in the parameters and obvious in a
  full-frame PNG. The measurements caught none of them; they only confirmed the one thing they
  were built to check.
- **A measurement calibrated against one tank is not calibrated against another.** Both halves
  of `water-luminance.py` had a size baked into them, and both broke silently when the tank was
  resized rather than reporting anything wrong: the luminance bands were stated in metres
  against a 6.2 m floor entry, and the fish filter capped a blob at 6000 px against a tank whose
  fish are a third the size of this one's. Both are now stated relative to the frame. Anything
  added here should be too.

## Renders

4 s, at both shapes and three seeds, after the looks were merged onto the reworked tanks:

```
/tmp/merge/<style>-s<seed>-<size>.png
  style  deepOcean | shallowReef | aquarium
  seed   7 | 42 | 1234
  size   1600x900 | 2560x720
/tmp/merge/crop-gravel.png     the aquarium's near floor at 1:1
```

From the pass that produced the values, against the tank as it was then:

```
before             /tmp/base-s42.png  /tmp/base-s7.png  /tmp/base-s1234.png
aquarium, first    /tmp/v6-aquarium-s7.png     — the vertical-key pass whose fish went grey
brass diagnostic   /tmp/crop-suit-before.png   /tmp/crop-suit-forced.png   /tmp/atlas-suit.png
```

## Out of scope, and where these numbers touch it

Caustics and god rays are a later phase. Two of these values are the ones that phase will want
to reopen: the deep look's key at 520 is low enough that an animated caustic gobo on it would be
faint, and the aquarium's 1350 from near-overhead is precisely the light a caustic pattern
belongs on. Neither look assumes caustics exist, and adding them will change the substrate
balance — re-run `tools/water-luminance.py` afterwards rather than assuming the ratios hold.

The tank's dimensions were reworked in parallel with these values, and the prediction made here
about what that would cost held: everything stated in metres had to move, and everything
scale-free survived untouched. The fog distances went to `Tank`, which states them as fractions
of the tank's own depth range; the gravel's tile size was re-derived for a floor seen from
2.25 m; the measuring tool's bands became multiples of `Tank.floorEntryDepth` and its fish
filter a fraction of the frame. Every colour, light angle, intensity and substrate albedo came
across unchanged, and the floor ratios landed within 0.06 of where they were measured before the
tank moved under them.

That is the rule for anything added here: **state it against the frame or against the tank's own
depth range, never in metres.**
