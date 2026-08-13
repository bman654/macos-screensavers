"""Hard-surface primitives: boxes, lathes, boards and stone.

Creatures are lofted from smooth profiles (`body.py`). Wrecks, chests, helmets and
boulders are a different shape family: they want edges that are nearly — never exactly —
sharp, silhouettes turned on a lathe, boards that have taken a set, and stone that is
irregular without being noise for its own sake.

Two conventions carry over from the organic side for the same reasons they exist there:

* sizes are expressed relative to the model's own dimensions (a bevel is a fraction of
  the shortest edge, a rock's lumpiness a fraction of its radius). A number in absolute
  metres that looks right on a two-metre hull reads as faceting on a three-centimetre
  pebble;
* every random choice comes from an explicit `seed`, so a wreck rebuilt tomorrow is the
  same wreck.

Nothing here shades flat. A perfectly sharp edge with no highlight along it is the
clearest tell of untouched CG, so every primitive gets either a real bevel or an
angle-based split that leaves broad faces crisp and narrow ones smooth.
"""

import random
from math import cos, floor, radians, sin, tau

import bmesh
import bpy
from mathutils import Vector

from .body import shade_smooth
from .curves import Profile

# Gradient noise lives in about -0.707..0.707; scale it to roughly -1..1 so `strength`
# means what a caller expects it to mean.
_NOISE_GAIN = 1.41

_GRAD3 = (
    (1, 1, 0), (-1, 1, 0), (1, -1, 0), (-1, -1, 0),
    (1, 0, 1), (-1, 0, 1), (1, 0, -1), (-1, 0, -1),
    (0, 1, 1), (0, -1, 1), (0, 1, -1), (0, -1, -1),
)


def _fade(t):
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)


def _lerp(a, b, t):
    return a + (b - a) * t


class Noise:
    """Seeded 3-D gradient noise, with fbm.

    Blender's DISPLACE modifier plus a CLOUDS texture would do the same job but cannot be
    seeded — the texture has no seed input, and the usual workaround is to shift a
    coordinate empty, which is a hidden dependency rather than a parameter. Sampling here
    and baking the offsets into the mesh keeps a model a pure function of its arguments
    and leaves no texture datablock to survive export.
    """

    def __init__(self, seed=0):
        table = list(range(256))
        random.Random(seed).shuffle(table)
        self._p = table + table

    def _grad(self, xi, yi, zi, dx, dy, dz):
        p = self._p
        h = p[(p[(p[xi & 255] + yi) & 255] + zi) & 255] % 12
        gx, gy, gz = _GRAD3[h]
        return gx * dx + gy * dy + gz * dz

    def __call__(self, x, y, z):
        xi, yi, zi = floor(x), floor(y), floor(z)
        xf, yf, zf = x - xi, y - yi, z - zi
        u, v, w = _fade(xf), _fade(yf), _fade(zf)
        g = self._grad
        x1 = _lerp(g(xi, yi, zi, xf, yf, zf),
                   g(xi + 1, yi, zi, xf - 1, yf, zf), u)
        x2 = _lerp(g(xi, yi + 1, zi, xf, yf - 1, zf),
                   g(xi + 1, yi + 1, zi, xf - 1, yf - 1, zf), u)
        x3 = _lerp(g(xi, yi, zi + 1, xf, yf, zf - 1),
                   g(xi + 1, yi, zi + 1, xf - 1, yf, zf - 1), u)
        x4 = _lerp(g(xi, yi + 1, zi + 1, xf, yf - 1, zf - 1),
                   g(xi + 1, yi + 1, zi + 1, xf - 1, yf - 1, zf - 1), u)
        return _NOISE_GAIN * _lerp(_lerp(x1, x2, v), _lerp(x3, x4, v), w)

    def fbm(self, x, y, z, octaves=4, gain=0.5, lacunarity=2.0):
        """Sum of octaves, normalized to the same range as a single octave."""
        total, amplitude, frequency, norm = 0.0, 1.0, 1.0, 0.0
        for _ in range(max(1, int(octaves))):
            total += amplitude * self(x * frequency, y * frequency, z * frequency)
            norm += amplitude
            amplitude *= gain
            frequency *= lacunarity
        return total / norm


# -- mesh plumbing ------------------------------------------------------------------


