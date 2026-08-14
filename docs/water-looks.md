# Water looks

Three validated lighting-and-water parameter sets for the tank, and the rule that makes them
coherent. The numbers live in `Savers/Aquarium/Sources/WaterLook.swift` and
`Savers/Aquarium/Sources/TankFloor.swift`; this file is why they are what they are.

A look is one half of a tank style — `TankStyle` pairs it with the tank's dimensions, its prop
density and the substrate the look is balanced against, and the tank style picks the pair.
The ocean is **two** looks over one set of dimensions: `shallowReef` and `deepOcean` draw the
same volume of water and differ only in what that water is doing to the light in it.

```bash
AQUARIUM_STYLE=shallowReef AQUARIUM_SEED=7 \
  tools/run-saver.swift Aquarium --size 1600x900 --seconds 4 --screenshot /tmp/reef.png
tools/water-luminance.py /tmp/reef.png
tools/water-luminance.py --entry-depth 2.25 /tmp/aquarium.png   # the aquarium's own tank
AQUARIUM_STYLE=aquarium AQUARIUM_GRAVEL=neon AQUARIUM_SEED=42 \
  tools/run-saver.swift Aquarium --size 1600x900 --seconds 3 --screenshot /tmp/tank.png
tools/crop.py /tmp/tank.png --out /tmp/band.png --band     # the substrate, at 1:1
```

Both Python tools want the repository's own interpreter, which is not tracked:

```bash
uv venv --python 3.14.3 .venv
uv pip install --python .venv/bin/python numpy scipy pillow
```

`AQUARIUM_STYLE` is `aquarium`, `shallowReef`, `deepOcean` or `random`, defaulting to
`shallowReef`. It is the render loop's way in — the user's is the settings sheet, which
persists the same names to `ScreenSaverDefaults` (`AquariumSettings`). The environment wins
where both are present, and is empty under `legacyScreenSaver`.

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
| **key** | `1.0, 0.95, 0.82` @ **1316**, elevation **78°**, azimuth 8° | **Warm**, and near-vertical instead of 65.9°. A hood lamp has all but no angle — but it is not the cool white it literally is, and see "The relight for colour" below for why. The intensity is the cool white's divided by this colour's own luminance, so the change between them is the light's colour and not how much of it there is. |
| rim | `0.42, 0.68, 1.0` @ **430** | The *strongest* of the three, not the weakest. In a glass box the back and side walls really do throw light back at a fish's far flank, and this is what catches it. |
| **accent** | `1.0, 0.72, 0.42` @ **260**, elevation **18°**, azimuth −38° | The only warm light in a tank whose water, ambient and environment are all blue, and the exact complement of the key: at 18° it grazes everything standing *up* in the tank and barely touches what it stands on. The two things that needed one are a fish's flank and a vertical brass helmet. |

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

**The relight for colour, and why the key was the lever.** The gravel read dull on a real
display whatever colour the bag was, and three separate complaints — the dull gravel, the bright
hues that would not read bright, and the brass that could not glint — turned out to be one
problem in the illuminant. Adding up what actually lands on a horizontal bed settled it:

```
key   1.35 x 0.978 x (0.86, 0.94, 1.00)  =  (1.14, 1.24, 1.32)
ambient        0.62 x (0.46, 0.68, 0.94)  =  (0.29, 0.42, 0.58)
environment  ~1.25 x (0.17, 0.44, 0.76)   =  (0.21, 0.55, 0.95)
                                    total    (1.63, 2.21, 2.85)   <- red at 57% of blue
```

**The key is the right lever because of where it lands, not because it is the biggest term.** At
elevation 78 it strikes the floor at N·L 0.98 and a fish's flank at 0.21, so warming it warms the
gravel about five times as hard as it warms the fish — which is the whole difficulty, since the
fill that keeps the flanks vivid is also the blue that washes the floor. The measurement bore it
out exactly: the near band went from blue-dominant `0.247, 0.302, 0.388` to red-dominant
`0.333, 0.294, 0.282` while flank chroma held at 0.047 against 0.049.

