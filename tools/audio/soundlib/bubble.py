"""A bubble in water, from its radius.

A bubble is one of the very few everyday sounds that is genuinely *parametric*, which is
why the aquarium's audio can follow this repo's rule that assets are code rather than
committed binaries. A bubble entering water rings as a Minnaert resonator: the gas is the
spring, the water moving around it is the mass, and the pitch follows from the radius
alone.

    f0 = (1 / 2*pi*r) * sqrt(3 * gamma * P0 / rho)

With air at atmospheric pressure in fresh water that collapses to **f0 * r = 3.26 m*Hz** —
a 1 mm bubble rings at 3.3 kHz, a 3 mm bubble at 1.1 kHz, and a 6 mm bubble at 540 Hz.
So the "radius distribution" of an airstone is literally its frequency distribution, and
authoring a bubble bed means authoring a histogram of radii and an arrival rate. Those are
the same kind of numbers as the ones in `Savers/Aquarium/Models/`.

**The result that shapes the whole runtime.** Radiation damping is

    delta_rad = 2*pi*f0*r / c

and since f0*r is a constant, so is delta_rad — 0.0138, the same for every bubble size.
That means the ring-down time is inversely proportional to frequency, which is exactly
what happens to a recorded sound when you resample it. **Replaying a baked bubble at a
different rate therefore produces the correct bubble for the corresponding radius**, not
an approximation of one. Six baked radii plus a rate knob cover the whole continuum, which
is why the shipped library is a few hundred kilobytes rather than a few megabytes.
"""

from __future__ import annotations

import numpy as np

from . import dsp, plume

#: f0 * r for air in fresh water at 20 C and one atmosphere, in metre-hertz.
MINNAERT_CONSTANT = 3.26

#: Damping from the bubble radiating sound away, 2*pi*f0*r/c. Independent of radius.
RADIATION_DAMPING = 2 * np.pi * MINNAERT_CONSTANT / 1480.0

#: Time constant of the cloud term, expressed so the grain can be sized to hold it.
CLOUD_Q_DECAY = plume.CLOUD_Q / np.pi


def frequency(radius_mm: float) -> float:
    """The Minnaert frequency of a bubble of this radius, in hertz."""
    return MINNAERT_CONSTANT / (radius_mm * 1e-3)


def damping(radius_mm: float) -> float:
    """Total dimensionless damping: radiation plus thermal.

    Thermal damping — heat leaking between the compressing gas and the water — is the
    other half, and unlike radiation it does depend on size. The exponent here is fitted
    to the shape of the published curves rather than derived; what it has to get right is
    only the *direction*, which is that small bubbles ring shorter than large ones by more
    than their frequency alone accounts for. A bed with constant Q sounds mechanical
    because every size decays over the same number of cycles.
    """
    return RADIATION_DAMPING + 0.010 * (frequency(radius_mm) / 3260.0) ** 0.4


