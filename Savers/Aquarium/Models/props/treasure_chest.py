"""A sunken pirate chest: the lid hinges open, breathes out trapped air, and falls shut.

The whole model is authored in world coordinates at real scale and every placement is
baked into mesh data, so no object carries a scale and the only object transforms are the
lid's hinge translation and two grain-direction rotations. That is the rule
`spikes/004-articulated-decor/` exists to enforce: a scaled parent puts its children in a
stretched space, where a hinge shears instead of turning.

Meshes are joined into a handful of *families* rather than left as one object per board.
Two reasons, and they pull the same way:

* the bake gives every object its own atlas tile regardless of size, so thirty boards
  would each get a sixth of the atlas width and the 4 mm grain would land on three pixels;
* `wood_material` runs its grain along **object X**, so a family is exactly the set of
  boards that want their grain pointing the same way. The end panels and the lid's end
  boards get their own object rotation for that reason and nothing else.

Joining costs `plank_width`: on a joined face the across-boards coordinate is constant, so
the material's painted seam would tint a whole wall rather than stripe it. The seams here
are real instead — separate bowed boards with rolled edges, which cast an actual shadow
line and cannot be flattened by a viewing angle.
"""

import math

import bpy
from mathutils import Matrix, Vector

from saverlib import (
    BRASS,
    IRON,
    RUST,
    TARNISH,
    VERDIGRIS,
    assign,
    beveled_box,
    metal_material,
    plank,
    revolve,
    rock,
    wood_material,
)

from ._spec import Emitter, Part, Phase, Prop


# Overall envelope with the lid down: 0.34 x 0.22 x 0.24 m. The casket is 4 mm smaller in
# plan than the lid on every side, because a lid flush with its own box reads as a crate.
_BODY_HALF_X = 0.166
_BODY_HALF_Y = 0.106
_BODY_TOP = 0.150

_VAULT_A = 0.110                     # half-depth of the barrel vault, in Y
_VAULT_B = 0.090                     # its rise, so the closed chest stands 0.240 m
_LID_HALF_X = 0.170

_BOARD_T = 0.014
_STAVE_T = 0.012
_STAVES = 7                          # coopered, not smooth: a lid of flat staves reads as
                                     # joinery, and the facets catch a moving highlight
_STRAP_X = 0.090                     # the one number the hinges, lid straps and casket
                                     # straps all share, so they line up as one fitting

# The pivot sits on the lid's back-bottom corner, a whisker proud of the casket. Anywhere
# inside that corner and the lid's back lip rakes through the back wall as it swings.
_HINGE = Vector((0.0, _VAULT_A, _BODY_TOP + 0.005))

# Trapped air leaves from inside the chest, so the empty rides the lid — but it is kept
# close to the hinge on purpose. Out at the lid's front edge it would swing a quarter of a
# metre and the bubbles would appear to come from behind the raised lid rather than from
# the chest's mouth.
_EMITTER = Vector((0.0, 0.075, 0.100))

_OPEN_DEGREES = -80.0                # negative about +X: the lid's front edge is at -Y


def _place(obj, matrix, frame=None):
    """Bake a world placement into mesh data, optionally written in a family's frame.

    `frame` is the object rotation its family will carry. Expressing the placement in the
    world and dividing it out here means the geometry is authored in the coordinates it is
    read in, while the family still gets the local X it needs for wood grain.
    """
    obj.data.transform(matrix if frame is None else frame.inverted() @ matrix)
    return obj


def _join(objects, name):
    """Collapse one family into a single object.

    `bpy.ops.object.join` keeps only the active object's modifier stack, so a family may
    only contain pieces built the same way — all `plank`, or all solids. Mixing them would
    silently run a board's Solidify over a fitting and fatten it by its own thickness.
    """
    if len(objects) == 1:
        objects[0].name = name
        return objects[0]
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    result = bpy.ops.object.join()
    if "FINISHED" not in result:
        raise RuntimeError(f"joining '{name}' failed: {result}")
    joined = bpy.context.view_layer.objects.active
    joined.name = name
    return joined


def _attach(obj, parent):
    """Parent without moving anything.

    The parent inverse is written from the known hinge rather than read from
    `matrix_world`, which is lazily evaluated and would still hold the pre-parenting
    identity at this point in the build.
    """
    obj.parent = parent
    obj.matrix_parent_inverse = Matrix.Translation(-_HINGE)
    return obj


