"""A sea arch: a headland the water has punched a hole through.

The arch exists to be swum *through*. A tank of things a fish routes around is flat; one
opening a fish commits to crossing is what gives the depth axis something to prove. So the
model is two things — a mass of rock, and a declared `Passage` through its hole that the
swimming code can trust.

It is built the way the sea builds one: pile up a headland, then take the middle out. The
mass is a rounded slab the full width of the prop with three lumps banked against its feet,
and one swept solid is subtracted from all four to open the tunnel. Two earlier shapes were
tried and both failed in the render rather than in the numbers: a tube swept along an
arch-shaped path reads as a croissant, because what says *arch* is a wall of rock with a
void in it and not a bent limb; and full-height lumps standing shoulder to shoulder read as
a trilithon, because equals leaning together leave a notch where the span should be.

Punching the hole also gets two details for free that would otherwise need authoring: the
underside of the span is the cutter's surface and so comes out scoured smooth while the top
of it is weathered and pitted; and the opening runs down to the sand rather than sitting on
a sill the fish would have to hop.
"""

import math
import random

import bpy
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

from saverlib import (
    Noise, SweptTube, assign, beveled_box, bounding_radius, displace, rock, rock_material,
)

from ._spec import Passage, Prop

# What the manifest promises. The build measures the real figure for every seed and refuses
# to produce a model that does not honour this, so the number is a floor and not a hope; it
# sits well under the 0.24-0.27 m the three seeds actually measure, because a fish clipping
# through solid rock is far worse than a fish declining a gap it would have made.
PASSAGE_RADIUS = 0.21


# -- mesh plumbing -------------------------------------------------------------------
#
# Every transform below is baked into mesh data rather than left on the object. Scale on a
# parent stretches the space its children live in, and these children include the swim
# waypoints whose whole job is to be in the same metres as the vertices they must clear.


def _extent(obj):
    coords = [vert.co for vert in obj.data.vertices]
    lo = Vector(min(c[i] for c in coords) for i in range(3))
    hi = Vector(max(c[i] for c in coords) for i in range(3))
    return lo, hi


def _move(obj, offset):
    obj.data.transform(Matrix.Translation(Vector(offset)))
    obj.data.update()


def _resize(obj, size):
    """Scale a lump to exact bounding dimensions in metres.

    `rock` randomizes its own axes by up to ±28%, which is the right kind of variety for a
    boulder and the wrong kind for a pier that has to meet a span. Normalizing here keeps
    the seed's randomness in the surface, where it reads, and out of the proportions, where
    it decides whether the arch stands up.
    """
    lo, hi = _extent(obj)
    span = hi - lo
    factors = Vector(size[i] / max(span[i], 1e-6) for i in range(3))
    obj.data.transform(Matrix.Diagonal(factors).to_4x4())
    obj.data.update()
    return obj


def _place(obj, x, y):
    """Put a piece at (x, y) with its lowest vertex exactly on z = 0.

    Exactly on, never below: `build_prop` seats the whole prop by lifting it to its lowest
    vertex, so one half-buried pebble raises the arch off the seabed — and a lifted arch
    shows a sill of rock across the bottom of the opening that the fish has to climb.
    """
    lo, hi = _extent(obj)
    centre = (lo + hi) * 0.5
    return _move(obj, (x - centre.x, y - centre.y, -lo.z))


def _taper(obj, pivot_x, start_z, top_z, narrowing, thinning):
    """Draw a mass in toward its own axis as it rises.

    A headland is wider at the waterline than at the top, and stacking full-width lumps
    without this gives a slab with parallel sides — which, once a hole is cut in it, is a
    doorway. The taper starts partway up rather than at the ground so the feet stay planted
    instead of turning the whole thing into a cone.
    """
    span = max(top_z - start_z, 1e-6)
    for vert in obj.data.vertices:
        t = min(1.0, max(0.0, (vert.co.z - start_z) / span))
        t = t * t * (3.0 - 2.0 * t)
        vert.co.x = pivot_x + (vert.co.x - pivot_x) * (1.0 + (narrowing - 1.0) * t)
        vert.co.y *= 1.0 + (thinning - 1.0) * t
    obj.data.update()
    return obj


