"""Synthesis primitives shared by any saver that makes a sound.

The same split as `tools/blender/saverlib`: a primitive that a second saver would plausibly
want lives here, and the numbers that make a sound belong to one saver live with that
saver — `Savers/Aquarium/Sounds/`.
"""

from . import bubble, dsp, swish, water, wavefile  # noqa: F401

SAMPLE_RATE = water.SAMPLE_RATE
