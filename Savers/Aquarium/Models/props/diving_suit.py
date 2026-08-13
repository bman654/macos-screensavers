"""A standard diving dress — Mark V bonnet, corselet, canvas suit and weighted boots.

Pose: standing, planted on the sand, facing -Y.

Standing, not slumped. The tank places props independently, so a slumped figure would
have to lean on a rock that may not be drawn beside it, and one leaning on nothing reads
as a bug rather than as a wreck detail. Standing also keeps the helmet at the top of the
silhouette, which is the shape that identifies this prop at screensaver size.

The stance is deliberately asymmetric — one boot forward and turned out, the faceplate
tilted down — because a symmetric figure with a level head reads as a shop mannequin.

The helmet is most of the model's budget: bonnet, neck ring, corselet with its bolt ring,
a front port with a heavy flange and twelve wing nuts, two side ports, a top port, and the
air inlet elbow the hose leaves from.
"""

import random
from math import cos, pi, radians, sin, sqrt, tau

import bmesh
import bpy
from mathutils import Matrix, Vector

from saverlib import (
    BRASS, TARNISH, VERDIGRIS, Noise, Profile, SweptTube, assign, beveled_box,
    bounding_radius, glass_material, metal_material, revolve, rock, rock_material,
    shade_smooth,
)

from ._spec import Prop

# Everything is authored in world metres with the boot soles on z = 0, so these are the
# figure's real dimensions and the manifest below can simply quote them.
LEG_TOP = 0.960
TORSO_BASE = 0.740
CORSELET_BASE = 1.190
CORSELET_HEIGHT = 0.140
# The bonnet deliberately does not sit straight down on the corselet. Leaving four
# centimetres of neck ring showing between the two is what stops the helmet reading as a
# ball balanced on a cone.
BONNET_BASE = 1.362
BONNET_HEIGHT = 0.272

# The corselet is an oval plate, wide across the shoulders and shallow front to back,
# tapering to a circular neck ring. `revolve` only makes circles, so the oval is baked
# into the vertices afterwards — never onto the object's scale.
CORSELET_OVAL = 0.68

# A barrel that rolls over at the crown. The first pass domed from half height and the
# result read as a bald head rather than as a helmet: what makes a Mark V bonnet a bonnet
# is that it stays at full diameter well past the ports before it turns over.
BONNET_OUTLINE = [
    (0.104, 0.000), (0.132, 0.018), (0.148, 0.042), (0.154, 0.074),
    (0.156, 0.112), (0.155, 0.150), (0.150, 0.186), (0.137, 0.218),
    (0.108, 0.246), (0.062, 0.264), (0.000, BONNET_HEIGHT),
]
_BONNET_RADIUS = Profile([(height, radius) for radius, height in BONNET_OUTLINE])


def _on_bonnet(from_height, direction, sink=0.010):
    """Where a ray leaving the helmet's axis crosses the bonnet's surface.

    Placing ports by guessing a standoff buried the top one inside the dome. The dome is a
    known surface of revolution, so bisect on the ray parameter until the distance from the
    axis matches the outline's radius at that height, then step back `sink` so the port's
    collar seats in the shell rather than balancing on it.
    """
    out = Vector(direction).normalized()
    origin = Vector((0.0, 0.0, BONNET_BASE + from_height))

    def outside(distance):
        point = origin + out * distance
        horizontal = sqrt(point.x * point.x + point.y * point.y)
        return horizontal >= _BONNET_RADIUS(point.z - BONNET_BASE)

    near, far = 0.0, 0.6
    for _ in range(40):
        middle = 0.5 * (near + far)
        if outside(middle):
            far = middle
        else:
            near = middle
    return origin + out * (0.5 * (near + far) - sink)


# -- small mesh plumbing --------------------------------------------------------------


def _from_bmesh(name, bm, bevel=0.0, sharp_angle=34.0):
    """Link a hand-built bmesh with the same shading treatment `hardsurface` gives."""
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    shade_smooth(mesh)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    if bevel > 0.0:
        edge = obj.modifiers.new("Bevel", "BEVEL")
        edge.width = bevel
        edge.segments = 2
        edge.limit_method = "ANGLE"
        edge.angle_limit = radians(30.0)
        edge.use_clamp_overlap = True
    split = obj.modifiers.new("EdgeSplit", "EDGE_SPLIT")
    split.split_angle = radians(sharp_angle)
    split.use_edge_angle = True
    split.use_edge_sharp = False
    return obj