def ping(radius_mm: float, sample_rate: int, rng: np.random.Generator,
         chirp: float = 0.10, entrainment: float = 0.35,
         cloud: float = 1.0) -> np.ndarray:
    """One bubble, dry and mono. Peak level carries the size — do not normalise it.

    Four parts, in the order the ear notices them — and the *fourth* is the one that was
    missing from the first pass and the reason it sounded like air:

    - **The pinch-off transient.** A bubble does not fade in; a neck of water closes and
      the gas volume is released. That is a broadband click of a few hundred microseconds,
      and without it a bed is a set of tuned tones rather than a set of events. It is
      low-passed hard, because in water the click's own high end never survives to the
      listener — see `water.underwater`.
    - **The ring**, decaying at exp(-pi * delta * f0 * t).
    - **The chirp.** The bubble shrinks slightly as it rings and the frequency therefore
      *rises* — about 10% over one time constant. It is a small number and it is the
      single most identifiable thing about the sound: a bubble that holds a constant pitch
      reads as a marimba, and the direction matters, because a falling pitch reads as a
      drip instead.
    - **The kick it gives the cloud.** A bubble arriving into a plume does not only ring
      itself; it displaces gas into a body that is already there, and that body has a
      collective resonance of its own two to four octaves below — around 210 Hz — because a
      bubbly mixture carries the water's inertia on the gas's compressibility. See
      `plume.py`. This term does not depend on the bubble's own radius, and it is what
      actually carries: the reference aquarium recording peaks at 160-320 Hz, where nothing
      an aerator makes could possibly ring. Its absence is the whole reason the first pass
      sounded like bubbles bursting at the surface of a tank heard from above it.

      Scaled by *volume*, because what kicks the collective mode is how much gas arrived.
    """
    f0 = frequency(radius_mm)
    if f0 > sample_rate * 0.45:
        raise ValueError(f"radius {radius_mm} mm rings at {f0:.0f} Hz, above Nyquist")
    tau = 1.0 / (np.pi * damping(radius_mm) * f0)

    # Eight time constants is -70 dB for the ring, which is below the dither floor. The
    # grain also has to be long enough to hold the cloud term, which is far lower and
    # therefore decays far more slowly — truncating it would leave a step, and a step is a
    # click, and a click is the one thing this whole design is arranged to avoid.
    cloud_tau = CLOUD_Q_DECAY / plume.CLOUD_FREQUENCY
    span = max(8.0 * tau, 6.0 * cloud_tau)
    time = np.arange(int(span * sample_rate) + 1) / sample_rate
    envelope = np.exp(-time / tau)

    # Instantaneous frequency f0*(1 + chirp*t/tau), integrated for phase.
    phase = 2 * np.pi * f0 * (time + chirp * time * time / (2 * tau))
    # Half a period of raised-cosine attack on the ring, and it is not cosmetic.
    #
    # A random starting phase means sin() is generally non-zero at sample zero, which is a
    # step, and a step is broadband down to DC. Measured: it put the 0.9 mm bubble's
    # strongest spectral peak at 175 Hz — a tick that thumps. The excitation is not
    # instantaneous in the animal either; the neck takes a moment to close.
    ring = np.sin(phase + rng.uniform(0, 2 * np.pi)) * envelope
    ring = dsp.fade(ring, sample_rate, attack=0.5 / f0)

    transient = np.zeros_like(ring)
    burst = int(0.0006 * sample_rate)
    transient[:burst] = rng.standard_normal(burst) * dsp.raised_cosine(burst)[::-1]
    # Band-limited to the bubble's own register, not merely low-passed.
    #
    # The lower corner is the correction, and it was found by measuring: a low-passed click
    # is broadband down to DC, and the transfer then lifted its bottom, so the smallest
    # baked bubble's strongest spectral peak sat at 175 Hz instead of at its 3.6 kHz ring.
    # A 0.9 mm bubble that thumps is not a small bubble, it is a large one played quietly.
    # Physically the same thing: the gas volume is what radiates, so it cannot put much
    # energy an octave below its own resonance. The *cloud* may — but that is a different
    # oscillator with a different size, and it is added separately below.
    transient = dsp.bandpass(transient, sample_rate, f0 * 0.5,
                             min(f0 * 2.2, sample_rate * 0.42), order=2)
    transient = dsp.normalise(transient, entrainment)

    # Bigger bubbles are louder, and by a lot: radiated energy climbs with volume while
    # the ear's sensitivity falls away below a kilohertz, so the two only partly cancel.
    # This is what makes a 4 mm blorp sit over a 0.8 mm tick in the same bed without
    # either of them having a level of its own in the manifest.
    #
    # The exponent was 1.5 in the first pass and that was wrong in a way only the measured
    # library showed: combined with the submerged low-pass, which takes far more out of a
    # 4 kHz tick than out of a 700 Hz blorp, it spread the baked library over 34 dB. The
    # small sizes were then inaudible under the large ones at any mix, so half the grains
    # were doing nothing. The low-pass already carries most of this relation; the exponent
    # only has to carry the rest.
    level = (radius_mm / 2.0) ** 1.1

    gulp = np.zeros_like(ring)
    if cloud > 0:
        response = plume.cloud_response(ring.size, sample_rate, rng=rng)
        # Two numbers, and they were tuned against opposite complaints.
        #
        # The **exponent** was r**3 — the honest scaling, since a 3 mm bubble displaces
        # thirty-seven times the gas of a 0.9 mm one. It made the largest grain in the
        # library decide the balance for every other, and the user's verdict was that the
        # bubbles "sound dead": the collective term ran four times the ping for the big
        # sizes and buried the thing it is meant to accompany. 1.8 keeps the direction
        # without the tyranny.
        #
        # The **level** then went the other way, and the reference settled it. Its mid-range
        # is 12 to 18 dB below its peak, which is exactly what the 6 dB/octave tilt off a
        # 250 Hz peak predicts on its own — meaning a real tank has almost no *distinct*
        # pings up there. The ping really is garnish. What makes a bubble sound alive at
        # that level is its transient and its chirp, not its share of the spectrum.
        gulp = response * cloud * 4.5 * (radius_mm / 2.0) ** 1.8

    return (ring + transient) * level + gulp


def burst(radii: list[float], spacing: list[float], sample_rate: int,
          rng: np.random.Generator) -> np.ndarray:
    """Several bubbles in quick succession, as one grain.

    An airstone releases bubbles in trains, not independently: the neck that pinches one
    off is already forming the next. Trains a few milliseconds apart are heard as one
    gesture rather than as separate events, so baking them together is both cheaper and
    more faithful than asking the runtime scheduler to place them that precisely.
    """
    pings = [ping(radius, sample_rate, rng) for radius in radii]
    offsets = np.cumsum([0.0] + list(spacing))
    length = max(int(offset * sample_rate) + p.size for offset, p in zip(offsets, pings))

    out = np.zeros(length)
    for offset, p in zip(offsets, pings):
        start = int(offset * sample_rate)
        out[start:start + p.size] += p
    return out
