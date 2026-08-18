"""Swept tubes and deterministic recursive branching for organic models."""

import bisect
import math
import random
from numbers import Real

import bmesh
import bpy
from mathutils import Quaternion, Vector

from .body import shade_smooth
from .curves import Profile, as_profile, ring_angles, superellipse


_EPSILON = 1e-8


class SweptTube:
    """A queryable tube swept along a uniformly resampled three-dimensional path."""

    def __init__(
        self,
        path,
        radius,
        rings=64,
        segments=16,
        section=(1.0, 1.0),
        exponent=2.0,
        caps=True,
        rounded_caps=False,
        cap_rings=4,
        twist=0.0,
        sample_count=None,
        up=(0.0, 0.0, 1.0),
    ):
        if rings < 2:
            raise ValueError("rings must be at least 2")
        if segments < 3:
            raise ValueError("segments must be at least 3")
        if len(section) not in (2, 3):
            raise ValueError(
                "section must be (width, height) or (width, up, down) scale profiles"
            )
        if cap_rings < 1:
            raise ValueError("cap_rings must be at least 1")

        self.path = path
        self.radius = as_profile(radius)
        self.rings = int(rings)
        self.segments = int(segments)
        # Width, and the height above and below the axis. A body whose back and belly are
        # different depths is not a radius profile — the axis is the path, and the path
        # cannot be off-centre in its own frame — so it is a section that reaches further
        # one way than the other. A seahorse is the case: a crest over the head and a pot
        # belly under the trunk, on the same swept curve. Stating two profiles keeps the
        # symmetric case unchanged.
        self.section = (as_profile(section[0]), as_profile(section[1]),
                        as_profile(section[2] if len(section) == 3 else section[1]))
        self.exponent = as_profile(exponent)
        self.caps = bool(caps)
        if isinstance(rounded_caps, (tuple, list)):
            if len(rounded_caps) != 2:
                raise ValueError("rounded_caps must be a bool or a (start, end) pair")
            self.rounded_caps = (bool(rounded_caps[0]), bool(rounded_caps[1]))
        else:
            self.rounded_caps = (bool(rounded_caps), bool(rounded_caps))
        self.cap_rings = int(cap_rings)
        self.twist = _twist_function(twist)
        self.up = Vector(up)
        if self.up.length < _EPSILON:
            raise ValueError("up must be non-zero")
        self.up.normalize()

        samples = sample_count if sample_count is not None else max(64, self.rings * 4)
        source = _sample_path(path, int(samples))
        self.points = _resample_polyline(source, self.rings)
        self.ts = [i / (self.rings - 1) for i in range(self.rings)]
        self.tangents = _path_tangents(self.points)
        transported = _parallel_transport_frames(self.tangents, self.up)
        self.frames = [
            _twist_frame(normal, binormal, tangent, self.twist(t))
            for t, tangent, (normal, binormal) in zip(self.ts, self.tangents, transported)
        ]
        self.radii = [float(self.radius(t)) for t in self.ts]
        if min(self.radius.ys) <= 0.0:
            raise ValueError("radius must stay positive over the full path")
        if min(self.section[0].ys) <= 0.0:
            raise ValueError("section width scale must stay positive")
        if min(self.section[1].ys) <= 0.0:
            raise ValueError("section height scale must stay positive")
        if min(self.section[2].ys) <= 0.0:
            raise ValueError("section lower height scale must stay positive")
        if min(self.exponent.ys) <= 0.0:
            raise ValueError("section exponent must stay positive")

        self.object = None

    def point(self, t):
        """Return the path center at normalized arc position ``t``."""
        i, blend = _sample_index(t, len(self.points))
        return self.points[i].lerp(self.points[i + 1], blend)

    def tangent(self, t):
        """Return the unit path tangent at normalized arc position ``t``."""
        i, blend = _sample_index(t, len(self.tangents))
        tangent = self.tangents[i].lerp(self.tangents[i + 1], blend)
        return tangent.normalized()

    def frame(self, t):
        """Return the transported ``(normal, binormal, tangent)`` frame at ``t``."""
        i, blend = _sample_index(t, len(self.frames))
        tangent = self.tangent(t)
        normal = self.frames[i][0].lerp(self.frames[i + 1][0], blend)
        normal -= tangent * normal.dot(tangent)
        if normal.length < _EPSILON:
            normal = self.frames[i][1].cross(tangent)
        normal.normalize()
        binormal = tangent.cross(normal).normalized()
        return normal, binormal, tangent

    def radius_at(self, t):
        """Return the unscaled radius profile value at normalized arc position ``t``."""
        return float(self.radius(_clamp01(t)))

    def surface_point(self, t, theta):
        """Return a point on the swept surface in object space."""
        t = _clamp01(t)
        normal, binormal, _ = self.frame(t)
        y, z = self._section_point(t, theta, 1.0)
        return self.point(t) + normal * y + binormal * z

    def build(self, name="Tube", subsurf=1, uv=None):
        """Build and link the tube mesh, returning its Blender object.

        `uv` names a UV layer to write the sweep's own coordinates into: U is the
        normalized arc position along the path and V the fraction of the way round the
        section, starting at the flank where `ring_angles` starts. Nothing else can
        recover those afterwards — the sweep is the only place both numbers are known,
        and on a body that doubles back on itself no object-space coordinate stands in
        for either. It is what lets a marking be placed along a curled animal at all.

        A rounded cap sits *past* the end of the path, so its U runs outside 0..1 — the
        arc it adds, over the path's own length. Giving the whole cap `t` instead would
        collapse it to one coordinate, and a marking that repeats in U would then paint
        the entire tip with whatever it happens to draw at exactly 0 or 1.
        """
        angles = ring_angles(self.segments)
        bm = bmesh.new()
        rings = []
        # BMVert -> (u, segment index), or a segment index of None for a cap's pole,
        # which sits on the axis and so has no angle of its own.
        coordinates = {} if uv else None

        def ring(t, center, frame, scale=1.0, u=None):
            vertices = self._mesh_ring(bm, angles, t, center, frame, scale)
            if coordinates is not None:
                position = t if u is None else u
                coordinates.update((vertex, (position, index))
                                   for index, vertex in enumerate(vertices))
            return vertices

        if self.caps and self.rounded_caps[0]:
            rings.extend(self._rounded_cap_rings(bm, angles, start=True, ring=ring))

        for index, (t, center) in enumerate(zip(self.ts, self.points)):
            rings.append(ring(t, center, self.frames[index]))

        if self.caps and self.rounded_caps[1]:
            rings.extend(self._rounded_cap_rings(bm, angles, start=False, ring=ring))

        for previous, current in zip(rings, rings[1:]):
            _bridge_rings(bm, previous, current)

        if self.caps:
            start_pole = (
                self.points[0] - self.tangents[0] * self._cap_depth(0.0)
                if self.rounded_caps[0]
                else self.points[0]
            )
            end_pole = (
                self.points[-1] + self.tangents[-1] * self._cap_depth(1.0)
                if self.rounded_caps[1]
                else self.points[-1]
            )
            reach = self._cap_reach()
            for pole, position, capped in ((start_pole, -reach[0], rings[0]),
                                           (end_pole, 1.0 + reach[1], rings[-1])):
                vertex = bm.verts.new(pole)
                if coordinates is not None:
                    coordinates[vertex] = (position, None)
                _cap_ring(bm, vertex, capped)

        if uv:
            self._write_uv(bm, coordinates, uv)

        bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
        mesh = bpy.data.meshes.new(name)
        bm.to_mesh(mesh)
        bm.free()

        shade_smooth(mesh)
        obj = bpy.data.objects.new(name, mesh)
        bpy.context.collection.objects.link(obj)
        if subsurf:
            modifier = obj.modifiers.new("Subdivision", "SUBSURF")
            modifier.levels = int(subsurf)
            modifier.render_levels = int(subsurf)

        self.object = obj
        return obj

    def _section_point(self, t, theta, scale):
        radius = self.radius_at(t) * scale
        return superellipse(
            theta,
            radius * self.section[0](t),
            radius * self.section[1](t),
            radius * self.section[2](t),
            self.exponent(t),
        )

    def _cap_depth(self, t):
        height = 0.5 * (self.section[1](t) + self.section[2](t))
        section_scale = math.sqrt(self.section[0](t) * height)
        return self.radius_at(t) * section_scale

    def _mesh_ring(self, bm, angles, t, center, frame, scale):
        normal, binormal = frame[0], frame[1]
        vertices = []
        for theta in angles:
            y, z = self._section_point(t, theta, scale)
            vertices.append(bm.verts.new(center + normal * y + binormal * z))
        return vertices

    def _rounded_cap_rings(self, bm, angles, start, ring=None):
        index = 0 if start else -1
        t = 0.0 if start else 1.0
        sign = -1.0 if start else 1.0
        values = range(self.cap_rings, 0, -1) if start else range(1, self.cap_rings + 1)
        make = ring or (
            lambda t, center, frame, scale=1.0, u=None:
            self._mesh_ring(bm, angles, t, center, frame, scale)
        )
        reach = self._cap_reach()[0 if start else 1]
        rings = []
        for step in values:
            angle = 0.5 * math.pi * step / (self.cap_rings + 1)
            center = self.points[index] + self.tangents[index] * (
                sign * self._cap_depth(t) * math.sin(angle)
            )
            rings.append(make(t, center, self.frames[index], math.cos(angle),
                              u=t + sign * reach * math.sin(angle)))
        return rings

    def _cap_reach(self):
        """How far past each end a rounded cap goes, as a fraction of the path's length.

        The caps are the only part of the surface with no `t` of its own, and this is what
        gives them one: a coordinate that keeps going in the direction the path was headed.
        """
        length = sum((b - a).length for a, b in zip(self.points, self.points[1:]))
        if length <= _EPSILON:
            return (0.0, 0.0)
        return (self._cap_depth(0.0) / length if self.rounded_caps[0] else 0.0,
                self._cap_depth(1.0) / length if self.rounded_caps[1] else 0.0)

    def _write_uv(self, bm, coordinates, name):
        """Lay the sweep's (arc, angle) onto the built faces as a UV layer.

        Per *loop* rather than per vertex, because the ring closes: the face that joins
        the last segment back to the first shares its vertices with the face before it,
        and a per-vertex V would have to be both 1 and 0 there. Reading segment 0 as
        `segments` on that face alone is what makes V run cleanly 0..1 round the section
        instead of racing back through every other value in one quad.
        """
        layer = bm.loops.layers.uv.new(name)
        segments = self.segments
        for face in bm.faces:
            indices = [coordinates[loop.vert][1] for loop in face.loops
                       if coordinates[loop.vert][1] is not None]
            seam = bool(indices) and min(indices) == 0 and max(indices) == segments - 1
            around = []
            for loop in face.loops:
                index = coordinates[loop.vert][1]
                if index is None:
                    around.append(None)
                else:
                    around.append(
                        (index + segments if seam and index == 0 else index) / segments
                    )
            known = [value for value in around if value is not None]
            # A pole belongs to every angle at once, so it takes the mean of the ring
            # vertices it is capping in this face.
            pole = sum(known) / len(known) if known else 0.0
            for loop, value in zip(face.loops, around):
                loop[layer].uv = (coordinates[loop.vert][0],
                                  pole if value is None else value)


