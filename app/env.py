"""Shared environment-variable helper for gcal.py and weather.py."""

from __future__ import annotations

import os


def required_env(name: str) -> str:
    """Fetch an env var that has no sensible default (e.g. your own location).

    Fails loudly at import time rather than silently falling back to
    something that would only be correct for one specific installation.
    """
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"{name} must be set -- see .env.example.")
    return value


def optional_env_list(name: str, separator: str = ",") -> list[str]:
    """Comma-separated env var -> list of stripped, non-empty entries.

    Defaults to an empty list -- for personal-preference settings (e.g.
    which events to exclude) that have no meaningful default value.
    """
    raw = os.environ.get(name, "")
    return [item.strip() for item in raw.split(separator) if item.strip()]
