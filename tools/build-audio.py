#!/usr/bin/env python3
"""Bake the Aquarium's grain library.

Sounds are code here for the same reason models are: a bubble's pitch follows from its
radius and nothing else, so the source of truth is the script, and the WAVs under
`Savers/Aquarium/Assets/audio/` are build output. They are not tracked, and re-baking is a
normal part of the loop rather than an event.

    .venv/bin/python tools/build-audio.py                 # everything, ~10 seconds
    .venv/bin/python tools/build-audio.py --only bubble   # one family
    .venv/bin/python tools/audio-preview.py --seconds 60  # then listen to the result

The interpreter is the same one the image tools need — see `docs/next-session.md`.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

import numpy as np

_REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_REPO / "tools" / "audio"))
sys.path.insert(0, str(_REPO / "Savers" / "Aquarium" / "Sounds"))

import library  # noqa: E402
import soundscape  # noqa: E402
from soundlib import bubble, dsp, puff, swish, water, wavefile  # noqa: E402

_OUT = _REPO / "Savers" / "Aquarium" / "Assets" / "audio"
_SAMPLE_RATE = water.SAMPLE_RATE

#: Every grain lands here after its family is scaled. Leaves 1 dB of headroom for the
#: runtime's own summing, which is where the real peaks happen — the scheduler can put
#: four bubbles inside one ring-down.
_FAMILY_PEAK = 0.89


def _bake_bubbles(response: np.ndarray) -> list[dict]:
    grains: list[dict] = []
    for spec in library.BUBBLES:
        for variant in range(spec.variants):
            # Seeded from the sound's own parameters, so re-baking one grain does not
            # renumber the others — the same rule the tank's per-feature random streams
            # follow, and for the same reason.
            rng = np.random.default_rng(hash((round(spec.radius_mm, 3), variant)) % 2**32)
            dry = bubble.ping(spec.radius_mm, _SAMPLE_RATE, rng)
            grains.append({
                "name": f"bubble_{spec.radius_mm:.2f}mm_{variant}".replace(".", "p"),
                "family": "bubble",
                "radiusMm": spec.radius_mm,
                "frequency": bubble.frequency(spec.radius_mm),
                "samples": water.place(water.underwater(dry, _SAMPLE_RATE), response,
                                       wet=spec.wet),
            })

    for index, spec in enumerate(library.BURSTS):
        for variant in range(spec.variants):
            rng = np.random.default_rng(0xB0_0000 + index * 16 + variant)
            dry = bubble.burst(spec.radii, spec.spacing, _SAMPLE_RATE, rng)
            # A train's nominal radius is its largest bubble: that is the one the ear
            # pitches the gesture by, and it is what the scheduler must resample against.
            grains.append({
                "name": f"burst_{index}_{variant}",
                "family": "burst",
                "radiusMm": max(spec.radii),
                "frequency": bubble.frequency(max(spec.radii)),
                "samples": water.place(water.underwater(dry, _SAMPLE_RATE), response,
                                       wet=spec.wet),
            })
    return grains


def _bake_swishes(response: np.ndarray) -> list[dict]:
    grains: list[dict] = []
    for spec in library.SWISHES:
        for variant in range(spec.variants):
            rng = np.random.default_rng(0x5A15_0000 + variant + 97 * spec.beats)
            dry = swish.flurry(library.REFERENCE_BODY_LENGTH, spec.beats, _SAMPLE_RATE,
                               rng, effort=spec.effort)
            grains.append({
                "name": f"{spec.name}_{variant}",
                "family": spec.name,
                "bodyLength": library.REFERENCE_BODY_LENGTH,
                # A much lower floor than the bed gets, and a shade brighter. Both come
                # from the movement references rather than from taste — see
                # `water.underwater`, and `tools/audio-match.py --target dart`.
                "samples": water.place(
                    water.underwater(dry, _SAMPLE_RATE, brightness=1.3, floor=28.0),
                    response, wet=spec.wet),
            })
    return grains


def _bake_puffs(response: np.ndarray) -> list[dict]:
    grains: list[dict] = []
    for index, spec in enumerate(library.PUFFS):
        for variant in range(spec.variants):
            rng = np.random.default_rng(0x9FF0_0000 + index * 16 + variant)
            dry = puff.release(_SAMPLE_RATE, rng, size=spec.size)
            grains.append({
                "name": f"puff_{index}_{variant}",
                "family": "puff",
                # The size is what the scheduler resamples against, and it stands in for a
                # radius here: a bigger release is a slower rate, exactly as a bigger bubble
                # is. Carried so `_level_family` groups the variants of one size together.
                "radiusMm": round(puff.MEDIAN_RADIUS * spec.size, 3),
                "size": spec.size,
                # The bed's own treatment, not the fish's. A puff is bubbles rising in
                # water, so it keeps the tilt and the fine top that `swish` deliberately
                # cuts — see the module docstring.
                "samples": water.place(water.underwater(dry, _SAMPLE_RATE), response,
                                       wet=spec.wet),
            })
    return grains


def _level_family(grains: list[dict], families: set[str]) -> None:
    """Normalise each grain to the file's headroom, and carry its authored level as `gain`.

    The relation between size and loudness is the one thing the synthesis knows that the
    scheduler does not — a 4 mm blorp is far louder than a 0.9 mm tick, and that is
    authored in `bubble.ping`, not in the manifest. It has to survive to the runtime.

    The obvious way to make it survive is one scale factor for the whole family, and that
    was the first pass. It works and it wastes the format: measured across the baked
    library the quietest bubble landed at -35 dBFS peak, so a fifth of the sixteen-bit word
    was carrying the sound and the rest was carrying zero. Storing every grain at full
    level and moving the relation into a `gain` in the manifest is exactly equivalent
    arithmetically, and gives every grain the whole word.

    The level is taken per *group* — one nominal radius, or one gesture — and not per file.
    Variants of the same grain differ only in a noise seed, so their individual peaks
    differ by several decibels for no reason a listener should ever hear; measured on the
    first pass, three baked strokes of the same fish spanned 6 dB. Levelling them by group
    keeps the authored relation (size to loudness) and discards the accident (seed to
    peak). RMS rather than peak, because these are noise-like and RMS is what loudness
    tracks.
    """
    members = [g for g in grains if g["family"] in families]
    if not members:
        return

    for grain in members:
        grain["_peak"] = float(np.max(np.abs(grain["samples"])))
        grain["_rms"] = float(np.sqrt(np.mean(grain["samples"] ** 2)))

    groups: dict[tuple, list[dict]] = {}
    for grain in members:
        key = (grain["family"], round(grain.get("radiusMm", 0.0), 3))
        groups.setdefault(key, []).append(grain)
    for group in groups.values():
        level = float(np.mean([g["_rms"] for g in group]))
        for grain in group:
            grain["_target"] = level

    # Normalise each file to the headroom, then put the authored level back as a gain.
    for grain in members:
        peak = grain.pop("_peak")
        if peak > 0:
            grain["samples"] = grain["samples"] * (_FAMILY_PEAK / peak)
        grain["_fileRms"] = grain.pop("_rms") * (_FAMILY_PEAK / peak if peak > 0 else 1.0)

    scale = max(g["_target"] / g["_fileRms"] for g in members if g["_fileRms"] > 0)
    for grain in members:
        grain["gain"] = round(grain.pop("_target") / grain.pop("_fileRms") / scale, 6)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", action="append", default=[],
                        help="bake only families whose name contains this (bubble, swish)")
    parser.add_argument("--out", type=Path, default=_OUT)
    arguments = parser.parse_args()

    response = water.tank_space(_SAMPLE_RATE)

    grains: list[dict] = []
    wanted = arguments.only or ["bubble", "swish", "puff"]
    if any("bubble" in w or "burst" in w for w in wanted):
        grains += _bake_bubbles(response)
    if any("swish" in w or "dart" in w for w in wanted):
        grains += _bake_swishes(response)
    if any("puff" in w for w in wanted):
        grains += _bake_puffs(response)
    if not grains:
        print(f"error: --only {wanted} matched no families", file=sys.stderr)
        return 1

    if any(g["family"] in {"bubble", "burst"} for g in grains):
        _level_family(grains, {"bubble", "burst"})
    if any(g["family"] in {"swish", "dart"} for g in grains):
        _level_family(grains, {"swish", "dart"})
    # Levelled on its own, not with the bed. A puff has to be able to stand out from the bed
    # it arrives over — that is the whole point of it — so the two families' relative loudness
    # is a mix decision in `soundscape.py`, not an accident of their RMS.
    if any(g["family"] == "puff" for g in grains):
        _level_family(grains, {"puff"})

    arguments.out.mkdir(parents=True, exist_ok=True)
    entries = []
    total = 0
    print(f"{'grain':<26}{'sec':>7}{'gain dB':>9}{'rms dBFS':>10}{'KB':>7}")
    for grain in grains:
        samples = dsp.fade(grain.pop("samples"), _SAMPLE_RATE, release=0.01)
        path = arguments.out / f"{grain['name']}.wav"
        wavefile.write(path, samples, _SAMPLE_RATE)
        size = path.stat().st_size
        total += size

        rms = float(np.sqrt(np.mean(samples ** 2))) * grain["gain"]
        grain["file"] = path.name
        grain["frames"] = int(samples.shape[0])
        entries.append(grain)
        print(f"{grain['name']:<26}{samples.shape[0] / _SAMPLE_RATE:>7.3f}"
              f"{20 * np.log10(max(grain['gain'], 1e-9)):>9.1f}"
              f"{20 * np.log10(max(rms, 1e-9)):>10.1f}{size / 1024:>7.0f}")

    manifest = {
        "sampleRate": _SAMPLE_RATE,
        "referenceBodyLength": library.REFERENCE_BODY_LENGTH,
        "grains": entries,
        **soundscape.manifest(),
    }
    manifest_path = arguments.out / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")

    print(f"\n{len(entries)} grains, {total / 1024:.0f} KB -> {arguments.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
