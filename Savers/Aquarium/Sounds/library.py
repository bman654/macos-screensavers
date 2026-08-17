"""What the aquarium's grain library contains, and why it is this short.

Species numbers live with the saver, exactly like `Savers/Aquarium/Models/species/*.py`.
This file is the audio equivalent of a manifest: it declares the grains to bake, and
`tools/build-audio.py` bakes them.

**Why there are so few grains.** Both synthesis models here happen to be pure time-scales,
which means resampling a baked grain produces a *physically correct* different one rather
than an approximation:

- A bubble's damping is dominated by radiation, and radiation damping is 2*pi*f0*r/c with
  f0*r constant — so it is the same for every size. Ring-down time is therefore exactly
  inversely proportional to frequency, which is what a resample does. Playing a 1.5 mm
  bubble 20% fast *is* a 1.25 mm bubble.
- A swish's band centre goes as 1/sqrt(length) and its duration as sqrt(length), so
  scaling time by k is the same as scaling body length by 1/k^2. One reference fish
  covers every fish.

So the library is a handful of radii and one reference fish, and the runtime's rate knob
fills in the continuum. What the extra baked radii buy is not coverage but *tail
fidelity*: the tank reverb is baked in and a resample stretches it too, so the rate is kept
inside roughly +/-33% and the baked radii are spaced to make that enough.

**Variants exist because randomness cannot be resampled away.** Two bubbles of the same
size differ in starting phase and in the exact shape of the pinch-off, and a bed built from
one grain per size has an audible periodicity to it however the rate is jittered.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class BubbleGrain:
    """One baked bubble. `radius_mm` is the whole sound; everything else follows."""
    radius_mm: float
    variants: int = 3
    #: Ratio of reflected to direct sound. Bubbles are a metre or so away in a tank the
    #: listener is inside, which is wetter than a source at the ear and drier than one
    #: across a room. Modest, because the tank's response is baked into every grain and
    #: reverb is linear: at forty bubbles a second, forty tails sum.
    wet: float = 0.24


@dataclass(frozen=True)
class BurstGrain:
    """A short train of bubbles, baked as one gesture.

    An airstone does not release bubbles independently — the neck that pinches one off is
    already forming the next, and trains a few milliseconds apart are heard as a single
    blorp. Baking them together is more faithful than asking a scheduler to place events
    four milliseconds apart, and much cheaper.
    """
    radii: list[float]
    spacing: list[float]
    variants: int = 2
    wet: float = 0.24


@dataclass(frozen=True)
class SwishGrain:
    """One baked tail gesture, at the reference body length."""
    name: str
    beats: int
    effort: float
    variants: int = 3
    #: Drier than a bubble. A fish that a listener can hear is a fish close by, and the
    #: direct-to-reflected ratio is how that is said.
    wet: float = 0.18


#: The body length every swish is baked at, in metres. A blue tang, near the middle of the
#: library's 0.07 m to 1.5 m span, so the largest rate shift either way is about 2.7x —
#: which is a lot of tail stretch, and is why `soundscape.py` clamps what the runtime asks
#: for rather than tracking body length literally.
REFERENCE_BODY_LENGTH = 0.20

#: Five radii, spaced by a factor of about 1.75. With the runtime allowed +/-33% of rate these
#: overlap, and together they span 0.68 mm (4.8 kHz) to 5.9 mm (550 Hz) — the whole range
#: an aerator in a tank this size actually produces.
BUBBLES: list[BubbleGrain] = [
    # The fine end, and it earns its place by measurement rather than by taste. The
    # reference recording carries real energy out to ten kilohertz — relative to its own
    # total, 18 dB more above 5 kHz than the first pass had — and nothing else in this
    # library reaches up there. A 0.45 mm bubble rings at 7.2 kHz.
    BubbleGrain(radius_mm=0.45),
    BubbleGrain(radius_mm=0.90),
    BubbleGrain(radius_mm=1.53),
    BubbleGrain(radius_mm=2.60),
    BubbleGrain(radius_mm=4.40, wet=0.21),
]

#: Trains. The first is the common one — a stone ticking out three near-identical small
#: bubbles. The second is what happens when a big one tears loose and drags smaller ones
#: with it, and it is the bed's punctuation: without something of this size the bed is a
#: texture rather than an event stream.
BURSTS: list[BurstGrain] = [
    BurstGrain(radii=[1.1, 0.95, 1.25], spacing=[0.021, 0.017]),
    BurstGrain(radii=[3.6, 1.4, 1.9, 1.15], spacing=[0.028, 0.019, 0.024]),
]

#: One stroke and one bolt. `dart` is baked at the effort `FishDecision` actually commits
#: for that behaviour — 2.4 to 3.2 times cruise speed — rather than at a round number.
SWISHES: list[SwishGrain] = [
    SwishGrain(name="swish", beats=1, effort=1.0),
    SwishGrain(name="dart", beats=3, effort=2.4),
]
