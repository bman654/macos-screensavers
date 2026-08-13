"""Green moray eel (Gymnothorax funebris)."""

from ._spec import Fin, Species

# Green morays are brown; the green is a yellowish mucus over the skin, so the palette is
# a muddy olive rather than a clean green. The studio key drives irradiance well past 1,
# so these read roughly twice as bright as written — an olive that looks right as a
# number comes out as pale khaki.
_OLIVE_BACK = (0.010, 0.014, 0.005)
_OLIVE_MID = (0.035, 0.043, 0.011)
_OLIVE_BELLY = (0.132, 0.124, 0.040)
_BLOTCH = (0.008, 0.010, 0.005)

MORAY_EEL = Species(
    name="moray_eel",
    length=0.280,
    # A ribbon: about 9x longer than it is deep. The depth is nearly constant from behind
    # the head to two-thirds back, because an eel has no peduncle to taper into — the
    # body simply thins over the last quarter.
    # The nose pole has to stay small. Cosine ring spacing puts the first ring about
    # 0.1 mm behind it, so a fat first control point builds a flat disc there and leaves
    # a crease across the snout that survives subdivision — visible precisely because
    # this is the end of the animal that carries the read. Bluntness comes from the
    # fast rise just behind the tip instead.
    top=[(0.00, 0.0018), (0.008, 0.0058), (0.022, 0.0102), (0.045, 0.0140),
         (0.085, 0.0164), (0.14, 0.0170), (0.28, 0.0166), (0.48, 0.0160),
         (0.66, 0.0142), (0.82, 0.0108), (0.93, 0.0066), (0.975, 0.0032),
         (1.00, 0.0010)],
    bottom=[(0.00, 0.0017), (0.008, 0.0056), (0.024, 0.0100), (0.055, 0.0134),
            (0.10, 0.0146), (0.20, 0.0148), (0.40, 0.0146), (0.60, 0.0132),
            (0.78, 0.0098), (0.91, 0.0058), (0.97, 0.0028), (1.00, 0.0009)],
    # Round at the head, flattening to a blade at the tail: the half-width falls from
    # four-fifths of the half-height to a fifth of it.
    width=[(0.00, 0.0015), (0.008, 0.0046), (0.028, 0.0092), (0.08, 0.0128),
           (0.16, 0.0126), (0.30, 0.0106), (0.50, 0.0076), (0.68, 0.0050),
           (0.84, 0.0030), (0.97, 0.0009), (1.00, 0.0004)],
    spine=[(0.00, -0.0020), (0.12, 0.0006), (0.40, 0.0), (1.00, 0.0)],
    # A cross-section that starts near-circular and ends as a flattened oval. Pushing the
    # rear past ~3.2 makes the ribbon read as a rectangular strap in the studio key.
    exponent=[(0.00, 2.05), (0.16, 2.20), (0.45, 2.70), (0.75, 3.05), (1.00, 3.10)],
    colors=(_OLIVE_BELLY, _OLIVE_MID, _OLIVE_BACK),
    # Matched to the back, not the flank: the fin sits against the darkest part of the
    # body, and anything near the mid tone reads as a bright sail from every angle.
    fin_color=(0.013, 0.017, 0.006),
    outline_width=0.0,
    # Irregular darker shading rather than dots: cells four centimetres across, most of
    # them filled, with the edge softened almost to the cell centre.
    spots=[
        dict(color=_BLOTCH, count=8.0, size=0.62, coverage=0.78, softness=0.50,
             seed=2.0),
        dict(color=(0.086, 0.080, 0.030), count=5.0, size=0.54, coverage=0.55,
             softness=0.62, seed=11.0),
    ],
    patches=[
        # Paired nostril tubes at the snout tip and the small round gill opening well
        # behind the head. Both need a Y radius far past the body half-width or they
        # land on one flank only.
        dict(center=(0.1378, 0.0, 0.0022), radii=(0.0018, 0.100, 0.0020),
             color=(0.008, 0.010, 0.006), softness=0.40),
        dict(center=(0.0930, 0.0, -0.0030), radii=(0.0038, 0.100, 0.0040),
             color=(0.008, 0.010, 0.006), softness=0.50),
        # The gape. `mouth` bakes a fixed reddish flesh colour that reads as a pink
        # smear on an olive body, so the dark jaw line is a patch and `mouth` is left as
        # a thin sliver inside it — a mouth held slightly open rather than a painted lip.
        dict(center=(0.1195, 0.0, -0.0052), radii=(0.0225, 0.100, 0.0046),
             color=(0.003, 0.003, 0.003), softness=0.14),
    ],
    mouth=((0.1180, 0.0, -0.0052), (0.0130, 0.100, 0.0005)),
    # Leathery, scaleless skin: enough bump to break the specular up, not enough to read
    # as scales.
    scale_count=24.0,
    scale_depth=0.035,
    # One continuous fin: a low dorsal ridge from just behind the head to the tail tip,
    # a matching anal fin from the vent back, and a small caudal joining them.
    dorsal=Fin(t0=0.10, t1=1.00,
               span=[(0.00, 0.0008), (0.12, 0.0058), (0.30, 0.0088), (0.58, 0.0096),
                     (0.82, 0.0086), (0.95, 0.0048), (1.00, 0.0016)],
               rake=0.0012, sink=0.20, samples_u=72, samples_v=8),
    # The anal fin starts at the vent. Its onset has to be drawn out over a long stretch
    # of `u`: a short ramp puts a straight leading edge on the membrane and the bottom
    # silhouette steps down as if a piece had been bolted on.
    anal=Fin(t0=0.38, t1=1.00,
             span=[(0.00, 0.0004), (0.14, 0.0016), (0.32, 0.0050), (0.55, 0.0068),
                   (0.80, 0.0062), (0.94, 0.0034), (1.00, 0.0012)],
             rake=0.0012, sink=0.20, samples_u=48, samples_v=8),
    # No paired fins at all, which is most of what makes an eel an eel.
    pectoral=None,
    pelvic=None,
    # Barely a tail: just enough membrane to carry the dorsal and anal ridges around the
    # tip. Anything with a flare reads as a paddle bolted onto the end of a ribbon.
    caudal=Fin(t0=0.0, t1=1.0,
               span=[(0.0, 0.0026), (0.5, 0.0038), (1.0, 0.0026)],
               flare=[(0.0, 0.0), (1.0, 0.0022)],
               samples_u=16, samples_v=8),
    caudal_spread=1.0,
    # The fin membrane is body-coloured — it is skin, not rays — but it needs a narrow
    # pale margin or the continuous ridge disappears into the body silhouette and the
    # eel reads as a cigar.
    fin_style=dict(tip_color=(0.030, 0.032, 0.012),
                   edge_color=(0.155, 0.142, 0.050), edge_width=0.10,
                   opacity=0.99, ray_contrast=0.05),
    eye=(0.052, 0.62, 0.0090),
)