def _curve(points):
    """A smooth path callable through control points, parameterized by chord length.

    Each axis is a monotone cubic, which cannot overshoot — that is what keeps the air
    hose from dipping below the sand between two control points that both sit on it.
    """
    pts = [Vector(p) for p in points]
    lengths = [0.0]
    for a, b in zip(pts, pts[1:]):
        lengths.append(lengths[-1] + (b - a).length)
    total = max(lengths[-1], 1e-9)
    ts = [d / total for d in lengths]
    axes = [Profile([(t, p[i]) for t, p in zip(ts, pts)]) for i in range(3)]
    return lambda t: Vector((axes[0](t), axes[1](t), axes[2](t)))


def _oval(obj, factor):
    """Squash the mesh along Y, where `factor` is a callable of the local height.

    Baked into the vertices rather than left on the object: a scale on a parent stretches
    the space its children live in and arrives in SceneKit as wrong units.
    """
    for vert in obj.data.vertices:
        vert.co.y *= factor(vert.co.z)


def _fabric(obj, seed, ring_period=0.075, ring_depth=0.008, drape=0.008,
            feature=0.30, subdivide=0):
    """Turn a smooth swept form into slack canvas, in place.

    `displace` alone gives isotropic lumps, which reads as a dented metal mannequin. Heavy
    canvas concertinas into rings that run around a limb and wander as they go, so the
    offset is a noise-warped ring term plus a broad drape, faded out where the surface
    faces up or down so caps and shoulders do not corrugate.
    """
    noise = Noise(seed * 613 + 29)
    warp = Noise(seed * 617 + 71)
    radius = max(bounding_radius(obj), 1e-6)

    bm = bmesh.new()
    bm.from_mesh(obj.data)
    if subdivide > 0:
        bmesh.ops.subdivide_edges(bm, edges=bm.edges[:], cuts=int(subdivide),
                                  use_grid_fill=True)
    bm.normal_update()

    scale = 1.0 / (feature * radius)
    for vert in bm.verts:
        p = vert.co * scale
        broad = noise.fbm(p.x, p.y, p.z, octaves=3, gain=0.52)
        phase = vert.co.z / ring_period + 0.85 * warp.fbm(
            vert.co.x * 4.0, vert.co.y * 4.0, vert.co.z * 0.8, octaves=2)
        flank = 1.0 - abs(vert.normal.z)
        offset = drape * broad + ring_depth * sin(tau * phase) * flank * flank
        vert.co = vert.co + vert.normal * offset

    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    bm.to_mesh(obj.data)
    bm.free()
    obj.data.update()
    return obj


# -- fasteners ------------------------------------------------------------------------


def _ring_frames(frame, count, radius, height, oval=1.0, phase=0.0):
    """Placement matrices evenly spaced around a circle in `frame`'s XY plane."""
    frames = []
    for i in range(count):
        angle = phase + tau * i / count
        offset = Vector((radius * cos(angle), radius * oval * sin(angle), height))
        frames.append(frame @ Matrix.Translation(offset)
                      @ Matrix.Rotation(angle, 4, "Z"))
    return frames


def _studs(name, frames, head=0.010, height=0.011, sides=6, wings=None, seed=0):
    """A ring of fasteners in one mesh: hex bolt heads, or wing nuts if `wings` is a span.

    They share a mesh rather than being one object each because the prop is joined before
    baking anyway. Each pair of wings takes its own seeded rotation — a ring of identically
    aligned wing nuts reads as a machined moulding, and real ones were tightened by hand.
    """
    rng = random.Random(seed * 733 + 19)
    bm = bmesh.new()
    for placement in frames:
        bmesh.ops.create_cone(
            bm, cap_ends=True, cap_tris=False, segments=sides,
            radius1=head, radius2=head * 0.88, depth=height,
            matrix=placement @ Matrix.Translation((0.0, 0.0, height * 0.5)))
        if wings:
            # A thin upright plate, not a bar: given a square-ish section the wings bevel
            # and smooth into beads, and beads are decoration rather than a fastener.
            bmesh.ops.create_cube(bm, size=1.0, matrix=(
                placement @ Matrix.Translation((0.0, 0.0, height * 0.62))
                @ Matrix.Rotation(rng.uniform(0.0, pi), 4, "Z")
                @ Matrix.Diagonal((wings, head * 0.52, height * 0.72, 1.0))))
    return _from_bmesh(name, bm, bevel=head * 0.14, sharp_angle=26.0)


