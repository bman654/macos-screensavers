"""The prop catalog, assembled by discovery.

One module per prop, and every `Prop` instance defined at module level is registered
automatically — the same arrangement as `species`, and for the same reason: adding a prop
touches exactly one new file, so several can be authored concurrently.
"""

import importlib
import pkgutil

from ._spec import Emitter, Part, Phase, Prop

CATALOG = {}

for _module in pkgutil.iter_modules(__path__):
    if _module.name.startswith("_"):
        continue
    _loaded = importlib.import_module(f"{__name__}.{_module.name}")
    for _value in vars(_loaded).values():
        if isinstance(_value, Prop):
            if _value.name in CATALOG:
                raise ValueError(f"duplicate prop name: {_value.name}")
            CATALOG[_value.name] = _value

__all__ = ["CATALOG", "Emitter", "Part", "Phase", "Prop"]