The accent then buys back what the key cannot reach. It costs floor ratio — river 0.74 → 0.81,
and the brightest bed, `quartz`, 0.88 → **0.96** — which is the one number in this file with less
margin than it had. Caustics bring quartz back to 0.92, and that is what ships.

**A warning for anyone retuning the accent: lowering a light's elevation raises the near-floor
reading rather than sparing it.** The usual intuition — a grazing light spends less on the ground
— is inverted here because the band the tool measures is the substrate's *cross-section*, which
is a vertical face. Dropping the accent from 18° to 8° did not move the ratio at all.

And an honest limit: **the accent does not fix the brass**, because two upstream faults still
stand — every baked material arrives `metalness = 0` and the suit's atlas has no warm texels at
all. What it removes is the third one, so that when the bake is fixed there is finally something
warm in the tank for a red-orange alloy to reflect.

#### The gravel

The aquarium is the only look seen from **outside**, through a pane of glass, and the substrate
is where that has consequences. It is drawn by three files the ocean barely touches:
`Substrate` selects the surface, `GravelPalette` is the catalogue of colours,
`SubstrateTexture` draws the tiles, and `TankFloor` builds both faces of the bed.

```
tileSize 0.55 m   grainRadius 6...13 texels of 512   grainCount 2200   relief 0.62
grainContrast 0.30 (multiplicative)                  roughness 0.55
targetLuminance 0.0348 linear    chroma 1.75    warmth 1.30, 1.03, 0.86
substrateBand 0.11 of the frame's height  -> glass at 1.282 x floorEntryDepth = 2.89 m
section exposure 3.30x   lean 16 deg   crest 0.0138 m
```

**The bed is stones, not speckle, and the difference is a height buffer.** Each stone is
splatted as an irregular flattened dome into a 512² height field and only wins the texels where
it stands *above* what is already there, so overlapping stones occlude each other the way stones
in a bag do. Three consequences worth keeping:

- **Coverage past 1x now buys packing rather than noise.** The old tile painted each grain over
  the last, so more grains only meant later grains winning; 2200 stones is about 2.2x overdraw
  and produces a closed bed with shadow down the gaps.
- **The height field becomes a normal map**, which is the single change that made any palette
  work. Nothing else in the tile responds to the lamp at all. The first gravel was flat-shaded
  ellipses and no amount of colour tuning could make a flat disc read as a pebble.
- **Crevice shading is baked into the albedo; directional shading is not.** Curvature — how far
  a texel sits below its own neighbourhood — does not depend on where the lamp is, so it is safe
  to bake and stays right when a caustic gobo starts modulating the key. Bake the directional
  half and a floor lit from a new angle carries the old angle's shadows.

**Size is the one number that is not scale-free.** Real aquarium gravel is 3–6 mm and at 3 mm a
stone is under two pixels — the floor comes back as coloured static. 0.55 m per tile makes a
13–28 mm stone, which is a size a large display tank plausibly uses and which the eye can
resolve. It is sized against *the aquarium's* 2.25 m floor entry; the same stones on open seabed
would be too small to see, which is one more reason gravel is not a substitute for sand.

##### The cross-section, and the camera move it needed

In a photograph of a real tank the bottom of the frame is not the top of the gravel — it is a
band of gravel **cut open** where the bed meets the glass. Reproducing it turned out to need one
change to the tank rather than a texture: **the viewer has to stand back from the pane.**

The floor meets the bottom of the frame at `floorEntryDepth` and everything nearer is below the
frame, so a camera sitting on the glass — as this one always did — can never see the bed in
section however deep the bed is. `Tank.substrateBand` states how much of the frame's height the
section should fill, and `Tank.glassDepth` turns that into where the pane stands: substrate at
depth *d* lands at NDC y = `-floorEntryDepth / d`, so a pane at `floorEntryDepth / (1 - 2f)`
leaves exactly *f* of the frame below it. It is aspect-invariant for the same reason every other
number here is, and 32:9 and 16:9 renders show the same band.

Three things follow, and all three are load-bearing:

- **The floor is drawn only from the pane outward.** Floor nearer than the glass is on the
  viewer's side of it and paints over the section it is supposed to sit behind.
