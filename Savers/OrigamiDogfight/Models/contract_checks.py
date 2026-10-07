"""Contract checks for the parts the runtime moves or ties things to, by name.

`build_model.py` runs these after a model is seated and before anything is written, so a
crane whose wing would flap about the wrong line, or a windmill whose sails would cut its own
tower, fails its build instead of reaching the saver. `docs/origami-plan.md` "Asset contract"
is the binding statement of what they enforce.

Every check reads the scene in Blender's axes: nose / front +X, left +Y, up +Z.
"""

import math

_ON_AXIS = 1e-6   # metres; a vertex this close to a hinge line is on it


class ContractError(RuntimeError):
    pass


def _unrotated_leaf(name, obj):
    if obj.type != "MESH":
        raise ContractError(f"{name}: {obj.name} must be a mesh")
    if obj.children:
        raise ContractError(f"{name}: {obj.name} must be one node, but has children "
                            f"{[c.name for c in obj.children]}")
    if any(abs(a) > 1e-9 for a in obj.rotation_euler) or obj.rotation_mode != "XYZ":
        raise ContractError(f"{name}: {obj.name} must arrive unrotated, so the runtime's "
                            f"angle is absolute")


def check_wings(name, root, extra):
    """A bird's body is the root mesh; `wing_l` and `wing_r` are its only children, each
    hinged on its own root edge, which lies on the node's local X axis through its origin.

    Manifest: `wings` = {"axis": [1, 0, 0], "nodes": [{"node", "pivot", "lift"}, ...],
    "range": [down, up]}. `lift` is the sign of a turn about the node's own +X that raises
    the wing; `range` is how far, in degrees of lift, a wing may travel.
    """
    if root.type != "MESH":
        raise ContractError(f"{name}: a bird's body is its root mesh")
    wings = extra.get("wings")
    if not isinstance(wings, dict) or wings.get("axis") != [1, 0, 0]:
        raise ContractError(f"{name}: manifest wings must turn about [1, 0, 0], got {wings!r}")
    entries = {entry.get("node"): entry for entry in wings.get("nodes", [])}
    if set(entries) != {"wing_l", "wing_r"} or len(wings["nodes"]) != 2:
        raise ContractError(f"{name}: manifest wings must name wing_l and wing_r, got "
                            f"{list(entries)}")
    if entries["wing_l"].get("lift") != 1 or entries["wing_r"].get("lift") != -1:
        raise ContractError(f"{name}: about +X, a positive turn lifts wing_l and lowers wing_r")
    down, up = wings.get("range", (0, 0))
    if not -90 <= down < 0 < up <= 90:
        raise ContractError(f"{name}: wing range {wings.get('range')!r} must span level")

    children = {obj.name: obj for obj in root.children}
    if set(children) != {"wing_l", "wing_r"}:
        raise ContractError(f"{name}: a bird's children are wing_l and wing_r, got "
                            f"{sorted(children)}")
    for label, side in (("wing_l", 1.0), ("wing_r", -1.0)):
        wing = children[label]
        _unrotated_leaf(name, wing)
        local = [v.co for v in wing.data.vertices]
        hinge = [p.x for p in local if abs(p.y) < _ON_AXIS and abs(p.z) < _ON_AXIS]
        if len(hinge) < 2 or not min(hinge) < 0.0 < max(hinge):
            raise ContractError(f"{name}: {label}'s root edge must lie on its local X axis, "
                                f"either side of its origin; on-axis x: {sorted(hinge)}")
        if any(p.y * side < -_ON_AXIS for p in local):
            raise ContractError(f"{name}: {label} reaches across its own hinge")
    left, right = children["wing_l"].location, children["wing_r"].location
    if (abs(left.x - right.x) > 1e-6 or abs(left.z - right.z) > 1e-6
            or abs(left.y + right.y) > 1e-6):
        raise ContractError(f"{name}: the wings' hinges do not mirror: {tuple(left)} and "
                            f"{tuple(right)}")

    body = [v.co for v in root.data.vertices]
    length = max(p.x for p in body) - min(p.x for p in body)
    width = max(p.y for p in body) - min(p.y for p in body)
    if length < 4.0 * width:
        raise ContractError(f"{name}: the body does not lie along X ({length:.4f} long, "
                            f"{width:.4f} wide)")


def check_blades(name, root, meshes, extra):
    """`blades` is one node, origin at the hub, balanced about its local X axis, and its
    sails clear everything else at every angle.

    Manifest: `blades` = {"node": "blades", "hub", "axis": [1, 0, 0], "radius", "turn"};
    `radius` is the sails' reach from the axis, `turn` the sign of the turn about +X that
    the wind drives them in.
    """
    entry = extra.get("blades")
    if (not isinstance(entry, dict) or entry.get("node") != "blades"
            or entry.get("axis") != [1, 0, 0] or entry.get("turn") not in (1, -1)):
        raise ContractError(f"{name}: manifest blades must name the node, axis [1, 0, 0] and "
                            f"a turn of 1 or -1, got {entry!r}")
    found = [obj for obj in root.children if obj.name == "blades"]
    if len(found) != 1:
        raise ContractError(f"{name}: needs exactly one child named blades")
    blades = found[0]
    _unrotated_leaf(name, blades)
    local = [v.co for v in blades.data.vertices]
    reach = max(math.hypot(p.y, p.z) for p in local)
    if abs(reach - entry.get("radius", 0.0)) > 1e-4:
        raise ContractError(f"{name}: the sails reach {reach:.4f} m, the manifest says "
                            f"{entry.get('radius')!r}")
    for axis in (1, 2):
        lo, hi = min(p[axis] for p in local), max(p[axis] for p in local)
        if abs(lo + hi) > 0.05 * reach:
            raise ContractError(f"{name}: the blades are not balanced on their hub "
                                f"({'xyz'[axis]} {lo:.3f}..{hi:.3f})")

    _check_sweep(name, blades, [obj for obj in meshes if obj is not blades], reach)


