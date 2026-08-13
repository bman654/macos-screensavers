"""A clump of rock spires with fish-sized gaps between them.

Like the arch, this prop exists for the space inside it rather than the stone: a tank of
things a fish routes around is flat, and a cluster a fish threads *between* is what gives
the depth axis something to prove. So the columns are placed for their gaps first — clumped
and uneven, never a ring — and the routes through them are then found and measured rather
than assumed.

The columns are lathed rather than lumped, but only a few control points become ledges.
Uneven bed spacing leaves long massive runs between close thin strata, and reverse steps
leave resistant caps wider than the softer necks below. Everything after the lathe exists
to take the turned look back out of it: an independent lean, sections whose off-round axis
changes with height, and erosion that pits the tops harder than the undersides.
"""

import math
import random

import bmesh
import bpy
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

from saverlib import Noise, assign, bounding_radius, displace, revolve, rock, rock_material

from ._spec import Passage, Prop

# What the manifest promises for both routes. The build measures every gap on every seed and
# refuses to produce a model that does not honour this. It is deliberately short of the
# 0.195-0.273 m the six gaps across the three seeds actually measure, because a fish clipping
# through solid rock is far worse than a fish declining a gap it would have made.
PASSAGE_RADIUS = 0.150
MIN_SCALE = 0.92


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
    return obj


def _seat(obj, x, y):
    """Put a piece's foot at (x, y) with its lowest vertex exactly on z = 0.

    Exactly on, never below: `build_prop` seats the whole prop by lifting it to its lowest
    vertex, so one half-buried pebble raises every column off the seabed. Centre the low foot
    rather than the full bounding box: the latter shifts an outward-leaning shaft back inward
    by half its lean and quietly takes away the throat that the lean exists to open.
    """
    lo, hi = _extent(obj)
    foot = [vert.co for vert in obj.data.vertices
            if vert.co.z <= lo.z + (hi.z - lo.z) * 0.035]
    centre_x = sum(co.x for co in foot) / len(foot)
    centre_y = sum(co.y for co in foot) / len(foot)
    return _move(obj, (x - centre_x, y - centre_y, -lo.z))


def _lean(obj, height, offset):
    """Tip a column over as it rises, without shearing its foot off the floor.

    A smoothstep rather than a straight shear: the base stays vertical where it meets the
    seabed and the movement accumulates up the shaft, which is what a column undercut on one
    side actually does. Independent per column — a clump that all leans one way reads as a
    single broken object.
    """
    # Reach the authored lean by mid-shaft: the passages sit below the shorter column's
    # crown, so saving most of the bend for the tip would widen open water, not the throat.
    span = max(height * 0.55, 1e-6)
    for vert in obj.data.vertices:
        t = min(1.0, max(0.0, vert.co.z / span))
        bend = t * t * (3.0 - 2.0 * t)
        vert.co.x += offset[0] * bend
        vert.co.y += offset[1] * bend
    obj.data.update()
    return obj