def _slant(obj, pivot_x, half_width, high, low):
    """Run the crest down from one end of the mass to the other.

    A slab of even height is a gateway. Real headlands step down toward the sea, and one
    monotone slope across the whole mass does more to break the manufactured reading than
    any amount of noise on its faces — noise changes the surface, this changes the
    silhouette.
    """
    for vert in obj.data.vertices:
        t = min(1.0, max(0.0, (vert.co.x - pivot_x) / (2.0 * half_width) + 0.5))
        vert.co.z *= low + (high - low) * t
    obj.data.update()
    return obj


def _erode(obj, seed, coarse=0.040, pitting=0.020, feature=0.34, scour=0.75,
           shelter=None):
    """Weather a mass of rock, harder on the faces the sea and the light can reach.

    `saverlib.displace` is the same idea with one strength everywhere. Here the fine
    octaves are masked by the vertex normal's Z — `scour` is how much of the pitting is
    withheld from downward faces — because surge polishes an underside and rain, light and
    settling grit pit a top, and pitting both identically is what makes an eroded form read
    merely as a bumpy one.

    `shelter` scales the whole displacement per vertex. The arch uses it to hold the
    weathering back inside the tunnel, which is both what the water does — a bore the surge
    runs through every day is the smoothest surface on the rock — and what keeps a metre of
    low-frequency erosion from quietly closing the passage the prop exists for.
    """
    noise = Noise(seed * 3121 + 17)
    radius = bounding_radius(obj)
    broad = 1.0 / max(feature * radius, 1e-9)
    fine = broad * 4.5
    for vert in obj.data.vertices:
        p = vert.co * broad
        q = vert.co * fine
        up = max(0.0, min(1.0, vert.normal.z * 0.5 + 0.5))
        offset = coarse * radius * noise.fbm(p.x, p.y, p.z, octaves=3, gain=0.55)
        offset += (
            pitting * radius
            * noise.fbm(q.x + 19.0, q.y, q.z, octaves=4)
            * (1.0 - scour + scour * up)
        )
        if shelter is not None:
            offset *= shelter(vert.co)
        vert.co = vert.co + vert.normal * offset
    obj.data.update()
    return obj


def _bake(obj):
    """Replace an object's mesh with its evaluated form and drop the modifier stack."""
    obj.update_tag()
    bpy.context.view_layer.update()
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = bpy.data.meshes.new_from_object(obj.evaluated_get(depsgraph))
    previous = obj.data
    obj.modifiers.clear()
    obj.data = evaluated
    if previous.users == 0:
        bpy.data.meshes.remove(previous)
    return obj


def _shell(name, size, levels=3):
    """A rounded slab with even quad topology, ready to be weathered.

    Subdividing a beveled box's edges directly gives vertices but not *evenly spaced* ones
    — the bevel's corner patches fill as triangle fans, and a centimetre of displacement
    along the normals of those slivers shreds the crest into spikes. A subdivision surface
    produces one uniform quad grid over the whole form instead, which is what makes a large
    low-frequency displacement read as an eroded mass rather than as a broken mesh.
    """
    box = beveled_box(name, size=size, bevel=0.25, segments=2, sharp_angle=None)
    subdivision = box.modifiers.new("Subdivision", "SUBSURF")
    subdivision.levels = levels
    subdivision.render_levels = levels
    _bake(box)
    # Subdivision pulls the surface inside its cage, so the slab comes out smaller than it
    # was asked for. Rescaling to the requested dimensions keeps the caller in metres.
    return _resize(box, size)


def _crease(obj, angle=34.0):
    """Split shading where the rock fractures and leave the water-worn faces smooth."""
    split = obj.modifiers.new("EdgeSplit", "EDGE_SPLIT")
    split.split_angle = math.radians(angle)
    split.use_edge_angle = True
    split.use_edge_sharp = False
    return obj


