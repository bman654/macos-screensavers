"""Render one fish per marking, so the vocabulary can be seen before it is chosen.

    tools/blender/run.sh Savers/Aquarium/Models/marking_swatches.py

Every marking `fish_material` offers is applied to the same neutral grey body, one per
tile, and tiled into a labelled sheet at `build/markings/swatches.png`. Writing a species
means picking markings and numbers off a page; this is that page, and it is generated
from the same code path a species goes through (`build_fish.build`) so it cannot drift
away from what a species would actually get.

`--only <text>` renders just the swatches whose label matches, which is the loop to use
when adding a marking to the vocabulary.
"""

import argparse
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.abspath(os.path.join(_HERE, "..", "..", ".."))
sys.path[:0] = [os.path.join(_REPO, "tools", "blender"), os.path.join(_REPO, "tools"), _HERE]

import gallery  # noqa: E402
from saverlib import studio  # noqa: E402
from species import Fin, Species  # noqa: E402

from build_fish import build  # noqa: E402

_INK = (0.02, 0.02, 0.04)
_WHITE = (0.95, 0.95, 0.93)
_GOLD = (0.98, 0.72, 0.05)
_ROSE = (0.90, 0.10, 0.35)
_TEAL = (0.05, 0.55, 0.62)

# A plain perch shape in unsaturated grey. The body must not compete with any marking
# colour, and it has to be mid-toned rather than pale: a white marking on a white body
# shows only its outline, which is exactly the sort of "renders fine, proves nothing"
# swatch this tool exists to avoid.
# Fin geometry, kept separate from the fins themselves so a swatch that only wants to
# recolour one fin can rebuild it — `Fin(**_DORSAL, color=_GOLD)` — instead of restating
# a span profile that has nothing to do with what the swatch is demonstrating.
_DORSAL = dict(t0=0.16, t1=0.80,
               span=[(0.00, 0.004), (0.25, 0.0150), (0.65, 0.0140), (1.00, 0.004)],
               rake=0.003, sink=0.22, samples_u=24)
_ANAL = dict(t0=0.56, t1=0.86,
             span=[(0.0, 0.004), (0.5, 0.0120), (1.0, 0.0035)], rake=0.003, sink=0.25)
_PECTORAL = dict(t0=0.30, t1=0.44,
                 span=[(0.0, 0.005), (0.45, 0.0165), (1.0, 0.005)],
                 rake=0.005, curl=0.0035, sink=0.30, samples_u=14, samples_v=12)
_CAUDAL = dict(t0=0.0, t1=1.0,
               span=[(0.0, 0.0140), (0.5, 0.0180), (1.0, 0.0140)],
               flare=[(0.0, 0.0), (1.0, 0.0230)], samples_u=24, samples_v=14)

_BODY = dict(
    length=0.100,
    top=[(0.00, 0.0055), (0.08, 0.0195), (0.26, 0.0262), (0.46, 0.0250),
         (0.70, 0.0160), (0.88, 0.0092), (1.00, 0.0060)],
    bottom=[(0.00, 0.0058), (0.10, 0.0180), (0.30, 0.0238), (0.50, 0.0222),
            (0.72, 0.0140), (0.90, 0.0082), (1.00, 0.0056)],
    width=[(0.00, 0.0038), (0.10, 0.0098), (0.30, 0.0120), (0.55, 0.0104),
           (0.80, 0.0060), (1.00, 0.0030)],
    spine=[(0.00, -0.0032), (0.24, 0.0008), (1.00, 0.0)],
    exponent=2.5,
    colors=((0.30, 0.32, 0.34), (0.17, 0.18, 0.21), (0.06, 0.07, 0.10)),
    fin_color=(0.15, 0.17, 0.21),
    mouth=((0.0455, 0.0, -0.0080), (0.0048, 0.0090, 0.0032)),
    scale_count=54.0,
    scale_depth=0.16,
    dorsal=Fin(**_DORSAL),
    anal=Fin(**_ANAL),
    pectoral=Fin(**_PECTORAL),
    caudal=Fin(**_CAUDAL),
    caudal_spread=0.80,
    eye=(0.140, 0.44, 0.046),
)