- **The reef's near edge moves to the pane too.** `reefNearDepth` takes the glass as a floor.
  That cost the aquarium a quarter of its reef area, so `propDensity` went 1.7 → 2.3 to hold the
  tank as full as it was — density is per unit of floor, so less floor means asking for more.
- **The crest may only rise, never dip.** The section's top edge is lumpy geometry rather than a
  ruled line, because a bed of loose stones does not have a straight edge. But every part of the
  surface that is drawn projects *above* that line, so a dip would expose open water behind it.

**11% of the frame is also close to the ceiling.** The lowest a fish is ever placed is 0.62 of
the frame's half-height plus a 0.07 bob, so a band past about 15% would start putting fish in
front of gravel they are supposed to be swimming behind.

##### The palettes, and the two rules that make them safe

Twenty-eight of them, drawn per launch off a stream of its own and pinnable with
`AQUARIUM_GRAVEL`, grouped by the colour scheme each commits to: naturals, single-hue beds,
two-tone contrast mixes (achromatic, complementary, analogous), and multi-hue — ending with the
fluorescent bag, which is the one place the hue-count rule is broken on purpose.

- **Value is governed, hue is free, and the governing is of the finished tile.** Every tile is
  scaled so its mean *linear* luminance lands on `targetLuminance` times the palette's own
  `brightness`. Contrast within a palette is untouched — it is one scalar over the whole buffer.
  Normalising the *palette* instead is not good enough: the crevice shading and the coverage
  darken a tile by amounts that depend on the stone size and the packing, so the delivered floor
  would land wherever those happened to put it.

  `brightness` was not in the first design and its absence is only visible on a contact sheet of
  all twenty-eight beds: pinning every palette to *one* mean makes a white-quartz bed and a
  black-basalt bed normalise to the same number and arrive as the same mid-grey, which is absurd
  — a bag of white gravel is brighter than a bag of black gravel and that is the difference
  between them. It costs the bright hues too, because there is no dark yellow that reads as
  yellow. So the bed's brightness follows the bag's own in-air luminance, compressed to the 0.35
  power and clamped to 0.55–1.20. A 120:1 spread of bags becomes barely 2:1 on the floor, and the
  clamp is what the catalogue's coherence rests on: `quartz` and `sunflower` reach it and measure
  0.88 and 0.84 against `river`'s 0.72 and `obsidian`'s 0.47. At an upper clamp of 1.40 the white
  bed measured 0.99 and was one rounding away from out-brightening its own water.
- **The correction for the blue wash is made entirely in chroma.** The near floor is the darkest
  surface in the tank and on top of it sit the look's blue ambient, its blue lighting environment
  and about a sixth of the way to fog — all additive, none of which care what the stones are. A
  bed painted at a real bag's saturation arrives washed: fluorescent pink measured out as dull
  maroon, neon yellow as olive. Brightness is not the lever, because the coherence rule has that
  one — but it says nothing whatever about chroma. So `chroma` pushes each stone away from its
  own grey at constant luminance, and `warmth` puts back the red end first, since blue is what
  the wash is made of. Neither can move the floor measurement however far they are pushed.

  **1.75 is where this should stop, and the remaining deficit belongs to the lamp.** The
  installed build still reads a little dull, and the reason is upstream of the palette: a home
  tank is lit by *fluorescent* tubes, under which dyed gravel is startlingly saturated — much
  more so than the same bag in daylight — and this look's key is a cool white with every other
  contribution to that floor frankly blue. Pushing `chroma` further is a second correction
  stacked on the same problem, and past here it starts making the gravel look cut out and pasted
  into the tank rather than lit by it. Relighting is also nearly free to try, because every
  palette is normalised to a *delivered* luminance: a warmer key moves the colour without moving
  the floor ratio. See the caustics entry in `docs/next-session.md`.

  Two details in `styled()` that both cost a rendered catalogue to find. The push works on the
  colour's **tint** — what is left after its own grey — and never on the grey itself, because
  warming a whole colour also warms the slight bias in an off-white stone and then amplifies it,
  and the quartz bed came out mustard. And the push is **capped at the gamut** rather than
  clamped after it: clamping a channel to zero rescales a colour unevenly, which is a hue change,
  and it turned every orange bed into a red one — `tangerine`, `ember` and `harbour` all arrived
  looking like `cherry`. Scaling the tint by whatever factor keeps every channel in gamut
  preserves the hue exactly, and says the right thing besides: a colour already at the edge of
  the gamut cannot be made more saturated, while the naturals — where the wash actually does its
  damage — still take the full 1.75.