def _finish(name, bm, sharp_angle=32.0, subsurf=0, smooth=True):
    """Turn a bmesh into a linked object with hard-surface shading.

    Smooth shading plus an EdgeSplit modifier is the portable way to get "smooth where
    the surface is smooth, crisp where it turns a corner". `mesh.use_auto_smooth` was
    removed in 4.1 and its replacement is an operator that needs a valid context, which
    is exactly what background builds do not have.
    """
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()

    if smooth:
        shade_smooth(mesh)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)

    # Subdivision first: EdgeSplit duplicates vertices, and a subdivision surface applied
    # after the split pulls the two copies apart into visible cracks.
    if subsurf:
        mod = obj.modifiers.new("Subdivision", "SUBSURF")
        mod.levels = subsurf
        mod.render_levels = subsurf
    if smooth and sharp_angle is not None:
        split = obj.modifiers.new("EdgeSplit", "EDGE_SPLIT")
        split.split_angle = radians(sharp_angle)
        split.use_edge_angle = True
        split.use_edge_sharp = False
    return obj


def bounding_radius(obj):
    """Half the diagonal of the object's local bounding box."""
    lo = Vector((float("inf"),) * 3)
    hi = Vector((float("-inf"),) * 3)
    for vert in obj.data.vertices:
        lo = Vector(min(lo[i], vert.co[i]) for i in range(3))
        hi = Vector(max(hi[i], vert.co[i]) for i in range(3))
    return max((hi - lo).length * 0.5, 1e-6)


# -- primitives ---------------------------------------------------------------------


def beveled_box(name, size=(1.0, 1.0, 1.0), bevel=0.05, segments=3,
                sharp_angle=32.0, subsurf=0):
    """A box whose edges catch a highlight.

    `size` is the full extent on each axis, centred on the origin.

    `bevel` is a fraction of the *shortest* edge, not a distance: a chest lid and a hull
    plate want the same visual amount of edge break at wildly different sizes, and
    clamping to the short edge means the bevel can never eat the whole box. 0.5 is a full
    round-over on that axis.

    `segments` trades crispness for roundness. 1 gives a single chamfer facet that still
    reads as a machined edge; 3-4 gives a rolled edge that catches a moving highlight,
    which is what old timber and cast brass both look like.
    """
    sx, sy, sz = (float(v) for v in size)
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    for vert in bm.verts:
        vert.co = Vector((vert.co.x * sx, vert.co.y * sy, vert.co.z * sz))

    width = float(bevel) * min(abs(sx), abs(sy), abs(sz))
    if width > 1e-9 and segments >= 1:
        bmesh.ops.bevel(
            bm,
            geom=list(bm.verts) + list(bm.edges) + list(bm.faces),
            offset=width,
            offset_type="OFFSET",
            segments=int(segments),
            profile=0.5,
            affect="EDGES",
            clamp_overlap=True,
        )
    return _finish(name, bm, sharp_angle=sharp_angle, subsurf=subsurf)


def _outline_radius(outline, interpolation):
    """Return (radius_at_height, sorted control heights) for a lathe outline.

    A smooth outline is interpolated with the same monotone cubic used for bodies,
    because it is the one interpolant that cannot overshoot: an overshooting spline
    between two control points produces a negative radius and an inside-out lathe.
    """
    points = sorted(((float(h), float(r)) for r, h in outline), key=lambda p: p[0])
    if len(points) < 2:
        raise ValueError("a revolve outline needs at least two (radius, height) points")

    # A vertical step — two points at the same height with different radii — is legal in
    # a silhouette but not in a function of height, so nudge the duplicate up by a hair.
    span = max(points[-1][0] - points[0][0], 1e-6)
    epsilon = span * 1e-4
    cleaned = [points[0]]
    for height, radius in points[1:]:
        if height <= cleaned[-1][0]:
            height = cleaned[-1][0] + epsilon
        cleaned.append((height, radius))

    heights = [h for h, _ in cleaned]
    if interpolation == "linear":
        radii = [r for _, r in cleaned]

        def at(height):
            if height <= heights[0]:
                return radii[0]
            if height >= heights[-1]:
                return radii[-1]
            for i in range(len(heights) - 1):
                if heights[i] <= height <= heights[i + 1]:
                    t = (height - heights[i]) / (heights[i + 1] - heights[i])
                    return _lerp(radii[i], radii[i + 1], t)
            return radii[-1]

        return at, heights

    return Profile(cleaned), heights