# -- ports ----------------------------------------------------------------------------


def _port_frame(from_height, direction, sink):
    """A matrix whose +Z points out of the bonnet at the port's mounting plane."""
    out = Vector(direction).normalized()
    rotation = out.to_track_quat("Z", "Y").to_matrix().to_4x4()
    return Matrix.Translation(_on_bonnet(from_height, out, sink)) @ rotation


def _port(prefix, frame, aperture, flange, boss_depth, nuts, brass, glass, dark,
          seed, wings=False):
    """One circular window: a sunken boss, a dark interior, glass, a flange and fasteners.

    The boss is not decoration. A flat ring pressed against a 0.29 m bonnet stands a
    couple of centimetres off the shell at its rim, and a ring floating over a visible gap
    is worse than no port at all. A real helmet solves it the same way: the glass ring
    screws to a raised collar, so the collar is modelled and sunk into the dome.
    """
    outer = aperture + flange
    inset = boss_depth * 0.55
    lip_base = flange * 0.52

    # The collar, sunk back into the dome. Open at both ends with a wall thickness, so
    # the camera never sees a zero-width sheet where it meets the bonnet.
    boss = revolve(f"{prefix}_boss",
                   [(outer * 0.97, -boss_depth), (outer * 0.99, -boss_depth * 0.35),
                    (outer, 0.0)],
                   segments=40, rings=4, interpolation="linear", cap_bottom=False,
                   cap_top=False, thickness=flange * 0.55, sharp_angle=30.0)
    # Something dark behind the glass. Without it the port shows the brass dome through a
    # tinted lens and reads as a bulge, not as a window into an empty helmet.
    backing = revolve(f"{prefix}_interior",
                      [(aperture * 1.06, -inset), (aperture * 1.02, -inset + 0.004),
                       (aperture * 0.72, -inset + 0.011), (0.0, -inset + 0.015)],
                      segments=36, rings=6, cap_bottom=True, sharp_angle=40.0)
    pane = revolve(f"{prefix}_glass",
                   [(aperture * 1.01, 0.002), (aperture * 1.01, 0.007),
                    (aperture * 0.80, 0.014), (0.0, 0.018)],
                   segments=40, rings=8, cap_bottom=True, sharp_angle=40.0)
    # The retaining ring: a flat plate the wing nuts bear on, plus a raised inner lip that
    # actually holds the glass. Two lathes because the lip is a crease and the plate is a
    # face; one smooth outline through both would round the step away.
    plate = revolve(f"{prefix}_flange",
                    [(outer, 0.0), (outer, flange * 0.44), (outer * 0.985, flange * 0.52)],
                    segments=44, rings=3, interpolation="linear", cap_bottom=False,
                    cap_top=False, thickness=flange, sharp_angle=30.0)
    lip = revolve(f"{prefix}_lip",
                  [(aperture + flange * 0.34, lip_base),
                   (aperture + flange * 0.34, lip_base + flange * 0.38),
                   (aperture + flange * 0.22, lip_base + flange * 0.52)],
                  segments=40, rings=3, interpolation="linear", cap_bottom=False,
                  cap_top=False, thickness=flange * 0.30, sharp_angle=30.0)

    parts = [boss, backing, pane, plate, lip]
    for part, material in zip(parts, (brass, dark, glass, brass, brass)):
        part.matrix_world = frame
        assign(part, material)

    fasteners = _studs(
        f"{prefix}_studs",
        _ring_frames(frame, nuts, outer - flange * 0.34, flange * 0.50),
        head=flange * 0.30 if wings else flange * 0.26,
        height=flange * 0.70 if wings else flange * 0.40,
        sides=12 if wings else 6, wings=flange * 1.25 if wings else None, seed=seed)
    assign(fasteners, brass)
    parts.append(fasteners)
    return parts


# -- the helmet -----------------------------------------------------------------------


def _bonnet(brass):
    obj = revolve("bonnet", BONNET_OUTLINE, segments=52, rings=30, cap_bottom=True,
                  sharp_angle=42.0)
    obj.location.z = BONNET_BASE
    assign(obj, brass)
    return obj


