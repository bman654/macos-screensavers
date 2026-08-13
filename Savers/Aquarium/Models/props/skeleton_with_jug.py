"""A seated skeleton raising a stoneware jug to what is left of its mouth.

The gag is the whole model: he drinks, and the whiskey runs straight out of the hole in
the jug's base as a stream of bubbles. Everything here serves that reading at screen
size, where the prop may be two hundred pixels tall and nothing but silhouette survives.

Three things are not obvious:

* **One moving part, not two.** `part_arm` is an empty whose origin sits on the shoulder
  joint; the arm bones, the jug, the hand and the bubble emitter are all its children. A
  single rotation therefore lifts and *tips* the jug together, and the emitter rides
  along with no extra machinery. See `docs/decorations.md`.
* **The rest pose is derived from the drinking pose, not guessed.** A rigid arm keeps the
  jug's mouth at a fixed distance from the shoulder, so the only way to guarantee it
  arrives at the lips is to place it at the lips and swing it *back* by the cycle's own
  angle — see `_swing`. That is why the numbers below describe the face and not the lap,
  and why retuning `_SWING` moves the resting jug without ever breaking the drink.
* **The shoulder is deliberately low and the skull deliberately high.** That is a slouch,
  and it is also what buys the reach: the shorter the shoulder-to-lips distance, the
  smaller the arc the jug swings through, and below about 0.12 m the resting jug ends up
  inside the ribcage instead of in his lap.

Everything else here is spent on the four silhouettes a viewer actually recognises as a
skeleton — the ribcage tapering to a waist over a visible spine, the jaw and orbits of the
skull, the flare of the iliac blades, and knobbled bone ends — because a figure assembled
from smooth capsules reads as pipe cleaners no matter how good its pose is.
"""

import math
import random

import bpy
from mathutils import Matrix, Vector

from saverlib import (
    Profile, SweptTube, assign, beveled_box, bone_material, revolve, rock_material,
    studio,
)

from ._spec import Emitter, Part, Phase, Prop

# The underwater sheet and the tank both look at a prop from -Y, so the drinking arm and
# the jug live on that side where nothing can occlude them, and he faces +X.
_NEAR = -1.0

# -- the pose, in metres --------------------------------------------------------------

_SPINE_BASE = Vector((0.012, 0.0, 0.098))
_SPINE_TOP = Vector((-0.100, 0.0, 0.362))
_SHOULDER_Y = 0.088
# The shoulders hang well below the top of the thoracic spine. That is the slouch, and it
# is also what buys the arm its reach: see the module docstring.
_SHOULDER_Z = 0.310
_NECK_JOINT = Vector((-0.150, 0.0, 0.490))   # foramen magnum: where the skull sits
_HEAD_TILT = 20.0                            # degrees back — a drinker looks at the sky

_SHOULDER = Vector((-0.090, _NEAR * _SHOULDER_Y, _SHOULDER_Z))
_SHOULDER_FAR = Vector((-0.090, -_NEAR * _SHOULDER_Y, _SHOULDER_Z))

_UPPER_ARM = 0.175
_FOREARM = 0.150
_FEMUR = 0.205
_TIBIA = 0.180

# The arm sweeps this far to drink. It is a big swing on purpose: read at distance comes
# from how much of the frame the motion crosses, not from how correct it is.
_SWING = 106.0

# -- the jug --------------------------------------------------------------------------

_JUG_HEIGHT = 0.175
_JUG_LEAN = 22.0        # rest tilt, back toward the body, so it tips mouth-down when raised
_JUG_Y = _NEAR * 0.035  # close to the midline: the jug has to end up in front of the face
_HOLE = 0.011           # the whole point of the prop

# Radius against height, in the jug's own frame with its base on z = 0. The neck is
# deliberately long and thin and the rim deliberately flared: at screen size the jug has
# perhaps forty pixels of silhouette, and neck plus handle is the entire difference
# between a whiskey jug and an egg.
_JUG_OUTLINE = [
    (_HOLE, 0.000),
    (0.033, 0.006),     # a near-flat base, so the hole reads as a hole and not as a neck
    (0.044, 0.024),
    (0.047, 0.060),     # belly — taller than it is wide, or it reads as a ball
    (0.044, 0.090),
    (0.024, 0.114),     # shoulder
    (0.0125, 0.132),    # neck
    (0.0125, 0.160),
    (0.022, 0.175),     # rim
]