def revolve(name, outline, segments=48, rings=40, sweep=None, interpolation="smooth",
            cap_bottom=True, cap_top=True, cap_sweep=True, thickness=0.0,
            sharp_angle=32.0, subsurf=0):
    """Lathe a silhouette around +Z.

    `outline` is a sequence of (radius, height) points in metres, in any order; height is
    the axis coordinate. A jug, a diving helmet, an amphora and a vent chimney are all
    the same object to this function — a silhouette plus a wall — so the parameters are
    the ones that separate them:

    * `interpolation` — "smooth" rounds through the control points (amphora shoulder,
      helmet dome), "linear" keeps every control point as a crease (helmet rim, the
      stepped collar of a vent). Mixing both in one model means two `revolve` calls.
    * `cap_bottom` / `cap_top` — a jug is capped at the bottom and open at the top, a
      chimney is open at both ends.
    * `thickness` — wall thickness in metres. An open lathe is a zero-width sheet and
      shows its lack of substance the moment the camera sees the opening; anything with
      a mouth needs this.
    * `sweep` — radians, default a full turn. A partial sweep gives a cut-away or a
      broken shard; `cap_sweep` closes the two radial ends back to the axis so the result
      is a solid wedge rather than a curved sheet.

    `segments` is the count around, `rings` the number of evenly-spaced samples along the
    height. Control heights are always sampled exactly on top of those, which is what
    keeps a "linear" corner from being rounded off by the sampling.
    """
    radius_at, control_heights = _outline_radius(outline, interpolation)
    lo, hi = control_heights[0], control_heights[-1]

    levels = sorted(set(
        [lo, hi] + control_heights
        + [lo + (hi - lo) * i / (rings + 1) for i in range(1, rings + 1)]
    ))

    sweep = tau if sweep is None else float(sweep)
    closed = sweep >= tau - 1e-6
    count = segments if closed else segments + 1
    angles = [sweep * i / segments for i in range(count)]

    bm = bmesh.new()
    columns = []   # one list of verts per level; a single-element list means a pole
    for height in levels:
        radius = max(float(radius_at(height)), 0.0)
        is_pole = radius <= 1e-6 and height in (lo, hi)
        if is_pole:
            columns.append([bm.verts.new((0.0, 0.0, height))])
            continue
        radius = max(radius, 1e-6)
        columns.append([
            bm.verts.new((radius * cos(a), radius * sin(a), height)) for a in angles
        ])

    for lower, upper in zip(columns, columns[1:]):
        _bridge(bm, lower, upper, closed, count)

    for ring, cap, upward in ((columns[0], cap_bottom, False), (columns[-1], cap_top, True)):
        if cap and len(ring) > 1:
            _cap(bm, ring, closed, upward)

    if not closed and cap_sweep:
        _cap_sweep(bm, columns, levels)

    obj = _finish(name, bm, sharp_angle=sharp_angle, subsurf=subsurf)
    if thickness:
        solid = obj.modifiers.new("Solidify", "SOLIDIFY")
        solid.thickness = float(thickness)
        solid.offset = -1.0         # grow inward, so the outline stays the silhouette
        solid.use_rim = True
        obj.modifiers.move(len(obj.modifiers) - 1, 0)
    return obj


def _bridge(bm, lower, upper, closed, count):
    """Connect two rings, either of which may have collapsed to a pole vertex."""
    span = count if closed else count - 1
    for i in range(span):
        j = (i + 1) % count
        if len(lower) == 1:
            bm.faces.new((lower[0], upper[i], upper[j]))
        elif len(upper) == 1:
            bm.faces.new((upper[0], lower[j], lower[i]))
        else:
            bm.faces.new((lower[i], lower[j], upper[j], upper[i]))


def _cap(bm, ring, closed, upward):
    """Close a ring with a fan to a centre vertex, so the cap can be displaced later."""
    height = ring[0].co.z
    hub = bm.verts.new((0.0, 0.0, height))
    count = len(ring)
    span = count if closed else count - 1
    for i in range(span):
        j = (i + 1) % count
        bm.faces.new((hub, ring[j], ring[i]) if upward else (hub, ring[i], ring[j]))