def _neck_ring(brass):
    """The interrupted-thread collar the bonnet locks into, with its lug band."""
    collar = revolve(
        "neck_ring",
        [(0.106, 0.000), (0.117, 0.010), (0.117, 0.042), (0.104, 0.050),
         (0.104, 0.062)],
        segments=48, rings=4, interpolation="linear", cap_bottom=False, cap_top=False,
        thickness=0.013, sharp_angle=28.0,
    )
    collar.location.z = BONNET_BASE - 0.040
    assign(collar, brass)

    frame = Matrix.Translation((0.0, 0.0, BONNET_BASE - 0.030))
    lugs = _studs("neck_lugs", _ring_frames(frame, 8, 0.114, 0.0),
                  head=0.013, height=0.017, sides=4)
    assign(lugs, brass)
    return [collar, lugs]


def _corselet_oval(local_z):
    """Wide oval at the shoulders, circular by the time it reaches the neck ring."""
    t = min(1.0, max(0.0, (local_z - 0.028) / 0.090))
    return CORSELET_OVAL + (1.0 - CORSELET_OVAL) * (t * t * (3.0 - 2.0 * t))


def _corselet(brass):
    """The flanged breastplate the bonnet bolts onto.

    The bottom flange is its own flat ring, not a step in the breastplate's outline. As
    part of the lathe its bolt heads had to sit on a sloping cone, ended up inside the
    shell and vanished; a horizontal washer gives them a face to stand on, which is also
    how the real thing clamps the canvas.
    """
    flange = revolve(
        "corselet_flange", [(0.238, 0.000), (0.238, 0.016)],
        segments=52, rings=2, interpolation="linear", cap_bottom=False, cap_top=False,
        thickness=0.046, sharp_angle=30.0,
    )
    _oval(flange, lambda z: CORSELET_OVAL)
    flange.location.z = CORSELET_BASE
    assign(flange, brass)

    plate = revolve(
        "corselet",
        [(0.213, 0.010), (0.209, 0.032), (0.197, 0.056), (0.172, 0.080),
         (0.140, 0.102), (0.112, 0.122), (0.094, 0.134), (0.092, CORSELET_HEIGHT)],
        segments=52, rings=22, interpolation="linear",
        cap_bottom=False, cap_top=False, thickness=0.012, sharp_angle=34.0,
    )
    _oval(plate, _corselet_oval)
    plate.location.z = CORSELET_BASE
    assign(plate, brass)

    bolts = _studs(
        "corselet_bolts",
        _ring_frames(Matrix.Translation((0.0, 0.0, CORSELET_BASE + 0.015)),
                     16, 0.216, 0.0, oval=CORSELET_OVAL),
        head=0.012, height=0.013)
    assign(bolts, brass)

    # A second, smaller ring of studs on the breast, where the bonnet's clamps land.
    studs = _studs(
        "corselet_studs",
        _ring_frames(Matrix.Translation((0.0, 0.0, CORSELET_BASE + 0.058)),
                     10, 0.182, 0.0, oval=0.74, phase=0.31),
        head=0.009, height=0.010)
    assign(studs, brass)
    return [flange, plate, bolts, studs]


def _inlet(brass):
    """The air inlet elbow at the back of the bonnet, and the hose start it hands off."""
    heading = Vector((sin(radians(46.0)), cos(radians(46.0)), 0.0))
    root = _on_bonnet(0.050, heading, sink=0.018)
    end = Vector((0.152, 0.180, 1.322))
    path = _curve([
        root,
        root + heading * 0.042 + Vector((0.0, 0.0, 0.003)),
        Vector((0.142, 0.152, 1.378)),
        end,
    ])
    elbow = SweptTube(path, Profile([(0.0, 0.031), (0.45, 0.026), (1.0, 0.028)]),
                      rings=20, segments=16, rounded_caps=(False, False))
    obj = elbow.build("inlet_elbow", subsurf=1)
    assign(obj, brass)

    collar = revolve("inlet_collar",
                     [(0.036, 0.000), (0.036, 0.014), (0.033, 0.018)],
                     segments=24, rings=3, interpolation="linear",
                     cap_bottom=False, cap_top=False, thickness=0.008, sharp_angle=30.0)
    tangent = elbow.tangent(0.98)
    collar.matrix_world = (Matrix.Translation(end - tangent * 0.016)
                           @ tangent.to_track_quat("Z", "Y").to_matrix().to_4x4())
    assign(collar, brass)
    return [obj, collar], end, tangent


# -- the suit -------------------------------------------------------------------------