def _vault_chords():
    """The stave chords of the barrel vault, front edge to back edge.

    Returns (midpoint, roll angle, chord length) per stave. The roll is a rotation about X,
    so a stave's local +Z — its outward face — is `(0, -sin, cos)`, which is the outward
    ellipse normal. Sweeping from phi = pi down to 0 is what makes that sign come out
    right; the other direction turns every board inside out.
    """
    chords = []
    for index in range(_STAVES):
        angles = (math.pi * (1.0 - index / _STAVES),
                  math.pi * (1.0 - (index + 1) / _STAVES))
        points = [Vector((0.0, _VAULT_A * math.cos(a), _BODY_TOP + _VAULT_B * math.sin(a)))
                  for a in angles]
        span = points[1] - points[0]
        chords.append(((points[0] + points[1]) * 0.5, math.atan2(span.z, span.y),
                       span.length))
    return chords


def _outward(roll):
    return Vector((0.0, -math.sin(roll), math.cos(roll)))


# -- families ------------------------------------------------------------------------


def _casket_boards(seed):
    """Front, back and floor: every board's length runs along X, so grain does too."""
    boards = []
    rows = 3
    height = _BODY_TOP / rows
    for face, sign in (("front", -1.0), ("back", 1.0)):
        for row in range(rows):
            board = plank(
                f"chest_{face}_{row}", length=_BODY_HALF_X * 2.0, width=height,
                thickness=_BOARD_T, bow=0.010, cup=0.06, twist=3.0,
                seed=seed * 101 + len(boards), samples_u=14, samples_v=4,
            )
            # Roll the board up onto its edge; the sign puts its outward face outward.
            _place(board, Matrix.Translation((
                0.0, sign * (_BODY_HALF_Y - _BOARD_T * 0.5), (row + 0.5) * height,
            )) @ Matrix.Rotation(sign * math.pi * 0.5, 4, "X"))
            boards.append(board)

    for index in range(2):
        floor = plank(
            f"chest_floor_{index}", length=_BODY_HALF_X * 2.0 - _BOARD_T * 2.0,
            width=(_BODY_HALF_Y - _BOARD_T), thickness=_BOARD_T,
            bow=0.008, cup=0.05, twist=2.0,
            seed=seed * 101 + len(boards), samples_u=10, samples_v=4,
        )
        _place(floor, Matrix.Translation((
            0.0, (index - 0.5) * (_BODY_HALF_Y - _BOARD_T), _BOARD_T * 0.5,
        )))
        boards.append(floor)
    return boards


def _casket_panels(seed, frame):
    """The two end panels. Their boards run along Y, which is why they are their own
    family: `frame` yaws the object so the material's grain axis follows them."""
    panels = []
    rows = 2
    height = _BODY_TOP / rows
    for side, sign in (("left", -1.0), ("right", 1.0)):
        for row in range(rows):
            panel = plank(
                f"chest_end_{side}_{row}", length=_BODY_HALF_Y * 2.0 - _BOARD_T * 2.0,
                width=height, thickness=_BOARD_T, bow=0.008, cup=0.05, twist=2.5,
                seed=seed * 101 + 40 + len(panels), samples_u=10, samples_v=4,
            )
            # Length along Y, width up Z, thickness across X: a quarter turn about Z after
            # standing the board on edge.
            _place(panel, Matrix.Translation((
                sign * (_BODY_HALF_X - _BOARD_T * 0.5), 0.0, (row + 0.5) * height,
            )) @ Matrix.Rotation(math.pi * 0.5, 4, "Z")
                @ Matrix.Rotation(sign * math.pi * 0.5, 4, "X"), frame)
            panels.append(panel)
    return panels


def _strap(name, size, center, roll=0.0, frame=None):
    fitting = beveled_box(name, size=size, bevel=0.28, segments=2)
    return _place(fitting, Matrix.Translation(center) @ Matrix.Rotation(roll, 4, "X"),
                  frame)


