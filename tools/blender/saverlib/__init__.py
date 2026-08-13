"""Reusable parametric modelling helpers for screensaver assets."""

from .curves import Profile, as_profile, smoothstep, superellipse
from .body import Body, BodySpec, shade_smooth
from .fins import build_fin, caudal_root, dorsal_root, flank_root, ventral_root
from .materials import assign, eye_material, fin_material, fish_material
from .tube import BranchSpec, BranchingResult, SweptTube, build_branching
from . import studio

__all__ = [
    "Profile", "as_profile", "smoothstep", "superellipse",
    "Body", "BodySpec", "shade_smooth",
    "build_fin", "caudal_root", "dorsal_root", "flank_root", "ventral_root",
    "assign", "eye_material", "fin_material", "fish_material",
    "BranchSpec", "BranchingResult", "SweptTube", "build_branching",
    "studio",
]
