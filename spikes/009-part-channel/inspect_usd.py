#!/usr/bin/env python3
"""Summarize the color primvar in usdcat-generated USDA files."""

import json
import re
from pathlib import Path

SPIKE_DIR = Path(__file__).resolve().parent
TUPLE = re.compile(r"\(([^()]*)\)")


def tuples_from_declaration(line):
    return [tuple(float(item.strip()) for item in match.group(1).split(",")) for match in TUPLE.finditer(line)]


def inspect(path):
    lines = path.read_text().splitlines()
    declaration_index = next(i for i, line in enumerate(lines) if "color3f[] primvars:displayColor" in line)
    values = tuples_from_declaration(lines[declaration_index])
    interpolation = next(
        re.search(r'"([^"]+)"', line).group(1)
        for line in lines[declaration_index + 1:declaration_index + 5]
        if "interpolation" in line
    )
    points_line = next(line for line in lines if "point3f[] points =" in line)
    points = tuples_from_declaration(points_line)
    unique = sorted({tuple(round(channel, 6) for channel in value) for value in values})
    texcoords = {}
    for uv_index, line in enumerate(lines):
        match = re.search(r"texCoord2f\[\] primvars:([^ ]+)", line)
        if not match:
            continue
        uv_values = tuples_from_declaration(line)
        uv_interpolation = next(
            re.search(r'"([^"]+)"', candidate).group(1)
            for candidate in lines[uv_index + 1:uv_index + 5]
            if "interpolation" in candidate
        )
        texcoords[match.group(1)] = {
            "count": len(uv_values),
            "interpolation": uv_interpolation,
            "u_range": [min(value[0] for value in uv_values), max(value[0] for value in uv_values)],
            "v_range": [min(value[1] for value in uv_values), max(value[1] for value in uv_values)],
            "unique_u": len({round(value[0], 6) for value in uv_values}),
            "unique_v": len({round(value[1], 6) for value in uv_values}),
        }
    return {
        "file": str(path),
        "points": len(points),
        "displayColor_count": len(values),
        "interpolation": interpolation,
        "r_range": [min(value[0] for value in values), max(value[0] for value in values)],
        "g_range": [min(value[1] for value in values), max(value[1] for value in values)],
        "nonzero_r": sum(value[0] > 1e-6 for value in values),
        "nonzero_g": sum(value[1] > 1e-6 for value in values),
        "unique_count": len(unique),
        "first_unique": unique[:8],
        "last_unique": unique[-8:],
        "texcoords": texcoords,
    }


def main():
    results = {}
    for path in sorted((SPIKE_DIR / "output").glob("*/scene.usda")):
        results[path.parent.name] = inspect(path)
    output = SPIKE_DIR / "output" / "usd-report.json"
    output.write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
