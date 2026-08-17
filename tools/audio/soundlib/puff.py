"""An aerator letting go — the slug of gas a chest releases when its lid opens.

The bed already follows the props: `Bubbler` reports the declared birth rate of whichever
emitters are alive, and the bed's density is derived from it. But a density change is not an
*event*, and the user's verdict on the first build with sound says exactly what that costs:

> "Right now I hear a fairly steady bubble bed... what would be interesting is to tie a
> burst of bubbles to when one of the bubblers activates and releases its set of bubbles,
> like when the chest opens and bubbles come out — something audible to the visual."

So this is the aerator's equivalent of `swish.py`: one gesture, baked, fired at the moment
the picture shows it happening. Same physics as everything else here — arrivals of entrained
air kicking a collective mode — and it shares both primitives with the fish and the bed,
which is the point rather than a saving.

**How it differs from a fish, and why.** A fish drags a loose cloud out of its boundary
layer; a chest releases gas that has been *trapped*, so:

- The arrivals do not build. A lid opening is a release, not an entrainment, so the envelope
  starts at its peak on the first sample and decays. `swish.stroke` ramps over its first 22%
  because a fish has to get moving first; a puff has nothing to overcome.
- The radii are coarser. Trapped gas tears into big bubbles as it breaks the surface of the
  slug, where a boundary layer sheds fine ones — median 2.4 mm against the fish's 3.4 mm at
  the baked size but with a much longer upper tail, which is what supplies the blorps.
- **No cliff.** `swish.py` cuts hard at 780 Hz because its references do and the fizz above
  read as spray in air. A puff is bubbles rising in water, exactly like the bed, so it keeps
  the bed's tilt and its fine top — cutting it would make a chest sound like a fish.
- The collective is the aerator's, `plume.CLOUD_FREQUENCY`, not the fish's much lower cloud.
  It is the same column of gas the bed's own plume term describes, so a puff sits in the
  bed's register and reads as *more of what is already there* rather than as a new instrument.

Like every other gesture in this library it is a pure time-scale, so one baked puff covers
every emitter: a bigger release is a slower playback rate, which lowers the radii, lowers the
collective, spreads the arrivals and lengthens the gesture, all by the correct amounts.
"""

from __future__ import annotations

import numpy as np

from . import bubble, dsp, plume

#: Median radius of the bubbles a release breaks into, in millimetres, at the baked size.
#:
#: Coarser than the bed's 1.2 mm median: the bed is a stone ticking out bubbles one at a
#: time through a fixed pore, and this is a slug tearing itself apart, which has no such
#: sorting. 2.4 mm rings at 1.4 kHz.
MEDIAN_RADIUS = 2.4

#: Spread, log-normal. Wider than the bed's 0.62 for the same reason the median is higher —
#: nothing sizes these, so the distribution is whatever the tearing produces.
RADIUS_SIGMA = 0.70

#: Clamps, in millimetres. The upper one is deliberately past the bed's 5.6: the big slow
#: blorp at the start of a release is the single most recognisable thing about it, and the
#: bed never produces one that large.
RADIUS_MIN = 0.5
RADIUS_MAX = 11.0

#: Bubbles a second at the instant of release.
#:
#: Below about sixty a second the ear counts them and a release reads as a handful of
#: separate plops rather than as gas escaping; well above it the individual blorps stop
#: being distinguishable and it becomes the bed again, louder. This sits where both are
#: audible at once, which is what a chest opening actually sounds like.
PEAK_RATE = 95.0

#: Seconds, at the baked size. How long the gas takes to finish coming out.
DURATION = 1.35

#: How fast the arrivals thin out over that time. Exponential, and steep enough that the
#: second half is a scatter of stragglers rather than a tail of even density — a release
#: that stops evenly sounds like a fade rather than like something emptying.
DECAY = 3.4


def release(sample_rate: int, rng: np.random.Generator, size: float = 1.0) -> np.ndarray:
    """One aerator release, dry and mono.

    `size` scales the whole gesture as a pure time-scale would, so that the baked variants
    can differ in more than a noise seed without any of them being a different synthesis.
    """
    scale = float(np.clip(size, 0.4, 2.5))
    count = int(DURATION * scale * sample_rate)
    if count < 16:
        return np.zeros(16)

    position = np.linspace(0.0, 1.0, count)
    # Peak on the first sample: a lid opening releases what was already there.
    envelope = np.exp(-DECAY * position)

    peak_rate = PEAK_RATE / scale
    median = MEDIAN_RADIUS * scale

    out = np.zeros(count)
    excitation = np.zeros(count)

    # An inhomogeneous Poisson process, thinned against the envelope, exactly as the fish
    # gesture does it and for the same reason: drawing at the mean rate and scaling the
    # amplitude instead leaves a constant rhythm underneath at every level.
    when = 0.0
    while True:
        when += float(rng.exponential(1.0 / peak_rate))
        index = int(when * sample_rate)
        if index >= count:
            break
        if rng.random() > envelope[index]:
            continue

        radius = float(np.clip(median * np.exp(rng.normal(0.0, RADIUS_SIGMA)),
                               RADIUS_MIN, RADIUS_MAX))
        # No per-bubble cloud term. The collective is driven once, below, from the whole
        # arrival process — counting it twice is the mistake that turned the bed's resonator
        # into a note.
        grain = bubble.ping(radius, sample_rate, rng, cloud=0.0)
        end = min(index + grain.size, count)
        out[index:end] += grain[:end - index]
        # Volume, because what kicks a collective mode is how much gas arrived.
        excitation[index] += radius ** 3

    # The plume's collective mode, struck by the arrivals — the same term and the same
    # frequency the bed uses, which is what makes a puff read as the tank rather than as
    # something layered over it. Three modes rather than the fish's four: the column above
    # an emitter is a more coherent body than a cloud shed off a moving animal, so its
    # spread of modes is narrower.
    body = np.zeros(count)
    base = plume.CLOUD_FREQUENCY / scale
    for index, (ratio, q) in enumerate(((1.0, 6.0), (1.7, 4.0), (2.9, 2.6))):
        mode = plume.cloud_response(int(0.30 * sample_rate), sample_rate,
                                    frequency=base * ratio, q=q, spread=0.35, rng=rng)
        body += np.convolve(excitation, mode)[:count] * (0.8 ** index)
    if np.max(np.abs(body)) > 0:
        body = dsp.normalise(body, 1.0) * 0.75

    mixed = dsp.normalise(out, 1.0) + body
    # Deliberately no low-pass. See the module docstring: the cliff belongs to the fish.
    return dsp.fade(mixed, sample_rate, attack=0.002, release=0.08)
