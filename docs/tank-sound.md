# The tank's voice

What the aquarium sounds like, why it sounds like that, and how to change it. The audio
equivalent of `docs/water-looks.md`: the code carries the *what*, this carries the argument.

Read `spikes/006-saver-audio/README.md` first if you are touching the plumbing. It is mostly
a list of things that look like they work and do not, and none of it is re-derived here.

**Signed off by the user** on the third pass: *"the aq-4-tank sample now sounds pretty
realistic. The bubbles are nice and I can hear the occasional swish sound of fish moving
around."* The two passes before it were both rejected, and what they got wrong is recorded
below rather than deleted — each was a plausible piece of reasoning that measurement refuted.

## The brief, and the one instruction that shaped everything

> "You probably want to make these sounds sound like they're travelling underwater, because
> that's where the sounds, the bubbles and stuff, are emanating. Don't give me sounds as they
> would sound in the air."

That is a stronger constraint than it looks, because the honest physics points the other way.

## The first pass got this wrong, and here is exactly how

Judged by the user on the built saver: *"All the sound grains sound like they're in air, open
air. The bubbles sound like if I were standing over the aquarium hearing the bubbles pop on the
surface. The fish swish sounds like somebody swishing something in the air."*

That verdict is worth keeping because the reasoning behind the first pass was not obviously
silly — it was just untested against anything real. It went: a submerged listener's ear canal is
flooded, bone conduction is a low-pass, therefore low-pass everything. So it low-passed at
1.8 kHz and called it water.

Then the user supplied a reference recording of a real aquarium and it took one measurement to
see the mistake. `tools/audio-match.py` carries the profile and the tool; the numbers are:

```
            20    40    80   160   320   640  1280  2560  5120     centroid
reference  -30   -26    -9    -1   -12   -16   -24   -29   -37       259 Hz
first pass -43   -36   -32   -30    -9    -1    -9   -23   -54      1093 Hz
```

Three things, in descending order of how badly they mattered:

1. **It was two octaves too high.** The reference peaks at **160–320 Hz**. Nothing an aerator
   makes rings there — a bubble at 240 Hz would be fourteen millimetres across.
2. **Cutting the top does not sink a sound, it shrinks it.** Relative to its own total the
   reference has ~17 dB *more* energy above 5 kHz than the low-passed version did. A narrow
   midrange hump with a cliff either side is what a small speaker sounds like, which is why the
   old one read as a thing in a room rather than a thing in water. The real shape is a **6 dB
   per octave tilt held for five octaves** — no corner anywhere.
3. **The low end of the reference is mostly its music.** Worth stating because it is a trap: the
   track has a background score, and chasing its bass would have been chasing a bass drum. The
   30–320 Hz percussive envelope there autocorrelates at 0.60 on a 0.33 s lag, which is a tempo.
   The profile in `audio-match.py` is taken from the opening seconds, before the music enters —
   the user pointed at that window.

**A measurement subtlety that bit once and would bite again.** Band energy and spectrum slope
are not the same number: integrating a `f^-a` spectrum over an octave gives band energy going as
`f^(1-a)`, so brown noise — famously -6 dB/octave — falls only **-3 dB/octave in band terms**.
The reference's -6 dB/octave *band* slope therefore wants a **-9 dB/octave spectrum**, and the
first attempt at the turbulence layer used plain brown noise and came out 17 dB too bright at
10 kHz.

## What a hydrophone in a tank is actually hearing

Not the bubbles. **The cloud.**

A bubbly liquid is a completely different medium from water: the gas supplies compressibility
while the water supplies inertia, so the speed of sound collapses — a void fraction of even one
percent takes it from 1480 m/s to a few tens of metres per second. A plume of radius R therefore
has a **collective resonance** of order `c_mix / 4R`, which for a stream a few centimetres
across lands in the low hundreds of hertz. Every bubble that arrives kicks that mode, and the
mode is what carries.

This is the whole reason the first pass could not have been fixed by tuning. The peak it was
missing is not at any bubble's frequency, so no adjustment of the radius distribution could ever
have produced it. `soundlib/plume.py` is that oscillator; `bubble.ping` gained a `cloud` term
scaled by the bubble's **volume**, because what kicks the collective mode is how much gas
arrived.

So the balance inverted: **the plume is the bed, and the individual pings are garnish on it.**

## Water does not muffle anything over a metre

Worth keeping, because it is true and it is why the naive model fails.

