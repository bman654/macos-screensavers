"""Assemble a fish from its species definition, then render and/or export it.

Run through `tools/blender/run.sh`, which puts `saverlib` on the path:

    tools/blender/run.sh Savers/Aquarium/Models/build_fish.py -- \
        --species clownfish --preview --export build/clownfish.usdz
"""

import argparse
import math
import os
import sys

import bpy
from mathutils import Vector

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.abspath(os.path.join(_HERE, "..", "..", ".."))
sys.path[:0] = [os.path.join(_REPO, "tools", "blender"), _HERE]

from saverlib import (  # noqa: E402
    Body, BodySpec, assign, build_fin, caudal_root, dorsal_root, eye_material,
    fin_material, fish_material, flank_root, studio, ventral_root,
)
from species import CATALOG  # noqa: E402


def build(spec):
    body_spec = BodySpec(
        length=spec.length,
        width=spec.width,
        top=spec.top,
        bottom=spec.bottom,
        spine=spec.spine,
        exponent=spec.exponent,
    )
    body = Body(body_spec, rings=88, segments=32)

    root = bpy.data.objects.new(f"Fish_{spec.name}", None)
    bpy.context.collection.objects.link(root)

    body_obj = body.build(f"{spec.name}_body", subsurf=2)
    body_obj.parent = root

    belly, mid, back = spec.colors
    skin = fish_material(
        f"{spec.name}_skin",
        belly=belly, mid=mid, back=back,
        body_height=max(body_spec.top.peak, body_spec.bottom.peak),
        body_length=spec.length,
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
    )
    assign(body_obj, skin)

    membrane = fin_material(f"{spec.name}_fin", spec.fin_color, **(spec.fin_style or {}))
    same_tail = (spec.caudal_color == spec.fin_color
                 and spec.caudal_style == spec.fin_style)
    tail_membrane = membrane if same_tail else fin_material(
        f"{spec.name}_caudal", spec.caudal_color, **(spec.caudal_style or {}))
    for obj, is_caudal in _build_fins(spec, body):
        obj.parent = root
        assign(obj, tail_membrane if is_caudal else membrane)

    iris = eye_material(f"{spec.name}_eye")
    for obj in _build_eyes(spec, body):
        obj.parent = root
        assign(obj, iris)

    return root


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
    """Return (object, is_caudal) pairs. Fins get one subdivision level and a very thin
    solidify: at two levels the modifier stack inflates a flat membrane into a pillow."""
    fins = []
    up = Vector((0.0, 0.0, 1.0))
    down = Vector((0.0, 0.0, -1.0))
    common = dict(thickness=0.0012, subsurf=1)

    if spec.dorsal:
        f = spec.dorsal
        fins.append((build_fin(
            f"{spec.name}_dorsal",
            root=dorsal_root(body, f.t0, f.t1, sink=f.sink),
            out_dir=lambda u: up, span=f.span, rake=f.rake, curl=f.curl, flare=f.flare,
            curl_axis=(0, 1, 0), samples_u=f.samples_u, samples_v=f.samples_v, **common,
        ), False, f))

    if spec.anal:
        f = spec.anal
        fins.append((build_fin(
            f"{spec.name}_anal",
            root=ventral_root(body, f.t0, f.t1, sink=f.sink),
            out_dir=lambda u: down, span=f.span, rake=f.rake, curl=f.curl, flare=f.flare,
            curl_axis=(0, 1, 0), samples_u=f.samples_u, samples_v=f.samples_v, **common,
        ), False, f))

    if spec.caudal:
        f = spec.caudal
        fins.append((build_fin(
            f"{spec.name}_caudal",
            root=caudal_root(body, t=1.0, spread=spec.caudal_spread),
            out_dir=lambda u: Vector((-1.0, 0.0, 0.0)),
            span=f.span, rake=f.rake, curl=f.curl, flare=f.flare,
            curl_axis=(0, 1, 0), samples_u=f.samples_u, samples_v=f.samples_v, **common,
        ), True, f))

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
            fins.append((build_fin(
                f"{spec.name}_{attr}_{'L' if side > 0 else 'R'}",
                root=flank_root(body, f.t0, f.t1, theta, side=side, sink=f.sink),
                out_dir=lambda u, d=mirrored: d,
                span=f.span, rake=f.rake, curl=f.curl * side, flare=f.flare,
                curl_axis=(0, 0, 1), samples_u=f.samples_u, samples_v=f.samples_v,
                **common,
            ), False, f))

    return [(_fin_uv(obj, f.samples_u, f.samples_v), is_caudal)
            for obj, is_caudal, f in fins]


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
    t, height, radius_frac = spec.eye
    theta = height * (math.pi / 2.0)
    radius = radius_frac * spec.length
    point = body.surface_point(t, theta)

    eyes = []
    for side in (1.0, -1.0):
        bpy.ops.mesh.primitive_uv_sphere_add(radius=radius, segments=28, ring_count=18)
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
    print(f"[build_fish] joined into '{joined.name}': "
          f"{len(joined.data.vertices)} verts, "
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
    parser.add_argument("--samples", type=int, default=64)
    parser.add_argument("--save-blend", default=None)
    parser.add_argument("--no-join", action="store_true",
                        help="keep parts as separate objects (renders identically)")
    parser.add_argument("--join", action="store_true",
                        help="join before rendering, the way --export does, to confirm "
                             "the materials still read once the parts are one mesh")
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    args = parser.parse_args(argv)

    spec = CATALOG[args.species]

    studio.reset_scene()
    studio.setup_render(resolution=(900, 700), samples=args.samples)
    fish = build(spec)

    out_dir = os.path.join(args.out, spec.name)
    os.makedirs(out_dir, exist_ok=True)

    joined = _join(fish, spec) if args.join else None

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
        os.makedirs(os.path.dirname(os.path.abspath(args.export)), exist_ok=True)
        bpy.ops.wm.usd_export(
            filepath=os.path.abspath(args.export),
            export_materials=True,
            export_textures=False,
            evaluation_mode="RENDER",
            generate_preview_surface=True,
        )
        print(f"[build_fish] exported: {args.export}")

    if args.save_blend:
        bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(args.save_blend))


# Guarded so other build scripts can import `build` and `join_parts` rather than
# duplicating fish assembly; Blender runs a --python script with __name__ == "__main__".
if __name__ == "__main__":
    main()