def _subtract(obj, cutter):
    """Cut `cutter` out of `obj` and leave no modifier behind.

    Evaluated through the depsgraph rather than `modifier_apply`, which needs a selection
    and an active object that a background build does not reliably have. The result has to
    be real geometry before `build` returns: the passage is measured against these
    vertices, and a live modifier would let it be measured against the uncut mass.
    """
    before = _extent(obj)
    boolean = obj.modifiers.new("Sea Cave", "BOOLEAN")
    boolean.operation = "DIFFERENCE"
    boolean.object = cutter
    boolean.solver = "EXACT"

    # Writing to `mesh.transform` or to `mesh.vertices` does not tag the object as changed,
    # so without this the boolean is evaluated against whatever the cutter looked like when
    # it was first linked — before it was stretched, displaced and moved into place. There
    # is no error and no visual tell beyond a hole that is suspiciously tidy.
    cutter.update_tag()
    obj.update_tag()
    bpy.context.view_layer.update()
    depsgraph = bpy.context.evaluated_depsgraph_get()
    cut = bpy.data.meshes.new_from_object(obj.evaluated_get(depsgraph))
    previous = obj.data
    obj.modifiers.clear()
    obj.data = cut
    if previous.users == 0:
        bpy.data.meshes.remove(previous)

    # The exact solver does not report failure; it returns a wrong answer. Given an operand
    # it cannot classify it will hand back the union, or an empty mesh, and both sail
    # through a clearance check — an arch with no rock in it measures beautifully clear. A
    # difference can only ever shrink the bounding box, so that is the invariant to test.
    if not cut.vertices:
        raise RuntimeError(f"the sea cave cut erased '{obj.name}' instead of opening it")
    lo, hi = _extent(obj)
    if (any(lo[i] < before[0][i] - 1e-4 for i in range(3))
            or any(hi[i] > before[1][i] + 1e-4 for i in range(3))):
        raise RuntimeError(
            f"the sea cave cut grew '{obj.name}' rather than opening it, which means the "
            "solver returned a union"
        )
    return obj


# -- passage -------------------------------------------------------------------------


def _solid(objects):
    """One BVH over every piece of the prop, in world space.

    `find_nearest` returns the distance to the nearest *surface*, not to the nearest
    vertex, so a coarse mesh cannot flatter the answer; and the sign of the offset against
    the hit normal says whether a sample is inside the rock at all, which a vertex distance
    can never tell you.
    """
    verts, polys = [], []
    for obj in objects:
        matrix = obj.matrix_world
        base = len(verts)
        verts.extend(matrix @ vert.co for vert in obj.data.vertices)
        polys.extend([index + base for index in poly.vertices] for poly in obj.data.polygons)
    return BVHTree.FromPolygons(verts, polys)


def _line_clearance(tree, x, z, y_half, samples=33):
    """The tightest clearance anywhere along a straight run through the hole.

    Sampled densely along the whole route rather than evaluated at the waypoints, because
    the waypoints are the two places a route is guaranteed to be clear and the mouth of the
    tunnel — where the rock flares in — is where it is not.
    """
    worst = float("inf")
    for i in range(samples):
        point = Vector((x, -y_half + 2.0 * y_half * i / (samples - 1), z))
        location, normal, _, distance = tree.find_nearest(point)
        if location is None:
            continue
        if (point - location).dot(normal) < 0.0:
            return -distance          # inside the rock; never a passage
        worst = min(worst, distance)
    return worst