# Where the hand takes the handle, in the jug's frame. The handle faces away from the
# body: on the near side it would be foreshortened to nothing, and on the body side both
# it and the hand would disappear behind the pelvis.
_GRIP = Vector((0.074, _NEAR * 0.026, 0.108))


def build(seed=0):
    rng = random.Random(seed * 6151 + 17)

    root = bpy.data.objects.new("decor_skeleton_with_jug", None)
    bpy.context.collection.objects.link(root)

    bone = bone_material(
        f"skeleton_bone_{seed}", size=0.30,
        dirt=rng.uniform(0.55, 0.75), translucency=0.16,
        algae=rng.uniform(0.30, 0.46), seed=seed,
    )
    # Sockets are not a material so much as a shadow: near-black, matte, and barely
    # colonised, because algae on an eye socket fills the one hole the skull needs.
    socket = rock_material(
        f"skeleton_socket_{seed}", size=0.06,
        base=(0.0045, 0.0042, 0.0040), secondary=(0.013, 0.012, 0.011),
        speckle=0.08, roughness=0.92, algae=0.10, seed=seed + 5,
    )
    # Salt-glazed stoneware: a dark iron-brown slip over a buff body. `rock_material`
    # reaches it — three tones, a speckle and a roughness range is what a fired glaze
    # looks like — with the roughness pulled down to where the glaze is wet-looking.
    jug_glaze = rock_material(
        f"skeleton_jug_{seed}", size=0.13,
        base=(0.024, 0.012, 0.006), secondary=(0.086, 0.055, 0.026),
        speckle=0.16, roughness=0.24, algae=rng.uniform(0.20, 0.34), seed=seed + 11,
    )

    head = Matrix.Translation(_NECK_JOINT) @ Matrix.Rotation(math.radians(-_HEAD_TILT), 4, "Y")
    statics = _skeleton(rng, head, bone, socket)
    for obj in statics:
        obj.parent = root

    lips = head @ Vector((0.062, 0.0, -0.024))
    lips.y = _JUG_Y
    _drinking_arm(root, lips, bone, jug_glaze)

    # Centre the model on X and Y so the tank can yaw it about its own middle. The root
    # carries the offset as a translation; nothing here may carry a scale.
    bpy.context.view_layer.update()
    low, high = studio.scene_bounds()
    root.location = Vector((-(low.x + high.x) * 0.5, -(low.y + high.y) * 0.5, 0.0))
    return root


# -- the static skeleton --------------------------------------------------------------


def _skeleton(rng, head, bone, socket):
    """Everything that does not move: torso, skull, legs and the arm he leans on."""
    objects = []

    objects.extend(_pelvis())

    # A beaded radius, not a smooth taper: the ribs have to look like they attach to
    # something, and a column of vertebrae is the only reason a ribcage reads as a cage
    # rather than as a coil hanging in space. The beads need four rings each to survive.
    objects.append(_tube("spine", _spine_path(), _vertebrae(9, 0.0215, 0.0150),
                         rings=44, segments=10, section=(1.0, 0.86)))

    objects.extend(_ribcage())
    objects.append(_sternum())

    for side in (1.0, -1.0):
        objects.append(_tube(
            f"clavicle_{'l' if side > 0 else 'r'}",
            [_SPINE_TOP + Vector((0.0, 0.0, -0.004)),
             Vector((-0.076, side * 0.048, 0.372)),
             Vector((-0.090, side * _SHOULDER_Y, _SHOULDER_Z))],
            0.0072, rings=10, segments=8,
        ))

    objects.append(_tube("neck", [
        _SPINE_TOP, Vector((-0.126, 0.0, 0.424)), _NECK_JOINT + Vector((0.004, 0.0, -0.010)),
    ], _vertebrae(5, 0.0140, 0.0104, taper=0.94), rings=26, segments=8))

    objects.extend(_skull(head))
    objects.extend(_legs(rng))
    objects.extend(_propping_arm(rng))

    for obj in objects:
        assign(obj, socket if obj.name.startswith(("socket", "nasal")) else bone)
    return objects