class BranchSpec:
    """Parameters shared by every generation of a branching tube structure."""

    def __init__(
        self,
        trunk_length,
        radius,
        children_per_split=2,
        split_angle=math.radians(35.0),
        split_angle_jitter=0.0,
        length_decay=0.72,
        radius_decay=0.65,
        depth=3,
        curvature=0.0,
        droop=0.0,
        seed=0,
        planarity=0.0,
        split_positions=(0.82,),
        alternating=False,
        tip_radius_ratio=0.72,
        junction_overlap=0.8,
        section=(1.0, 1.0),
        exponent=2.0,
    ):
        if trunk_length <= 0.0 or radius <= 0.0:
            raise ValueError("trunk_length and radius must be positive")
        if children_per_split < 0 or depth < 0:
            raise ValueError("children_per_split and depth cannot be negative")
        if not 0.0 <= split_angle <= math.pi:
            raise ValueError("split_angle must be in [0, pi]")
        if split_angle_jitter < 0.0:
            raise ValueError("split_angle_jitter cannot be negative")
        if junction_overlap < 0.0:
            raise ValueError("junction_overlap cannot be negative")
        if not 0.0 < length_decay <= 1.0 or not 0.0 < radius_decay <= 1.0:
            raise ValueError("length_decay and radius_decay must be in (0, 1]")
        if not 0.0 <= planarity <= 1.0:
            raise ValueError("planarity must be in [0, 1]")
        if not 0.0 < tip_radius_ratio <= 1.0:
            raise ValueError("tip_radius_ratio must be in (0, 1]")
        positions = tuple(float(value) for value in split_positions)
        if any(value <= 0.0 or value >= 1.0 for value in positions):
            raise ValueError("split_positions must lie strictly inside (0, 1)")
        if any(b <= a for a, b in zip(positions, positions[1:])):
            raise ValueError("split_positions must be strictly increasing")

        self.trunk_length = float(trunk_length)
        self.radius = float(radius)
        self.children_per_split = int(children_per_split)
        self.split_angle = float(split_angle)
        self.split_angle_jitter = float(split_angle_jitter)
        self.length_decay = float(length_decay)
        self.radius_decay = float(radius_decay)
        self.depth = int(depth)
        self.curvature = float(curvature)
        self.droop = float(droop)
        self.seed = int(seed)
        self.planarity = float(planarity)
        self.split_positions = positions
        self.alternating = bool(alternating)
        self.tip_radius_ratio = float(tip_radius_ratio)
        self.junction_overlap = float(junction_overlap)
        self.section = section
        self.exponent = exponent