def _torso(seed, canvas):
    # The crotch sits low. A coverall's is lower than a body's to begin with, and the
    # first pass put it at 58% of the figure's height, which reads as a small torso on
    # long legs — a child's proportions, not a diver's.
    obj = revolve(
        "torso",
        [(0.140, 0.000), (0.178, 0.055), (0.196, 0.130), (0.199, 0.200),
         (0.194, 0.270), (0.186, 0.340), (0.176, 0.400), (0.166, 0.450),
         (0.146, 0.482), (0.108, 0.500)],
        segments=40, rings=28, cap_bottom=True, cap_top=True, sharp_angle=48.0,
    )
    _oval(obj, lambda z: 0.72)
    # A shallower, longer-wavelength corrugation than the limbs get. The first pass used
    # the same numbers everywhere and the chest came out looking like a ribbed pullover:
    # a torso is a big surface, so folds that read as canvas on a sleeve read as knitwear
    # when they are repeated twenty times across a chest.
    _fabric(obj, seed + 3, ring_period=0.115, ring_depth=0.0055, drape=0.013,
            feature=0.30, subdivide=1)
    obj.location.z = TORSO_BASE
    assign(obj, canvas)
    return obj


def _weight_belt(brass, lead, strap):
    """Belt and lead weights at the waist.

    Not decoration: without it the suit is one continuous grey mass from the corselet to
    the boots, and a mass that size with nothing crossing it reads as a sack.
    """
    band = revolve(
        "weight_belt",
        [(0.204, 0.000), (0.210, 0.012), (0.210, 0.062), (0.204, 0.074)],
        segments=44, rings=6, interpolation="linear", cap_bottom=False, cap_top=False,
        thickness=0.016, sharp_angle=30.0,
    )
    _oval(band, lambda z: 0.74)
    band.location.z = 0.972
    assign(band, strap)

    # Two slabs, front and back, not a ring of small ones. A ring read as patch pockets on
    # a utility belt; a Mark V belt carried two big lead plates and that is also the shape
    # that survives being 40 pixels tall.
    pieces = [band]
    for face in (-1.0, 1.0):
        slab = beveled_box(f"belt_weight_{'f' if face < 0 else 'b'}",
                           size=(0.188, 0.054, 0.118), bevel=0.20, segments=3)
        slab.matrix_world = Matrix.Translation((0.0, face * 0.148, 1.010))
        assign(slab, lead)
        pieces.append(slab)

    buckle = beveled_box("belt_buckle", size=(0.086, 0.030, 0.062), bevel=0.24,
                         segments=3)
    buckle.matrix_world = Matrix.Translation((0.014, -0.174, 1.008))
    assign(buckle, brass)
    pieces.append(buckle)
    return pieces


def _leg(side, forward, seed, canvas):
    """One trouser leg. The top is a dome buried inside the torso, not a visible disc."""
    x = side * 0.086
    path = _curve([
        (x, 0.030, LEG_TOP),
        (x * 1.12, 0.010 + forward * 0.25, 0.760),
        (x * 1.20, -0.008 + forward * 0.62, 0.480),
        (x * 1.22, -0.014 + forward, 0.260),
        (x * 1.22, -0.016 + forward, 0.150),
    ])
    tube = SweptTube(
        path,
        Profile([(0.0, 0.082), (0.10, 0.112), (0.34, 0.106), (0.62, 0.092),
                 (0.88, 0.077), (1.0, 0.072)]),
        rings=26, segments=18, rounded_caps=(True, False),
    )
    obj = tube.build(f"leg_{'r' if side > 0 else 'l'}", subsurf=1)
    _fabric(obj, seed + (7 if side > 0 else 11), ring_period=0.070, ring_depth=0.0062,
            drape=0.007, feature=0.26)
    assign(obj, canvas)
    return obj