def _best_line(objects, x_range, z_range, y_half, steps=17):
    """Find the through-line with the largest tightest clearance, and measure it.

    The waypoints cannot be authored as constants. Erosion is seeded, so where the hole is
    widest moves from seed to seed, and a route that was clear on seed 0 can be through rock
    on seed 2. Searching for the best line and then measuring it is the whole difference
    between a declared radius and a true one.
    """
    tree = _solid(objects)
    best = (float("-inf"), 0.0, 0.0)
    for i in range(steps):
        x = x_range[0] + (x_range[1] - x_range[0]) * i / (steps - 1)
        for j in range(steps):
            z = z_range[0] + (z_range[1] - z_range[0]) * j / (steps - 1)
            clearance = _line_clearance(tree, x, z, y_half)
            if clearance > best[0]:
                best = (clearance, x, z)
    return best


def _empty(root, name, location, size=0.05):
    node = bpy.data.objects.new(name, None)
    bpy.context.collection.objects.link(node)
    node.empty_display_type = "SPHERE"
    node.empty_display_size = size
    node.location = location
    node.parent = root
    return node


# -- the arch ------------------------------------------------------------------------


def build(seed=0):
    rng = random.Random(seed * 7717 + 31)
    root = bpy.data.objects.new("decor_rock_arch", None)
    bpy.context.collection.objects.link(root)

    stone = rock_material(
        # `size` is a texture-feature count across this many metres, not the prop's own
        # width. On something more than a metre and a half across, quoting the real width
        # spreads mottling and speckle so thinly that the rock renders as a lit sand dune.
        f"arch_stone_{seed}", size=0.40,
        # `secondary` is the darker of the two on purpose. `rock_material` mixes base into
        # secondary over a broad noise, so a lighter secondary lifts half the surface and
        # the whole prop reads as dry sandstone under the studio key.
        base=(0.068, 0.066, 0.060), secondary=(0.036, 0.038, 0.035),
        speckle=0.52, roughness=0.84, algae=0.45, seed=seed * 31 + 5,
    )
    rubble_stone = rock_material(
        f"arch_rubble_{seed}", size=0.24,
        base=(0.062, 0.060, 0.054), secondary=(0.032, 0.034, 0.031),
        speckle=0.60, roughness=0.88, algae=0.52, seed=seed * 31 + 61,
    )

    # Which side carries the heavy leg alternates with the seed rather than being drawn, so
    # no two exported variants can come out as the same arch mirrored.
    heavy_left = seed % 2 == 0
    side = -1.0 if heavy_left else 1.0

    depth = rng.uniform(0.52, 0.60)              # through the tunnel, and the fish's commit
    hole_x = rng.uniform(-0.05, 0.05)
    # The tunnel's floor sits well below the seabed on purpose. An opening whose bottom is
    # only just under z = 0 meets the rock face at a grazing angle there and the cut leaves
    # a feather edge of stone curving across the bottom of the mouth.
    hole_z = rng.uniform(0.30, 0.34)
    hole_half_x = rng.uniform(0.255, 0.275)
    # Taller than it is wide. An opening as wide as it is high is a porthole; one that runs
    # down into the sand is an arch, and the fish crosses it at whatever height it was
    # already swimming at rather than having to climb a sill.
    hole_half_z = rng.uniform(0.46, 0.50)
    heavy_leg = rng.uniform(0.36, 0.42)
    light_leg = rng.uniform(0.25, 0.30)
    # Taller than it is wide overall. A mass much wider than it is high is a boulder that
    # happens to have a hole in it; the legs have to be long enough to read as legs.
    crest = rng.uniform(1.20, 1.30)

    # One dominant mass with lumps banked against it, never a pile of equals: a single
    # headland the full width of the prop keeps one silhouette, and cutting the hole out of
    # its middle is what leaves the legs behind.
    outer_heavy = hole_x + side * (hole_half_x + heavy_leg)
    outer_light = hole_x - side * (hole_half_x + light_leg)

    mass = []

    def lump(name, size, x, y, angularity, detail=4, pivot=None):
        # `angularity` is deliberately low for anything the cutter touches. Its planar
        # fractures cut a lumpy sphere with `clear_outer`, which on some seeds leaves a
        # surface the exact boolean cannot classify — and the failure is silent: the cut
        # returns the whole mass erased, or the union. The angular reading is recovered
        # afterwards by eroding the cut result. Rubble and crown boulders, which are never
        # cut, keep their fractures.
        piece = rock(name, radius=0.5, angularity=angularity,
                     seed=seed * 1009 + len(mass) * 61 + 7, detail=detail,
                     lumpiness=rng.uniform(0.36, 0.50), flatten=0.0,
                     grain=0.07)
        _resize(piece, size)
        _place(piece, x, y)
        # Tapered about its own axis unless told otherwise. A lump drawn in toward the
        # hole's centre as it rises leans away from the mass at its foot, and what should
        # be rock banked against a leg reads as a flying buttress.
        _taper(piece, hole_x if pivot is None else pivot, size[2] * 0.34, size[2],
               rng.uniform(0.86, 0.94), rng.uniform(0.88, 0.96))
        mass.append(piece)
        return piece

    # The headland is a rounded slab, not a lump. An ellipsoid the full width of the prop
    # thins toward both ends, so once the hole is cut the legs are crescent blades that do
    # not reach the seabed. A box keeps its section out to its corners, which is what a
    # cliff does, and the bevel plus erosion take the manufacture out of it.
    headland = _shell("arch_headland", (abs(outer_heavy - outer_light), depth, crest))
    # A warp of space, not a push along the normals. Displacing a rounded slab along its
    # own normals by more than the radius of its rim folds the surface over and leaves torn
    # flaps down every edge; `along_normal=False` bends the whole mass instead, and cannot
    # fold as long as the amplitude stays well under the feature size.
    displace(headland, strength=0.11, feature_size=0.80, octaves=2,
             seed=seed * 331 + 13, along_normal=False)
    _place(headland, (outer_heavy + outer_light) * 0.5, rng.uniform(-0.02, 0.02))
    _taper(headland, hole_x, crest * 0.30, crest,
           rng.uniform(0.80, 0.88), rng.uniform(0.84, 0.92))
    _slant(headland, hole_x, abs(outer_heavy - outer_light) * 0.5,
           1.0 if heavy_left else rng.uniform(0.76, 0.86),
           rng.uniform(0.76, 0.86) if heavy_left else 1.0)
    mass.append(headland)
    # Shoulders bank against each foot: an ellipsoid alone thins to a wedge at its ends, and
    # a leg that thins toward the seabed is standing on a knife.
    # Each shoulder is kept clear of the widest part of the cutter. A lump that only just
    # reaches into the cut is sliced at a grazing angle and what survives is a thin crescent
    # shell standing off the rock — the single ugliest artefact this prop can produce.
    clear = hole_half_x * 1.30 + 0.06

    def shoulder(name, leg, toward, height, detail):
        inner = hole_x + side * toward * clear
        outer = hole_x + side * toward * (hole_half_x + leg + 0.10)
        centre = (inner + outer) * 0.5
        return lump(name, (abs(outer - inner), depth * rng.uniform(0.86, 0.98), height),
                    centre, rng.uniform(-0.05, 0.05),
                    rng.uniform(0.05, 0.18), detail=detail, pivot=centre)

    # Low and broad, not tall and narrow. These are rock banked against the feet — a
    # shoulder as tall as the leg it leans on reads as a second, thinner spire.
    shoulder("arch_shoulder_heavy", heavy_leg, 1.0, crest * rng.uniform(0.40, 0.50), 4)
    shoulder("arch_shoulder_light", light_leg, -1.0, crest * rng.uniform(0.32, 0.42), 3)
    # A low buttress against the heavy foot. It exists for the silhouette: without something
    # breaking the line at knee height the whole prop reads as one smooth loaf.
    lump("arch_buttress",
         (rng.uniform(0.26, 0.36), depth * rng.uniform(0.62, 0.78), rng.uniform(0.30, 0.46)),
         outer_heavy + side * rng.uniform(0.04, 0.12), rng.uniform(-0.20, 0.20) * depth,
         rng.uniform(0.06, 0.20), detail=3,
         pivot=outer_heavy + side * 0.08)

    # The hole. A straight bore reads as drilled, so the cutter flares at both mouths and
    # wanders slightly off the axis on its way through — which is what a wave that swirls
    # through a gap for a few thousand years actually leaves.
    reach = depth * 0.5 + 0.30
    drift_x = rng.uniform(-0.035, 0.035)
    drift_z = rng.uniform(-0.030, 0.030)
    cutter = SweptTube(
        lambda t: Vector((
            hole_x + drift_x * math.sin(math.pi * t),
            -reach + 2.0 * reach * t,
            drift_z * math.sin(math.pi * t),
        )),
        # A gentle flare only. Anything stronger meets the rock face at a grazing angle and
        # leaves a feather edge of stone standing around the mouth like a shell.
        [(0.00, hole_half_x * 1.16), (0.26, hole_half_x * 1.06),
         (0.50, hole_half_x), (0.74, hole_half_x * 1.05),
         (1.00, hole_half_x * 1.14)],
        rings=26,
        segments=26,
        # A rounded section, not the squarer one stone would take: the opening is the
        # shape the water carved, and a superellipse flat on top gives a doorway lintel.
        exponent=2.0,
        caps=True,
    ).build("arch_cutter", subsurf=0)
    # Stretched about the tunnel's own axis and only then lifted into place. Scaling a
    # cutter already sitting at z = hole_z multiplies that height too, which raises the
    # opening and leaves a sill of rock across the bottom of it.
    cutter.data.transform(Matrix.Diagonal((1.0, 1.0, hole_half_z / hole_half_x, 1.0)))
    _move(cutter, (0.0, 0.0, hole_z))
    displace(cutter, strength=0.035, feature_size=0.55, octaves=3, seed=seed * 617 + 29)

    # Cut first, weather second. Displacing along vertex normals occasionally folds the
    # surface through itself somewhere in a concave fracture, and the exact solver's answer
    # for a self-intersecting operand is not a difference at all — on one seed it returned
    # the *union*, quietly filling the hole with the cutter. Cutting the clean lump and
    # eroding the result is immune to that, and has the better side effect of weathering
    # the rim and the tunnel walls continuously with the rest of the rock.
    def scoured(co):
        radial = math.hypot((co.x - hole_x) / hole_half_x, (co.z - hole_z) / hole_half_z)
        return min(1.0, max(0.22, (radial - 1.0) / 0.55))

    for index, piece in enumerate(mass):
        _subtract(piece, cutter)
        # Two passes at different scales. One pass at a single feature size gives an evenly
        # bumpy surface, which is the difference between weathered stone and orange peel.
        _erode(piece, seed * 97 + index * 13, coarse=0.055, pitting=0.008, feature=0.50,
               shelter=scoured)
        _erode(piece, seed * 89 + index * 29 + 5, coarse=0.030, pitting=0.014, feature=0.22,
               shelter=scoured)
        _erode(piece, seed * 83 + index * 37 + 11, coarse=0.014, pitting=0.022, feature=0.09,
               shelter=scoured)
        _crease(piece)
        piece.parent = root
        assign(piece, stone)
    bpy.data.objects.remove(cutter, do_unlink=True)

    # Rubble banked against the feet, outside the opening only: anything on the inner face
    # is directly in the fish's way, and the hole is the entire point of the prop.
    pieces = list(mass)
    for index in range(7):
        toward_heavy = index % 2 == 0
        foot_x = outer_heavy if toward_heavy else outer_light
        width = (heavy_leg if toward_heavy else light_leg) * 0.5
        away = math.copysign(1.0, foot_x - hole_x)
        size = rng.uniform(0.070, 0.130)
        piece = rock(
            f"arch_rubble_{index:02d}",
            radius=size,
            angularity=rng.uniform(0.38, 0.62),
            seed=seed * 811 + index * 37 + 3,
            detail=3,
            lumpiness=0.42,
            flatten=0.36,
        )
        _place(piece,
               foot_x + away * rng.uniform(0.25, 0.72) * width,
               rng.uniform(-0.55, 0.55) * depth)
        piece.parent = root
        assign(piece, rubble_stone)
        pieces.append(piece)

    # A boulder or two still perched on the crown: the tell that this used to be a cliff.
    # Their height is read off the eroded surface by a downward ray rather than assumed from
    # `crest`, because by this point the crest has been tapered, slanted and weathered and
    # the nominal number is nowhere near where the rock actually is.
    surface = _solid(mass)
    for index in range(2):
        size = rng.uniform(0.085, 0.130)
        cap = rock(
            f"arch_crown_{index:02d}",
            radius=size,
            angularity=rng.uniform(0.40, 0.60),
            seed=seed * 907 + index * 53 + 11,
            detail=3,
            lumpiness=0.46,
            flatten=0.40,
        )
        # Bedded into the crown rather than balanced on it. The headland's top is a curve,
        # so a boulder placed out toward its shoulder at full height hangs in mid air.
        cap_x = hole_x + rng.uniform(-0.26, 0.26)
        cap_y = rng.uniform(-0.16, 0.16)
        hit = surface.ray_cast(Vector((cap_x, cap_y, crest * 2.0)), Vector((0.0, 0.0, -1.0)))
        if hit[0] is None:
            bpy.data.objects.remove(cap, do_unlink=True)
            continue
        _move(cap, (cap_x, cap_y, hit[0].z - size * rng.uniform(0.20, 0.45)))
        cap.parent = root
        assign(cap, rubble_stone)
        pieces.append(cap)

    # The route, found rather than assumed, and measured rather than asserted. The search
    # box is the inside of the opening, so no sample can land within a pier and report the
    # thickness of the rock as though it were clearance.
    clearance, route_x, route_z = _best_line(
        pieces,
        (hole_x - hole_half_x * 0.55, hole_x + hole_half_x * 0.55),
        (max(0.24, hole_z - hole_half_z * 0.45), hole_z + hole_half_z * 0.45),
        reach,
    )
    print(f"[rock_arch] seed {seed}: passage at x={route_x:.3f} z={route_z:.3f}, "
          f"measured clearance {clearance:.3f} m, declared {PASSAGE_RADIUS:.3f} m")
    if clearance < PASSAGE_RADIUS:
        raise RuntimeError(
            f"rock_arch seed {seed}: the hole measures {clearance:.3f} m but the manifest "
            f"promises {PASSAGE_RADIUS:.3f} m"
        )

    _empty(root, "swim_arch_near", (route_x, -reach, route_z))
    _empty(root, "swim_arch_centre", (route_x, 0.0, route_z))
    _empty(root, "swim_arch_far", (route_x, reach, route_z))
    return root


ROCK_ARCH = Prop(
    name="rock_arch",
    build=build,
    category="rock",
    # Measured, not guessed: the three seeds span 1.60-1.66 m including their rubble and
    # stand 1.28-1.30 m, and the circle the prop sweeps as the tank yaws it is 0.85 m. That
    # circle is the footprint — not the width of one leg. Anything less lets the placement
    # pass stand a coral inside the opening.
    footprint=0.86,
    height=1.30,
    # Barely tilted. An arch leaning more than a few degrees stops reading as something that
    # stood up to the sea, and the passage is authored horizontal.
    tilt_range=(-3.0, 3.0),
    # A narrow scale range on purpose: `passages[].radius` is in metres and the runtime
    # scales the model without rescaling the promise, so a 0.7x arch would advertise a hole
    # half again wider than the one it has.
    scale_range=(0.94, 1.08),
    weight=0.7,
    max_per_scene=1,
    # More than twice the footprint on purpose. A fish has to line up on the passage before
    # it commits, so the approach at each mouth needs to stay clear as well as the arch.
    min_spacing=2.10,
    passages=(
        Passage(("swim_arch_near", "swim_arch_centre", "swim_arch_far"),
                radius=PASSAGE_RADIUS),
    ),
    seeds=3,
)
