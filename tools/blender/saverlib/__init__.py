"""Reusable parametric modelling helpers for screensaver assets."""

from .curves import Profile, as_profile, smoothstep, superellipse
from .body import Body, BodySpec, shade_smooth
from .curved import CurvedBody, CurvedBodySpec
from .fins import build_fin, caudal_root, dorsal_root, flank_root, ventral_root
from .materials import assign, eye_material, fin_material, fish_material
from .tube import BranchSpec, BranchingResult, SweptTube, build_branching
from .hardsurface import (
    Noise, beveled_box, bounding_radius, displace, plank, revolve, rock,
)
from .surfaces import (
    BRASS, COPPER, IRON, RUST, STEEL, TARNISH, VERDIGRIS,
    bone_material, glass_material, metal_material, rock_material,
    sand_material, wood_material,
)
from . import studio

__all__ = [
    "Profile", "as_profile", "smoothstep", "superellipse",
    "Body", "BodySpec", "shade_smooth",
    "CurvedBody", "CurvedBodySpec",
    "build_fin", "caudal_root", "dorsal_root", "flank_root", "ventral_root",
    "assign", "eye_material", "fin_material", "fish_material",
    "BranchSpec", "BranchingResult", "SweptTube", "build_branching",
    "Noise", "beveled_box", "bounding_radius", "displace", "plank", "revolve", "rock",
    "BRASS", "COPPER", "IRON", "RUST", "STEEL", "TARNISH", "VERDIGRIS",
    "bone_material", "glass_material", "metal_material", "rock_material",
    "sand_material", "wood_material",
    "studio",
]