Absorption in fresh water is about 2 × 10⁻¹⁴ dB per metre per hertz squared. Over the metre of a
tank, a 10 kHz component loses two *millionths* of a decibel. The water is not attenuating
anything. What produces the effect are:

1. **A flooded ear canal** — bone conduction, which is the tilt in `underwater`, measured rather
   than assumed.
2. **Direction collapsing** — at 1480 m/s the interaural delay across a head is about 40 µs and
   the head casts almost no shadow, so sound is *around* you rather than *over there*. Hence a
   narrow pan (±0.40) and a decorrelated stereo space baked into every grain. **A hard pan is an
   air cue and it undoes all of this instantly.**
3. **Sub-millisecond reflections**, which thicken every attack.

## Sounds are code, the same way models are

A bubble entering water rings as a **Minnaert resonator**: the gas is the spring, the water
moving around it is the mass, and the frequency follows from the radius alone.

```
f0 = (1 / 2πr) √(3γP₀/ρ)   →   f0·r = 3.26 m·Hz
```

A 1 mm bubble rings at 3.3 kHz, a 3 mm bubble at 1.1 kHz, a 6 mm bubble at 540 Hz. So an
airstone's *radius distribution is its frequency distribution*, and authoring a bubble bed
means authoring a histogram and an arrival rate — the same kind of numbers as the ones in
`Savers/Aquarium/Models/`. Nothing here is a sample library, and no binary is a source of
truth.

### The result that made the library small

Radiation damping is `δ = 2πf0·r/c`, and since `f0·r` is constant, **δ is the same for every
bubble size** — 0.0138. Ring-down time is therefore exactly inversely proportional to
frequency, which is precisely what resampling does to a recording. **Playing a baked 1.5 mm
bubble 20% fast *is* a 1.25 mm bubble**, not an approximation of one.

The same falls out for a fish's movement, by construction: the radii it entrains scale with
√length, its arrival rate inversely, its duration with it, and its cloud modes inversely — and
every one of those is what resampling does. One reference fish covers every fish in the
library exactly.

So the shipped library is **five radii, two trains and two gestures — 25 files, ~1.9 MB** —
and the runtime's rate knob fills in the continuum. What extra baked radii buy is not
coverage but *tail fidelity*: the tank's response is baked in and a resample stretches that
too, so the ratio is kept inside ±33%.

## A fish moving water is a burst of bubbles, not a whoosh

Two attempts at this were wrong the same way, and the user named it both times. The first put
noise through a moving band-pass — how Foley whooshes are made — and read as "somebody
swishing something in the air". Dropping the band two octaves did not help: *"still sound
like open air movement, something like a fan in the air."*

The correction arrived as three reference recordings whose filenames were the whole answer:
**underwater movement bubble motion**. In the user's words:

> "What one hears is less the swishing of the fish and more movement of water, which sounds a
> bit like bubbles."

**A swept band of noise can never be that at any centre frequency, because the thing being
described is granular.** So `swish.py` is not a filter any more — it is a scheduler over
`bubble.ping`, exactly like the bed. Something moving through water drags bubbles out of its
boundary layer, and what a listener hears is that cloud being made and released.

An inhomogeneous Poisson burst of entrained bubbles over the gesture, driving a ladder of four
collective cloud modes, then a hard cliff. Three things the references settled that would
otherwise have been guessed wrong:

- **They carry their heaviest energy at 20–80 Hz** — 15 to 20 dB more than the tank bed — so a
  fish needs its own high-pass floor at 28 Hz. The bed's 130 Hz floor was cutting off exactly
  the part that says *something big moved through water*, and measured 22 dB short down there.
- **A cliff, not a tilt.** 25 dB down by 2 kHz and 50 dB by 4 kHz. Everything else in this
  library is tilted; this one is cut, and the fizz above the cut was what read as spray.
- **One cloud frequency is not enough.** A cloud shed off a moving body is ragged and breaking
  up, and using a single mode left an 11 dB hole at 160–320 Hz between it and the bottom of the
  ping distribution. Four modes over two and a half octaves fill it.

`tools/audio-match.py --target dart` scores against those samples.

The gesture is still a **pure time-scale**, which is what keeps the library at one baked fish:
radii scale with the animal, arrival rate inversely, duration with it, cloud frequency
inversely. Every one of those is what resampling does.

## Reverb is baked into every grain, and that is free

Convolution is linear and time-invariant, so a hundred grains each carrying the tank's
impulse response sum to exactly what one reverb fed by a hundred dry grains would produce.
Baking it costs nothing in fidelity, costs a quarter-second of tail per grain on disk, and
buys two things worth more: the saver needs no reverb unit on the audio thread, and **`afplay
grain.wav` is an honest preview of what a listener will hear.**