def _spine_path():
    return [
        _SPINE_BASE,
        _SPINE_BASE.lerp(_SPINE_TOP, 0.35) + Vector((0.014, 0.0, 0.0)),
        _SPINE_BASE.lerp(_SPINE_TOP, 0.72) + Vector((0.004, 0.0, 0.0)),
        _SPINE_TOP,
    ]


def _spine_point(t):
    """A point along the lumbar-to-shoulder line, ignoring its slight curve."""
    return _SPINE_BASE.lerp(_SPINE_TOP, t)


def _chest_forward():
    """Unit vector out of the front of the chest, square to the leaning spine."""
    up = (_SPINE_TOP - _SPINE_BASE).normalized()
    return Vector((up.z, 0.0, -up.x))


_RIBS = 7


def _rib_level(u):
    """Where rib pair `u` (0 at the bottom) sits and how far it wraps.

    Returned as (attachment, half-width, depth to the sternum, front drop, half-angle the
    rib stops short of the front midline). The cage is an egg: widest a little above the
    middle, pinched under the shoulders, and tapering to a waist at the bottom because the
    lowest pairs float — they stop out at the flank instead of reaching the sternum. That
    shortening is the taper; hoops of near-constant size are what read as a slinky.
    """
    egg = 0.56 + 0.44 * math.sin(math.pi * (0.15 + 0.76 * u))
    return (
        _spine_point(0.40 + 0.55 * u),
        0.074 * egg,
        0.104 * (0.60 + 0.40 * egg),
        0.058 - 0.022 * u,
        math.radians(13.0 + 66.0 * max(0.0, 1.0 - 2.4 * u) ** 2),
    )


def _rib_front(u):
    """The point where rib pair `u` meets the midline, sternum or not."""
    attach, _, depth, drop, _ = _rib_level(u)
    return attach + _chest_forward() * depth - (_SPINE_TOP - _SPINE_BASE).normalized() * drop


def _ribcage():
    """Seven hoops, each one rib pair joined through the spine.

    A pair per tube rather than a rib per tube halves the object count and removes the
    junction where two ribs would meet at the vertebra, which is the one place a visible
    intersection would show. Every hoop is open at the front: the top pairs stop on the
    sternum and the bottom pairs stop well short of it.
    """
    forward = _chest_forward()
    up = (_SPINE_TOP - _SPINE_BASE).normalized()
    ribs = []
    for index in range(_RIBS):
        u = index / (_RIBS - 1)
        attach, span, depth, drop, reach = _rib_level(u)
        centre = attach + forward * (depth * 0.5)

        def hoop(t, centre=centre, span=span, depth=depth, drop=drop, reach=reach):
            # Theta runs from just off the front midline, around the back, and out to the
            # mirrored point on the other side, so one tube is a whole rib pair.
            theta = reach + (2.0 * math.pi - 2.0 * reach) * t
            front = 0.5 * (1.0 + math.cos(theta))
            return (centre
                    + forward * (depth * 0.5 * math.cos(theta))
                    + Vector((0.0, span * math.sin(theta), 0.0))
                    - up * (drop * front))

        # Thickest where it leaves the spine (t = 0.5) and thinnest at the sternal ends,
        # and flattened into a blade rather than left as a rod.
        ribs.append(_tube(f"rib_{index}", hoop,
                          Profile([(0.0, 0.0048), (0.5, 0.0070), (1.0, 0.0048)]),
                          rings=34, segments=8, section=(1.20, 0.62)))
    return ribs


