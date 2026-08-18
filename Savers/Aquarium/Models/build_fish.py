"""Assemble a fish from its species definition, then render and/or export it.

Run through `tools/blender/run.sh`, which puts `saverlib` on the path:

    tools/blender/run.sh Savers/Aquarium/Models/build_fish.py -- \
        --species clownfish --preview --export build/clownfish.usdz
"""

import argparse
import json
import math
import os
import sys
import time

import bpy
from mathutils import Vector

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.abspath(os.path.join(_HERE, "..", "..", ".."))
sys.path[:0] = [os.path.join(_REPO, "tools", "blender"), _HERE]

from saverlib import (  # noqa: E402
    Body, BodySpec, CurvedBody, CurvedBodySpec, assign, build_fin, caudal_root,
    dorsal_root, eye_material, fin_material, fish_material, flank_root, studio,
    ventral_root,
)
from saverlib.bake import (  # noqa: E402
    DEFAULT_MARGIN,
    DEFAULT_RESOLUTION,
    DEFAULT_UV_MARGIN,
    bake_atlas,
)
from species import CATALOG  # noqa: E402


# Surface relief ships in the normal atlas. At tank scale these meshes need enough geometry
# for a clean silhouette, not enough to reproduce details that the texture already carries.
_BODY_RINGS = 40
# A swept body spends its rings on a path that turns through most of a circle rather
# than on a nearly straight one, so it needs more of them to stay smooth round the bend.
_SWEPT_RINGS = 96
_BODY_SEGMENTS = 16
_BODY_SUBSURF = 1
_FIN_SUBSURF = 0
_EYE_SEGMENTS = 20
_EYE_RINGS = 12

# The per-vertex part channel: which movable part a vertex belongs to, and how far out along
# that part it sits. It is what lets one geometry shader modifier beat the pectoral fins
# without touching the rest of the fish — see `swimModifier` in `SwimDeformation.swift`.
#
# It is authored here as a POINT colour attribute on every mesh *before* modifiers are
# evaluated, so Solidify and subdivision propagate it the way they propagate geometry, and it
# is transcoded to a second UV set after the atlas bake (`_part_uv`). Both halves of that are
# forced: SceneKit drops vertex colour entirely on macOS 26, and `bake_atlas` deletes every UV
# layer that exists when it runs, so the colour attribute is the only channel that survives the
# middle of the pipeline and a UV set is the only one that survives the end of it.
_PART_CHANNEL = "displayColor"
_PART_UV = "st1"

# Part ids ride in R. Both ends of the range are reserved: 0 is "no part", and 1 is what
# Blender's join fills in for a mesh that arrived without the attribute at all — so a real id
# must be strictly interior, or an omitted part would silently lose its id and never move.
# The shader matches with a tolerance window, never with equality.
_NO_PART = 0.0
_PECTORAL_IDS = {1.0: 0.25, -1.0: 0.35}
# A dorsal membrane that undulates on its own. It rides the same `finPhase` and
# `finAmplitude` the pectorals do rather than asking for uniforms of its own, because
# the shader's argument block has sixteen spare bytes against a cliff it falls off
# silently — see `spikes/010-shader-uniform-block/README.md`. A new *id* is free; a new
# *uniform* very nearly is not.
_RIPPLE_ID = 0.45


def _body(spec):
    """The body, and the height and length its skin material is scaled against.

    Two shapes of animal, one interface. A lofted body is a depth above and below a
    straight backbone; a swept one is a section carried along a curve, which is what an
    animal that doubles back on itself needs — see `saverlib.curved`. Everything after
    this point, fins and eyes and markings alike, asks the same questions of either.
    """
    if spec.is_swept:
        body = CurvedBody(
            CurvedBodySpec(
                path=spec.path,
                radius=spec.radius,
                section=spec.section,
                exponent=spec.exponent,
                up=spec.body_up,
                dorsal_at=spec.dorsal_at,
            ),
            rings=_SWEPT_RINGS,
            segments=_BODY_SEGMENTS,
        )
        low, high = body.bounds()
        return body, (high.z - low.z) / 2.0, high.x - low.x

    body_spec = BodySpec(
        length=spec.length,
        width=spec.width,
        top=spec.top,
        bottom=spec.bottom,
        spine=spec.spine,
        exponent=spec.exponent,
    )
    return (Body(body_spec, rings=_BODY_RINGS, segments=_BODY_SEGMENTS),
            max(body_spec.top.peak, body_spec.bottom.peak),
            spec.length)