# (label, overrides). Each entry is exactly what a species file would write.
_SWATCHES = [
    ("bands", dict(
        bands=[(0.24, 0.045), (0.55, 0.050), (0.84, 0.030)])),
    ("bands + per-band colour", dict(
        bands=[(0.24, 0.045, _WHITE), (0.55, 0.050, _GOLD), (0.84, 0.030, _INK)],
        outline_width=0.0)),
    ("stripes", dict(
        stripes=[(0.78, 0.055, _INK), (0.52, 0.030, _GOLD), (0.24, 0.050, _ROSE)])),
    ("stripes + band", dict(
        stripes=[(0.62, 0.075, _TEAL)],
        bands=[(0.30, 0.035, _INK)], outline_width=0.0)),
    ("diagonal_stripes", dict(
        diagonal_stripes=dict(angle=28.0, spacing=0.070, width=0.45, color=_GOLD))),
    ("diagonal_stripes, angle +40", dict(
        diagonal_stripes=dict(angle=40.0, spacing=0.090, width=0.40, color=_GOLD))),
    ("diagonal_stripes, angle -40", dict(
        diagonal_stripes=dict(angle=-40.0, spacing=0.090, width=0.40, color=_ROSE))),
    ("diagonal_stripes + t_range", dict(
        colors=((0.10, 0.14, 0.34), (0.06, 0.10, 0.28), (0.03, 0.05, 0.18)),
        diagonal_stripes=dict(angle=22.0, spacing=0.055, width=0.35, color=_GOLD,
                              t_range=(0.34, 1.0)))),
    ("spots", dict(
        colors=((0.94, 0.94, 0.92), (0.88, 0.88, 0.86), (0.70, 0.72, 0.76)),
        spots=dict(count=22.0, size=0.30, coverage=0.85, color=_INK))),
    ("spots + coverage/size", dict(
        colors=((0.10, 0.10, 0.13), (0.06, 0.06, 0.09), (0.03, 0.03, 0.05)),
        spots=[dict(count=13.0, size=0.20, coverage=0.55, color=_WHITE, seed=3.0),
               dict(count=30.0, size=0.14, coverage=0.35, color=_WHITE, seed=9.0)])),
    ("spots + t_range/h_range", dict(
        spots=dict(count=18.0, size=0.34, coverage=0.9, color=_ROSE,
                   t_range=(0.40, 1.0), h_range=(0.0, 0.55)))),
    ("patches", dict(
        patches=[
            dict(center=(0.0335, 0.0, 0.0035), radii=(0.0060, 0.100, 0.0180),
                 color=_INK, softness=0.35),
            dict(center=(-0.0040, 0.0, -0.0010), radii=(0.0190, 0.100, 0.0105),
                 color=_TEAL, softness=0.55),
        ])),
    ("split", dict(
        colors=((0.62, 0.10, 0.62), (0.55, 0.06, 0.58), (0.34, 0.02, 0.38)),
        split=dict(t=0.46, color=_GOLD, hardness=0.75))),
    ("split, soft", dict(
        colors=((0.62, 0.10, 0.62), (0.55, 0.06, 0.58), (0.34, 0.02, 0.38)),
        split=dict(t=0.46, color=_GOLD, hardness=0.2))),
    ("eye_ring", dict(
        eye_ring=_GOLD)),
    ("eye_ring, wide", dict(
        eye_ring=dict(color=_ROSE, width=1.4, softness=0.6))),
    ("fin gradient", dict(
        fin_color=(0.10, 0.30, 0.62),
        fin_style=dict(tip_color=(0.98, 0.32, 0.05)))),
    ("fin edge", dict(
        fin_color=(0.55, 0.06, 0.42),
        fin_style=dict(edge_color=(0.30, 0.85, 0.95), edge_width=0.18))),
    ("fin spots", dict(
        fin_color=(0.96, 0.64, 0.06),
        fin_style=dict(spots=dict(count=6.0, size=0.34, color=_INK, coverage=0.9)))),
    # Per-fin colour and style. The species-level fin_style still supplies whatever a
    # fin does not override, and `style` replaces the species dict outright rather than
    # merging into it — the pectorals below keep no part of the ink-edged default.
    ("per-fin colour + style", dict(
        fin_color=(0.10, 0.30, 0.62),
        fin_style=dict(edge_color=_INK, edge_width=0.12),
        dorsal=Fin(**_DORSAL, color=_GOLD),
        anal=Fin(**_ANAL, color=_TEAL),
        pectoral=Fin(**_PECTORAL, color=_ROSE, style=dict(opacity=0.45)),
        caudal=Fin(**_CAUDAL))),
    # One continuous fin whose colour follows a two-tone body: the u ramp is the only
    # way to do this, because the dorsal is a single membrane and cannot be two
    # materials. Stops close together give the hard edge; the third element of a stop
    # sets that station's tip colour.
    ("fin along_colors", dict(
        colors=((0.42, 0.030, 0.42), (0.34, 0.010, 0.40), (0.16, 0.004, 0.26)),
        split=dict(t=0.50, color=_GOLD, hardness=0.85),
        fin_color=(0.30, 0.010, 0.36),
        dorsal=Fin(**_DORSAL, style=dict(
            along_colors=[(0.00, (0.30, 0.010, 0.36), (0.14, 0.004, 0.24)),
                          (0.49, (0.30, 0.010, 0.36), (0.14, 0.004, 0.24)),
                          (0.57, _GOLD, (0.99, 0.86, 0.30)),
                          (1.00, _GOLD, (0.99, 0.86, 0.30))],
            opacity=0.95)),
        anal=Fin(**_ANAL, color=_GOLD),
        caudal=Fin(**_CAUDAL, color=_GOLD))),
    ("everything at once", dict(
        colors=((0.96, 0.52, 0.06), (0.92, 0.30, 0.03), (0.52, 0.10, 0.01)),
        split=dict(t=0.62, color=(0.10, 0.35, 0.72), hardness=0.35),
        stripes=[(0.80, 0.040, _GOLD)],
        bands=[(0.26, 0.040, _WHITE)],
        diagonal_stripes=dict(angle=30.0, spacing=0.060, width=0.30, color=_WHITE,
                              t_range=(0.62, 1.0)),
        spots=dict(count=20.0, size=0.22, coverage=0.5, color=_INK, seed=5.0),
        patches=[dict(center=(0.0335, 0.0, 0.0035), radii=(0.0055, 0.100, 0.0175),
                      color=_INK, softness=0.35)],
        fin_color=(0.94, 0.40, 0.05),
        fin_style=dict(tip_color=(0.99, 0.86, 0.35), edge_color=_INK, edge_width=0.10))),
]


