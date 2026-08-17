"""A fish moving water — which is a burst of bubbles, not a whoosh.

**Two attempts at this were wrong in the same way and the user named it both times.** The
first put a band of noise through a moving filter, which is how Foley whooshes are made,
and the verdict was that it sounded "like somebody swishing something in the air". Lowering
the band by two octaves did not help: "still sound like open air movement, something like a
fan in the air."

The correction came with three reference recordings, and their filenames are the whole
answer — *underwater movement bubble motion*. What the user was after, in their words:

> "What one hears is less the swishing of the fish and more movement of water, which sounds
> a bit like bubbles."

A swept band of noise cannot ever be that, at any centre frequency, because the thing being
described is **granular**. Measured on those references: energy is broadband from 20 Hz to
about 1.3 kHz and then falls off a cliff — 25 dB down by 2 kHz and 50 dB down by 4 kHz —
and the spectrogram is a dense field of short blobs and gliding streaks rather than a smooth
wash. Those streaks are individual bubbles.

So a fish's movement is synthesised the same way the bed is: **entrained air**. Something
moving through water drags bubbles off itself and out of the boundary layer, and what a
listener hears is that cloud being made and released. This module is therefore a scheduler
over `bubble.ping` plus the collective term from `plume.py`, and it shares both with the
aerator — which is right, because it is the same physics.

**The gesture stays a pure time-scale**, which is what keeps the library small: radii scale
with the animal, arrival rate scales inversely, duration scales with it, and the collective
frequency scales inversely. Every one of those is what resampling does, so one baked
reference fish still covers every fish in the library exactly.
"""

from __future__ import annotations

import numpy as np

from . import bubble, dsp, plume

#: Median bubble radius a one-metre animal entrains, in millimetres.
#:
#: Stated per metre because the whole gesture is a pure time-scale; what it is fitted to is
#: the *baked* grain at 20 cm, where it works out to 3.4 mm and rings at 960 Hz. That puts the
#: distribution around it between 300 Hz and 1.3 kHz, which is where the reference recordings
#: put theirs — they fall off a cliff above that.
METRE_FISH_RADIUS = 7.6

#: Spread of that distribution, log-normal. Wide, because a boundary layer does not sort
#: bubbles by size and a narrow distribution reads as a tuned chord rather than as water.
RADIUS_SIGMA = 0.55

#: Bubbles a second at the peak of a one-metre animal's stroke.
#:
#: High on purpose. This is the number that separates "movement of water" from "a few
#: bubbles": below about eighty a second the ear counts individual events and the gesture
#: falls apart into ticks. Scaled inversely with body length.
METRE_FISH_RATE = 115.0

#: The collective mode of the cloud a moving animal drags with it, for a one-metre body.
#:
#: Far below the aerator's plume, and the references are why: they carry heavy energy at
#: 20-80 Hz, 15-20 dB more than the tank bed does. A cloud shed off a body is larger and
#: looser than the column above a stone, and a bigger cloud resonates lower.
METRE_FISH_CLOUD = 27.0

#: Where the gesture stops. The references fall 25 dB by 2 kHz and 50 dB by 4 kHz — a cliff,
#: not the gentle tilt that `water.underwater` applies to everything else. Bubbles this size
#: ring above it and would otherwise put a fizz on top that reads as spray in air.
CUTOFF = 780.0