def build(spec):
    body, body_height, body_length = _body(spec)

    root = bpy.data.objects.new(f"Fish_{spec.name}", None)
    bpy.context.collection.objects.link(root)

    body_obj = body.build(f"{spec.name}_body", subsurf=_BODY_SUBSURF)
    body_obj.parent = root

    belly, mid, back = spec.colors
    skin = fish_material(
        f"{spec.name}_skin",
        belly=belly, mid=mid, back=back,
        body_height=body_height,
        body_length=body_length,
        scale_count=spec.scale_count,
        scale_depth=spec.scale_depth,
        bands=spec.bands,
        band_color=spec.band_color,
        band_softness=spec.band_softness,
        outline_color=spec.outline_color,
        outline_width=spec.outline_width,
        stripes=spec.stripes,
        stripe_color=spec.stripe_color,
        stripe_softness=spec.stripe_softness,
        diagonal_stripes=spec.diagonal_stripes,
        spots=spec.spots,
        patches=spec.patches,
        split=spec.split,
        mouth=spec.mouth,
        mouth_color=spec.mouth_color,
        eye_ring=_eye_ring(spec, body),
    )
    assign(body_obj, skin)

    membranes = _fin_materials(spec)
    for obj, kind, fin in _build_fins(spec, body):
        obj.parent = root
        assign(obj, membranes(kind, fin))

    iris = eye_material(f"{spec.name}_eye")
    for obj in _build_eyes(spec, body):
        obj.parent = root
        assign(obj, iris)

    # Everything that is not a labelled moving part still has to say so. A mesh that reaches
    # the join without the channel is filled *white* by Blender, which is the id the shader
    # must never see — so this sweeps the whole fish rather than being called beside each
    # part, and a part added later is caught instead of silently losing its id and never moving.
    for child in root.children_recursive:
        if child.type == "MESH" and _PART_CHANNEL not in child.data.color_attributes:
            _part_channel(child)

    return root


def _fin_materials(spec):
    """Resolve each fin to its membrane material, one material per distinct look.

    A fin takes the species' `fin_color`/`fin_style` — `caudal_color`/`caudal_style` for
    the tail — unless it overrides either itself. Fins that end up asking for the same
    pair share a material, so the common case of every fin looking alike still builds
    exactly one, and a species that styles four fins separately builds four rather than
    one per fin instance.
    """
    built = []

    def resolve(kind, fin):
        caudal = kind == "caudal"
        default_color = spec.caudal_color if caudal else spec.fin_color
        default_style = spec.caudal_style if caudal else spec.fin_style
        color = tuple(default_color if fin.color is None else fin.color)
        style = default_style if fin.style is None else fin.style
        for known_color, known_style, material in built:
            if known_color == color and known_style == style:
                return material
        material = fin_material(f"{spec.name}_{kind}_fin", color, **(style or {}))
        built.append((color, style, material))
        return material

    return resolve


def _eye_placement(spec, body):
    """Where the eye sits on the body surface, and how big it is."""
    t, height, radius_frac = spec.eye
    return body.surface_point(t, height * (math.pi / 2.0)), radius_frac * spec.length


def _eye_ring(spec, body):
    """Turn `Species.eye_ring` into the annulus `fish_material` draws.

    The species gives a colour (or a colour plus a width); the placement is derived from
    `Species.eye` so the ring cannot drift away from the eye it belongs to when the eye
    moves.
    """
    if not spec.eye_ring:
        return None
    params = dict(spec.eye_ring) if isinstance(spec.eye_ring, dict) \
        else {"color": spec.eye_ring}
    point, radius = _eye_placement(spec, body)
    params.setdefault("center", (point.x, 0.0, point.z))
    params.setdefault("radius", radius)
    return params