def _cap_sweep(bm, columns, levels):
    """Close the two radial ends of a partial sweep back onto the axis."""
    for end in (0, -1):
        axis = [bm.verts.new((0.0, 0.0, h)) for h in levels]
        for i in range(len(columns) - 1):
            lower, upper = columns[i], columns[i + 1]
            a = lower[end] if len(lower) > 1 else lower[0]
            b = upper[end] if len(upper) > 1 else upper[0]
            if a is b:
                continue
            bm.faces.new((axis[i], a, b, axis[i + 1]))


def plank(name, length, width, thickness, bow=0.012, cup=0.05, twist=4.0, seed=0,
          bevel=0.3, samples_u=18, samples_v=6, sharp_angle=40.0):
    """A board that has taken a set, lying in the XY plane with its length along X.

    Sawn timber left underwater does three things, and a row of identical straight boxes
    reads as a fence rather than a wreck: it bows along its length, cups across its
    width, and takes a slight twist end to end. All three are seeded, so `seed=i` in a
    loop gives a hull of boards that differ.

    `bow` is peak deflection as a fraction of `length`, `cup` as a fraction of `width`,
    `twist` is the total end-to-end rotation in degrees, and `bevel` is the edge
    softening as a fraction of `thickness`. The seeded amounts are randomized in sign and
    scaled to between half and all of what is asked, so the argument is the worst case
    rather than the exact value.
    """
    rng = random.Random(seed)
    noise = Noise(seed * 977 + 13)

    def vary(amount):
        return amount * rng.uniform(0.5, 1.0) * rng.choice((-1.0, 1.0))

    bow_amp = vary(bow * length)
    cup_amp = vary(cup * width)
    twist_rad = radians(vary(twist))
    grain = thickness * 0.12
    period = max(length, 1e-6)

    bm = bmesh.new()
    grid = []
    for i in range(samples_u):
        u = i / (samples_u - 1) - 0.5
        column = []
        for j in range(samples_v):
            v = j / (samples_v - 1) - 0.5
            x, y = u * length, v * width
            z = bow_amp * (1.0 - 4.0 * u * u)          # shallow arc, flat at the ends
            z += cup_amp * (4.0 * v * v - 1.0 / 3.0)   # mean-free, so cupping does not lift
            z += y * twist_rad * u * 2.0
            z += grain * noise.fbm(x / period * 6.0, y / period * 6.0, 0.0, octaves=3)
            column.append(bm.verts.new((x, y, z)))
        grid.append(column)

    for i in range(samples_u - 1):
        for j in range(samples_v - 1):
            bm.faces.new((grid[i][j], grid[i + 1][j], grid[i + 1][j + 1], grid[i][j + 1]))

    obj = _finish(name, bm, sharp_angle=sharp_angle)
    solid = obj.modifiers.new("Solidify", "SOLIDIFY")
    solid.thickness = float(thickness)
    solid.offset = 0.0
    if bevel > 0.0:
        # Bevelling as a modifier rather than in bmesh: the board is solidified after it
        # is warped, so the edges that need breaking do not exist until the stack runs.
        edge = obj.modifiers.new("Bevel", "BEVEL")
        edge.width = min(float(bevel) * thickness, thickness * 0.45)
        edge.segments = 2
        edge.limit_method = "ANGLE"
        edge.angle_limit = radians(30.0)
        edge.use_clamp_overlap = True
    # The split has to run last: it is judging angles on the solidified, bevelled board,
    # not on the single-sided sheet that came out of bmesh.
    obj.modifiers.move(0, len(obj.modifiers) - 1)
    return obj