class BranchingResult:
    """The queryable tubes and Blender objects produced by ``build_branching``."""

    def __init__(self, tubes):
        self.tubes = tubes
        self.joined_object = None

    @property
    def objects(self):
        if self.joined_object:
            return [self.joined_object]
        return [tube.object for tube in self.tubes if tube.object is not None]

    def join(self, name="Branches", bake_modifiers=True, weld_voxel_size=None):
        """Join branch objects, optionally voxel-unioning their intersecting junctions."""
        if weld_voxel_size is not None and weld_voxel_size <= 0.0:
            raise ValueError("weld_voxel_size must be positive")
        objects = self.objects
        if not objects:
            return None
        if len(objects) == 1:
            objects[0].name = name
            self.joined_object = objects[0]
            if weld_voxel_size is not None:
                _weld_junctions(objects[0], weld_voxel_size)
            return objects[0]

        if bake_modifiers:
            for obj in objects:
                _bake_modifiers(obj)
        bpy.ops.object.select_all(action="DESELECT")
        for obj in objects:
            obj.select_set(True)
        bpy.context.view_layer.objects.active = objects[0]
        bpy.ops.object.join()
        self.joined_object = bpy.context.view_layer.objects.active
        self.joined_object.name = name
        for tube in self.tubes:
            tube.object = None
        if self.tubes:
            self.tubes[0].object = self.joined_object
        if weld_voxel_size is not None:
            _weld_junctions(self.joined_object, weld_voxel_size)
        return self.joined_object


