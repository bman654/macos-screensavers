"""Filters, noise and envelopes — the primitives every sound in this repo is built from.

Nothing here knows about water or about bubbles. The rule is the same one that separates
`tools/blender/saverlib` from `Savers/*/Models`: a primitive any sound would use lives
here, and the numbers that make a sound *this* sound live with the saver.
"""

from __future__ import annotations

import numpy as np
from scipy import signal


def lowpass(x: np.ndarray, sample_rate: int, cutoff: float, order: int = 2) -> np.ndarray:
    return _sos(x, signal.butter(order, _norm(cutoff, sample_rate), "low", output="sos"))


def highpass(x: np.ndarray, sample_rate: int, cutoff: float, order: int = 2) -> np.ndarray:
    return _sos(x, signal.butter(order, _norm(cutoff, sample_rate), "high", output="sos"))


def bandpass(x: np.ndarray, sample_rate: int, low: float, high: float,
             order: int = 2) -> np.ndarray:
    band = [_norm(low, sample_rate), _norm(high, sample_rate)]
    return _sos(x, signal.butter(order, band, "band", output="sos"))


def low_shelf(x: np.ndarray, sample_rate: int, corner: float, gain_db: float) -> np.ndarray:
    """A single-biquad shelf, RBJ cookbook, Q = 0.7.

    Used for the low lift that makes a sound feel like it is arriving through something
    dense rather than through air. A shelf and not a peak: the point is that *everything*
    below the corner comes up together, which is what "thicker medium" sounds like.
    """
    a = 10.0 ** (gain_db / 40.0)
    w = 2 * np.pi * corner / sample_rate
    cos_w, sin_w = np.cos(w), np.sin(w)
    alpha = sin_w / (2 * 0.7071)
    two_root_a_alpha = 2 * np.sqrt(a) * alpha

    b = np.array([
        a * ((a + 1) - (a - 1) * cos_w + two_root_a_alpha),
        2 * a * ((a - 1) - (a + 1) * cos_w),
        a * ((a + 1) - (a - 1) * cos_w - two_root_a_alpha),
    ])
    denominator = np.array([
        (a + 1) + (a - 1) * cos_w + two_root_a_alpha,
        -2 * ((a - 1) + (a + 1) * cos_w),
        (a + 1) + (a - 1) * cos_w - two_root_a_alpha,
    ])
    return _sos(x, signal.tf2sos(b / denominator[0], denominator / denominator[0]))


def sweeping_bandpass(x: np.ndarray, sample_rate: int, centres: np.ndarray,
                      q: float) -> np.ndarray:
    """A band-pass whose centre frequency moves per sample.

    A moving filter is what separates a *swish* from a burst of noise: the ear reads the
    downward slide of the band as something passing, and reads a static band as a hiss.
    Implemented as a direct-form state-variable filter rather than as a cascade of static
    filters, because recomputing biquad coefficients per sample and running them through
    `sosfilt` in blocks makes a stepped sweep, and the steps are audible as a chirp of
    their own.
    """
    x = np.asarray(x, dtype=np.float64)
    centres = np.clip(np.asarray(centres, dtype=np.float64), 20.0, sample_rate * 0.45)
    f = 2.0 * np.sin(np.pi * centres / sample_rate)
    damping = 1.0 / q

    out = np.zeros_like(x)
    low = band = 0.0
    for n in range(x.size):
        high = x[n] - low - damping * band
        band += f[n] * high
        low += f[n] * band
        out[n] = band
    return out


def brown_noise(count: int, rng: np.random.Generator) -> np.ndarray:
    """Integrated white noise, DC-removed and unit-normalised.

    -6 dB/octave. The spectrum of moving water rather than of a hiss: turbulence puts its
    energy at the bottom, and white noise stood in for it in the first pass and read as
    tape hiss no amount of low-pass could rescue.
    """
    walk = np.cumsum(rng.standard_normal(count))
    walk -= np.linspace(walk[0], walk[-1], count) if count > 1 else walk
    peak = np.max(np.abs(walk))
    return walk / peak if peak > 0 else walk


def raised_cosine(count: int) -> np.ndarray:
    """Half a cosine rising 0 -> 1. The only fade shape used anywhere here.

    A linear fade has a corner in its first derivative at both ends, and on a fade this
    short that corner is a click — the same finding the audio spike recorded about gates.
    """
    if count <= 1:
        return np.ones(max(count, 0))
    return 0.5 * (1.0 - np.cos(np.pi * np.arange(count) / (count - 1)))


def fade(x: np.ndarray, sample_rate: int, attack: float = 0.0,
         release: float = 0.0) -> np.ndarray:
    """Raised-cosine fades on both ends, in seconds. Safe when a grain is shorter."""
    out = np.array(x, dtype=np.float64, copy=True)
    length = out.shape[0]

    rise = min(int(attack * sample_rate), length)
    if rise > 0:
        out[:rise] *= _broadcast(raised_cosine(rise), out.ndim)
    decay = min(int(release * sample_rate), length - rise)
    if decay > 0:
        out[length - decay:] *= _broadcast(raised_cosine(decay)[::-1], out.ndim)
    return out


def normalise(x: np.ndarray, peak: float) -> np.ndarray:
    current = float(np.max(np.abs(x))) if x.size else 0.0
    return x * (peak / current) if current > 0 else x


def resample_linear(x: np.ndarray, ratio: float) -> np.ndarray:
    """Play a buffer back at `ratio` times its rate, with linear interpolation.

    The runtime does exactly this to turn a handful of baked bubbles into a continuum of
    radii — see `bubble.py` for why a resample is the physically *correct* transform for
    a bubble and not merely a cheap one. Mirrored here so the preview mix and the saver
    are the same instrument.
    """
    if ratio <= 0:
        raise ValueError("resample ratio must be positive")
    frames = int(x.shape[0] / ratio)
    positions = np.arange(frames) * ratio
    left = np.floor(positions).astype(int)
    right = np.minimum(left + 1, x.shape[0] - 1)
    weight = (positions - left)[:, None] if x.ndim == 2 else positions - left
    return x[left] * (1.0 - weight) + x[right] * weight


def _norm(frequency: float, sample_rate: int) -> float:
    return float(np.clip(frequency / (sample_rate * 0.5), 1e-5, 0.999))


def _sos(x: np.ndarray, sos: np.ndarray) -> np.ndarray:
    return signal.sosfilt(sos, np.asarray(x, dtype=np.float64), axis=0)


def _broadcast(envelope: np.ndarray, ndim: int) -> np.ndarray:
    return envelope[:, None] if ndim == 2 else envelope