Linearity cuts both ways, which is why the tail is short (220 ms at the bottom, 50 ms at the
top): at forty bubbles a second, forty tails are summing.

The response is deliberately **not** the physically exact answer. A rectangular metre of water
is a resonator whose lowest axial mode sits at 740 Hz with wide, sparse modes above it, and
rendering that honestly produces a tin can. What reads as a body of water is dense early
diffusion with a short dark tail, so that is what is built.

## Measured mistakes, all of which made something sound wrong

Each is commented where it happens. They are here because all three were invisible in the
parameters and obvious in a measurement.

- **Levelling reverb bands by RMS makes a bass-heavy room.** A 240 Hz-wide band levelled to
  the same total power as a 7.2 kHz-wide one has thirty times the density per hertz. The
  response then carried its strongest octave at 160–320 Hz, and every grain convolved with it
  acquired a low thump on its onset: the 0.9 mm bubble, which rings at 3.6 kHz, arrived with
  its spectral peak at **175 Hz**. Level bands by spectral *density* — weight × √bandwidth.
- **A random starting phase on a decaying sine is a step, and a step is broadband to DC.**
  Same symptom, separate cause, found in the same measurement. Half a period of raised-cosine
  attack fixes it, and the excitation is not instantaneous in the animal either.
- **Band energy is not spectrum slope.** Integrating an `f^-a` spectrum over an octave gives
  band energy going as `f^(1-a)`, so brown noise at a famous -6 dB/octave falls only -3
  dB/octave in band terms. Using it directly for the turbulence layer landed 17 dB too bright
  at 10 kHz. Whatever a profile is measured in, the synthesis has to be reasoned about in the
  same units.
- **A state-variable band-pass fed brown noise runs flat down to DC.** An SVF's band output
  has 6 dB/octave skirts and brown noise falls at 6 dB/octave, so the two cancel exactly. This
  bit twice: once in the swish, which measured its strongest peak at 93 Hz — a subwoofer thump,
  inaudible on the laptop speaker most of these will play through — and once in the saver's
  synthesised water floor, where it put **nineteen decibels** too much energy below 80 Hz and
  dragged the spectral centroid to 188 Hz against the preview's 671.

## The loop

The authoring loop is the one this repo already has, with the render step swapped. **The user
is the ear, exactly as they are the eye for the tank.** `audio-lens` reports RMS, peak,
clipping and centroid and draws a spectrogram, which is how an agent checks a sound without
hearing it — and it is a lens, not a verdict.

```bash
.venv/bin/python tools/build-audio.py                    # bake, ~10 s
.venv/bin/python tools/audio-preview.py --grains         # the library, once each
.venv/bin/python tools/audio-preview.py --seconds 90     # a tank
afplay /tmp/aquarium.wav
```

`tools/audio-preview.py` reads the **shipped manifest**, which is what the saver reads too, so
a preview that sounds right is a saver that sounds right. It stands in for the two things it
cannot know — which aerators a launch drew, and what the fish are doing — with the same
statistics. `--emitters 24c,55` names the declared particle rates in the tank; `c` means
continuous.

The ground truth is the saver itself:

```bash
AQUARIUM_SOUND=1 AQUARIUM_AUDIO_STATS=20 AQUARIUM_AUDIO_RECORD=/tmp/tank.wav \
    tools/run-saver.swift Aquarium --size 1200x700 --seconds 95 --screenshot /tmp/t.png
```

The recording is written as 16-bit PCM rather than the mixer's own float format on purpose:
`format.settings` produces 32-bit float in a `WAVE_FORMAT_EXTENSIBLE` container, which
`afplay` handles and every inspection tool in this loop refuses. **A recording nothing can
measure is not a diagnostic.**

One voice per process is verified the way the spike verified it — `--instances 3` puts three
views in one host, and the readout says `owner mine / engine running` for exactly one of them
and `owner other / engine off` for the other two. Ownership can also be *taken* now, but only
from a stalled owner: it carries a heartbeat on the machine's clock, and a view that has not
drawn a frame for 0.75 s is not eligible to hold it. That matters because a window ordered out
stops rendering and is told nothing, and the view is immortal — without it, one abandoned view
would silence a healthy one for the life of the host.

Comparing the two by octave band is what caught the water floor above:

