"""Small TOML reader for the manager's generated test configurations.

Python 3.11 ships ``tomllib`` in the standard library.  Ubuntu 22.04 ships
Python 3.10, so the regression suite uses this dependency-free fallback there.
It intentionally supports only the TOML values emitted by this project.
"""

from __future__ import annotations

import ast
from typing import Any


def _parse_value(value: str) -> Any:
    value = value.strip()
    if value == "true":
        return True
    if value == "false":
        return False
    if value.startswith('"') or value.startswith("'") or value.startswith("["):
        try:
            return ast.literal_eval(value)
        except (SyntaxError, ValueError) as exc:
            raise ValueError(f"unsupported TOML value: {value}") from exc
    try:
        return int(value)
    except ValueError as exc:
        raise ValueError(f"unsupported TOML value: {value}") from exc


def loads(text: str) -> dict[str, Any]:
    """Parse the simple sections and scalar/array values Homa writes."""

    document: dict[str, Any] = {}
    section: dict[str, Any] | None = None
    pending_key: str | None = None
    pending_value: list[str] = []

    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue

        if pending_key is not None:
            pending_value.append(line)
            if line.endswith("]"):
                assert section is not None
                section[pending_key] = _parse_value("\n".join(pending_value))
                pending_key = None
                pending_value = []
            continue

        if line.startswith("[") and line.endswith("]"):
            section_name = line[1:-1].strip()
            if not section_name or section_name in document:
                raise ValueError(f"invalid TOML section on line {line_number}")
            section = {}
            document[section_name] = section
            continue

        if section is None or "=" not in line:
            raise ValueError(f"invalid TOML assignment on line {line_number}")

        key, value = (part.strip() for part in line.split("=", 1))
        if not key or key in section:
            raise ValueError(f"invalid TOML key on line {line_number}")
        if value.startswith("[") and not value.endswith("]"):
            pending_key = key
            pending_value = [value]
        else:
            section[key] = _parse_value(value)

    if pending_key is not None:
        raise ValueError(f"unterminated TOML array for {pending_key}")
    return document