def _triangles(obj, origin):
    """Every face of `obj` as triangles, in world space relative to `origin`."""
    world = [obj.matrix_world @ v.co - origin for v in obj.data.vertices]
    for polygon in obj.data.polygons:
        corners = list(polygon.vertices)
        for k in range(1, len(corners) - 1):
            yield world[corners[0]], world[corners[k]], world[corners[k + 1]]


def _nearest_to_axis(triangle):
    """How close the triangle comes to the X axis: its distance from the origin in the
    YZ plane, where the axis is a point."""
    points = [(p.y, p.z) for p in triangle]
    sides = [(b[0] - a[0]) * (0.0 - a[1]) - (b[1] - a[1]) * (0.0 - a[0])
             for a, b in zip(points, points[1:] + points[:1])]
    if all(s >= 0 for s in sides) or all(s <= 0 for s in sides):
        return 0.0
    best = math.inf
    for (ax, ay), (bx, by) in zip(points, points[1:] + points[:1]):
        dx, dy = bx - ax, by - ay
        length = dx * dx + dy * dy
        t = 0.0 if length == 0.0 else max(0.0, min(1.0, -(ax * dx + ay * dy) / length))
        best = min(best, math.hypot(ax + t * dx, ay + t * dy))
    return best


def _check_sweep(name, blades, others, reach):
    """Nothing else may stand inside the volume the blades sweep about their X axis.

    At each distance from the axis the blades sweep a ring whose back is the furthest back
    any blade surface reaches at that distance (taken per triangle, which over-reaches and
    so errs safe); every other surface within `reach` must stand behind that ring. Surfaces
    are sampled, not just their corners, because a tapering tower's wall comes nearest the
    sails between its corners. The windshaft, within 6% of `reach` of the axis, is meant to
    run back into the cap and is exempt.
    """
    hub = blades.matrix_world.translation.copy()
    shaft, bins = 0.06 * reach, 400
    width = reach * 1.001 / bins
    back = [math.inf] * bins
    for triangle in _triangles(blades, hub):
        outer = max(math.hypot(p.y, p.z) for p in triangle)
        if outer <= shaft:
            continue
        lowest = min(p.x for p in triangle)
        first = int(_nearest_to_axis(triangle) / width)
        for b in range(first, min(int(outer / width), bins - 1) + 1):
            back[b] = min(back[b], lowest)
    margin, deepest = 0.02 * reach, min(back)
    for obj in others:
        for triangle in _triangles(obj, hub):
            if (max(p.x for p in triangle) <= deepest - margin
                    or _nearest_to_axis(triangle) > reach):
                continue
            a, b, c = triangle
            longest = max((b - a).length, (c - b).length, (a - c).length)
            steps = max(1, min(200, math.ceil(longest / (0.01 * reach))))
            for i in range(steps + 1):
                for j in range(steps + 1 - i):
                    p = a + (b - a) * (i / steps) + (c - a) * (j / steps)
                    radius = math.hypot(p.y, p.z)
                    if radius <= shaft or radius > reach:
                        continue
                    k = min(int(radius / width), bins - 1)
                    if p.x > min(back[max(k - 1, 0):k + 2]) - margin:
                        raise ContractError(
                            f"{name}: turning, the blades would cut {obj.name} at "
                            f"{tuple(round(v, 3) for v in p + hub)}")


def check_hangs_from_origin(name, meshes):
    """The lowest point is the knot the model hangs from, on its vertical axis, so the
    runtime ties it on by its origin."""
    points = [obj.matrix_world @ v.co for obj in meshes for v in obj.data.vertices]
    lowest = min(p.z for p in points)
    if abs(lowest) > 1e-6:
        raise ContractError(f"{name}: the knot must be at z = 0, lowest point {lowest:+.6f}")
    stray = [p for p in points if p.z < 1e-4 and math.hypot(p.x, p.y) > 1e-4]
    if stray:
        raise ContractError(f"{name}: something hangs as low as the knot, off its axis, at "
                            f"{tuple(round(v, 5) for v in stray[0])}")


def check_opening(name, opening, bounds):
    """A building's open end: its centre on the floor at the front (+X) of the model, its
    clear width and height inside the model's own."""
    lo, hi = bounds
    centre, width, height = opening.get("centre"), opening.get("width"), opening.get("height")
    if not (isinstance(centre, list) and len(centre) == 3
            and all(isinstance(v, (int, float)) and math.isfinite(v) for v in centre)):
        raise ContractError(f"{name}: opening centre {centre!r} is not a point")
    if (abs(centre[0] - hi.x) > 1e-3 or abs(centre[1] - (lo.y + hi.y) * 0.5) > 1e-3
            or abs(centre[2] - lo.z) > 1e-6):
        raise ContractError(f"{name}: the opening must be centred on the floor at the front, "
                            f"got {centre}")
    if not (0 < width <= hi.y - lo.y and 0 < height <= hi.z - lo.z):
        raise ContractError(f"{name}: opening {width} x {height} m does not fit the model")
