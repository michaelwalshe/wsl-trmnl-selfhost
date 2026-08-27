"""Data service for the self-hosted TRMNL dashboard.

Exposes GET /data returning {"calendar_source": ..., "weather_source": ...,
"hourly_source": ...} -- the same shape trmnl-calendar-weather's Liquid
templates already expect from TRMNL's cloud Plugin Merge (see .trmnlp.yml in
that repo). Terminus's own Extension scheduler polls this on its configured
cadence; this service just answers with fresh (short-cached) data each time.
"""

from __future__ import annotations

import logging
import time

from flask import Flask, jsonify

import gcal
import weather

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("trmnl-data")

app = Flask(__name__)

CACHE_TTL_SECONDS = 15 * 60
_cache: dict = {"payload": None, "fetched_at": 0.0}


def _build_payload() -> dict:
    return {
        "calendar_source": gcal.fetch_calendar_source(),
        **weather.fetch_weather(),
    }


def get_payload() -> dict:
    age = time.time() - _cache["fetched_at"]
    if _cache["payload"] is not None and age < CACHE_TTL_SECONDS:
        return _cache["payload"]

    try:
        payload = _build_payload()
    except Exception:
        log.exception("Failed to build dashboard payload")
        if _cache["payload"] is not None:
            log.warning("Serving stale cached payload (age=%.0fs)", age)
            return _cache["payload"]
        raise

    _cache["payload"] = payload
    _cache["fetched_at"] = time.time()
    return payload


@app.get("/data")
def data():
    return jsonify(get_payload())


@app.get("/health")
def health():
    return {"status": "ok"}


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8090)