```
             20    80   160   320   640  1280  2560  5120       rms
saver      -27.5 -25.1 -22.6  -8.7  -2.3  -5.9 -20.5 -49.1    -36.6
preview    -22.9 -21.9 -20.0 -12.5  -1.5  -6.9 -21.7 -50.7    -34.2
```

## Where the numbers live

| | |
|---|---|
| `tools/audio/soundlib/` | primitives any saver's sound would use |
| `Savers/Aquarium/Sounds/library.py` | which grains to bake |
| `Savers/Aquarium/Sounds/soundscape.py` | **every number that shapes the mix** |
| `Savers/Aquarium/Assets/audio/` | build output, untracked |
| `SoundVoices.swift` | the render thread — voices, scheduler, water floor, gate |
| `SoundSession.swift` | whether the screen is being saved, **and whether this view is showing it** |
| `AquariumSound.swift` | engine lifecycle, ownership, the scene's API |

## It follows the tank, not a clock

Two things drive it, and both are already on screen:

- **The bed's density is the declared birth rate of whichever emitters are emitting**, scaled
  by `RATE_SCALE` and capped by `MAX_RATE`. A launch with a thermal vent bubbles continuously;
  one with only a treasure chest is quiet between its puffs; one with neither gets the ambient
  trickle, which is not zero because a tank that falls silent for twenty seconds reads as
  broken rather than as calm.
- **A swish is a fish working**, and getting that to mean anything took three attempts.

  **Effort alone is useless here.** Of the seven behaviours in `FishDecision`, only `dart` asks
  for more than 1.15 times cruise speed, so *any* effort threshold in the usable range means
  "darts only" — and darts are deliberately rare, four entries in a hundred and fifty seconds
  across a whole school. Measured on the built saver: **two swishes in eighty seconds.** Nobody
  would notice the feature exists.

  **Yaw rate alone saturates.** A turn is the same physics — a fish comes round by pushing water
  sideways with its body — but the school steers constantly, so half of maximum yaw rate gave
  **fifty-three in ninety seconds with more than half refused** by the tank cooldown. When the
  refusals are comparable to the count, the cooldown is setting the rate and the fish are not.

  **Speed times yaw rate is the lateral acceleration**, which is what actually displaces water,
  and it is selective for free: a hovering fish pivoting on its pectorals comes round fast and
  moves nothing. Normalised by the fish's own scale — `TURN_SHARE` is a fraction of what that
  animal makes at cruise speed turning at its own limit — so a clownfish and a moray are judged
  the same way.

  It has a cliff in it, which is worth knowing before turning the knob: at cruise a fish cannot
  exceed 1.0 by definition, so anything above 1 asks for a fish that is *also* going faster than
  cruise.

  ```
  TURN_SHARE   swishes per 90 s (refused)     aquarium/42, ten fish
  0.90         30–35  (28–38)                 cooldown-bound
  1.05         26     (16)                    shipped
  1.30          2     (0)                     effectively darts only
  ```

  **1.05 errs toward audible on purpose**, because it has not been heard yet and a feature
  nobody notices cannot be judged. One every three and a half seconds may well be too much; the
  cliff means a small increase makes a large difference, so 1.10–1.15 is where to go next if it
  is.

  Both triggers are edge-triggered with a per-fish and a per-tank cooldown. The per-tank one is
  load-bearing: ten fish each entitled to a swish every few seconds is a shoal of whispers.

## The gate has two halves, and one of them was missing until it shipped

`AquariumSound.update(time:isPresenting:)` is audible only when the screensaver session is
running **and** this view's window is the one the screensaver is being drawn into. The second
half was added after the first build reached a real machine, and both of the failures it fixes
were observed rather than reasoned about:

- a view left over from a *previous* activation — still animating at 60 fps ten minutes later —
  claimed the sound half a second before the session's real view was constructed, and then held
  it for the whole session, so the tank on screen was silent while something else played;
- a screensaver dismissed inside its first second left the sound fading up onto the desktop of a
  user who was working, because `willstop` is posted before the host exists to hear it, exactly
  as `didstart` is.

The argument, the measurements and the three refuted theories are in
`spikes/006-saver-audio/README.md` §"Phase 0 was not enough". Two things to carry into any
future audio work here: **it is a property of the view, not an arbitration between views** —
one host holds several saver *bundles* at once and their owner `static`s cannot see each other
— and **it is re-read every frame**, because the level changes underneath a live view with no
callback of any kind.

To reach it from this repo's loop: `AQUARIUM_SOUND_SESSION=1` asserts the session half, since
under the harness the honest answer depends on whether System Settings happens to be open. The
level half needs no override — the harness window passes it, deliberately.

