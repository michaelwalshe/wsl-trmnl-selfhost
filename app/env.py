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