def _slug(label):
    return "".join(c if c.isalnum() else "_" for c in label).strip("_").lower()


def render(index, label, overrides, out_dir, samples):
    """Render one swatch. The index prefixes the filename because punctuation all slugs
    to the same underscore — "angle +40" and "angle -40" are one name otherwise, and the
    second silently overwrites the first, which reads as a marking that ignores its
    parameter rather than as two files with one name."""
    params = dict(_BODY)
    params.update(overrides)
    studio.reset_scene()
    studio.setup_render(resolution=(620, 520), samples=samples)
    build(Species(name=_slug(label), **params))
    studio.studio_lights(radius=params["length"] * 3.0)
    return studio.render_views(out_dir, views=[("side", -90.0, 0.0)],
                               prefix=f"{index:02d}_{_slug(label)}")[0]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default=os.path.join(_REPO, "build", "markings"))
    parser.add_argument("--only", default=None, help="substring of the swatch label")
    parser.add_argument("--samples", type=int, default=48)
    parser.add_argument("--columns", type=int, default=4)
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    args = parser.parse_args(argv)

    wanted = [(index, label, overrides)
              for index, (label, overrides) in enumerate(_SWATCHES)
              if not args.only or args.only.lower() in label.lower()]
    if not wanted:
        raise SystemExit(f"[markings] no swatch matches {args.only!r}")

    entries = [(render(index, label, overrides, args.out, args.samples), label)
               for index, label, overrides in wanted]
    sheet = gallery.build_sheet(entries, os.path.join(args.out, "swatches.png"),
                                columns=min(args.columns, len(entries)), cell=(620, 560))
    print(f"[markings] {len(entries)} swatches: {sheet}")


if __name__ == "__main__":
    main()