**And when the tank is silent on a real machine, `SoundLog` is the only instrument there is.**
The environment is empty inside `legacyScreenSaver`, so `AQUARIUM_AUDIO_STATS` cannot be reached
there, and "I heard nothing" otherwise has five causes that look identical from the front of the
screen — switched off, judged a thumbnail, no grain library, session gate shut, or not the
presenting view. It is off unless a sentinel file exists, so a shipped saver does no file I/O:

```bash
D=~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/tmp
touch "$D/aquarium-audio-debug" && killall legacyScreenSaver
# ... run the screensaver ...
cat "$D"/aquarium-sound-*.log
rm "$D/aquarium-audio-debug"      # and it is inert again
```

## Tying the audible to the visible

The first build with sound was judged working and *disconnected*:

> "Right now I hear a fairly steady bubble bed... what would be interesting is to keep the
> bubble bed that we currently have, but tie the swishes to the actual fish doing something
> like darting or changing direction, and tie a burst of bubbles to when one of the bubblers
> activates and releases its set of bubbles, like when the chest opens."

Both couplings already existed and neither was legible, for two different reasons. Fixing them
took one new gesture and one change to the fish, and the fish change is not an audio change at
all.

### The props: a density is not an event

`setEmission` derives the bed's arrival rate from whichever emitters are alive, so a chest
opening genuinely did raise the bed — by an amount nobody can hear as a *moment*. `puff.py` is
the onset: one baked gesture, fired on the frame a stream starts, panned and attenuated at the
prop's own position so it comes from where the bubbles can be seen leaving.

It is built from the same primitives as the bed and the fish — an inhomogeneous Poisson burst of
bubbles kicking the plume's collective mode — and differs in exactly three ways, each with a
reason:

- **It starts at full density and decays.** `swish.stroke` ramps over its first 22% because a
  fish has to get moving; a lid releases gas that was already there.
- **Coarser radii with a long upper tail**, past what the bed can produce (11 mm against 5.6).
  Trapped gas tears into big bubbles where a boundary layer sheds fine ones, and that first slow
  blorp is the single most recognisable thing about a release.
- **No cliff.** `swish.py` cuts hard at 780 Hz because its references do; a puff is bubbles
  rising in water exactly like the bed, so it keeps the bed's tilt. Cutting it would make a chest
  sound like a fish.

Size follows the picture with nothing authored per prop: the emitter's declared particle rate —
7 a second for a clamshell, 55 for a treasure chest — picks the baked release, so the chest gets
the big one. Measured at **one puff about every ten seconds** on a two-emitter tank, which is the
props' own 11–26 s idle showing through.

### The fish: the sound was right and the picture was invisible

The swish trigger was working exactly as designed and the design was the problem. It fired on
lateral acceleration, so most of what it caught was a hard turn during a cruise — and a hard turn
is not something a viewer can *see happen*. The user's verdict names it precisely:

> "Probably I have never seen a fish dart. The visual change in acceleration is too subtle to
> register, which leads to me not tying the visual to the audible swish."

Two changes, and the load-bearing one is to the tank rather than to the sound:

- **A dart is now visible.** It was 0.35–0.8 s at 2.4–3.2× cruise *holding its heading* — a fish
  that got slightly faster in a straight line for half a second, four times in a hundred and
  fifty seconds across ten fish. It is now 0.75–1.3 s at 2.6–3.6× and **turns 26° to 66°**, which
  is what a real C-start does and what the eye actually catches. The turn costs no animation:
  `School` banks a fish into its own yaw rate, so a heading change buys the visible roll for
  free. Weight 0.15 → 0.34 and the cooldown 8–22 s → 5–13 s.
- **The gesture is spent on darts only.** `noteSwish` still measures strain — it fires when the
  animal is moving fast rather than when it made up its mind, and `strength` still separates a
  hard bolt from a lazy one — but it is gated on `behavior == .dart`.

`TURN_SHARE` therefore no longer sets the rate; the dart weight and cooldown do. The old cliff
table in this file is kept below because it is a measurement, but it describes a trigger that no
longer fires outside a dart.

## Default off, and that is settled

Ambient sound only, toggleable, **defaulting to off**. A screensaver starts *because* the user
walked away, so unrequested sound plays to an empty room, or into a meeting they just walked
into, or at 2am. Opted-in ambience is charming; the same audio uninvited is why people
uninstall screensavers. Not to be relitigated.