def _part_channel(obj, part_id=_NO_PART, distance=None):
    """Write the part channel onto one mesh, before its modifiers are evaluated.

    `distance(vertex_index)` gives how far that vertex lies from the part's hinge, in the
    model's own units; it is stored raw and normalized by the finished body's length in
    `_part_uv`, which is the only place that length is known. Everything that does not move
    on its own — body, eyes, every fin but the pectorals — gets `_NO_PART` and a zero
    distance, which the shader reads as "leave this vertex alone".
    """
    mesh = obj.data
    attribute = mesh.color_attributes.get(_PART_CHANNEL) or mesh.color_attributes.new(
        name=_PART_CHANNEL, type="FLOAT_COLOR", domain="POINT"
    )
    mesh.color_attributes.active_color = attribute
    mesh.color_attributes.render_color_index = mesh.color_attributes.find(_PART_CHANNEL)

    values = []
    for index in range(len(mesh.vertices)):
        values.extend((part_id, 0.0 if distance is None else distance(index), 0.0, 1.0))
    attribute.data.foreach_set("color", values)
    mesh.update()
    return obj


def _hinged_channel(obj, fin, root, part_id):
    """Label a fin with its part id and true hinge-to-vertex distance.

    Both kinds of moving fin need the same measurement: a beat is a hinge about the root
    and a ripple grows with distance from it, so either way the shader needs the actual
    lever arm after `build_fin` has applied span, flare, rake, and curl. The freshly
    authored mesh still has both its vertex coordinates and the same `root(u)` callable
    used to build it; the vertex index recovers u before modifiers add or interpolate
    geometry.
    """
    samples_u, samples_v = fin.samples_u, fin.samples_v

    def distance(index):
        i, _ = divmod(index, samples_v)
        hinge = Vector(root(i / (samples_u - 1)))
        return (obj.data.vertices[index].co - hinge).length

    return _part_channel(obj, part_id, distance)


def _part_uv(joined):
    """Move the part channel into the second UV set and drop the colour attribute.

    Runs immediately before export. On a baked path that must be after `bake_atlas`, which
    removes every UV layer that exists when it runs. The distance stored per vertex is
    normalized here by the finished mesh's own length along X, which is exactly the `bodyLength`
    uniform the runtime measures
    from the imported geometry: the shader multiplies by it and gets the authored distance back
    in object units, so `finAmplitude` is an angle in radians for every species alike.

    The V flip is SceneKit's, not ours: its USD importer flips V on import, so the value
    written here is pre-flipped to arrive the right way up.
    """
    mesh = joined.data
    source = mesh.color_attributes.get(_PART_CHANNEL)
    if source is None:
        raise RuntimeError(f"'{joined.name}' lost its part channel before the transcode")
    if source.domain != "POINT":
        raise RuntimeError(
            f"'{joined.name}' part channel has domain {source.domain!r}, expected 'POINT'"
        )
    material_uv = mesh.uv_layers.active
    if material_uv is None:
        raise RuntimeError(f"'{joined.name}' has no material UV layer to keep active")

    xs = [vertex.co.x for vertex in mesh.vertices]
    length = max(max(xs) - min(xs), 1e-6)

    colors = [0.0] * (len(source.data) * 4)
    source.data.foreach_get("color", colors)
    coordinates = []
    for loop in mesh.loops:
        base = loop.vertex_index * 4
        coordinates.extend((colors[base], 1.0 - colors[base + 1] / length))

    channel = mesh.uv_layers.new(name=_PART_UV)
    channel.data.foreach_set("uv", coordinates)
    # The material UV stays the render layer, which is what makes it export as `st` with the
    # part channel following as `st1`; SceneKit then hands them over as texcoords 0 and 1.
    mesh.uv_layers.active = material_uv
    material_uv.active_render = True
    mesh.update()

    # The data now lives in `st1`, and a `displayColor` left behind would render this fish
    # black-and-red in any consumer that honours it.
    mesh.color_attributes.remove(source)

    parts = sorted({round(colors[i * 4], 4) for i in range(len(mesh.vertices))})
    print(f"[build_fish] part channel -> {_PART_UV}: ids {parts}, body length {length:.4f}")
    return channel


def _fin_uv(obj, samples_u, samples_v, name="UVMap"):
    """Write the fin's own (along-root, root-to-tip) coordinate into a UV layer.

    `build_fin` lays its grid out as one column of v per u, so a vertex's index still
    carries the (u, v) it was built at; the UV then rides through solidify, subdivision
    and the join, which no object-space coordinate can do — each fin points a different
    way and none of them keeps an origin of its own after `join_parts`.

    The layer is deliberately named UVMap, which is also what the eye spheres' own UVs
    are called: the join merges layers by name, and a second layer would leave the fin
    material reading whichever one the join happened to mark active for rendering.
    """
    mesh = obj.data
    uv = mesh.uv_layers.get(name) or mesh.uv_layers.new(name=name)
    coordinates = []
    for loop in mesh.loops:
        u, v = divmod(loop.vertex_index, samples_v)
        coordinates.extend((u / (samples_u - 1), v / (samples_v - 1)))
    uv.data.foreach_set("uv", coordinates)
    mesh.update()
    return obj