def build_branching(
    spec,
    name="Branches",
    origin=(0.0, 0.0, 0.0),
    direction=(0.0, 0.0, 1.0),
    plane_normal=(0.0, 1.0, 0.0),
    rings=20,
    segments=12,
    rounded_caps=True,
    subsurf=1,
):
    """Build a seeded recursive branch hierarchy and return a ``BranchingResult``."""
    if not isinstance(spec, BranchSpec):
        raise TypeError("spec must be a BranchSpec")
    direction = _unit_vector(direction, "direction")
    plane_normal = _unit_vector(plane_normal, "plane_normal")
    if abs(direction.dot(plane_normal)) > 0.999:
        raise ValueError("plane_normal cannot be parallel to direction")

    rng = random.Random(spec.seed)
    tubes = []
    counter = [0]

    def build_segment(start, heading, length, radius, generation):
        bend_axis = _bend_axis(heading, plane_normal, spec.planarity, rng)
        path = _curved_segment(start, heading, bend_axis, length, spec.curvature, spec.droop)
        root_radius = radius if generation == 0 else radius * 0.08
        tube = SweptTube(
            path,
            Profile([
                (0.0, root_radius),
                (0.10, radius),
                (0.72, radius * 0.9),
                (1.0, radius * spec.tip_radius_ratio),
            ]),
            rings=rings,
            segments=segments,
            section=spec.section,
            exponent=spec.exponent,
            rounded_caps=(rounded_caps if generation == 0 else False, rounded_caps),
        )
        counter[0] += 1
        tube.build(f"{name}_{counter[0]:03d}", subsurf=subsurf)
        tubes.append(tube)

        if generation >= spec.depth or spec.children_per_split == 0:
            return

        for split_index, split_t in enumerate(spec.split_positions):
            parent_tangent = tube.tangent(split_t)
            attachment = tube.point(split_t)
            phase = rng.uniform(0.0, 2.0 * math.pi)
            for child_index in range(spec.children_per_split):
                azimuth = phase + 2.0 * math.pi * child_index / spec.children_per_split
                if spec.alternating:
                    azimuth += math.pi * (split_index % 2)
                planar_parity = child_index + (split_index if spec.alternating else 0)
                radial = _branch_radial(
                    parent_tangent,
                    plane_normal,
                    azimuth,
                    spec.planarity,
                    planar_parity,
                )
                angle = max(
                    0.0,
                    spec.split_angle
                    + rng.uniform(-spec.split_angle_jitter, spec.split_angle_jitter),
                )
                child_heading = (
                    parent_tangent * math.cos(angle) + radial * math.sin(angle)
                ).normalized()
                child_radius = radius * spec.radius_decay
                child_start = attachment - parent_tangent * (
                    child_radius * spec.junction_overlap
                )
                build_segment(
                    child_start,
                    child_heading,
                    length * spec.length_decay,
                    child_radius,
                    generation + 1,
                )

    build_segment(Vector(origin), direction, spec.trunk_length, spec.radius, 0)
    return BranchingResult(tubes)