def _arm(side, seed, canvas, reach, brass):
    """One sleeve, hanging with a slight bend. `reach` swings the cuff forward."""
    x = side * 0.174
    path = _curve([
        (x, 0.012, 1.135),
        (x * 1.06, 0.004, 1.030),
        (x * 1.12, -0.020 - reach * 0.30, 0.900),
        (x * 1.10, -0.048 - reach * 0.75, 0.786),
        (x * 1.06, -0.058 - reach, 0.730),
    ])
    tube = SweptTube(
        path,
        Profile([(0.0, 0.068), (0.14, 0.082), (0.48, 0.072), (0.82, 0.062),
                 (1.0, 0.057)]),
        rings=22, segments=16, rounded_caps=(True, False),
    )
    obj = tube.build(f"arm_{'r' if side > 0 else 'l'}", subsurf=1)
    _fabric(obj, seed + (13 if side > 0 else 17), ring_period=0.052, ring_depth=0.0050,
            drape=0.005, feature=0.26)
    assign(obj, canvas)

    # The brass cuff the glove clamps to. It also gives the sleeve an end, which stops the
    # arm reading as one continuous tube from the shoulder to the hand.
    tag = "r" if side > 0 else "l"
    cuff = revolve(f"cuff_{tag}",
                   [(0.066, 0.000), (0.069, 0.008), (0.069, 0.030), (0.066, 0.038)],
                   segments=28, rings=4, interpolation="linear",
                   cap_bottom=False, cap_top=False, thickness=0.010, sharp_angle=30.0)
    along = tube.tangent(1.0)
    cuff.matrix_world = (Matrix.Translation(tube.point(1.0) - along * 0.034)
                         @ along.to_track_quat("Z", "Y").to_matrix().to_4x4())
    assign(cuff, brass)

    # A gloved fist: a lump, not a hand. At screensaver size a modelled hand costs a lot
    # of geometry to look worse than a mitt does.
    fist = rock(f"hand_{tag}", radius=0.062, angularity=0.0,
                seed=seed * 31 + (5 if side > 0 else 9), detail=3,
                lumpiness=0.24, flatten=0.10)
    for vert in fist.data.vertices:
        vert.co.z *= 1.32
    fist.location = Vector((x * 1.05, -0.062 - reach, 0.694))
    assign(fist, canvas)
    return [obj, cuff, fist]


def _boot(side, forward, toe_out, seed, canvas, brass):
    """A weighted boot: brass sole plate, brass toe cap and ankle band, leather upper.

    Deliberately oversized: sized off a human foot they read as two plates the figure
    happened to be standing on, and the point of these boots is that they are lead-soled
    bricks the diver could barely lift.
    """
    tag = "r" if side > 0 else "l"
    # The whole boot is placed with one matrix, and each piece's own offset goes into that
    # matrix rather than into `.location`. Composing against `piece.matrix_world` instead
    # silently loses the offset: `matrix_world` is only recomputed on a depsgraph update,
    # so it still reads as the identity for an object assigned a location this tick.
    placement = (Matrix.Translation((side * 0.106, forward, 0.0))
                 @ Matrix.Rotation(radians(-side * toe_out), 4, "Z"))

    def place(obj, offset):
        obj.matrix_world = placement @ Matrix.Translation(offset)
        return obj

    sole = beveled_box(f"boot_sole_{tag}", size=(0.168, 0.322, 0.034),
                       bevel=0.28, segments=3)
    assign(sole, brass)

    upper = beveled_box(f"boot_upper_{tag}", size=(0.160, 0.238, 0.152),
                        bevel=0.34, segments=4)
    _fabric(upper, seed + (23 if side > 0 else 29), ring_period=0.048,
            ring_depth=0.0035, drape=0.004, feature=0.40, subdivide=1)
    assign(upper, canvas)

    cap = beveled_box(f"boot_toe_{tag}", size=(0.166, 0.142, 0.102),
                      bevel=0.40, segments=4)
    assign(cap, brass)

    band = beveled_box(f"boot_band_{tag}", size=(0.162, 0.198, 0.032),
                       bevel=0.32, segments=3)
    assign(band, brass)

    return [
        place(sole, (0.0, 0.0, 0.017)),
        place(upper, (0.0, 0.036, 0.106)),
        place(cap, (0.0, -0.106, 0.066)),
        place(band, (0.0, 0.036, 0.190)),
    ]


# -- hose and lifeline ----------------------------------------------------------------


