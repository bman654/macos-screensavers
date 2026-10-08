"""The origami model catalog, assembled by discovery.

Every module in this package that defines `Model` instances at module level has them
registered automatically, the same arrangement as the Aquarium's `props`: adding a model
touches one file, so several families can be authored concurrently.
"""

import importlib
import pkgutil

from ._spec import GROUNDED, KINDS, Model

CATALOG = {}

for _module in pkgutil.iter_modules(__path__):
    if _module.name.startswith("_"):
        continue
    _loaded = importlib.import_module(f"{__name__}.{_module.name}")
    for _value in vars(_loaded).values():
        if isinstance(_value, Model):
            if _value.name in CATALOG:
                raise ValueError(f"duplicate model name: {_value.name}")
            CATALOG[_value.name] = _value

__all__ = ["CATALOG", "GROUNDED", "KINDS", "Model"]