##### Results

Aquarium, seed 42 at 1600x900, against the palette this replaced:

| | near band Y | surface Y | backdrop Y | ratio | near band sRGB |
|---|---|---|---|---|---|
| before | 0.0732 | 0.0743 | 0.0987 | 0.74 | 0.196, 0.290, 0.529 |
| river | 0.0727 | 0.0683 | 0.1006 | **0.72** | 0.247, 0.302, 0.388 |
| neon | 0.0762 | 0.0696 | 0.1006 | 0.76 | 0.255, 0.318, 0.322 |
| quartz | | | | 0.88 | |
| sunflower | | | | 0.84 | |
| obsidian | | | | 0.47 | |

The ratio is measuring a different surface than it used to — the 1.05–1.29x entry band is now the
*section*, because that is what occupies the bottom of the frame. What the sRGB column shows is
the whole point of the chroma work: the river bed delivers a warm neutral where every previous
gravel delivered blue-grey.

**`monochrome` reports 0.20 and is fine.** A two-to-one mix of black and white stones is bimodal,
and the band's *median* lands in the black. It is the same class of false reading as deep ocean's
seed 7, and the same rule applies: a single failing number is a reason to look at the render.

The two ocean looks were re-measured and are unchanged: deep ocean 0.78, shallow reef 0.77–0.82,
and deep ocean's seed 7 still reports 1.84 for the brain-coral reason recorded above. The sand
path is byte-for-byte the one they were signed off on, and it is kept separate from the stone
path on purpose — sand is a *material* whose grains are never resolved, and running it through
the height-buffer splat would resolve every grain as an object, which is precisely what sand is
not.

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

**That third constraint is now lifted, and it changes nothing on its own.** The aquarium has a
warm accent lamp — `1.0, 0.72, 0.42` at a low elevation, chosen partly for this — so there is
finally warm light in the tank for a red-orange alloy to return. The suit still reads as rock,
because the two faults above are upstream of the scene and neither has been touched. The value of
having done it first is that when the bake *is* fixed, the fix will be visible immediately
instead of landing in a tank that still had no red in it.

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
- **Judge at full frame — and then again at 1:1.** Every problem found here — the seam, the
  confetti gravel, the grey sand, the vignette eating the ramp — was invisible in the parameters
  and obvious in a full-frame PNG. The measurements caught none of them; they only confirmed the
  one thing they were built to check. The substrate then added the opposite failure: whether a
  floor reads as gravel or as coloured static is a question about texels, and a 4K frame shown at
  2000 px wide has already thrown it away. `tools/crop.py` cuts the region out at 1:1, and states
  its regions as fractions of the frame for the same reason `water-luminance.py` states its bands
  as multiples of the entry depth.
- **The floor is seen almost edge-on, so isotropic mip selection erases it.** The near substrate
  keeps its full width on screen and is compressed to a fraction of its height, so one mip level
  has to serve both axes and the blurrier one wins: the stones the tile went to such lengths to
  draw arrived as horizontal smears, and the whole normal map with them. `maxAnisotropy = 16` on
  both the diffuse and the normal is the single line that decides whether any of that work is
  visible. It cost 0.35 ms of GPU time at 4112x2658, which is the cheapest thing in this file.
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

## Caustics and god rays

Both are the same lamp seen through the same surface, and they are **complements rather than two
helpings of one thing**: a caustic is the part of the light still focused when it reaches the
ground, a shaft is the part scattered out of the column on the way down. So they want opposite
water, and that — not taste — is what decides which look gets which.