def _build_fins(spec, body):
    """Return (object, kind, Fin) triples, `kind` being the species field the fin came
    from. The authored grid is already dense enough for a smooth tank-scale silhouette,
    so fins get only a very thin solidify; subdivision adds geometry without visible benefit.

    The kind travels with the object because it is what picks the fin's material: the
    caudal falls back to the species' tail colours and everything else to its fin
    colours, and the two mirrored copies of a paired fin must land on one material.
    """
    fins = []
    up = Vector((0.0, 0.0, 1.0))
    down = Vector((0.0, 0.0, -1.0))
    common = dict(thickness=0.0012, subsurf=_FIN_SUBSURF)

    if spec.dorsal:
        f = spec.dorsal
        root = dorsal_root(body, f.t0, f.t1, sink=f.sink)
        obj = build_fin(
            f"{spec.name}_dorsal",
            root=root,
            out_dir=lambda u: up, span=f.span, rake=f.rake, curl=f.curl, flare=f.flare,
            curl_axis=(0, 1, 0), samples_u=f.samples_u, samples_v=f.samples_v, **common,
        )
        if f.ripples:
            _hinged_channel(obj, f, root, _RIPPLE_ID)
        fins.append((obj, "dorsal", f))

    if spec.anal:
        f = spec.anal
        fins.append((build_fin(
            f"{spec.name}_anal",
            root=ventral_root(body, f.t0, f.t1, sink=f.sink),
            out_dir=lambda u: down, span=f.span, rake=f.rake, curl=f.curl, flare=f.flare,
            curl_axis=(0, 1, 0), samples_u=f.samples_u, samples_v=f.samples_v, **common,
        ), "anal", f))

    if spec.caudal:
        f = spec.caudal
        fins.append((build_fin(
            f"{spec.name}_caudal",
            root=caudal_root(body, t=1.0, spread=spec.caudal_spread),
            out_dir=lambda u: Vector((-1.0, 0.0, 0.0)),
            span=f.span, rake=f.rake, curl=f.curl, flare=f.flare,
            curl_axis=(0, 1, 0), samples_u=f.samples_u, samples_v=f.samples_v, **common,
        ), "caudal", f))

    # Paired fins are mirrored onto both flanks.
    for attr, theta_frac, direction in (
        ("pectoral", 0.10, Vector((-0.20, 0.92, -0.32))),
        ("pelvic", 0.80, Vector((-0.10, 0.42, -0.90))),
    ):
        f = getattr(spec, attr)
        if not f:
            continue
        theta = 2.0 * math.pi * theta_frac
        for side in (1.0, -1.0):
            mirrored = Vector((direction.x, direction.y * side, direction.z))
            root = flank_root(body, f.t0, f.t1, theta, side=side, sink=f.sink)
            obj = build_fin(
                f"{spec.name}_{attr}_{'L' if side > 0 else 'R'}",
                root=root,
                out_dir=lambda u, d=mirrored: d,
                span=f.span, rake=f.rake, curl=f.curl * side, flare=f.flare,
                curl_axis=(0, 0, 1), samples_u=f.samples_u, samples_v=f.samples_v,
                **common,
            )
            # The pectorals are the only fins that beat on their own, so they are the only
            # ones that carry a part id. The side is known here and is written into the id
            # rather than left for the shader to infer from the sign of a vertex's y: by the
            # time the shader runs, y is a coordinate the swim wave is also displacing.
            if attr == "pectoral":
                _hinged_channel(obj, f, root, _PECTORAL_IDS[side])
            fins.append((obj, attr, f))

    return [(_fin_uv(obj, f.samples_u, f.samples_v), kind, f)
            for obj, kind, f in fins]


def _bake_modifiers(obj):
    """Replace an object's mesh with its fully evaluated form.

    Blender's USD exporter writes a subdivision *scheme* rather than tessellated
    geometry, and SceneKit ignores the scheme — so an un-baked export arrives as the
    coarse control cage. Baking here also lets parts be joined without losing the
    per-part modifier stacks, since join() keeps only the active object's modifiers.
    """
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = obj.evaluated_get(depsgraph)
    baked = bpy.data.meshes.new_from_object(evaluated)
    previous = obj.data
    obj.modifiers.clear()
    obj.data = baked
    if previous.users == 0:
        bpy.data.meshes.remove(previous)