def _casket_fittings():
    """Corner banding, a rim strap, two vertical straps and the hinge barrels.

    The rim strap stands 1 mm proud of everything it crosses. Fittings that meet at the
    same offset would present coplanar faces, and the resulting z-fight is the one artefact
    that reads instantly as CG rather than as ironwork.
    """
    iron, brass = [], []
    corner_x = _BODY_HALF_X - 0.019
    corner_y = _BODY_HALF_Y - 0.019
    for sx in (-1.0, 1.0):
        for sy in (-1.0, 1.0):
            iron.append(_strap(
                f"chest_corner_x_{sx:+.0f}{sy:+.0f}", (0.004, 0.038, _BODY_TOP),
                (sx * (_BODY_HALF_X + 0.002), sy * corner_y, _BODY_TOP * 0.5)))
            iron.append(_strap(
                f"chest_corner_y_{sx:+.0f}{sy:+.0f}", (0.038, 0.004, _BODY_TOP),
                (sx * corner_x, sy * (_BODY_HALF_Y + 0.002), _BODY_TOP * 0.5)))

    for sy in (-1.0, 1.0):
        iron.append(_strap(
            f"chest_rim_y_{sy:+.0f}", (_BODY_HALF_X * 2.0 + 0.006, 0.005, 0.018),
            (0.0, sy * (_BODY_HALF_Y + 0.0025), _BODY_TOP - 0.014)))
        for sx in (-1.0, 1.0):
            iron.append(_strap(
                f"chest_strap_{sx:+.0f}{sy:+.0f}", (0.030, 0.004, _BODY_TOP),
                (sx * _STRAP_X, sy * (_BODY_HALF_Y + 0.002), _BODY_TOP * 0.5)))
    for sx in (-1.0, 1.0):
        iron.append(_strap(
            f"chest_rim_x_{sx:+.0f}", (0.005, _BODY_HALF_Y * 2.0 + 0.006, 0.018),
            (sx * (_BODY_HALF_X + 0.0025), 0.0, _BODY_TOP - 0.014)))

    brass.append(_strap("chest_lock_plate", (0.060, 0.005, 0.048),
                        (0.0, -(_BODY_HALF_Y + 0.0025), 0.100)))
    brass.append(_strap("chest_escutcheon", (0.014, 0.006, 0.020),
                        (0.0, -(_BODY_HALF_Y + 0.0055), 0.100)))

    for sx in (-1.0, 1.0):
        # A solid lathe rather than a tube: `thickness` would add a Solidify modifier and
        # this family is joined into one object, where a stray modifier applies to all.
        barrel = revolve(f"chest_hinge_{sx:+.0f}", [(0.008, -0.028), (0.008, 0.028)],
                         segments=16, rings=2, interpolation="linear")
        _place(barrel, Matrix.Translation(
            _HINGE + Vector((sx * _STRAP_X, 0.0, 0.0))) @ Matrix.Rotation(
                math.pi * 0.5, 4, "Y"))
        brass.append(barrel)

    iron.extend(_end_handles())
    return iron, brass


def _end_handles():
    """A drop bail on each end.

    Worth its ten boxes: the ends are the one face with no strap crossing it, and a chest
    that cannot be lifted reads as a box with bands painted on it.
    """
    handles = []
    reach = 0.035
    for sx in (-1.0, 1.0):
        for sy in (-1.0, 1.0):
            handles.append(_strap(
                f"chest_bail_plate_{sx:+.0f}{sy:+.0f}", (0.005, 0.024, 0.026),
                (sx * (_BODY_HALF_X + 0.0025), sy * reach, 0.106)))
            handles.append(_strap(
                f"chest_bail_arm_{sx:+.0f}{sy:+.0f}", (0.005, 0.006, 0.032),
                (sx * (_BODY_HALF_X + 0.0045), sy * reach, 0.090)))
        handles.append(_strap(
            f"chest_bail_bar_{sx:+.0f}", (0.005, reach * 2.0 + 0.006, 0.006),
            (sx * (_BODY_HALF_X + 0.0045), 0.0, 0.077)))
    return handles


def _hoard(seed):
    """A mound of coin, cheap on purpose: the chest is closed most of the time and this is
    only ever seen through the mouth in the seconds the lid is up."""
    pieces = []
    # Faceted rather than rounded: `angularity` is doing duty here as "a heap of small hard
    # objects", because a smooth mound under a gold shader reads as melted butter.
    mound = rock("chest_hoard_mound", radius=0.080, angularity=0.42, seed=seed * 7 + 3,
                 detail=3, lumpiness=0.60, flatten=0.70, grain=0.14, sharp_angle=40.0)
    _place(mound, Matrix.Translation((0.0, 0.0, 0.048)))
    pieces.append(mound)

    noise = [(-0.070, -0.030, 0.058, 0.5), (0.055, 0.035, 0.066, -0.7),
             (0.010, -0.055, 0.054, 0.3), (-0.030, 0.050, 0.062, 1.1),
             (0.072, -0.040, 0.048, -0.2), (-0.006, 0.028, 0.078, 0.9)]
    for index, (x, y, z, tilt) in enumerate(noise):
        coin = revolve(f"chest_coin_{index}", [(0.013, 0.0), (0.013, 0.002)],
                       segments=16, rings=1, interpolation="linear", sharp_angle=40.0)
        _place(coin, Matrix.Translation((x, y, z))
               @ Matrix.Rotation(tilt + seed * 0.37, 4, "Z")
               @ Matrix.Rotation(0.45, 4, "X"))
        pieces.append(coin)
    return pieces