def _sample_path(path, sample_count):
    if callable(path):
        if sample_count < 2:
            raise ValueError("sample_count must be at least 2")
        points = [Vector(path(i / (sample_count - 1))) for i in range(sample_count)]
    else:
        points = [Vector(point) for point in path]
    if len(points) < 2:
        raise ValueError("path must provide at least two points")

    filtered = [points[0]]
    for point in points[1:]:
        if (point - filtered[-1]).length > _EPSILON:
            filtered.append(point)
    if len(filtered) < 2:
        raise ValueError("path must have non-zero length")
    return filtered


def _resample_polyline(points, count):
    cumulative = [0.0]
    for previous, current in zip(points, points[1:]):
        cumulative.append(cumulative[-1] + (current - previous).length)
    total = cumulative[-1]
    result = []
    for i in range(count):
        distance = total * i / (count - 1)
        segment = min(bisect.bisect_right(cumulative, distance) - 1, len(points) - 2)
        span = cumulative[segment + 1] - cumulative[segment]
        blend = (distance - cumulative[segment]) / span
        result.append(points[segment].lerp(points[segment + 1], blend))
    return result


def _path_tangents(points):
    tangents = []
    for index in range(len(points)):
        if index == 0:
            delta = points[1] - points[0]
        elif index == len(points) - 1:
            delta = points[-1] - points[-2]
        else:
            delta = points[index + 1] - points[index - 1]
        if delta.length < _EPSILON:
            raise ValueError("resampled path contains a degenerate tangent")
        tangents.append(delta.normalized())
    return tangents


def _parallel_transport_frames(tangents, up):
    tangent = tangents[0]
    normal = up - tangent * up.dot(tangent)
    if normal.length < _EPSILON:
        fallback = min(
            (Vector((1.0, 0.0, 0.0)), Vector((0.0, 1.0, 0.0)), Vector((0.0, 0.0, 1.0))),
            key=lambda axis: abs(axis.dot(tangent)),
        )
        normal = fallback - tangent * fallback.dot(tangent)
    normal.normalize()
    frames = [(normal.copy(), tangent.cross(normal).normalized())]

    # Parallel transport carries one frame through inflections; a Frenet normal flips
    # there and makes an otherwise valid sweep look like a shredded modelling mistake.
    for previous, current in zip(tangents, tangents[1:]):
        axis = previous.cross(current)
        cosine = max(-1.0, min(1.0, previous.dot(current)))
        if axis.length > _EPSILON:
            sine = axis.length
            axis.normalize()
            normal = Quaternion(axis, math.atan2(sine, cosine)) @ normal
        elif cosine < 0.0:
            # At an exact reversal the minimal rotation is undefined. Keeping the normal
            # is equivalent to choosing a half-turn about it; the binormal flips below.
            normal = normal.copy()
        normal -= current * normal.dot(current)
        normal.normalize()
        frames.append((normal.copy(), current.cross(normal).normalized()))
    return frames