def displace(obj, strength=0.06, feature_size=0.5, octaves=4, seed=0, gain=0.5,
             lacunarity=2.0, subdivide=0, along_normal=True):
    """Push an object's vertices around with seeded fbm noise, in place.

    `strength` and `feature_size` are both fractions of the object's own bounding radius:
    `feature_size=0.5` means the largest noise feature is about half the model across, so
    the same call roughens a pebble and a hull without retuning. `octaves` adds the
    smaller detail on top — 1 is a slow undulation, 5 is pitted stone.

    `subdivide` cuts every edge first. Without it this silently does nothing useful on a
    box or a lathe, which have no interior vertices to move, and that failure looks like
    a broken noise function rather than a missing argument.

    Displacement follows the vertex normal, which is what erosion and encrustation both
    do. `along_normal=False` offsets along three decorrelated noise channels instead, for
    the melted, undercut look of a coral-covered lump.
    """
    noise = Noise(seed)
    radius = bounding_radius(obj)
    scale = 1.0 / max(feature_size * radius, 1e-9)
    amount = strength * radius

    bm = bmesh.new()
    bm.from_mesh(obj.data)
    if subdivide > 0:
        bmesh.ops.subdivide_edges(bm, edges=bm.edges[:], cuts=int(subdivide),
                                  use_grid_fill=True)
    bm.normal_update()

    for vert in bm.verts:
        p = vert.co * scale
        if along_normal:
            offset = vert.normal * (amount * noise.fbm(p.x, p.y, p.z, octaves, gain,
                                                       lacunarity))
        else:
            offset = Vector((
                noise.fbm(p.x, p.y, p.z, octaves, gain, lacunarity),
                noise.fbm(p.x + 31.7, p.y, p.z, octaves, gain, lacunarity),
                noise.fbm(p.x, p.y + 57.3, p.z, octaves, gain, lacunarity),
            )) * amount
        vert.co = vert.co + offset

    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    bm.to_mesh(obj.data)
    bm.free()
    obj.data.update()
    return obj


def rock(name, radius=0.25, angularity=0.35, seed=0, detail=4, lumpiness=0.35,
         flatten=0.25, grain=0.05, sharp_angle=None):
    """A boulder, cobble or shard.

    `angularity` runs from 0 — a water-rounded cobble, all broad lumps and no corners —
    to 1, a freshly broken shard with flat conchoidal faces meeting at hard arrises.
    It drives three things at once, because those three always move together in real
    stone: how many planar fractures cut the form, how much of the surface is rounded
    lump rather than flat face, and how fine the residual texture is.

    `lumpiness` and `grain` are the low- and high-frequency surface deviation as
    fractions of `radius`; `flatten` squashes the result along Z so it sits on the
    seabed instead of looking like a ball that stopped rolling. `detail` is icosphere
    subdivisions — 3 (162 verts) is enough for gravel, 4 (642) for anything the camera
    passes close to.

    The fine noise is applied *before* the fractures, so a cut face is perfectly flat.
    Cutting first and then displacing puts noise on a face that should be glassy, which
    is what makes a shard read as a lumpy potato with edges.
    """
    angularity = min(1.0, max(0.0, float(angularity)))
    if sharp_angle is None:
        # A rounded cobble needs a high split angle or the displaced facets crease into
        # dents; a shard needs a low one so its fracture faces stay separate planes.
        sharp_angle = 58.0 - 32.0 * angularity
    rng = random.Random(seed)
    noise = Noise(seed * 7919 + 101)

    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=int(detail), radius=radius)

    # An anisotropic squash first: a rock built purely from noise on a sphere still
    # reads as a sphere, because its silhouette stays circular from every angle.
    axes = [rng.uniform(0.72, 1.28) for _ in range(3)]
    axes[2] *= (1.0 - 0.6 * float(flatten))
    for vert in bm.verts:
        vert.co = Vector((vert.co[i] * axes[i] for i in range(3)))

    broad = lumpiness * (1.0 - 0.45 * angularity)
    fine = grain * (1.0 - 0.5 * angularity)
    bm.normal_update()
    for vert in bm.verts:
        p = vert.co / radius
        offset = radius * (
            broad * noise.fbm(p.x * 1.1, p.y * 1.1, p.z * 1.1, octaves=2, gain=0.55)
            + fine * noise.fbm(p.x * 6.0 + 11.0, p.y * 6.0, p.z * 6.0, octaves=4)
        )
        vert.co = vert.co + vert.normal * offset

    for _ in range(int(round(angularity * 6.0))):
        direction = Vector((rng.gauss(0, 1), rng.gauss(0, 1), rng.gauss(0, 1)))
        if direction.length < 1e-6:
            continue
        direction.normalize()
        origin = direction * (radius * rng.uniform(0.42, 0.85))
        cut = bmesh.ops.bisect_plane(
            bm, geom=bm.verts[:] + bm.edges[:] + bm.faces[:], dist=1e-6,
            plane_co=origin, plane_no=direction, clear_outer=True,
        )
        edges = [g for g in cut["geom_cut"] if isinstance(g, bmesh.types.BMEdge)]
        if edges:
            bmesh.ops.contextual_create(bm, geom=edges)

    return _finish(name, bm, sharp_angle=sharp_angle)