def _lid_staves(seed):
    staves = []
    for index, (mid, roll, width) in enumerate(_vault_chords()):
        stave = plank(
            f"lid_stave_{index}", length=_LID_HALF_X * 2.0 - _STAVE_T * 2.0, width=width,
            thickness=_STAVE_T, bow=0.006, cup=0.03, twist=1.5,
            seed=seed * 101 + 80 + index, samples_u=14, samples_v=4,
        )
        _place(stave, Matrix.Translation(mid) @ Matrix.Rotation(roll, 4, "X"))
        staves.append(stave)
    return staves


def _lid_panels(frame):
    """The two semi-elliptical end boards, let in flush with the staves' ends.

    A half-disc slab is a lathe with a half sweep; the ellipse comes from squashing the
    disc's height into Z as the placement is baked. Both the axis permutation and the
    squash live in one matrix, which keeps its determinant positive on the mirrored end so
    the normals do not invert.
    """
    panels = []
    squash = _VAULT_B / _VAULT_A
    for sign in (-1.0, 1.0):
        panel = revolve(f"lid_end_{sign:+.0f}", [(_VAULT_A, 0.0), (_VAULT_A, _STAVE_T)],
                        segments=24, rings=1, sweep=math.pi, interpolation="linear")
        axes = Matrix(((0.0, 0.0, sign), (sign, 0.0, 0.0), (0.0, squash, 0.0))).to_4x4()
        _place(panel, Matrix.Translation((
            sign * (_LID_HALF_X - _STAVE_T), 0.0, _BODY_TOP)) @ axes, frame)
        panels.append(panel)
    return panels


def _lid_fittings():
    """Two straps over the vault, faceted onto the staves, and the hasp that meets the
    lock plate. Both straps stand on the same X as the hinge barrels below them."""
    iron, brass = [], []
    chords = _vault_chords()
    for sx in (-1.0, 1.0):
        for index, (mid, roll, width) in enumerate(chords):
            iron.append(_strap(
                f"lid_strap_{sx:+.0f}_{index}", (0.026, width, 0.004),
                mid + _outward(roll) * (_STAVE_T * 0.5 + 0.002)
                + Vector((sx * _STRAP_X, 0.0, 0.0)), roll))
    brass.append(_strap("lid_hasp", (0.034, 0.005, 0.059),
                        (0.0, -(_BODY_HALF_Y + 0.008), 0.1265)))
    return iron, brass


# -- materials -----------------------------------------------------------------------


def _wood(name, seed):
    """Timber that has been down there a long time: dark, matte and colonised on its
    upward faces. `grain_spacing` and the biofilm patch size are absolute metres, which is
    the reason this model is built at real scale rather than scaled up at export."""
    return wood_material(
        name, size=0.30, grain_spacing=0.004,
        # Zero on purpose: the boards are separate geometry, so the seams are real. The
        # painted variant needs the across-boards axis to vary over a face, and on a joined
        # wall it does not — it would tint the whole face instead of striping it.
        plank_width=0.0,
        # Waterlogged, not bleached. `waterlog` pulls the timber toward a neutral dark
        # grey, and past about 0.6 the last of the brown goes with it — under the tank's
        # blue-green key that lands as painted sage rather than as drowned oak.
        waterlog=0.58, roughness=0.62, algae=0.26, seed=seed,
    )


def _iron_material(seed):
    # Held back from the top of the corrosion range on purpose: at 0.78 there is no bare
    # iron left anywhere, and a strap that is patina end to end averages out to uniform
    # terracotta. Just over half leaves dark metal between the rust blooms.
    return metal_material(f"chest_iron_{seed}", size=0.12, base=IRON, corrosion=0.56,
                          patina=RUST, roughness=0.46, algae=0.28, seed=seed)


def _brass_material(seed):
    # Verdigris rather than rust: the lock, hasp and hinge knuckles are the cast pieces,
    # and copper alloy goes green where iron goes orange.
    return metal_material(f"chest_brass_{seed}", size=0.09, base=BRASS, corrosion=0.62,
                          patina=VERDIGRIS, roughness=0.34, algae=0.18, seed=seed)