def _twist_frame(normal, binormal, tangent, angle):
    if abs(angle) < _EPSILON:
        return normal, binormal
    rotation = Quaternion(tangent, angle)
    return (rotation @ normal).normalized(), (rotation @ binormal).normalized()


def _twist_function(twist):
    if isinstance(twist, Real):
        total = float(twist)
        return lambda t: total * t
    profile = twist if isinstance(twist, Profile) else as_profile(twist)
    return lambda t: float(profile(t))


def _sample_index(t, count):
    position = _clamp01(t) * (count - 1)
    index = min(int(position), count - 2)
    return index, position - index


def _clamp01(value):
    return max(0.0, min(1.0, float(value)))


def _bridge_rings(bm, previous, current):
    count = len(previous)
    for index in range(count):
        following = (index + 1) % count
        bm.faces.new((previous[index], previous[following], current[following], current[index]))


def _cap_ring(bm, pole, ring):
    for index in range(len(ring)):
        following = (index + 1) % len(ring)
        bm.faces.new((pole, ring[index], ring[following]))


def _unit_vector(value, label):
    vector = Vector(value)
    if vector.length < _EPSILON:
        raise ValueError(f"{label} must be non-zero")
    return vector.normalized()


def _basis_around(direction):
    reference = min(
        (Vector((1.0, 0.0, 0.0)), Vector((0.0, 1.0, 0.0)), Vector((0.0, 0.0, 1.0))),
        key=lambda axis: abs(axis.dot(direction)),
    )
    first = (reference - direction * reference.dot(direction)).normalized()
    return first, direction.cross(first).normalized()


def _branch_radial(direction, plane_normal, azimuth, planarity, parity):
    first, second = _basis_around(direction)
    spatial = first * math.cos(azimuth) + second * math.sin(azimuth)
    planar = plane_normal.cross(direction)
    if planar.length < _EPSILON:
        planar = first
    else:
        planar.normalize()
    if parity % 2:
        planar.negate()
    radial = spatial * (1.0 - planarity) + planar * planarity
    return radial.normalized() if radial.length > _EPSILON else planar


def _bend_axis(direction, plane_normal, planarity, rng):
    first, second = _basis_around(direction)
    angle = rng.uniform(0.0, 2.0 * math.pi)
    spatial = first * math.cos(angle) + second * math.sin(angle)
    planar = plane_normal.cross(direction)
    if planar.length < _EPSILON:
        planar = first
    else:
        planar.normalize()
    bend = spatial * (1.0 - planarity) + planar * planarity
    return bend.normalized() if bend.length > _EPSILON else planar


def _curved_segment(start, direction, bend_axis, length, curvature, droop):
    down = Vector((0.0, 0.0, -1.0))

    def path(t):
        return (
            start
            + direction * (length * t)
            + bend_axis * (length * curvature * t * t)
            + down * (length * droop * t * t)
        )

    return path


def _bake_modifiers(obj):
    # Joining keeps only the active object's modifier stack, so every branch must be
    # evaluated first or all but one silently revert to their coarse control cages.
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = obj.evaluated_get(depsgraph)
    baked = bpy.data.meshes.new_from_object(evaluated)
    previous = obj.data
    obj.modifiers.clear()
    obj.data = baked
    if previous.users == 0:
        bpy.data.meshes.remove(previous)


def _weld_junctions(obj, voxel_size):
    if voxel_size <= 0.0:
        raise ValueError("weld_voxel_size must be positive")
    if obj.modifiers:
        _bake_modifiers(obj)
    remesh = obj.modifiers.new("Junction Union", "REMESH")
    remesh.mode = "VOXEL"
    remesh.voxel_size = float(voxel_size)
    remesh.use_smooth_shade = True
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.modifier_apply(modifier=remesh.name)
    shade_smooth(obj.data)

    # A voxel union trades intersection seams for a quantized surface; one subdivision
    # level restores the organic highlight without materially changing the silhouette.
    subdivision = obj.modifiers.new("Junction Smoothing", "SUBSURF")
    subdivision.levels = 1
    subdivision.render_levels = 1
