"""The species catalog, assembled by discovery.

One module per species, and every `Species` instance defined at module level is
registered automatically. Discovery rather than an explicit import list is deliberate:
adding a species touches exactly one new file, so several species can be authored
concurrently without any of them editing a file another one is editing.
"""

import importlib
import pkgutil

from ._spec import Fin, Species

CATALOG = {}

for _module in pkgutil.iter_modules(__path__):
    if _module.name.startswith("_"):
        continue
    _loaded = importlib.import_module(f"{__name__}.{_module.name}")
    for _value in vars(_loaded).values():
        if isinstance(_value, Species):
            if _value.name in CATALOG:
                raise ValueError(f"duplicate species name: {_value.name}")
            CATALOG[_value.name] = _value

__all__ = ["CATALOG", "Fin", "Species"]