def stroke(body_length_m: float, sample_rate: int, rng: np.random.Generator,
           effort: float = 1.0) -> np.ndarray:
    """One movement, dry and mono: a cloud of entrained air made and released.

    `effort` is speed over cruise speed — the same quantity the swim shader uses to drive
    tail-beat rate. It raises the arrival rate and shortens the gesture together, because a
    fish moving harder entrains more air in less time.
    """
    scale = np.sqrt(max(body_length_m, 0.02))
    duration = float(np.clip(0.42 * scale / max(effort, 0.3) ** 0.5, 0.12, 1.1))
    count = int(duration * sample_rate)
    if count < 16:
        return np.zeros(16)

    position = np.linspace(0.0, 1.0, count)
    # Entrainment builds fast and lets go slowly. A symmetric envelope reads as a machine
    # cycling; water is grabbed and then released.
    envelope = np.where(position < 0.22,
                        0.5 * (1 - np.cos(np.pi * position / 0.22)),
                        np.exp(-3.0 * (position - 0.22)))

    peak_rate = METRE_FISH_RATE / scale * np.clip(effort, 0.3, 2.6) ** 0.6
    median_radius = METRE_FISH_RADIUS * scale

    out = np.zeros(count)
    excitation = np.zeros(count)

    # Arrivals, thinned by the envelope. Drawing from the peak rate and rejecting against
    # the envelope gives a proper inhomogeneous Poisson process rather than a train with a
    # volume knob on it, and the difference is audible: the latter has a constant *rhythm*
    # under it whatever its level.
    when = 0.0
    while True:
        when += float(rng.exponential(1.0 / peak_rate))
        index = int(when * sample_rate)
        if index >= count:
            break
        if rng.random() > envelope[index]:
            continue

        radius = float(np.clip(median_radius * np.exp(rng.normal(0.0, RADIUS_SIGMA)),
                               0.35, 9.0))
        # No cloud term per bubble: the collective is driven once, below, from the whole
        # arrival process. Adding it here as well would count the same physics twice and —
        # measured on the bed, where it was done that way — a fixed-frequency resonator
        # struck this often stops being a texture and becomes a note.
        grain = bubble.ping(radius, sample_rate, rng, cloud=0.0)
        end = min(index + grain.size, count)
        out[index:end] += grain[:end - index]
        excitation[index] += radius ** 3

    # The collective modes of the cloud, struck by the arrivals. This is the body of the
    # gesture and most of what a listener actually registers as *water moving*; the
    # individual pings above it are the texture that says it is water and not wind.
    #
    # **Several modes, not one.** A cloud shed off a moving body is not a single sphere of
    # gas — it is a ragged, stretched, breaking-up volume, and such a thing has a spread of
    # collective modes rather than a frequency. Using one left a measured 11 dB hole at
    # 160-320 Hz, right between the single mode and the bottom of the ping distribution,
    # and it also risks the failure the bed already had: one frequency struck repeatedly is
    # a note. Four of them, spread over two and a half octaves and damped more heavily the
    # higher they sit, fill the band the way the references do.
    body = np.zeros(count)
    base = METRE_FISH_CLOUD / scale
    for index, (ratio, q) in enumerate(((1.0, 1.6), (1.9, 1.4), (3.4, 1.1), (5.8, 0.9))):
        mode = plume.cloud_response(int(0.30 * sample_rate), sample_rate,
                                    frequency=base * ratio, q=q, spread=0.3, rng=rng)
        body += np.convolve(excitation, mode)[:count] * (0.85 ** index)
    if np.max(np.abs(body)) > 0:
        body = dsp.normalise(body, 1.0) * 0.9

    mixed = dsp.normalise(out, 1.0) + body
    # The cliff. Everything else in this library is tilted rather than cut, but the
    # references really do fall away hard here, and the fizz above it is what read as spray.
    mixed = dsp.lowpass(mixed, sample_rate, CUTOFF / scale, order=2)
    return dsp.fade(mixed, sample_rate, attack=0.004, release=0.04)


def flurry(body_length_m: float, beats: int, sample_rate: int,
           rng: np.random.Generator, effort: float = 2.4) -> np.ndarray:
    """Several movements in succession — what a dart actually is.

    A dart in `FishDecision` is 0.35 to 0.8 seconds at 2.4 to 3.2 times cruise speed, and
    what the fish does in that time is beat its tail several times, hard, accelerating.
    Successive strokes come faster and shed less, because the fish has the speed it wanted
    by the second one and is riding it.
    """
    strokes = [stroke(body_length_m, sample_rate, rng, effort=effort * (0.74 ** index))
               for index in range(max(beats, 1))]

    interval = 0.26 * np.sqrt(max(body_length_m, 0.02))
    offsets = np.cumsum([0.0] + [interval * (0.84 ** index)
                                 for index in range(len(strokes) - 1)])
    length = max(int(offset * sample_rate) + s.size for offset, s in zip(offsets, strokes))

    out = np.zeros(length)
    for offset, s in zip(offsets, strokes):
        start = int(offset * sample_rate)
        out[start:start + s.size] += s
    return out
