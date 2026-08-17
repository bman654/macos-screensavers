"""The sound of a column of bubbles, which is not the sound of the bubbles in it.

**This file exists because the first pass at the aquarium's audio did not have it, and that
was the whole reason it sounded wrong.** That pass modelled individual bubbles correctly —
a Minnaert resonator ringing at 3.26/r — mixed them, and produced something the user
described as "bubbles popping on the surface, heard from above the tank". Measuring a real
aquarium recording says why in one number: **its energy peaks at 160-320 Hz**, and a bubble
ringing at 240 Hz would be fourteen millimetres across. Whatever a hydrophone in a tank is
mostly hearing, it is not the bubbles ringing individually.

**What it is hearing is the cloud.** A bubbly liquid is a wildly different medium from
water: the gas supplies compressibility and the water supplies inertia, so the speed of
sound in a bubbly mixture collapses — a void fraction of even a percent takes it from
1480 m/s to a few tens of metres per second. A plume of radius R therefore has a collective
resonance of order c_mix / 4R, which for a stream a few centimetres across lands in the low
hundreds of hertz. Every bubble that arrives kicks that collective mode, and the mode is
what carries. That is the low gurgling body of the sound, and it is *independent of the
size of the individual bubbles*, which is exactly why no amount of adjusting the radius
distribution could ever have produced it.

Three things follow, and they are the design:

- **The plume is the bed**, and individual pings are garnish riding on top of it. That is
  the reverse of the first pass's balance, and the reference bears it out: its mid-range is
  12 to 18 dB below its peak, which is exactly what the tilt alone predicts — meaning a real
  tank has almost no *distinct* pings up there.
- **The cloud's frequency is a property of the plume, not of the bubble**, so its term lives
  inside `bubble.ping` as each arrival's kick to the collective mode.
- **There is no continuous layer.** This module deliberately offers no "bed" function: the
  roar of a plume is not a texture that runs underneath the bubbles, it is what a stream of
  bubbles *sums to*. An earlier version had one and the user's verdict was "a steady
  background hum or bass bed... I don't know what that's supposed to represent". Nothing was
  the honest answer. A plume stops when the aerator stops; a pad does not.
"""

from __future__ import annotations

import numpy as np

from . import dsp

#: The collective resonance of an aerator's plume, in hertz.
#:
#: Placed to put the finished bed's peak in the 160-320 Hz band the reference recording
#: measures, which is the number this whole file is answering. Measured at this setting the
#: bed lands at a 323 Hz centroid against the reference's 259. It is not a fitted constant
#: so much as a stated one: c_mix / 4R for a plume a few centimetres across covers a wide
#: range, and where inside it a given tank sits is not something a script can know.
CLOUD_FREQUENCY = 250.0

#: How sharply the cloud rings. Low, and deliberately: a plume is a loose, leaky, constantly
#: reshaping body of gas, not a bell.
#:
#: It went 2.6 -> 1.15 -> 6.0, and the round trip is worth recording because the first move
#: was a misdiagnosis. The user's verdict on the 2.6 build was "a steady background hum, kind
#: of irritating", and the bed did measure a 233 Hz peak standing 3.3 dB above its own noise
#: floor — so the Q looked like the culprit and was lowered. It was not: the culprit was the
#: mode being a struck *sine*, which is tonal at any Q. Lowering the Q instead shortened the
#: ring-down to 1.5 ms, and a 1.5 ms burst is very nearly an impulse — broadband, including
#: 13 dB too much below 80 Hz, which is the "bass bed" half of the same complaint.
#:
#: With the mode noise-excited (see `cloud_response`) a high Q is safe and is what the
#: physics wants: an 8 gives a ring-down near 10 ms and puts the energy where it belongs.
#: Measured at this setting the bed's spectral flatness over 100-600 Hz is 0.85 against the
#: reference recording's own 0.20 — it is now *less* tonal than the real thing.
CLOUD_Q = 8.0

#: How far the mode wanders between strikes, as a log-normal spread on its frequency.
#:
#: A plume's size and void fraction change continuously as gas arrives and leaves, so its
#: collective frequency is never twice the same.
#:
#: It was 0.55, which was chosen when the mode was a struck sine and the spread was doing
#: double duty as the thing that stopped repeated strikes accumulating into a pitch. Noise
#: excitation does that job properly now, which buys back a *tighter* distribution — and
#: tighter is what the profile wants: at 0.55 enough strikes landed near 80 Hz to put 13 dB
#: too much energy below that, which is the "bass bed" half of the same complaint.
CLOUD_SPREAD = 0.33


def cloud_response(count: int, sample_rate: int, frequency: float = CLOUD_FREQUENCY,
                   q: float = CLOUD_Q, spread: float = CLOUD_SPREAD,
                   rng: np.random.Generator | None = None) -> np.ndarray:
    """The collective mode's ring-down, as an impulse response of `count` samples.

    **Noise-excited, not a struck sine, and that is the whole difference between water and a
    hum.** A decaying sinusoid is a bell: it has one frequency and a listener hears a pitch.
    Strike it a dozen times a second at the same frequency — which is exactly what a bubble
    bed does — and the pitch stops being incidental and becomes a note. Measured on the build
    that did it that way, the bed carried a peak standing 3 to 5 dB above its own noise
    floor, and the user's verdict was "a steady background hum... kind of irritating".

    Detuning it per strike helps and is not enough on its own, because a sine is tonal even
    when it wanders. A *band* of noise at the same centre with the same damping has the same
    spectral placement and no pitch at all, and it is also the more honest model: the
    collective mode of a plume is driven by a chaotic process and damped heavily, so what it
    radiates is much closer to filtered noise than to a ringing tone.

    `spread` detunes it as well, because a plume's size and void fraction change continuously
    as gas arrives and leaves, so its mode really does wander.
    """
    time = np.arange(count) / sample_rate
    centre = frequency
    if spread and rng is not None:
        centre *= float(np.exp(rng.normal(0.0, spread)))
    centre = float(np.clip(centre, 12.0, sample_rate * 0.3))

    source = rng if rng is not None else np.random.default_rng(0)
    noise = source.standard_normal(count)
    width = max(centre / max(q, 0.2), 12.0)
    band = dsp.bandpass(noise, sample_rate,
                        max(centre - width * 0.5, 8.0),
                        min(centre + width * 0.5, sample_rate * 0.45), order=2)

    decay = np.exp(-np.pi * centre * time / q)
    out = band * decay
    return dsp.normalise(out, 1.0)