def _sternum():
    """The plate the upper ribs run into. Without it the cage never closes at the front."""
    top, bottom = _rib_front(1.0), _rib_front(0.42)
    span = (top - bottom).length
    up = (_SPINE_TOP - _SPINE_BASE).normalized()
    plate = beveled_box("sternum", size=(0.012, 0.030, span), bevel=0.35, segments=2)
    # `_place` pitches about Y, and the plate has to lie along the leaning spine rather
    # than upright, or it stands away from the ribs it is supposed to join.
    _place(plate, (top + bottom) * 0.5, math.degrees(math.asin(up.x)))
    return plate


def _vertebrae(count, body, disc, taper=0.72):
    """A radius that swells once per vertebra, so the spine reads as a stack.

    Monotone-cubic interpolation through alternating radii gives a bead per vertebra for
    the cost of a profile; the alternative is `count` more objects in the atlas for a
    column that is half hidden behind the ribs.
    """
    steps = count * 2
    return Profile([
        (i / steps, (body if i % 2 == 0 else disc) * (1.0 - (1.0 - taper) * i / steps))
        for i in range(steps + 1)
    ])


def _pelvis():
    """Sacrum, two flared iliac blades, and the mass he is sitting on.

    He is seated and side-on, so the pelvis lands in the middle of the silhouette. A box
    there reads as a beanbag; the blades are the shape that says hips, and they only work
    because a swept tube with a very flat section is a curved plate.
    """
    sacrum = _tube("sacrum", [Vector((-0.026, 0.0, 0.028)), Vector((-0.008, 0.0, 0.058)),
                              _SPINE_BASE + Vector((0.0, 0.0, 0.004))],
                   Profile([(0.0, 0.010), (0.55, 0.019), (1.0, 0.021)]),
                   rings=12, segments=10, section=(1.0, 0.78))

    blades = []
    for side in (1.0, -1.0):
        tag = "l" if side > 0 else "r"
        blades.append(_tube(f"ilium_{tag}", [
            Vector((-0.030, side * 0.020, 0.040)),
            Vector((0.008, side * 0.056, 0.076)),
            Vector((0.054, side * 0.088, 0.104)),
        ], Profile([(0.0, 0.026), (0.45, 0.047), (1.0, 0.038)]),
            rings=20, segments=14, section=(1.0, 0.21)))

    seat = beveled_box("ischium", size=(0.082, 0.128, 0.058), bevel=0.34, segments=3)
    _place(seat, Vector((0.006, 0.0, 0.042)), -16.0)
    return [sacrum, *blades, seat]


