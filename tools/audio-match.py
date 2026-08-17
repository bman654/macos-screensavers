#!/usr/bin/env python3
"""Measure a sound against the reference recording of a real aquarium.

The audio equivalent of `tools/water-luminance.py`: one number per band, and a target to
hit. It exists because the first pass at this repo's aquarium audio was measured only
against *itself* — the saver was checked against the Python preview, the two agreed to
within a few decibels, and both were wrong in the same direction. The user's verdict on
that build was that every grain "sounds completely like it's in the air".

    .venv/bin/python tools/audio-match.py /tmp/aquarium.wav
    .venv/bin/python tools/audio-match.py --profile /tmp/ref.wav --from 6 --to 12

**The target below is measured, not chosen.** It comes from a stock aquarium recording the
user supplied as the direction they wanted, in the window they pointed at — the opening
seconds, before its background music comes in. Everything about it is band-relative, so it
says nothing about level and cannot be satisfied by turning something up.

What the numbers say, and it is worth reading before changing them:

- **The energy peaks at 160-320 Hz.** Not at a bubble's Minnaert frequency, which for the
  sizes an aerator makes is two to four kilohertz. Whatever a hydrophone in a tank is
  mostly hearing, it is not individual bubbles ringing.
- **It falls about 6 dB per octave above that, smoothly, for five octaves.** A gentle tilt
  over a very wide range — not a filter corner. The first pass used a pair of low-pass
  corners at 1.8 and 5.2 kHz and produced the opposite shape: a narrow midrange hump with
  a cliff on both sides, which is exactly what "small" and "in air" sound like.
- **It keeps its top.** Relative to its own total the reference has ~17 dB *more* energy
  above 5 kHz than the first pass did. Muffling something is not the same as sinking it.
- **There is very little below 80 Hz.** The strong bass in the middle of the reference
  track is its music: measured, the 30-320 Hz percussive envelope there autocorrelates at
  0.60 on a 0.33 s lag, which is a tempo, not a bubble.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

import numpy as np

_REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_REPO / "tools" / "audio"))

from soundlib import wavefile  # noqa: E402

EDGES = [20, 40, 80, 160, 320, 640, 1280, 2560, 5120, 10240, 20000]

#: Band energies in dB relative to the total, from the reference recording at 6-12 s.
TARGET = [-30.4, -26.3, -9.2, -1.1, -12.0, -15.6, -23.5, -28.5, -37.2, -49.0]

#: The same, for a fish moving — averaged over the three "underwater movement bubble motion"
#: samples the user supplied after judging the first two attempts at the swish.
#:
#: It is a different shape from the bed and deliberately kept separate. Two features matter:
#: far more energy below 80 Hz, which is a larger and looser cloud than an aerator's column;
#: and a **cliff** above 1.3 kHz rather than the bed's gentle tilt — 25 dB down by 2 kHz and
#: 50 dB by 4 kHz. The fizz above that cliff is what read as spray in air.
DART_TARGET = [-9.3, -9.4, -12.4, -5.9, -4.6, -10.8, -24.8, -53.0, -71.3, -79.3]

TARGETS = {"bed": TARGET, "dart": DART_TARGET}

#: How far off a band may be before it is worth acting on. Generous, because this is a
#: direction rather than a specification and the ear is the judge — but a band 20 dB out is
#: not a matter of taste.
TOLERANCE = 6.0


def profile(samples: np.ndarray, sample_rate: int) -> list[float]:
    """Band energies in dB relative to the total, averaged over the whole signal."""
    mono = samples.mean(axis=1) if samples.ndim == 2 else samples
    window = 1 << 14
    frequencies = np.fft.rfftfreq(window, 1 / sample_rate)
    accumulated = np.zeros(len(EDGES) - 1)

    for start in range(0, max(len(mono) - window, 1), window // 2):
        block = mono[start:start + window]
        if block.size != window:
            continue
        spectrum = np.abs(np.fft.rfft(block * np.hanning(window))) ** 2
        for index, (low, high) in enumerate(zip(EDGES, EDGES[1:])):
            accumulated[index] += spectrum[(frequencies >= low) & (frequencies < high)].sum()

    total = accumulated.sum()
    return [float(10 * np.log10(max(band / total, 1e-12))) for band in accumulated]


def centroid(bands: list[float]) -> float:
    """Band-weighted centre of mass, in hertz. One number for "how low does it sit"."""
    weights = [10 ** (value / 10) for value in bands]
    centres = [np.sqrt(low * high) for low, high in zip(EDGES, EDGES[1:])]
    return float(sum(c * w for c, w in zip(centres, weights)) / sum(weights))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wav", type=Path, nargs="+")
    parser.add_argument("--from", dest="start", type=float, default=0.0)
    parser.add_argument("--to", dest="end", type=float, default=0.0)
    parser.add_argument("--target", choices=sorted(TARGETS), default="bed")
    parser.add_argument("--profile", action="store_true",
                        help="print the measured profile as a TARGET list and stop")
    arguments = parser.parse_args()

    target = TARGETS[arguments.target]
    header = "".join(f"{edge:>7}" for edge in EDGES[:-1])
    print(f"{'':<22}{header}{'centroid':>10}")
    print(f"{'TARGET ' + arguments.target:<22}"
          + "".join(f"{value:>7.1f}" for value in target)
          + f"{centroid(target):>9.0f} Hz")

    worst = 0.0
    for path in arguments.wav:
        samples, rate = wavefile.read(path)
        if arguments.end > arguments.start:
            samples = samples[int(arguments.start * rate):int(arguments.end * rate)]
        elif arguments.start:
            samples = samples[int(arguments.start * rate):]

        measured = profile(samples, rate)
        if arguments.profile:
            print("\nTARGET = [" + ", ".join(f"{v:.1f}" for v in measured) + "]")
            continue

        print(f"{path.name:<22}" + "".join(f"{value:>7.1f}" for value in measured)
              + f"{centroid(measured):>9.0f} Hz")
        error = [value - want for value, want in zip(measured, target)]
        flags = "".join(f"{d:>+7.0f}" if abs(d) > TOLERANCE else f"{'.':>7}" for d in error)
        print(f"{'  vs target':<22}{flags}")
        worst = max(worst, max(abs(d) for d in error))

    if not arguments.profile:
        print(f"\nworst band error {worst:.0f} dB "
              f"({'within tolerance' if worst <= TOLERANCE else 'out of tolerance'})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