def _gold_material(seed):
    # Barely corroded, and that is the whole point of the hoard: gold is the one thing in
    # the tank that still has a specular highlight after a century underwater.
    return metal_material(f"chest_gold_{seed}", size=0.08, base=(0.68, 0.50, 0.16),
                          corrosion=0.10, patina=TARNISH, roughness=0.24, algae=0.06,
                          seed=seed)


# -- assembly ------------------------------------------------------------------------


def build(seed=0):
    root = bpy.data.objects.new("decor_treasure_chest", None)
    bpy.context.collection.objects.link(root)

    yaw = Matrix.Rotation(math.pi * 0.5, 4, "Z")
    iron = _iron_material(seed)
    brass = _brass_material(seed)

    boards = _join(_casket_boards(seed), "chest_boards")
    assign(boards, _wood(f"chest_timber_{seed}", seed))
    boards.parent = root

    panels = _join(_casket_panels(seed, yaw), "chest_panels")
    assign(panels, _wood(f"chest_endgrain_{seed}", seed + 5))
    panels.rotation_euler = yaw.to_euler()
    panels.parent = root

    casket_iron, casket_brass = _casket_fittings()
    for piece in casket_iron:
        assign(piece, iron)
    for piece in casket_brass:
        assign(piece, brass)
    fittings = _join(casket_iron + casket_brass, "chest_fittings")
    fittings.parent = root

    hoard = _join(_hoard(seed), "chest_hoard")
    assign(hoard, _gold_material(seed))
    hoard.parent = root

    # The lid's origin is the hinge, which is the entire articulation contract: Blender
    # writes an object's origin as its prim transform, so the node SceneKit receives turns
    # about this point with no pivot metadata to carry across.
    lid = _join(_lid_staves(seed), "part_lid")
    assign(lid, _wood(f"chest_lid_{seed}", seed + 11))
    lid.data.transform(Matrix.Translation(-_HINGE))
    lid.location = _HINGE
    lid.parent = root

    lid_panels = _join(_lid_panels(yaw), "lid_panels")
    assign(lid_panels, _wood(f"chest_lid_ends_{seed}", seed + 17))
    lid_panels.rotation_euler = yaw.to_euler()
    _attach(lid_panels, lid)

    lid_iron, lid_brass = _lid_fittings()
    for piece in lid_iron:
        assign(piece, iron)
    for piece in lid_brass:
        assign(piece, brass)
    lid_fittings = _join(lid_iron + lid_brass, "lid_fittings")
    _attach(lid_fittings, lid)

    emitter = bpy.data.objects.new("emit_bubbles", None)
    emitter.empty_display_type = "PLAIN_AXES"
    emitter.empty_display_size = 0.02
    bpy.context.collection.objects.link(emitter)
    emitter.location = _EMITTER
    _attach(emitter, lid)
    return root


TREASURE_CHEST = Prop(
    name="treasure_chest",
    build=build,
    category="decoration",
    # Half the plan diagonal of the closed chest (0.346 x 0.239 m), which is the circle it
    # occupies on the floor whichever way the tank yaws it.
    footprint=0.21,
    # The open lid, not the closed silhouette: closed this stands 0.25 m, but it spends
    # part of every cycle at 0.40 m and the placement pass needs the headroom.
    height=0.41,
    # Wide enough for the raised lid too: opening swings the vault back to a plan radius
    # of 0.27, so two chests at 2 x footprint would open through one another.
    min_spacing=0.55,
    tilt_range=(-7.0, 7.0),
    scale_range=(0.85, 1.20),
    weight=0.8,
    max_per_scene=1,
    parts=(Part(node="part_lid", axis=(1.0, 0.0, 0.0), open_degrees=_OPEN_DEGREES),),
    emitters=(Emitter(
        node="emit_bubbles", rate=55.0, radius=0.030, size=(0.003, 0.009), speed=0.11,
    ),),
    cycle=(
        # A range, not a number: two chests opening on the same beat is the most
        # mechanical-looking failure available to a tank full of these.
        Phase("idle", (11.0, 26.0)),
        # Up quickly and then settle — something inside pushes it. Down slowly at first
        # and then away: an iron-bound lid falls, and water only damps the fall, it does
        # not hold the lid up.
        Phase("move", 1.1, part="part_lid", to=1.0, ease="easeOut"),
        Phase("emit", 2.6, emitter="emit_bubbles"),
        Phase("move", 1.7, part="part_lid", to=0.0, ease="easeIn"),
    ),
    seeds=3,
)
