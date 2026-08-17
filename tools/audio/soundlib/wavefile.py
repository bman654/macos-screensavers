"""Reading and writing the only audio container this repo needs.

16-bit PCM, because that is what `AVAudioFile` opens without a codec and what `afplay`
plays without thinking about it. Everything upstream of here is float64 in [-1, 1];
quantisation happens once, at the boundary, with dither.
"""

from __future__ import annotations

import wave
from pathlib import Path

import numpy as np


def write(path: Path | str, samples: np.ndarray, sample_rate: int) -> Path:
    """Write mono (N,) or stereo (N, 2) float samples as 16-bit PCM.

    Peaks are *not* normalised here. A grain library whose members were each normalised
    to full scale would have thrown away the one thing the synthesis knows and the
    scheduler does not: how loud a 4 mm bubble is next to a 0.7 mm one. Relative level
    across the library is authored, so it has to survive the file.
    """
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)

    frames = np.atleast_2d(samples.T).T if samples.ndim == 1 else samples
    if frames.ndim == 1:
        frames = frames[:, None]
    channels = frames.shape[1]

    peak = float(np.max(np.abs(frames))) if frames.size else 0.0
    if peak > 1.0:
        raise ValueError(f"{path.name}: peak {peak:.3f} would clip; scale before writing")

    # TPDF dither at one LSB. Inaudible at -96 dBFS and it removes the correlated
    # quantisation buzz from the long, quiet reverb tails these grains all end in —
    # which is exactly where truncation distortion is audible, because there is nothing
    # else there to mask it.
    rng = np.random.default_rng(0x1F15)
    dither = (rng.random(frames.shape) - rng.random(frames.shape)) / 32768.0
    quantised = np.clip(np.round((frames + dither) * 32767.0), -32768, 32767)

    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(channels)
        handle.setsampwidth(2)
        handle.setframerate(sample_rate)
        handle.writeframes(quantised.astype("<i2").tobytes())
    return path


def read(path: Path | str) -> tuple[np.ndarray, int]:
    """Read a 16-bit PCM WAV back as float in [-1, 1], shaped (N, channels)."""
    with wave.open(str(path), "rb") as handle:
        if handle.getsampwidth() != 2:
            raise ValueError(f"{path}: only 16-bit PCM is supported")
        channels = handle.getnchannels()
        rate = handle.getframerate()
        raw = handle.readframes(handle.getnframes())
    samples = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768.0
    return samples.reshape(-1, channels), rate