def join_parts(root, name):
    """Collapse a fish into a single mesh with one material slot per part.

    Two reasons, both load-bearing. A school is one draw call per fish instead of ten,
    and — more importantly — every vertex ends up in a single object space, so the swim
    deformation can be expressed in local coordinates. Deforming separate parts requires
    world space, and `u_modelTransform` inside a SceneKit geometry modifier does not
    behave, so a joined mesh removes the need for it entirely.
    """
    meshes = [child for child in root.children_recursive if child.type == "MESH"]
    if len(meshes) < 2:
        return meshes[0] if meshes else None

    for obj in meshes:
        _bake_modifiers(obj)

    # Check the evaluated meshes that actually enter the join. Join fills a missing colour
    # attribute with white, so an affected part would silently lose its id and never move.
    # It is cheaper to refuse to build than to find that in a render.
    missing = [obj.name for obj in meshes if _PART_CHANNEL not in obj.data.color_attributes]
    if missing:
        raise RuntimeError(f"part channel missing on: {', '.join(missing)}")

    bpy.ops.object.select_all(action="DESELECT")
    for obj in meshes:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    bpy.ops.object.join()

    joined = bpy.context.view_layer.objects.active
    joined.name = name
    joined.parent = None
    joined.matrix_world.identity()
    return joined


def _build_eyes(spec, body):
    """Two spheres seated into the head, sized by `Species.eye`.

    The trap in here is the 0.62 below: the eye's centre is pushed only 62% of the way
    out to the flank, so the sphere has to be *wider than that remaining 38%* to show at
    all. On a narrow head — a snout, a small fish, anything whose half-width at the eye's
    t is a couple of millimetres — a plausible-sounding radius is swallowed whole and the
    face renders blank, which looks like a missing object rather than a small number.

    So the radius is a fraction of body *length*, not of the local width, and if a face
    comes back with no eyes on it the fix is to raise `radius/length` (the third element
    of `eye`) rather than to go hunting for a build failure. Lowering the second element
    moves the eye down the flank, where the body is at its widest and the sphere has the
    most room; putting it up near the spine is the same problem again.
    """
    point, radius = _eye_placement(spec, body)

    eyes = []
    for side in (1.0, -1.0):
        bpy.ops.mesh.primitive_uv_sphere_add(
            radius=radius, segments=_EYE_SEGMENTS, ring_count=_EYE_RINGS
        )
        eye = bpy.context.active_object
        eye.name = f"{spec.name}_eye_{'L' if side > 0 else 'R'}"
        # Seat the eye into the socket so a sliver of sphere sits proud of the skin;
        # resting it on the surface reads as a bead glued to the head.
        eye.location = Vector((point.x, math.copysign(abs(point.y) * 0.62, side), point.z))
        eye.scale = (1.0, 0.85, 1.0)
        for polygon in eye.data.polygons:
            polygon.use_smooth = True
        eyes.append(eye)
    return eyes