def _erode(obj, seed, coarse=0.030, pitting=0.020, feature=0.30, scour=0.70):
    """Weather stone, harder on the faces the light and the settling grit can reach.

    `saverlib.displace` is the same idea with one strength everywhere. Here the fine octaves
    are masked by the vertex normal's Z — `scour` is how much of the pitting is withheld from
    downward faces — because an overhang stays smooth while a ledge collects and is pitted by
    everything that lands on it, and treating both alike is what makes an eroded form read
    merely as a bumpy one.
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
        vert.co = vert.co + vert.normal * offset
    obj.data.update()
    return obj


def _warp_sections(obj, radius, height, seed):
    """Make every horizontal section irregular in a different direction.

    One object-space displacement still leaves a lathe recognisable when its broadest noise
    happens to run up the shaft. Here two- and three-lobed sections rotate independently with
    height, while the section centre wanders a little as well. The foot is held in place so
    this reshaping does not undo the clumped bases or duplicate the authored lean.
    """
    noise = Noise(seed * 2347 + 29)
    for vert in obj.data.vertices:
        t = min(1.0, max(0.0, vert.co.z / max(height, 1e-6)))
        angle = math.atan2(vert.co.y, vert.co.x)
        distance = math.hypot(vert.co.x, vert.co.y)

        phase_two = 2.6 * noise(1.7, -2.1, t * 1.35) + 1.2 * t
        phase_three = 3.4 * noise(-3.3, 0.8, t * 1.80) - 0.9 * t
        section = (
            1.0
            + 0.17 * math.sin(2.0 * angle + phase_two)
            + 0.09 * math.sin(3.0 * angle + phase_three)
            + 0.045 * noise(math.cos(angle) * 1.7, math.sin(angle) * 1.7, t * 2.4)
        )
        distance *= min(1.30, max(0.70, section))

        # A smooth ramp keeps every base centred where the clearance layout expects it.
        loosen = t * t * (3.0 - 2.0 * t)
        drift_x = radius * 0.10 * loosen * noise(7.1, -1.3, t * 1.25)
        drift_y = radius * 0.10 * loosen * noise(-4.7, 6.2, t * 1.25)
        vert.co.x = math.cos(angle) * distance + drift_x
        vert.co.y = math.sin(angle) * distance + drift_y
        # Beds in real stone wander and dip; a perfectly level ring remains a lathe tell even
        # after its plan section is irregular. Keep the foot level, then grow a low asymmetric
        # ripple with height so ledges and the broken crown never form geometric hoops.
        phase_z = 2.1 * noise(2.4, -5.2, t * 1.55)
        vert.co.z += height * loosen * (
            0.010 * math.sin(angle + phase_z)
            + 0.004 * math.sin(2.0 * angle - phase_z * 0.7)
        )
    obj.data.update()
    return obj


def _shade_strata(obj, bands, crown_start, height, seed, stone, band_stone, crown_stone):
    """Pick out a few actual beds and the broken crown without painting every ring.

    This runs before any displacement, while a profile height still identifies the faces the
    outline created. A broad angular noise shifts each band's limits so its mineral margin
    wanders across the coarse profile grid instead of becoming a clean painted ribbon.
    """
    assign(obj, stone)
    obj.data.materials.append(band_stone)
    obj.data.materials.append(crown_stone)
    noise = Noise(seed * 1877 + 43)
    radius = max(bounding_radius(obj), 1e-6)
    for poly in obj.data.polygons:
        centre = sum((obj.data.vertices[index].co for index in poly.vertices), Vector())
        centre /= len(poly.vertices)
        boundary_shift = height * 0.014 * noise(
            centre.x / radius * 1.4,
            centre.y / radius * 1.4,
            centre.z / height * 0.8,
        )
        if centre.z >= crown_start + boundary_shift * 0.45:
            poly.material_index = 2
        elif any(lo + boundary_shift <= centre.z <= hi + boundary_shift for lo, hi in bands):
            poly.material_index = 1
    return obj


def _subdivide_crown(obj, crown_start):
    """Give only the broken crown enough vertices to deform away from a flat fan cap."""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    crown_faces = [
        face for face in bm.faces
        if sum(vert.co.z for vert in face.verts) / len(face.verts) >= crown_start
    ]
    crown_edges = list({edge for face in crown_faces for edge in face.edges})
    if crown_edges:
        bmesh.ops.subdivide_edges(bm, edges=crown_edges, cuts=1, use_grid_fill=True)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    bm.to_mesh(obj.data)
    bm.free()
    obj.data.update()
    return obj


# -- passages ------------------------------------------------------------------------


def _solid(objects):
    """One BVH over every piece of the prop, in world space.

    `find_nearest` returns the distance to the nearest *surface* rather than to the nearest
    vertex, so a coarse mesh cannot flatter the answer, and the sign of the offset against
    the hit normal says whether a sample is inside the rock at all — which a vertex distance
    can never tell you.
    """
    verts, polys = [], []
    for obj in objects:
        matrix = obj.matrix_world
        base = len(verts)
        verts.extend(matrix @ vert.co for vert in obj.data.vertices)
        polys.extend([index + base for index in poly.vertices] for poly in obj.data.polygons)
    return BVHTree.FromPolygons(verts, polys)


def _run_clearance(tree, origin, direction, reach, samples=513):
    """The tightest clearance anywhere along a straight run, not just at its ends.

    Sampled densely along the whole route because the waypoints are the two places a route
    is guaranteed to be clear, and the throat of the gap — which is rarely where a waypoint
    lands — is where it is not. Distance to a surface is 1-Lipschitz, so half one sample step
    is removed from the observed minimum to guarantee the unsampled intervals too.
    """
    worst = float("inf")
    for index in range(samples):
        point = origin + direction * (-reach + 2.0 * reach * index / (samples - 1))
        location, normal, _, distance = tree.find_nearest(point)
        if location is None:
            continue
        if (point - location).dot(normal) < 0.0:
            return -distance          # inside the rock; never a passage
        worst = min(worst, distance)
    return worst - reach / (samples - 1)


def _best_run(tree, midpoint, across, direction, reach, spread, heights):
    """Search a gap for the through-line with the largest tightest clearance.

    The waypoints cannot be authored as constants: the columns lean and are weathered by
    seed, so the widest part of a gap moves, and a route that was clear on seed 0 can be
    through rock on seed 2. Searching and then *measuring* is the whole difference between
    a declared radius and a true one.
    """
    best = (float("-inf"), midpoint)
    for step in range(-8, 9):
        shifted = midpoint + across * (spread * step / 8.0)
        for height in heights:
            origin = Vector((shifted.x, shifted.y, height))
            clearance = _run_clearance(tree, origin, direction, reach)
            if clearance > best[0]:
                best = (clearance, origin)
    return best


def _empty(root, name, location, size=0.05):
    node = bpy.data.objects.new(name, None)
    bpy.context.collection.objects.link(node)
    node.empty_display_type = "SPHERE"
    node.empty_display_size = size
    node.location = location
    node.parent = root
    return node


# -- the columns ---------------------------------------------------------------------


def _column(name, radius, height, seed, rng, lean, materials):
    """One weathered stack: massive runs, sparse beds, undercuts and a broken cap."""
    outline = [(radius * rng.uniform(0.98, 1.03), 0.0)]
    fraction = rng.uniform(0.94, 0.98)
    outline.append((radius * fraction, height * rng.uniform(0.045, 0.065)))

    # One dependable basal shelf gives the stack a planted foot. Above it the widths hover
    # around one column rather than marching inward: occasional reverse steps and a cap wider
    # than its neck are what stop the silhouette reading as a cone.
    shelf = height * rng.uniform(0.12, 0.17)
    outline.append((radius * fraction, shelf))
    fraction -= rng.uniform(0.100, 0.145)
    shelf_top = shelf + height * rng.uniform(0.010, 0.018)
    outline.append((radius * fraction, shelf_top))
    # The basal shelf is geometry, not a highlighted stratum: colouring the dependable shelf
    # on every shaft creates a row of matching hoops across the whole clump.
    ledges = []

    # The same total height is divided into one long massive bed, two close thin beds and
    # several ordinary ones. Shuffling their order prevents the pattern repeating from shaft
    # to shaft while retaining the deliberately uneven rhythm.
    gaps = [
        rng.uniform(0.15, 0.22),
        rng.uniform(0.025, 0.045),
        rng.uniform(0.040, 0.065),
        rng.uniform(0.13, 0.19),
        rng.uniform(0.065, 0.105),
    ]
    rng.shuffle(gaps)
    total = sum(gaps)
    positions = []
    cursor = 0.21
    for gap in gaps:
        cursor += gap / total * 0.51
        positions.append(cursor)

    kinds = ["soft", "in", "soft", "out", "in"]
    rng.shuffle(kinds)
    for position, kind in zip(positions, kinds):
        # Small changes over a long run remain below the split angle and shade through as one
        # face; they are control points for the silhouette, not automatically another ledge.
        fraction = min(0.73, max(0.62, fraction + rng.uniform(-0.025, 0.035)))
        z = height * position
        outline.append((radius * fraction, z))
        if kind == "soft":
            continue

        if kind == "in":
            fraction -= rng.uniform(0.045, 0.090)
        else:
            fraction += rng.uniform(0.055, 0.115)
        fraction = min(0.76, max(0.60, fraction))
        top = z + height * rng.uniform(0.008, 0.017)
        outline.append((radius * fraction, top))
        ledges.append((z - height * 0.010, top + height * rng.uniform(0.025, 0.050)))

    # A resistant bed sometimes survives wider than the softer neck below it. Making that a
    # possibility rather than every shaft's uniform hat keeps the clump from becoming a set
    # of manufactured bollards.
    neck_z = height * rng.uniform(0.78, 0.83)
    neck = min(0.84, max(0.63, fraction + rng.uniform(-0.035, 0.020)))
    outline.append((radius * neck, neck_z))
    cap_z = neck_z + height * rng.uniform(0.014, 0.026)
    resistant_cap = rng.random() < 0.60
    cap = neck * (rng.uniform(1.12, 1.25) if resistant_cap else rng.uniform(0.94, 1.05))
    cap = min(0.98, cap)
    outline.append((radius * cap, cap_z))
    if resistant_cap:
        ledges.append((neck_z - height * 0.012, cap_z + height * 0.045))

    # Collapse to a small broken plateau through one sloped shoulder. The old broad fan cap
    # stayed mathematically flat because it had only a rim and one hub vertex.
    shoulder_z = height * rng.uniform(0.92, 0.96)
    outline.append((radius * cap * rng.uniform(0.88, 0.98), shoulder_z))
    outline.append((radius * cap * rng.uniform(0.38, 0.56), height))

    column = revolve(
        name, outline, segments=30, rings=34, interpolation="linear",
        cap_bottom=True, cap_top=True, sharp_angle=48.0,
    )
    band_count = 2 if radius >= 0.16 else 1
    bands = rng.sample(ledges, min(band_count, len(ledges)))
    _shade_strata(column, bands, neck_z, height, seed, *materials)
    # The flat fan was a crown-local topology problem. Cutting only its upper faces gives the
    # broad displacement room to break that surface without quadrupling every shaft face.
    _subdivide_crown(column, neck_z - height * 0.025)
    _warp_sections(column, radius, height, seed)
    _lean(column, height, lean)
    # Broad spatial distortion changes the mass; the two normal passes then weather it at
    # different scales instead of reproducing the old sandy orange peel.
    displace(column, strength=0.075, feature_size=0.72, octaves=2,
             seed=seed * 331 + 17, along_normal=False)
    _erode(column, seed * 97 + 11, coarse=0.050, pitting=0.006, feature=0.52)
    _erode(column, seed * 89 + 23, coarse=0.018, pitting=0.014, feature=0.15)
    return column


def build(seed=0):
    rng = random.Random(seed * 6421 + 17)
    root = bpy.data.objects.new("decor_rock_pillars", None)
    bpy.context.collection.objects.link(root)

    # Hue carries the broad contrast, not a futile race toward black: the stone ranges from
    # warm umber to blue-green, with larger texture features than the arch or boulder. Beds stay
    # close to that palette and differ mostly in texture; only the upward crown receives a large
    # colonisation increase, so a stratum cannot become a bright algae ribbon around the shaft.
    stone = rock_material(
        f"pillar_stone_{seed}", size=0.52,
        base=(0.058, 0.052, 0.041), secondary=(0.020, 0.037, 0.040),
        speckle=0.22, roughness=0.84, algae=0.34, seed=seed * 37 + 3,
    )
    band_stone = rock_material(
        f"pillar_band_{seed}", size=0.40,
        base=(0.061, 0.053, 0.039), secondary=(0.022, 0.039, 0.038),
        speckle=0.10, roughness=0.90, algae=0.34, seed=seed * 37 + 19,
    )
    crown_stone = rock_material(
        f"pillar_crown_{seed}", size=0.56,
        base=(0.062, 0.051, 0.033), secondary=(0.024, 0.037, 0.036),
        # Light comes from above, so the crown carrying the most growth is right — but the
        # step lands on the crown seam, which is a hard geometric edge, and a large step
        # across it reads as a moss beret rather than as colonisation. This is the same
        # failure the strata bands had: contrast is fine, contrast aligned with a crease is
        # not. Keep it a little above the shaft and let the seam stay the quiet edge.
        speckle=0.12, roughness=0.90, algae=0.50, seed=seed * 37 + 29,
    )
    scree_stone = rock_material(
        f"pillar_scree_{seed}", size=0.22,
        base=(0.064, 0.048, 0.031), secondary=(0.026, 0.036, 0.033),
        speckle=0.34, roughness=0.89, algae=0.48, seed=seed * 37 + 41,
    )

    # Clumped and stepped, never a ring and never evenly spaced: one dominant column with
    # the rest crowded around it at unequal distances and unrelated heights. What opens the
    # two gaps that carry the passages is the outward lean below, not extra spacing — a
    # cluster spaced far enough apart to swim between stops reading as a clump.
    tall = rng.uniform(1.18, 1.30)
    spin = rng.uniform(0.0, math.tau)
    mirror = 1.0 if seed % 2 == 0 else -1.0

    def around(angle, distance):
        return Vector((math.cos(spin + angle * mirror) * distance,
                       math.sin(spin + angle * mirror) * distance, 0.0))

    # Bases almost touching, shafts splaying above a narrower throat: the clump reads as one
    # outcrop at the seabed and still opens a fish-sized route at mid-height. Parallel columns
    # spaced far enough apart to swim between never do.
    layout = [
        ("pillar_main", Vector((0.0, 0.0, 0.0)), 0.210, tall),
        ("pillar_second", around(0.0, rng.uniform(0.60, 0.66)), 0.165,
         tall * rng.uniform(0.68, 0.76)),
        ("pillar_third", around(2.05, rng.uniform(0.58, 0.64)), 0.140,
         tall * rng.uniform(0.50, 0.58)),
        ("pillar_stub", around(3.6, rng.uniform(0.28, 0.34)), 0.105,
         tall * rng.uniform(0.28, 0.36)),
    ]
    if rng.random() < 0.5:
        layout.append(("pillar_spur", around(4.4, rng.uniform(0.32, 0.40)),
                       0.085, tall * rng.uniform(0.17, 0.24)))

    columns = {}
    for index, (name, centre, radius, height) in enumerate(layout):
        # Leaning outward, away from the tallest column. Real spires splay as the gaps
        # between them are undercut, and it is also the only lean that widens a gap instead
        # of narrowing one: the feet stay clumped and the throat opens at swimming height,
        # which is where the passage has to be.
        outward = Vector((centre.x, centre.y, 0.0))
        if outward.length > 1e-6:
            outward.normalize()
            lean_amount = height * rng.uniform(0.12, 0.16)
        else:
            # The old main shaft leaned along the second shaft, so those two moved together
            # and gained no clearance. Aim the dominant one away from the centre of its two
            # passage neighbours, but less strongly than the satellites that splay around it.
            away = spin + mirror * 1.0 + math.pi
            outward = Vector((math.cos(away), math.sin(away), 0.0))
            lean_amount = height * rng.uniform(0.035, 0.050)
        wander = height * 0.014
        lean = (outward * lean_amount
                + Vector((rng.uniform(-wander, wander), rng.uniform(-wander, wander), 0.0)))
        column = _column(
            name, radius, height, seed * 101 + index * 13 + 5, rng, (lean.x, lean.y),
            (stone, band_stone, crown_stone),
        )
        _seat(column, centre.x, centre.y)
        column.parent = root
        columns[name] = (column, centre, radius, height)

    # Scree around the feet. Placed outside each column's own radius so it banks against the
    # shaft instead of floating inside it, and never below z = 0.
    pieces = [entry[0] for entry in columns.values()]
    for index in range(9):
        name, centre, radius, _ = layout[index % len(layout)]
        angle = rng.uniform(0.0, math.tau)
        size = rng.uniform(0.045, 0.095)
        piece = rock(
            f"pillar_scree_{index:02d}",
            radius=size,
            angularity=rng.uniform(0.40, 0.66),
            seed=seed * 733 + index * 41 + 7,
            detail=3,
            lumpiness=0.44,
            flatten=0.42,
        )
        reach = radius + size * rng.uniform(0.5, 1.4)
        _seat(piece, centre.x + math.cos(angle) * reach, centre.y + math.sin(angle) * reach)
        piece.parent = root
        assign(piece, scree_stone)
        pieces.append(piece)

    # The routes. Each runs through the gap between two columns, square to the line joining
    # them, and is searched over both where it crosses that line and how high it sits — a
    # leaning column moves the throat of its gap several centimetres in each.
    tree = _solid(pieces)
    routes = (
        ("pillars_main_gap", "pillar_main", "pillar_second"),
        ("pillars_side_gap", "pillar_main", "pillar_third"),
    )
    for label, first, second in routes:
        _, centre_a, radius_a, _ = columns[first]
        _, centre_b, radius_b, _ = columns[second]
        span = centre_b - centre_a
        across = Vector((span.x, span.y, 0.0)).normalized()
        direction = Vector((-across.y, across.x, 0.0))
        midpoint = (centre_a + centre_b) * 0.5 + across * (radius_a - radius_b) * 0.5
        reach = span.length * 0.5 + max(radius_a, radius_b) + 0.34
        # Height is searched only over the part of the gap that has rock on both sides of
        # it. Left unbounded the search climbs above the shorter column every time, because
        # open water is always the widest gap there is — and calls swimming over the cluster
        # a passage through it.
        ceiling = min(columns[first][3], columns[second][3]) * 0.62
        steps = 13
        clearance, origin = _best_run(
            tree, midpoint, across, direction, reach, spread=0.16,
            heights=[0.22 + (ceiling - 0.22) * step / (steps - 1) for step in range(steps)],
        )
        scaled_clearance = clearance * MIN_SCALE
        print(f"[rock_pillars] seed {seed}: {label} at "
              f"({origin.x:.3f}, {origin.y:.3f}, {origin.z:.3f}), "
              f"measured clearance {clearance:.3f} m "
              f"({scaled_clearance:.3f} m at {MIN_SCALE:.2f}x), "
              f"declared {PASSAGE_RADIUS:.3f} m")
        if scaled_clearance < PASSAGE_RADIUS:
            raise RuntimeError(
                f"rock_pillars seed {seed}: the {label} measures {clearance:.3f} m, only "
                f"{scaled_clearance:.3f} m at {MIN_SCALE:.2f}x, but the manifest promises "
                f"{PASSAGE_RADIUS:.3f} m"
            )
        for suffix, along in (("near", -reach), ("mid", 0.0), ("far", reach)):
            _empty(root, f"swim_{label}_{suffix}", origin + direction * along)

    return root


ROCK_PILLARS = Prop(
    name="rock_pillars",
    build=build,
    category="rock",
    # Measured, not guessed: depending on yaw the three seeds span 1.10-1.52 by 1.33-1.58 m
    # including their scree, stand 1.25-1.33 m, and sweep a 1.00 m circle as the tank yaws.
    # Placing on one column's radius would let the scatter drop a coral into the very gap
    # the passages run through.
    footprint=1.05,
    height=1.35,
    # Barely tilted: the columns already lean independently, and the passages are authored
    # horizontal. Tilting the group as well starts to pull the shafts out of the seabed.
    tilt_range=(-2.5, 2.5),
    # A narrow scale range on purpose. `passages[].radius` is in metres and the runtime
    # scales the model without rescaling the promise, so a 0.7x clump would advertise gaps
    # half again wider than the ones it has.
    scale_range=(MIN_SCALE, 1.10),
    weight=1.1,
    max_per_scene=2,
    # Comfortably more than twice the footprint: a fish has to line up on a gap before it
    # commits, so the approach to each mouth needs to stay clear as well as the clump.
    min_spacing=2.30,
    passages=(
        Passage(("swim_pillars_main_gap_near", "swim_pillars_main_gap_mid",
                 "swim_pillars_main_gap_far"), radius=PASSAGE_RADIUS),
        Passage(("swim_pillars_side_gap_near", "swim_pillars_side_gap_mid",
                 "swim_pillars_side_gap_far"), radius=PASSAGE_RADIUS),
    ),
    seeds=3,
)
