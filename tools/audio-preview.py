#!/usr/bin/env python3
"""Render the aquarium's soundscape to a WAV, so a person can hear it before it is built.

This is the audio half of `tools/gallery.py`. The repo's hardest-won rule is that art is
judged by looking at the render at the size it will be seen, and the audio equivalent is
that it is judged by *listening*, not by reading parameters or a spectrogram. Nothing here
requires a build, an install, or a screensaver session:

    .venv/bin/python tools/audio-preview.py --seconds 90 && afplay /tmp/aquarium.wav
    .venv/bin/python tools/audio-preview.py --grains && afplay /tmp/aquarium.wav
    .venv/bin/python tools/audio-preview.py --only bed --seconds 60      # no fish
    .venv/bin/python tools/audio-preview.py --only fish --seconds 60     # no bubbles

**It reads the shipped manifest, not this file.** Every number that shapes the mix comes
out of `Savers/Aquarium/Assets/audio/manifest.json`, which is what the saver reads too, so
a preview that sounds right is a saver that sounds right. The one thing this cannot
reproduce is the tank on screen — the real scheduler's bubble rate follows a prop's authored
emit cycle and its swishes follow actual fish, so the preview stands in for both with the
same statistics. It is a design tool. `AQUARIUM_AUDIO_RECORD` on the saver itself is the
ground truth.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

import numpy as np

_REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_REPO / "tools" / "audio"))

from soundlib import dsp, wavefile  # noqa: E402

_ASSETS = _REPO / "Savers" / "Aquarium" / "Assets" / "audio"

#: Body lengths, in metres, spanning what the model library actually draws — a 7 cm
#: cardinalfish to a 1.5 m moray, weighted toward the middle the way a tank's roster is.
_BODY_LENGTHS = [0.08, 0.11, 0.14, 0.18, 0.22, 0.28, 0.40, 0.75]


def _emitters(text: str) -> list[tuple[float, bool]]:
    """Parse `24c,55` into [(24.0, continuous), (55.0, cyclic)]."""
    parsed = []
    for token in filter(None, (t.strip() for t in text.split(","))):
        continuous = token.endswith("c")
        parsed.append((float(token[:-1] if continuous else token), continuous))
    return parsed


class Mixer:
    """A stereo bus with one operation: drop a stereo grain in at a time, gain and pan."""

    def __init__(self, seconds: float, sample_rate: int):
        self.sample_rate = sample_rate
        self.buffer = np.zeros((int(seconds * sample_rate) + sample_rate, 2))

    def place(self, grain: np.ndarray, at: float, gain: float, pan: float) -> None:
        start = int(at * self.sample_rate)
        if start >= self.buffer.shape[0]:
            return
        # Constant power, so a grain does not get quieter as it moves off centre.
        angle = (np.clip(pan, -1.0, 1.0) + 1.0) * np.pi / 4.0
        weights = np.array([np.cos(angle), np.sin(angle)]) * np.sqrt(2.0) * gain

        end = min(start + grain.shape[0], self.buffer.shape[0])
        self.buffer[start:end] += grain[:end - start] * weights


def _load(manifest: dict) -> dict[str, list[dict]]:
    """Read every grain file once, grouped by family."""
    families: dict[str, list[dict]] = {}
    for entry in manifest["grains"]:
        samples, rate = wavefile.read(_ASSETS / entry["file"])
        if rate != manifest["sampleRate"]:
            raise ValueError(f"{entry['file']}: {rate} Hz, manifest says "
                             f"{manifest['sampleRate']}")
        families.setdefault(entry["family"], []).append({**entry, "samples": samples})
    return families


def _pick_bubble(radius_mm: float, candidates: list[dict],
                 rng: np.random.Generator) -> tuple[np.ndarray, float]:
    """The baked grain nearest this radius, resampled to hit it exactly.

    Playing a bubble faster makes it a smaller bubble — see `soundlib/bubble.py`; because
    radiation damping is independent of radius, the resample is the physically correct
    transform and not an approximation. So the library only has to be dense enough that
    the ratio stays modest, since the baked tank reverb is stretched along with it.
    """
    nearest = min(candidates, key=lambda g: abs(np.log(g["radiusMm"] / radius_mm)))
    ratio = float(np.clip(nearest["radiusMm"] / radius_mm, 0.75, 1.33))
    variants = [g for g in candidates if abs(g["radiusMm"] - nearest["radiusMm"]) < 1e-6]
    chosen = variants[rng.integers(len(variants))]
    return dsp.resample_linear(chosen["samples"], ratio), chosen["gain"]


def _bed(mixer: Mixer, manifest: dict, families: dict, seconds: float,
         emitters: list[tuple[float, bool]], rng: np.random.Generator) -> int:
    """Bubbles, arriving as a Poisson process whose rate follows the tank's emitters.

    `emitters` is a list of (declared particle rate, is continuous), standing in for what
    `Bubbler` knows for real: the thermal vent runs continuously at 24 particles a second,
    the treasure chest puffs 55 for a few seconds between long idles, the clamshell 7.
    Which of those a launch draws is the layout's business, so the preview names a
    plausible pair on the command line rather than pretending to know.

    The idle rate is not zero, and that matters: gas works loose from gravel and from the
    backs of leaves in a real tank continuously, and one that falls completely silent for
    the twenty-second idle of a cyclic prop reads as broken rather than as calm.
    """
    bed = manifest["bed"]
    singles = families["bubble"]
    bursts = families.get("burst", [])

    # The rate envelope, as a step function in time: sum the emitters that are alive in
    # each interval, scale, and floor at the ambient trickle.
    edges = {0.0, seconds}
    windows: list[tuple[float, float, float]] = []
    for declared, continuous in emitters:
        if continuous:
            windows.append((0.0, seconds, declared))
            continue
        when = -float(rng.uniform(0, 20))
        while when < seconds:
            idle = float(rng.uniform(11.0, 26.0))
            emit = float(rng.uniform(3.0, 6.5))
            windows.append((when + idle, when + idle + emit, declared))
            edges.update({when + idle, when + idle + emit})
            when += idle + emit
    steps = sorted(e for e in edges if 0.0 <= e <= seconds)

    schedule = []
    for start, end in zip(steps, steps[1:]):
        declared = sum(rate for lo, hi, rate in windows if lo <= start < hi)
        schedule.append((start, end,
                         max(bed["idleRate"],
                             min(declared * bed["rateScale"], bed["maxRate"]))))

    placed = 0
    for start, end, rate in schedule:
        # Poisson arrivals: exponential gaps at the segment's rate.
        at = max(start, 0.0)
        while at < min(end, seconds):
            at += float(rng.exponential(1.0 / rate))
            if at >= min(end, seconds):
                break

            radius = float(np.clip(
                bed["radiusMedian"] * np.exp(rng.normal(0.0, bed["radiusSigma"])),
                bed["radiusMin"], bed["radiusMax"]))

            if bursts and rng.random() < bed["burstShare"]:
                chosen = bursts[rng.integers(len(bursts))]
                ratio = float(np.clip(chosen["radiusMm"] / radius, 0.75, 1.33))
                samples = dsp.resample_linear(chosen["samples"], ratio)
                gain = chosen["gain"]
            else:
                samples, gain = _pick_bubble(radius, singles, rng)

            # A stream is a column, not a point: bubbles rising off one stone still arrive
            # from slightly different places and distances as they climb.
            mixer.place(samples, at,
                        gain=gain * bed["bubbleGain"] * float(rng.uniform(0.55, 1.0)),
                        pan=float(rng.uniform(-1, 1)) * manifest["mix"]["panWidth"])
            placed += 1
    return placed


def _water(manifest: dict, seconds: float, sample_rate: int,
           rng: np.random.Generator) -> np.ndarray:
    """The moving floor of water the grains sit on. Two filters on brown noise.

    Synthesised rather than baked, in the preview and in the saver alike: it is stationary,
    so it has no events to schedule and would have to be a loop if it were a file — and a
    loop is the one thing this design refuses. It is also two biquads, which is cheaper
    than reading a file.
    """
    water = manifest["water"]
    count = int(seconds * sample_rate) + sample_rate
    time = np.arange(count) / sample_rate

    channels = []
    for channel in range(2):
        noise = dsp.brown_noise(count, rng)
        # Third order, to match the three one-pole sections the saver uses. The two
        # implementations have to have the same asymptotic slope or the preview stops being
        # a rehearsal of the saver — which is the only thing that makes it worth having.
        band = dsp.highpass(noise, sample_rate, water["low"], order=3)
        # One pole on top, and the count matters. Brown noise is -6 dB/octave of *spectrum*,
        # which is only -3 dB/octave of *band energy* — the integral over a band twice as
        # wide gives half of it back. The reference falls 6 dB per octave in band terms, so
        # the spectrum it wants is nearer -9, and one more pole is what supplies it.
        band = dsp.lowpass(band, sample_rate, water["high"], order=1)
        channels.append(band / max(float(np.max(np.abs(band))), 1e-9))

    breathing = 1.0 - water["lfoDepth"] * 0.5 * (
        1.0 - np.cos(2 * np.pi * water["lfoHz"] * time))
    return np.stack(channels, axis=1) * (water["gain"] * breathing)[:, None]


def _fish(mixer: Mixer, manifest: dict, families: dict, seconds: float,
          rng: np.random.Generator) -> int:
    """Swishes, at the rate the tank's cooldowns actually allow.

    In the saver these are triggered by `School` — a fish whose effort passes a threshold,
    subject to a per-fish and a per-tank cooldown. The per-tank floor is what sets the rate
    a listener hears, so the preview reproduces that and draws the rest.
    """
    fish = manifest["fish"]
    at = 2.0
    placed = 0
    while at < seconds:
        at += float(rng.exponential(2.6)) + fish["tankCooldown"]
        if at >= seconds:
            break

        is_dart = rng.random() < 0.38
        candidates = families["dart" if is_dart else "swish"]
        chosen = candidates[rng.integers(len(candidates))]

        length = _BODY_LENGTHS[rng.integers(len(_BODY_LENGTHS))]
        ratio = float(np.clip(np.sqrt(manifest["referenceBodyLength"] / length),
                              fish["rateMin"], fish["rateMax"]))
        samples = dsp.resample_linear(chosen["samples"], ratio)

        # Distance. A fish at the back of the tank is quieter and nearer the middle of the
        # picture, so the two move together.
        nearness = float(rng.uniform(0.35, 1.0))
        gain = chosen["gain"] * (fish["dartGain"] if is_dart else fish["swishGain"])
        mixer.place(samples, at, gain=gain * nearness,
                    pan=float(rng.uniform(-1, 1)) * manifest["mix"]["panWidth"] * nearness)
        placed += 1
    return placed


def _grain_sheet(manifest: dict, families: dict, sample_rate: int) -> np.ndarray:
    """Every grain once, in order, with a gap — the contact sheet, for ears.

    `tools/gallery.py` exists because a parameter cannot tell you whether a model reads as
    a fish. The same is true here, and this is the same tool.
    """
    gap = np.zeros((int(0.45 * sample_rate), 2))
    pieces = []
    for family in ("bubble", "burst", "swish", "dart"):
        for grain in families.get(family, []):
            pieces.append(grain["samples"] * grain["gain"])
            pieces.append(gap)
    return np.concatenate(pieces) if pieces else gap


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=float, default=60.0)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--out", type=Path, default=Path("/tmp/aquarium.wav"))
    parser.add_argument("--only", choices=["bed", "fish", "water", "all"], default="all")
    parser.add_argument("--emitters", default="24c,55",
                        help="declared particle rates in the tank; suffix c for continuous"
                             " (default: a thermal vent and a treasure chest)")
    parser.add_argument("--grains", action="store_true",
                        help="play the whole library once instead of mixing a tank")
    arguments = parser.parse_args()

    manifest_path = _ASSETS / "manifest.json"
    if not manifest_path.exists():
        print(f"error: no grain library at {_ASSETS}. Run tools/build-audio.py first.",
              file=sys.stderr)
        return 1
    manifest = json.loads(manifest_path.read_text())
    families = _load(manifest)
    sample_rate = manifest["sampleRate"]

    if arguments.grains:
        mix = _grain_sheet(manifest, families, sample_rate)
        bubbles = swishes = 0
    else:
        rng = np.random.default_rng(arguments.seed)
        mixer = Mixer(arguments.seconds, sample_rate)
        bubbles = (_bed(mixer, manifest, families, arguments.seconds,
                        _emitters(arguments.emitters), rng)
                   if arguments.only in ("bed", "all") else 0)
        swishes = (_fish(mixer, manifest, families, arguments.seconds, rng)
                   if arguments.only in ("fish", "all") else 0)
        mix = mixer.buffer
        if arguments.only in ("water", "all"):
            mix = mix + _water(manifest, arguments.seconds, sample_rate, rng)[:mix.shape[0]]
        mix = mix * manifest["mix"]["masterGain"]
        mix = dsp.fade(mix, sample_rate, attack=manifest["mix"]["fadeIn"],
                       release=manifest["mix"]["fadeOut"])

    peak = float(np.max(np.abs(mix)))
    if peak > 0.995:
        # Reported rather than silently limited. A soundscape that clips is a level
        # decision that needs making in `soundscape.py`, not a bug in the renderer.
        print(f"WARNING: peak {20 * np.log10(peak):+.1f} dBFS — reduce masterGain",
              file=sys.stderr)
        mix = mix / peak * 0.995

    wavefile.write(arguments.out, mix, sample_rate)
    rms = float(np.sqrt(np.mean(mix ** 2)))
    print(f"{arguments.out}  {mix.shape[0] / sample_rate:.1f} s  "
          f"peak {20 * np.log10(max(peak, 1e-9)):+.1f} dBFS  "
          f"rms {20 * np.log10(max(rms, 1e-9)):+.1f} dBFS")
    if not arguments.grains:
        print(f"{bubbles} bubbles ({bubbles / arguments.seconds:.1f}/s), {swishes} swishes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
