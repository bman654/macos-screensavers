"""What water does to a sound on its way to a listener who is also in the water.

This is the file the whole audio track turns on, because the brief was not "aquarium
noises" — it was that every sound must arrive the way it arrives *underwater*, from a
source that is underwater, rather than the way the same event would sound in air.

**The honest physics first, because it points the other way.** Absorption in fresh water
is about 2e-14 dB per metre per hertz squared: over the metre of a tank, a 10 kHz
component loses two millionths of a decibel. A hydrophone dropped into a real aquarium
records something *brighter* than air, not duller — bubbles ring clean and high. So the
muffling everyone recognises as "underwater" is not the water attenuating anything over
these distances. It is three other things, and modelling those is what makes it read:

  1. **The listener's head is full of water**, so most of what reaches the cochlea arrives
     by bone conduction — a gentle, very wide tilt rather than a corner. `underwater` is
     that transfer, and its shape is *measured* off a real aquarium recording rather than
     reasoned out. The first attempt reasoned it out, got a pair of low-pass corners, and
     was wrong by two octaves.
  2. **Nothing is where it sounds like it is.** Sound travels at 1480 m/s in water, so
     the interaural delay across a head shrinks to about 40 microseconds and the head
     casts almost no acoustic shadow. Direction collapses; sound is *around* you rather
     than *over there*. That is why grains are baked with a decorrelated stereo space and
     panned only gently at runtime — a hard pan is an air cue and it breaks the illusion
     instantly.
  3. **A small body of water smears transients.** Reflections come back within a
     millisecond because the medium is fast, so an attack arrives as a thickened front
     rather than as a point. `tank_space` is that.
  4. **What a hydrophone in a tank mostly hears is not individual bubbles at all.** The
     measured peak sits at 160-320 Hz, and a bubble ringing there would be fourteen
     millimetres across. It is the *plume* — see `plume.py`, and the cloud term in
     `bubble.py` — and getting that wrong is why the first pass sounded like bubbles
     bursting at the surface of a tank you were standing over rather than sound made
     underneath it.

**Why the space is baked into every grain rather than added at runtime.** Convolution is
linear and time-invariant, so a hundred grains each carrying the tank's impulse response
sum to exactly what one reverb fed by a hundred dry grains would produce. Baking it
therefore costs nothing in fidelity, costs a quarter-second of tail per grain on disk,
and buys two things worth more than that: the saver needs no reverb unit on the audio
thread, and `afplay grain.wav` is an honest preview of what a listener will hear. In a
repo whose hardest-won rule is "look at the PNG, at the size it will be seen", the audio
equivalent is that the file you can play has to be the thing that ships.
"""

from __future__ import annotations

import numpy as np

from . import dsp

SAMPLE_RATE = 48_000

#: Speed of sound in fresh water at room temperature, m/s. Four times air, which is the
#: number behind both the collapsed stereo image and the sub-millisecond reflections.
SPEED_OF_SOUND = 1480.0


def underwater(x: np.ndarray, sample_rate: int = SAMPLE_RATE,
               brightness: float = 1.0, floor: float = 130.0) -> np.ndarray:
    """The transfer that makes a sound arrive through water rather than through air.

    **This is measured, and the first version was wrong.** It used to be a pair of low-pass
    corners at 1.8 and 5.2 kHz with a small shelf underneath, on the reasoning that a
    flooded ear canal is a low-pass. The user's verdict on the result was that every grain
    "sounds completely like it's in the air", and measuring a real aquarium recording
    against it says exactly why — see `tools/audio-match.py`, which carries the reference
    profile and the numbers:

    - The reference peaks at **160-320 Hz** and falls about **6 dB per octave** above that,
      smoothly, for five octaves. That is a *tilt*, not a corner.
    - Relative to its own total it has about **17 dB more energy above 5 kHz** than the
      low-passed version did. Cutting the top does not sink a sound; it shrinks it. A
      narrow midrange hump with a cliff either side is what a small speaker sounds like,
      which is why the old one read as being in a room rather than in water.

    So the shape is two poles, and both of them are gentle:

    - **A one-pole low-pass at 280 Hz.** One pole is exactly -6 dB/octave, which is the
      measured slope, and being one pole it never develops a corner to hear.
    - **A two-pole high-pass at 130 Hz.** The reference falls away below 160 too, faster
      than it does above — and the strong bass in the middle of that recording is its
      music, not its tank: the 30-320 Hz percussive envelope there autocorrelates at 0.60
      on a 0.33 s lag, which is a tempo.

    `brightness` slides the low-pass, so a source imagined nearer the listener keeps a
    little more of its top.

    `floor` moves the high-pass, and it is not cosmetic — it is the difference between two
    genuinely different sources. 130 Hz is right for an aerator's column, whose measured
    profile falls away below 160. A fish moving is not that: the movement references carry
    their heaviest energy at **20-80 Hz**, fifteen to twenty decibels more than the tank bed
    does, because the cloud shed off a moving body is far larger and looser than the column
    above a stone — and a bigger cloud resonates lower. Applying the bed's floor to a swish
    removes exactly the part of it that says something big moved through water, which is
    what happened on the first attempt at this and measured 22 dB short at 20-40 Hz.
    """
    out = dsp.highpass(x, sample_rate, floor, order=2)
    return dsp.lowpass(out, sample_rate, 280.0 * brightness, order=1)