def _skull(head):
    """Cranium, face, jaw and the dark holes that make it a skull and not an egg.

    Coordinates are in the skull's own frame — origin at the neck joint, +X out of the
    face — and `head` carries it into place, so tilting the head is one number rather
    than a rewrite of every landmark.
    """
    objects = []

    # Two thirds braincase, one third face — that ratio is most of why a skull reads as a
    # skull. The path is deliberately short against the radii: a long path with small end
    # radii and rounded caps gives two lobes with a waist between them, which is exactly
    # what the first version of this head looked like.
    objects.append(_tube("cranium", [Vector((-0.026, 0.0, 0.044)), Vector((0.000, 0.0, 0.046)),
                                     Vector((0.026, 0.0, 0.046))],
                         Profile([(0.0, 0.0545), (0.45, 0.0550), (1.0, 0.0480)]),
                         rings=24, segments=18, section=(1.0, 0.94)))

    # The face is a second ovoid emerging from the braincase's lower front, not a snout
    # hung underneath it. Teeth, nose and orbits all sit on this.
    objects.append(_tube("maxilla", [Vector((0.030, 0.0, 0.024)), Vector((0.052, 0.0, 0.000))],
                         Profile([(0.0, 0.032), (0.55, 0.028), (1.0, 0.023)]),
                         rings=10, segments=14, section=(1.0, 0.86)))

    # An orbit is a hole, and there is no boolean here. What reads instead is a flat dark
    # disc set barely proud of the skull, bounded by real bone on every side: the brow
    # above, the zygomatic below and out, the nose within. A raised ring around it was
    # tried first and read as a monocle.
    for side in (1.0, -1.0):
        centre = Vector((0.058, side * 0.028, 0.029))
        out = Vector((0.68, side * 0.65, -0.33)).normalized()
        objects.append(_harden(_tube(
            f"socket_{'l' if side > 0 else 'r'}",
            [centre - out * 0.030, centre + out * 0.0015],
            Profile([(0.0, 0.0080), (0.55, 0.0165), (1.0, 0.0165)]),
            rings=8, segments=16, rounded_caps=False,
        )))

    # Brow and cheekbones. The supraorbital ridge rides the front of the braincase over
    # the rims, and the zygomatic arch stands clear of it on its way back to the ear —
    # the gap under that arch is worth more than any amount of surface detail.
    objects.append(_tube("brow", [Vector((0.031, -0.046, 0.056)), Vector((0.072, 0.0, 0.055)),
                                  Vector((0.031, 0.046, 0.056))],
                         Profile([(0.0, 0.0080), (0.5, 0.0115), (1.0, 0.0080)]),
                         rings=16, segments=8, section=(0.90, 1.0)))
    for side in (1.0, -1.0):
        objects.append(_tube(
            f"zygomatic_{'l' if side > 0 else 'r'}",
            [Vector((0.052, side * 0.042, 0.010)), Vector((0.014, side * 0.052, 0.018)),
             Vector((-0.020, side * 0.046, 0.026))],
            Profile([(0.0, 0.0075), (0.5, 0.0055), (1.0, 0.0080)]),
            rings=16, segments=8, section=(1.25, 0.60)))

    # The mandible is a single U with a ramus at each end climbing to the ear. The jaw
    # line is most of what makes a skull read, and with the head tipped back to drink it
    # is the part of the skull the camera sees most of.
    objects.append(_tube("mandible", [
        Vector((-0.018, -0.042, 0.024)), Vector((-0.006, -0.048, -0.010)),
        Vector((0.012, -0.044, -0.026)), Vector((0.038, -0.030, -0.034)),
        Vector((0.060, 0.0, -0.036)),
        Vector((0.038, 0.030, -0.034)), Vector((0.012, 0.044, -0.026)),
        Vector((-0.006, 0.048, -0.010)), Vector((-0.018, 0.042, 0.024)),
    ], Profile([(0.0, 0.0068), (0.14, 0.0104), (0.5, 0.0112), (0.86, 0.0104),
                (1.0, 0.0068)]), rings=32, segments=8, section=(1.20, 0.58)))

    # A tooth row, because the gap between jaw and maxilla is the last thing that reads
    # as a mouth rather than as a crack.
    objects.append(_tube("teeth", [
        Vector((0.026, -0.026, -0.014)), Vector((0.050, -0.017, -0.019)),
        Vector((0.062, 0.0, -0.021)),
        Vector((0.050, 0.017, -0.019)), Vector((0.026, 0.026, -0.014)),
    ], 0.0060, rings=20, segments=8, section=(0.85, 1.0)))

    objects.append(_harden(_tube(
        "nasal", [Vector((0.044, 0.0, 0.020)), Vector((0.068, 0.0, 0.013))],
        Profile([(0.0, 0.0060), (0.6, 0.0105), (1.0, 0.0105)]), rings=6, segments=10,
        rounded_caps=False)))

    for obj in objects:
        obj.data.transform(head)
    return objects