def _hose(start, tangent, seed, rubber, rope_material):
    """The air hose, and the lifeline that was bound to it.

    A hose that sags to the sand and snakes away past the diver does more storytelling
    than any amount of detail on the suit — it says the other end of this used to be
    somewhere. Kept low and close so the footprint stays something placement can reason
    about.
    """
    rng = random.Random(seed * 149 + 3)
    lie = 0.030 + rng.uniform(-0.002, 0.002)
    control = [
        Vector(start),
        Vector(start) + tangent * 0.070,
        Vector((0.242, 0.312, 1.120)),
        Vector((0.302, 0.398, 0.720)),
        Vector((0.336, 0.418, 0.330)),
        Vector((0.362, 0.372, 0.074)),
        Vector((0.412, 0.212, lie)),
        Vector((0.486, -0.010, lie)),
        Vector((0.468, -0.238, lie)),
        Vector((0.352, -0.392, lie)),
        Vector((0.196, -0.446, lie)),
    ]
    hose = SweptTube(_curve(control),
                     Profile([(0.0, 0.027), (0.5, 0.026), (1.0, 0.025)]),
                     rings=88, segments=14, rounded_caps=(False, True))
    tube = hose.build("air_hose", subsurf=1)
    assign(tube, rubber)

    # The lifeline runs alongside, tied to the hose the way it always was. Offsetting the
    # same control points keeps the two reading as one bundle instead of two hoses.
    offset = [p + Vector((-0.031, -0.024, 0.0)) for p in control[2:-2]]
    offset[0] = control[2] + Vector((-0.022, -0.020, -0.012))
    line = SweptTube(_curve([control[1] + Vector((-0.010, -0.014, -0.012))] + offset),
                     Profile([(0.0, 0.012), (1.0, 0.011)]),
                     rings=52, segments=10, rounded_caps=(False, True))
    rope = line.build("lifeline", subsurf=1)
    for vert in rope.data.vertices:
        vert.co.z = max(vert.co.z, 0.013)
    assign(rope, rope_material)
    return [tube, rope]


# -- materials ------------------------------------------------------------------------


def _materials(seed):
    """Brass that has been down a long time, and canvas built out of `rock_material`.

    There is no canvas material in `surfaces.py` and none was written. `wood_material` is
    the wrong shape — its grain is a directional streak along object X, which runs across a
    limb swept along Z and turns a sleeve into planking. `rock_material` has the broad tonal
    drift, mid-frequency mottle and roughness break-up that heavy weave shows at this distance.
    """
    # A true metal bake makes pre-dulling compound the blue environment tint. Corrosion
    # supplies the age; brighter shared brass preserves the helmet's identifying highlight.
    brass = metal_material(f"suit_brass_{seed}", size=0.22, base=BRASS,
                           corrosion=0.38, patina=VERDIGRIS, roughness=0.26,
                           algae=0.32, seed=seed)
    ground_brass = metal_material(f"suit_brass_low_{seed}", size=0.16,
                                  base=(0.31, 0.205, 0.070), corrosion=0.50,
                                  patina=VERDIGRIS, roughness=0.32, algae=0.46,
                                  seed=seed + 4)
    canvas = rock_material(f"suit_canvas_{seed}", size=0.55,
                           base=(0.030, 0.028, 0.021), secondary=(0.068, 0.060, 0.043),
                           speckle=0.08, roughness=0.92, algae=0.30, seed=seed + 2)
    boot_canvas = rock_material(f"suit_leather_{seed}", size=0.24,
                                base=(0.019, 0.016, 0.012),
                                secondary=(0.046, 0.038, 0.028),
                                speckle=0.05, roughness=0.86, algae=0.44, seed=seed + 6)
    # Low grime on purpose: at 0.6 the silt film covered the whole pane and the port read
    # as a grey stone disc. A faceplate has to stay dark and specular or it stops being a
    # window, so the silt is thinned and the tint carries the age instead.
    glass = glass_material(f"suit_glass_{seed}", size=0.12,
                           tint=(0.018, 0.052, 0.042), roughness=0.08, grime=0.34,
                           waviness=0.45, algae=0.16, seed=seed + 8)
    interior = rock_material(f"suit_interior_{seed}", size=0.10,
                             base=(0.0035, 0.0038, 0.0042),
                             secondary=(0.009, 0.010, 0.011),
                             speckle=0.0, roughness=0.90, algae=0.0, seed=seed + 10)
    rubber = rock_material(f"suit_hose_{seed}", size=0.30,
                           base=(0.016, 0.015, 0.014), secondary=(0.038, 0.036, 0.031),
                           speckle=0.04, roughness=0.72, algae=0.46, seed=seed + 12)
    rope = rock_material(f"suit_rope_{seed}", size=0.12,
                         base=(0.048, 0.040, 0.024), secondary=(0.092, 0.078, 0.048),
                         speckle=0.12, roughness=0.94, algae=0.50, seed=seed + 14)
    lead = metal_material(f"suit_lead_{seed}", size=0.16, base=(0.075, 0.076, 0.080),
                          corrosion=0.55, patina=TARNISH, roughness=0.52,
                          algae=0.42, seed=seed + 16)
    return {
        "brass": brass, "ground_brass": ground_brass, "canvas": canvas,
        "boot": boot_canvas, "glass": glass, "interior": interior,
        "rubber": rubber, "rope": rope, "lead": lead,
    }