def tank_space(sample_rate: int = SAMPLE_RATE, seed: int = 0x7A4C,
               size: float = 1.0) -> np.ndarray:
    """A stereo impulse response for a body of water a metre or so across.

    Deliberately *not* the physically exact answer. A rectangular metre of water is a
    resonator whose lowest axial mode sits at 1480/2 = 740 Hz with wide, sparse modes
    above it, and rendering that honestly produces a tin can — a hard comb filter that
    reads as a cheap plate reverb rather than as water. What actually reads as a body of
    water is dense early diffusion with a short, dark tail, so that is what this builds:

    - **Early reflections inside the first three milliseconds.** At 1480 m/s a wall a
      metre away answers in 0.68 ms. They are what thickens an attack, and they are why a
      bubble here sounds like it happened in something rather than in the open.
    - **A diffuse tail that dies faster the higher it goes** — 220 ms at the bottom, 50 ms
      at the top. Frequency-dependent decay is the whole difference between a dark space
      and a bright one, and it compounds the submerged low-pass in the same direction.
      Short, and it has to be: the tail is baked into every grain, so at forty bubbles a
      second forty tails are summing, and a tail long enough to flatter one bubble turns a
      bed into a wash. Reverb is linear, which is the property that makes baking it free —
      and linear means it accumulates exactly as a runtime reverb would.
    - **Two decorrelated channels.** Same statistics, different noise. That gives the
      enveloping, directionless field of point 2 in this module's header; a mono tail
      convolved into both channels would collapse to the middle of the head.
    """
    length = int(0.28 * sample_rate)
    rng = np.random.default_rng(seed)
    time = np.arange(length) / sample_rate

    channels = []
    for channel in range(2):
        noise = rng.standard_normal(length)
        tail = np.zeros(length)
        # Band-split decay. -60 dB at the stated time, i.e. exp(-6.908 t / rt60).
        #
        # Each band is levelled to a target *spectral density* — its weight scaled by the
        # square root of its own width — and that detail is the whole difference between a
        # room and a rumble.
        #
        # Levelling the bands by RMS instead, which is the obvious thing and was the first
        # attempt, gives a 240 Hz-wide band the same total power as a 7.2 kHz-wide one:
        # thirty times the density per hertz. Measured, the response then carried its
        # strongest octave at 160-320 Hz, and every grain convolved with it acquired a low
        # thump on its onset — the 0.9 mm bubble, which rings at 3.6 kHz, arrived with its
        # spectral peak at 175 Hz.
        #
        # The weights tilt it dark on purpose, but only by a few decibels. The thickness
        # that says "underwater" is authored on the direct sound, in `submerged`; a
        # bass-heavy *room* on top of that is mud, and it is also wrong — a body of water
        # a metre across supports no mode below about 740 Hz, since sound crosses it in
        # under a millisecond.
        reference_width = 1400.0
        for low, high, rt60, weight in ((160.0, 400.0, 0.20 * size, 0.90),
                                        (400.0, 1800.0, 0.13 * size, 1.00),
                                        (1800.0, 9000.0, 0.050 * size, 0.50)):
            band = dsp.bandpass(noise, sample_rate, low, high, order=2)
            band = band * np.exp(-6.908 * time / rt60)
            target = weight * np.sqrt((high - low) / reference_width)
            tail += band * (target / max(float(np.sqrt(np.mean(band ** 2))), 1e-12))

        # The first few milliseconds are sparse rather than diffuse — a handful of real
        # surfaces, at water's distances. Jittered per channel so the pair does not comb.
        #
        # Each reflection is half a millisecond of noise rather than a Dirac. A Dirac is
        # the textbook reflection and it is the wrong one here twice over: a real surface
        # is textured, so it smears; and a train of Diracs fed through the high-pass below
        # excites the filter's own poles, which is where an earlier pass's 204 Hz ring in
        # every single grain came from. Shape the source, do not fix it with another
        # filter.
        early = np.zeros(length)
        burst = max(int(0.0005 * sample_rate), 4)
        window = dsp.raised_cosine(burst) * dsp.raised_cosine(burst)[::-1]
        for distance in (0.45, 0.72, 1.05, 1.4, 1.9):
            jitter = 1.0 + 0.11 * rng.standard_normal()
            delay = int(2.0 * distance * size * jitter / SPEED_OF_SOUND * sample_rate)
            if 0 < delay < length - burst:
                early[delay:delay + burst] += (
                    (0.55 / distance) * rng.standard_normal(burst) * window)

        response = early + 0.75 * tail / np.max(np.abs(tail))
        # First order, not second: a resonant corner would put its own note into every
        # grain in the library. The modal argument above says only that a tank has little
        # to say down here, not that it should ring.
        channels.append(dsp.highpass(response, sample_rate, 200.0, order=1))

    stereo = np.stack(channels, axis=1)
    return stereo / np.max(np.abs(stereo))


def place(x: np.ndarray, response: np.ndarray, wet: float = 0.35,
          spread: float = 1.0) -> np.ndarray:
    """Convolve a mono grain with the tank, and return stereo.

    `wet` is how far away the source is, expressed the way a listener actually judges
    distance — by the ratio of direct sound to reflected, not by loudness, which is a
    gain and is applied at runtime instead. `spread` widens or narrows the direct signal's
    place in the pair; at 1 the dry part sits centred and the reflections do the widening,
    which is what point 2 in the header asks for.
    """
    mono = np.asarray(x, dtype=np.float64).reshape(-1)
    length = mono.size + response.shape[0] - 1

    out = np.zeros((length, 2))
    for channel in range(2):
        out[:, channel] = np.convolve(mono, response[:, channel])[:length]
    out *= wet / max(np.max(np.abs(out)), 1e-12) * max(np.max(np.abs(mono)), 1e-12)

    direct = np.zeros((length, 2))
    direct[:mono.size, 0] = mono * (1.0 - 0.15 * (spread - 1.0))
    direct[:mono.size, 1] = mono * (1.0 + 0.15 * (spread - 1.0))
    return direct * (1.0 - wet) + out