def _legs(rng):
    """One leg stretched out, one knee up. Symmetry is what makes a skeleton a diagram."""
    objects = []
    splay = rng.uniform(0.9, 1.15)

    # The near leg is splayed well out of the midline: the jug rests in the gap it leaves.
    near_hip = Vector((0.020, _NEAR * 0.070, 0.092))
    near_knee = Vector((0.264, _NEAR * 0.112 * splay, 0.076))
    near_ankle = Vector((0.448, _NEAR * 0.086 * splay, 0.046))
    far_hip = Vector((0.020, -_NEAR * 0.062, 0.092))
    far_knee = Vector((0.238, -_NEAR * 0.086 * splay, 0.240))
    far_ankle = Vector((0.312, -_NEAR * 0.060 * splay, 0.034))

    for tag, hip, knee, ankle in (("near", near_hip, near_knee, near_ankle),
                                  ("far", far_hip, far_knee, far_ankle)):
        # Slightly flattened sections on the big bones: a femur is not a cylinder, and an
        # oval catches a highlight down its length instead of a hot stripe.
        objects.append(_tube(f"femur_{tag}", [hip, _fit(hip, knee, _FEMUR)],
                             _limb_bone(0.0145, 0.024, 0.021), rings=20, segments=10,
                             section=(1.0, 0.86)))
        knee = _fit(hip, knee, _FEMUR)
        objects.append(_tube(f"tibia_{tag}", [knee, _fit(knee, ankle, _TIBIA)],
                             _limb_bone(0.0115, 0.020, 0.015), rings=20, segments=10,
                             section=(1.0, 0.88)))
        # The fibula is nearly free and doubles the width of the lower leg's silhouette,
        # which is what stops a stretched leg reading as a single stick.
        offset = Vector((-0.008, _NEAR * 0.012 if tag == "near" else -_NEAR * 0.012, 0.0))
        objects.append(_tube(f"fibula_{tag}", [knee + offset * 0.6,
                                               _fit(knee, ankle, _TIBIA) + offset],
                             _limb_bone(0.0055, 0.008, 0.007), rings=10, segments=8))

        ankle = _fit(knee, ankle, _TIBIA)
        foot = beveled_box(f"foot_{tag}", size=(0.078, 0.040, 0.022), bevel=0.35, segments=2,
                           subsurf=1)
        # The stretched leg's foot lolls outward and back; the tucked one stands on its
        # sole. Both are one box, because a foot at this size is a wedge.
        pitch = -26.0 if tag == "near" else -6.0
        _place(foot, ankle + Vector((0.030, 0.0, -0.004)), pitch)
        objects.append(foot)
    return objects


def _propping_arm(rng):
    """The far arm, braced on the sand behind him: the reason he can lean back."""
    wrist = Vector((-0.152, -_NEAR * (0.112 + rng.uniform(-0.008, 0.012)), 0.034))
    upper, fore = _UPPER_ARM + 0.008, _FOREARM + 0.010
    elbow = _elbow(_SHOULDER_FAR, wrist, upper, fore, Vector((-1.0, -_NEAR * 0.35, -0.2)))
    return [
        _tube("humerus_far", [_SHOULDER_FAR, elbow], _limb_bone(0.0125, 0.020, 0.017),
              rings=18, segments=10, section=(1.0, 0.90)),
        _tube("radius_far", [elbow, wrist], _limb_bone(0.0105, 0.016, 0.012),
              rings=18, segments=10, section=(1.0, 0.88)),
        # Fingers splayed forward and pressed into the sand: this is a hand taking weight.
        *_hand("far", wrist, Vector((0.034, 0.0, -0.011)), Vector((0.0, 1.0, 0.0)),
               Vector((0.008, 0.0, -0.010))),
    ]


# -- the arm that drinks --------------------------------------------------------------