# -- assembly -------------------------------------------------------------------------


def build(seed=0):
    rng = random.Random(seed * 941 + 7)
    mats = _materials(seed)
    root = bpy.data.objects.new("decor_diving_suit", None)
    bpy.context.collection.objects.link(root)

    parts = []
    parts.append(_bonnet(mats["brass"]))
    parts.extend(_neck_ring(mats["brass"]))
    parts.extend(_corselet(mats["brass"]))

    # The front port is tilted down: the faceplate of a helmet on a standing diver is not
    # level, and a level one gives the figure a blank, forward stare that reads as a bust.
    parts.extend(_port(
        "faceplate",
        _port_frame(0.126, (0.0, -cos(radians(9.0)), -sin(radians(9.0))), 0.016),
        aperture=0.060, flange=0.034, boss_depth=0.048, nuts=12,
        brass=mats["brass"], glass=mats["glass"], dark=mats["interior"],
        seed=seed, wings=True,
    ))
    for side in (-1.0, 1.0):
        parts.extend(_port(
            f"side_port_{'r' if side > 0 else 'l'}",
            _port_frame(0.118, (side * cos(radians(20.0)), -sin(radians(20.0)), 0.0),
                        0.012),
            aperture=0.038, flange=0.021, boss_depth=0.030, nuts=8,
            brass=mats["brass"], glass=mats["glass"], dark=mats["interior"], seed=seed,
        ))
    parts.extend(_port(
        "top_port",
        _port_frame(0.090, (0.0, -sin(radians(36.0)), cos(radians(36.0))), 0.012),
        aperture=0.034, flange=0.020, boss_depth=0.030, nuts=8,
        brass=mats["brass"], glass=mats["glass"], dark=mats["interior"], seed=seed,
    ))

    inlet, hose_start, hose_tangent = _inlet(mats["brass"])
    parts.extend(inlet)
    parts.extend(_hose(hose_start, hose_tangent, seed, mats["rubber"], mats["rope"]))

    parts.append(_torso(seed, mats["canvas"]))
    parts.extend(_weight_belt(mats["ground_brass"], mats["lead"], mats["rubber"]))

    # Asymmetric stance: the left boot is planted forward and turned further out. A figure
    # standing to attention is the mannequin failure this whole prop has to avoid.
    stance = [(1.0, -0.012 + rng.uniform(-0.01, 0.01), 7.0),
              (-1.0, -0.086 + rng.uniform(-0.02, 0.02), 13.0)]
    for side, forward, toe_out in stance:
        parts.append(_leg(side, forward, seed, mats["canvas"]))
        parts.extend(_boot(side, forward, toe_out, seed, mats["boot"],
                           mats["ground_brass"]))
    for side, reach in ((1.0, 0.012), (-1.0, 0.046)):
        parts.extend(_arm(side, seed, mats["canvas"], reach, mats["ground_brass"]))

    for part in parts:
        part.parent = root
    return root


DIVING_SUIT = Prop(
    name="diving_suit",
    build=build,
    category="decoration",
    # Measured off the built mesh, not the nominal numbers above: the hose reaches 0.563 m
    # from the axis and the crown 1.640 m once displacement and bevels are evaluated. These
    # have to bound the geometry the tank gets, or placement drops a boulder on the hose.
    footprint=0.58,
    height=1.65,
    tilt_range=(-3.0, 3.0),
    # Placed at roughly two thirds of true size, which is deliberate and worth defending.
    # Authored at human scale it stood 1.65 m — the second tallest thing in the library,
    # over the 1.3 m arch and nearly twice the wreck's height — and a figure reads far larger
    # than terrain of the same size, so it towered over the scene it was meant to decorate.
    # The rest of the library is ornament scaled to the frame rather than to life: the wreck
    # is a boat in miniature and the coral heads are a third of a metre. Keeping the one
    # man-made figure at true scale made it the ruler that showed everything else up.
    # Narrow range still, because a diver is a *recognisable* size even when not a true one.
    scale_range=(0.55, 0.68),
    weight=0.45,
    max_per_scene=1,
    min_spacing=1.25,
    seeds=2,
)