def _join(fish, spec):
    joined = join_parts(fish, f"fish_{spec.name}")
    if joined is None:
        raise RuntimeError(f"building '{spec.name}' produced no mesh")
    joined.data.calc_loop_triangles()
    print(f"[build_fish] joined into '{joined.name}': "
          f"{len(joined.data.vertices)} verts, "
          f"{len(joined.data.loop_triangles)} triangles, "
          f"{len(joined.data.materials)} material slots, "
          f"uv layers {[layer.name for layer in joined.data.uv_layers]}")
    return joined


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--species", default="clownfish", choices=sorted(CATALOG))
    parser.add_argument("--out", default=os.path.join(_REPO, "build", "fish"))
    parser.add_argument("--render", action="store_true", help="studio turntable")
    parser.add_argument("--preview", action="store_true", help="underwater lighting")
    parser.add_argument("--export", default=None, help="write a .usdz to this path")
    parser.add_argument("--bake", action="store_true",
                        help="bake procedural materials before export")
    parser.add_argument("--textures", default=None,
                        help="directory for baked atlas PNGs; defaults beside the export")
    parser.add_argument("--resolution", type=int, default=DEFAULT_RESOLUTION)
    parser.add_argument("--margin", type=int, default=DEFAULT_MARGIN)
    parser.add_argument("--uv-margin", type=float, default=DEFAULT_UV_MARGIN)
    parser.add_argument("--device", default=None,
                        help="exact Cycles device name; any Metal GPU by default")
    parser.add_argument("--samples", type=int, default=64)
    parser.add_argument("--save-blend", default=None)
    parser.add_argument("--no-join", action="store_true",
                        help="keep parts as separate objects (renders identically)")
    parser.add_argument("--join", action="store_true",
                        help="join before rendering, the way --export does, to confirm "
                             "the materials still read once the parts are one mesh")
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    args = parser.parse_args(argv)
    if args.bake and not args.export:
        parser.error("--bake requires --export")
    if args.bake and args.no_join:
        parser.error("--bake requires the production joined mesh; remove --no-join")
    if args.export and args.no_join:
        parser.error("--export requires the production joined mesh; remove --no-join")

    spec = CATALOG[args.species]

    studio.reset_scene()
    studio.setup_render(resolution=(900, 700), samples=args.samples)
    fish = build(spec)

    out_dir = os.path.join(args.out, spec.name)
    os.makedirs(out_dir, exist_ok=True)

    joined = _join(fish, spec) if args.join or args.bake else None

    if args.bake:
        export_path = os.path.abspath(args.export)
        stem = os.path.splitext(os.path.basename(export_path))[0]
        texture_dir = os.path.abspath(
            args.textures
            or os.path.join(os.path.dirname(export_path), f"{stem}_textures")
        )
        started = time.monotonic()
        paths = bake_atlas(
            joined,
            texture_dir,
            atlas_name=spec.name,
            resolution=args.resolution,
            margin=args.margin,
            uv_margin=args.uv_margin,
            device_name=args.device,
        )
        for kind, path in paths.items():
            print(f"[build_fish] {kind}: {path}")
        print(
            f"[build_fish] baked {args.resolution}x{args.resolution}, "
            f"margin {args.margin}px in {time.monotonic() - started:.1f}s"
        )
        # Baking deliberately uses one sample; a same-run visual verification should still
        # render at the requested quality rather than inheriting the bake setting.
        bpy.context.scene.cycles.samples = args.samples

    if args.render or not (args.preview or args.export):
        studio.studio_lights(radius=spec.length * 3.0)
        paths = studio.render_views(out_dir, prefix="studio")
        sheet = studio.contact_sheet(paths, os.path.join(out_dir, "studio_sheet.png"))
        print(f"[build_fish] studio sheet: {sheet}")

    if args.preview:
        for light in [o for o in bpy.context.scene.objects if o.type == "LIGHT"]:
            bpy.data.objects.remove(light, do_unlink=True)
        studio.underwater_lights(radius=spec.length * 3.0)
        views = [("side", -90.0, 0.0), ("three-quarter", -58.0, 10.0), ("front", -20.0, 5.0)]
        paths = studio.render_views(out_dir, views=views, prefix="water")
        sheet = studio.contact_sheet(paths, os.path.join(out_dir, "water_sheet.png"), columns=3)
        print(f"[build_fish] underwater sheet: {sheet}")

    if args.export:
        if not args.no_join and joined is None:
            joined = _join(fish, spec)
        export_path = os.path.abspath(args.export)
        os.makedirs(os.path.dirname(export_path), exist_ok=True)
        # Bake paths arrive here after `bake_atlas`; non-bake paths retain their original active
        # UV. In both cases transcode exactly once, immediately before USD export.
        _part_uv(joined)
        bpy.ops.wm.usd_export(
            filepath=export_path,
            export_materials=True,
            export_textures_mode="NEW",
            overwrite_textures=True,
            evaluation_mode="RENDER",
            generate_preview_surface=True,
        )
        manifest_path = os.path.splitext(export_path)[0] + ".json"
        with open(manifest_path, "w") as handle:
            json.dump(spec.manifest(os.path.basename(export_path)), handle, indent=2)
            handle.write("\n")
        print(f"[build_fish] exported: {export_path}")
        print(f"[build_fish] manifest: {manifest_path}")

    if args.save_blend:
        bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(args.save_blend))


# Guarded so other build scripts can import `build` and `join_parts` rather than
# duplicating fish assembly; Blender runs a --python script with __name__ == "__main__".
if __name__ == "__main__":
    main()