def _drinking_arm(root, lips, bone, glaze):
    """`part_arm` and everything that rides on it.

    The empty's origin is the shoulder joint, which is what makes its node a pure pivot
    in SceneKit; every child's geometry is authored in model space and then moved into
    the pivot's space by baking the offset into its mesh, never by a parent transform.
    """
    arm = bpy.data.objects.new("part_arm", None)
    bpy.context.collection.objects.link(arm)
    arm.parent = root
    arm.location = _SHOULDER
    arm.empty_display_size = 0.05

    # Swing the drinking pose backwards by the cycle's own angle to find the rest pose.
    # Done the other way round the jug lands somewhere near the face and the animation
    # has to be re-tuned every time a bone moves.
    mouth = _swing(lips, _SWING)
    axis = Matrix.Rotation(math.radians(-_JUG_LEAN), 4, "Y") @ Vector((0.0, 0.0, 1.0))
    base = mouth - axis * _JUG_HEIGHT
    jug_from_arm = Matrix.Translation(base - _SHOULDER) @ Matrix.Rotation(
        math.radians(-_JUG_LEAN), 4, "Y")

    body = revolve("jug", _JUG_OUTLINE, segments=40, rings=26, thickness=0.0055,
                   cap_bottom=False, cap_top=False, sharp_angle=44.0)
    handle = _tube("jug_handle", [
        Vector((0.012, 0.0, 0.140)), Vector((0.052, 0.0, 0.138)),
        Vector((0.074, 0.0, 0.112)), Vector((0.066, 0.0, 0.082)),
        Vector((0.038, 0.0, 0.070)),
    ], Profile([(0.0, 0.0075), (0.5, 0.0090), (1.0, 0.0075)]), rings=16, segments=8,
        section=(1.0, 0.60))
    for obj in (body, handle):
        obj.parent = arm
        obj.matrix_basis = jug_from_arm
        assign(obj, glaze)

    grip = jug_from_arm @ _GRIP + Vector((0.0, _NEAR * 0.004, 0.0))
    elbow = _elbow(Vector((0.0, 0.0, 0.0)), grip, _UPPER_ARM, _FOREARM,
                   Vector((-0.35, _NEAR * 1.0, -0.45)))
    # The wrist sits back along the forearm, so the palm itself lies across the handle
    # and the fingers close over its far side rather than ending in mid-air.
    wrist = grip - (grip - elbow).normalized() * 0.030

    bones = [
        _tube("humerus_near", [Vector((0.0, 0.0, 0.0)), elbow],
              _limb_bone(0.0125, 0.020, 0.017), rings=18, segments=10, section=(1.0, 0.90)),
        _tube("radius_near", [elbow, wrist], _limb_bone(0.0105, 0.016, 0.012),
              rings=18, segments=10, section=(1.0, 0.88)),
        # Fingers spread along the handle and curl across it: a grip, not a splay.
        *_hand("near", wrist, grip - wrist, axis, Vector((0.0, -_NEAR * 0.020, -0.004))),
    ]
    for obj in bones:
        obj.parent = arm
        assign(obj, bone)

    emitter = bpy.data.objects.new("emit_jug", None)
    bpy.context.collection.objects.link(emitter)
    emitter.parent = body                 # rides the jug, so it needs no machinery
    emitter.location = (0.0, 0.0, -0.005)  # just outside the hole in the base
    emitter.empty_display_size = 0.02
    return arm


def _swing(point, degrees):
    """Rotate a point about the shoulder, the way `part_arm` will rotate at runtime."""
    return _SHOULDER + (Matrix.Rotation(math.radians(degrees), 3, "Y")
                        @ (point - _SHOULDER))


# -- small shared shapes --------------------------------------------------------------


def _tube(name, path, radius, rings=16, segments=10, section=(1.0, 1.0),
          rounded_caps=True, subsurf=0):
    return SweptTube(path, radius, rings=rings, segments=segments, section=section,
                     rounded_caps=rounded_caps).build(name, subsurf=subsurf)


def _harden(obj):
    """Split the shading at hard angles, so a flat cap reads as flat.

    `SweptTube` smooth-shades everything, which is right for a bone and wrong for the one
    place this model needs a crisp edge: an eye socket is a flat dark disc, and with its
    rim normals averaged into the surrounding wall it shades like a ball and reads as an
    eyeball rather than as a hole.
    """
    split = obj.modifiers.new("EdgeSplit", "EDGE_SPLIT")
    split.split_angle = math.radians(38.0)
    split.use_edge_angle = True
    split.use_edge_sharp = False
    return obj


def _limb_bone(shaft, head, foot):
    """A slim shaft with a knob at each end, because that knob is what an epiphysis is.

    The swelling has to sit slightly *inboard* of the tip and then narrow again, or the
    rounded cap simply continues it and the bone reads as a capsule. A constant radius is
    worse still: dowel is the fastest way to make a skeleton look like plastic tubing.
    """
    return Profile([
        (0.00, head * 0.76), (0.06, head), (0.17, shaft * 1.06), (0.5, shaft),
        (0.83, shaft * 1.06), (0.94, foot), (1.00, foot * 0.76),
    ])