| | caustics | god rays | why |
|---|---|---|---|
| deep ocean | none | **strongest**, 0.50 | Twenty metres diffuses the surface's focus away long before it lands, and it is the only backdrop dark enough for a shaft to stand against. |
| shallow reef | **strongest**, 2.6 m / 0.45 | none | A few metres of sunlit water is exactly what focuses a net onto sand. It is also the brightest and smoothest backdrop, which is what defeated its shafts — see below. |
| aquarium | 2.8 m / 0.45 | none | A tank has a rippled surface and a bright lamp. It has no shafts because it has nothing for them to light: this is the look whose marine snow is nearly zero, because a maintained tank has a filter. |

### The caustics ride the key light

The pattern is an `SCNLight.gobo` on the look's own key, which is the cheapest correct place for
it — it then lands on the floor, on everything standing on the floor, and on the backs of the
fish, from one texture and at no measurable frame cost (GPU held at 4.4 ms at 3200x1800).

**Four facts about SceneKit's gobo had to be measured, and each contradicts the documentation or
the obvious guess.** They are cheap to re-verify and expensive to assume:

| | what you would assume | what it does |
|---|---|---|
| gobo on a `.directional` light | spot lights only, per Apple's docs | **works** — a flat lit plane went from sd 0.0000 to 0.1669 with no clipping |
| what a gobo does to the light budget | masks it | **multiplies the light by the tile's own mean** — a 50/50 checker took a plane from 0.4000 to exactly 0.2000 |
| how an 8-bit tile is decoded | raw, or as sRGB | **colour-managed by the image's own tag** — sRGB, generic 2.2 and device RGB all decode through 2.2; only a *linear* tag arrives as authored (implied gamma 1.01) |
| tile size in the world | undocumented | **2.05 × `orthographicScale`** metres, linear from 0.1 to 2.0 |

The second and third compound into a silent disaster. A tile normalised to mean 0.5 and tagged
sRGB is delivered at 0.22, so the key would lose more than half its output and drag every floor
measurement down with it — while looking merely like a look that needed retuning.
`Caustics.compensation(forMean:)` divides the mean back out, which is what lets a look go on
stating **the light it delivers** rather than the light it would deliver if the gobo were white.
Verified end to end with a real tile at 1.0002.

`LinearImage` is where the tag lives, and everything generated in this saver that carries a
*number* rather than a picture must go through it. Note that `NSImage.lockFocus` — what the rest
of the saver uses — produces a calibrated-space image that measured as gamma **1.8**, which is
neither of the two answers anyone would guess.

**The pattern is a refraction Jacobian, not a noise function.** Light crossing a wavy surface is
bent by the surface's slope, so a patch of surface maps to a patch of ground of a different size
and its brightness is the reciprocal of how much it stretched; where neighbouring rays cross, the
patch collapses and the brightness diverges. That fold *is* the filament, and it is the part cell
noise cannot fake, because nothing in cell noise is diverging. The surface is a sum of plane waves
with **integer** wave vectors, which makes the tile exactly periodic by construction rather than
by tuning — a seam would draw a hard grid across the whole floor — and the blur that softens it
wraps for the same reason. Supersampling is not optional: the folds are true singularities, so one
sample per texel makes the filaments come out beaded rather than continuous, and blurring
afterwards only blurs the beads.

Two tuning results worth keeping:

- **The reef takes a tighter, stronger net than the aquarium**, which is the opposite of what the
  two water surfaces suggest and is a fact about their *floors*. The aquarium's bed is gravel — a
  field of resolved stones with its own light and shade at exactly the scale a tight net lands on
  — and a first pass at 1.1 m cells vanished into it, the two patterns competing until the result
  read as noise. What carries the caustics in that look is the rock and coral standing in them.
  The reef's sand has no such problem.
- **Caustics reach the aquarium's cross-section band barely, and it required no work.** The
  question was whether to suppress them there deliberately; the geometry answered it. The band is
  a near-vertical face taking about 21% of the near-vertical key and dominated by the accent
  instead, so the net lands on the receding bed and stops at the band on its own.

### The shafts are additive quads, and the reef could not have them

Two properties of this saver make that cheap: **the camera never moves**, so a quad that faces it
once faces it forever and no billboard constraint is needed; and the shafts are genuinely parallel
in world space, so the perspective camera converges them without anything fanning them by hand.