def _hand(tag, wrist, reach, out, curl):
    """A palm and four digits: three fingers plus an opposed thumb.

    Both hands are places the eye goes — one holds the jug, the other takes his weight —
    and a rounded stub on the end of a forearm reads as an amputation. `reach` is the
    palm, `out` the axis the fingers spread along, and `curl` where the tips end up, which
    is what separates a grip from a splayed brace.
    """
    forward = reach.normalized()
    out = out.normalized()
    span = reach.length
    parts = [_tube(f"palm_{tag}", [wrist, wrist + reach],
                   Profile([(0.0, 0.0100), (0.45, 0.0135), (1.0, 0.0120)]),
                   rings=8, segments=10, section=(0.60, 1.0))]

    finger = span * 0.86
    for index, offset in enumerate((-1.0, 0.0, 1.0)):
        base = wrist + reach + out * (offset * 0.0115)
        parts.append(_tube(f"finger_{tag}{index}", [
            base,
            base + forward * (finger * 0.55) + curl * 0.28 + out * (offset * 0.004),
            base + forward * (finger * 0.88) + curl + out * (offset * 0.009),
        ], Profile([(0.0, 0.0056), (0.55, 0.0046), (1.0, 0.0036)]), rings=12, segments=8))

    root = wrist + reach * 0.40 - out * 0.013
    parts.append(_tube(f"thumb_{tag}", [
        root,
        root + forward * (finger * 0.34) - out * 0.009 + curl * 0.30,
        root + forward * (finger * 0.60) - out * 0.003 + curl * 0.75,
    ], Profile([(0.0, 0.0062), (1.0, 0.0042)]), rings=10, segments=8))
    return parts


def _place(obj, position, pitch_degrees):
    """Bake a rotation and a position into a mesh, leaving the object transform clean."""
    obj.data.transform(Matrix.Translation(position)
                       @ Matrix.Rotation(math.radians(pitch_degrees), 4, "Y"))


def _fit(start, target, length):
    """`target` pulled onto the sphere of radius `length` about `start`.

    Limb bones have to be the same length on both sides of the body or the pose reads as
    a modelling mistake, so joint positions are aimed and then corrected rather than
    typed out to four decimal places.
    """
    direction = target - start
    if direction.length < 1e-6:
        raise ValueError("a bone needs a direction")
    return start + direction.normalized() * length


def _elbow(shoulder, hand, upper, fore, pole):
    """Two-bone IK: where the elbow must sit for both bones to reach the hand.

    Solving this beats typing an elbow position because the hand's position is itself
    derived — it is wherever the jug's handle ended up — so a hand-tuned elbow would have
    to be re-tuned every time the jug moves.
    """
    span = hand - shoulder
    length = min(span.length, (upper + fore) * 0.999)
    direction = span.normalized()
    along = (upper * upper - fore * fore + length * length) / (2.0 * length)
    out = math.sqrt(max(upper * upper - along * along, 0.0))
    side = pole - direction * pole.dot(direction)
    if side.length < 1e-6:
        side = direction.orthogonal()
    return shoulder + direction * along + side.normalized() * out


SKELETON_WITH_JUG = Prop(
    name="skeleton_with_jug",
    build=build,
    category="decoration",
    footprint=0.36,
    height=0.64,
    tilt_range=(-4.0, 4.0),
    scale_range=(0.90, 1.15),
    weight=0.6,
    max_per_scene=1,
    min_spacing=0.78,
    parts=[Part(node="part_arm", axis=(0.0, 1.0, 0.0), open_degrees=-_SWING)],
    emitters=[Emitter(node="emit_jug", rate=26.0, radius=0.009,
                      size=(0.0025, 0.0065), speed=0.075)],
    cycle=[
        # Comic timing: he waits a good while, hoists it fast, takes a long pull, and
        # lowers it reluctantly. The idle is a range so two props never sync up.
        Phase("idle", (7.0, 17.0)),
        Phase("move", 0.55, part="part_arm", to=1.0, ease="easeOut"),
        Phase("emit", (2.4, 3.6), emitter="emit_jug"),
        Phase("move", 1.8, part="part_arm", to=0.0, ease="easeInOut"),
    ],
    seeds=2,
)