**`SCNMaterial.multiply` is silently ignored once `blendMode` is `.add`.** With the multiply
colour scaled all the way to zero the shafts still drew at full strength — a failure that reads
exactly like a mis-tuned constant rather than like a property having no effect, and it cost a
whole tuning pass spent cutting a number that was doing nothing. Colour and brightness are baked
into the texture instead.

**A shaft's cross-section wants a Gaussian, not a raised cosine, and the swell must only ever
widen.** The first shafts read as "strips of plastic film" — the complaint that drove this rework
— and there were three causes, none of which was brightness alone. A raised cosine has a flat
shoulder and a corner where its slope changes, and the eye finds that corner and calls it an edge
even where the value there is already tiny; a Gaussian has no corner anywhere, so the shaft has no
edge to find. The colour was also weighted to the lamp, and additive pale blue-white pushes dark
blue water toward *white* — a region that changes hue as well as brightness reads as a different
substance laid over the sea rather than as more light within it, so the mix is now 0.72 to the
water. And a beam of constant width and brightness running the frame's whole height is an object
rather than a volume however softly it is drawn, so the section swells along its length.

**The swell may only widen.** Letting it narrow symmetrically was the obvious choice and it is
wrong in a way no still frame shows: a narrower Gaussian is a *steeper* one, so the thin part of
every shaft carried the hardest edge in the frame. Measured, the symmetric version came out with
sharper edges than the raised cosine it replaced while also being dimmer — which is precisely the
combination that reads as film.

**Beware the metric here.** A contrast reading taken across a row of open water is dominated by
the *vignette*, and after that is detrended it still carries a noise floor of about 0.0112 from
the marine snow. Both mislead in the same direction — they report a healthy number for a shaft
that has vanished. Rendering at `brightness: 0` measures the floor directly and it is worth doing
before trusting any reading: a sweep that appeared to show brightness having almost no effect was
actually showing three settings that had all fallen below the floor. Against a floor-corrected
amplitude, the shafts as first shipped measured 0.0145 and what replaced them measures 0.0076.

Two more that only a render shows. **Width was wrong by about three times at first** — wide shafts
do not read as light, they read as bands laid over the frame, because at that size the eye reads
the edge and not the beam; many narrow ones read as one shaft broken up by the surface. And **a
shaft must be spent before it reaches the ground**, or it reads as a hanging curtain: the fading
is the evidence that it is being scattered away.

**The shallow reef was meant to have both and has no shafts at all.** It was tried from 0.20 down
to 0.055 and the failure never changed character, only intensity — which is the tell that
brightness was never the problem. An additive band on a backdrop that is both the brightest of the
three *and* the smoothest shows its own edge however softly that edge is drawn, so the shafts read
as hard diagonal stripes ruled across the reef at every setting bright enough to see at all. Which
is the same fact that gives that look the strongest caustics, read the other way round.

### What both did to the measurements

| | before | after | why |
|---|---|---|---|
| shallow reef | 0.77 | **0.68** | caustics |
| deep ocean | 0.78 | **0.59** | god rays |
| aquarium, river | 0.81 | **0.78** | caustics |
| aquarium, quartz | 0.96 | **0.92** | caustics |

**Caustics lower the reported ratio without changing the light budget at all**, and the reason is
worth knowing before anyone reads it as a regression: the compensation preserves the *mean*, and
this tool reports a **median**. A caustic is a strongly skewed distribution — thin bright filaments
over wide dark gaps — so the median sits in the gaps. God rays lower it for a different and more
straightforward reason: they brighten the water the floor is measured *against*, not the floor,
which is the right direction for the rule the measurement exists to enforce.

**A prediction recorded here previously turned out to be wrong: the god rays did *not* give the
bloom anything to bite.** The deep ocean's brightest pixel is unchanged at Y 0.264 against its own
0.95 threshold. In fact bloom is currently a no-op in two looks and nearly one in the third —
shallow reef peaks at 0.800 against a 0.88 threshold and never crosses it at all; the aquarium
clears its 0.90 on 0.0012% of the frame. The thresholds are set above what these looks can
produce, so anyone who wants bloom to do something must lower a threshold rather than wait for a
brighter feature.

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
