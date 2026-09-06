"""Data service for the self-hosted TRMNL dashboard.

Exposes GET /data returning {"calendar_source": ..., "weather_source": ...,
"hourly_source": ...} -- the same shape trmnl-calendar-weather's Liquid
templates already expect from TRMNL's cloud Plugin Merge (see .trmnlp.yml in
that repo). Terminus's own Extension scheduler polls this on its configured
cadence; this service just answers with fresh (short-cached) data each time.
"""

from __future__ import annotations

import copy
import logging
import time
from datetime import datetime
from zoneinfo import ZoneInfo

from flask import Flask, jsonify

import gcal
import weather

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("trmnl-data")

app = Flask(__name__)

CACHE_TTL_SECONDS = 15 * 60
_cache: dict = {"payload": None, "fetched_at": 0.0, "last_error": None}


def _build_payload() -> dict:
    return {
        "calendar_source": gcal.fetch_calendar_source(),
        **weather.fetch_weather(),
    }


def _format_age(seconds: float) -> str:
    hours = int(seconds // 3600)
    if hours < 24:
        return f"{hours}h"
    return f"{hours // 24}d {hours % 24}h"


def _error_banner_event(detail: str) -> dict:
    """An all-day event, not a screen change -- the point is to surface a
    build failure (see get_payload) on the actual dashboard without
    touching the working template/rendering at all. Deliberately short and
    generic on-screen (no raw exception text): this is a physically
    visible display, and the real detail is already in /health and the
    container logs.
    """
    today = datetime.now(ZoneInfo(gcal.TIMEZONE)).strftime("%Y-%m-%d")
    return {
        "summary": f"⚠ Data error ({detail})",
        "all_day": True,
        "status": "confirmed",
        "start": None,
        "end": None,
        "start_full": today,
        "end_full": today,
        "location": None,
        "description": "",
        "background_color": "#d32f2f",
    }


def _empty_calendar_source() -> dict:
    """Structurally valid but eventless -- used only when a build has
    never once succeeded, so there's no stale calendar to show alongside
    the error banner."""
    tz = ZoneInfo(gcal.TIMEZONE)
    today = datetime.now(tz).replace(hour=0, minute=0, second=0, microsecond=0)
    return {
        "tz": gcal.TIMEZONE,
        "today_in_tz": gcal._iso_with_offset(today),
        "event_layout": "rolling_week",
        "first_day": 1,
        "time_format": "24h",
        "date_format": "short",
        "scroll_time": "07:00:00",
        "scroll_time_end": "22:00:00",
        "include_description": False,
        "include_event_time": True,
        "shade_weekends": True,
        "colorize_events": True,
        "highlight_today": True,
        "events": [],
    }


def _empty_weather_payload() -> dict:
    """Same idea as _empty_calendar_source, for the weather/hourly side."""
    right_now = {
        "icon": "wi-na",
        "conditions": "",
        "temperature": None,
        "feels_like": None,
        "humidity": None,
        "sunrise": "",
        "sunset": "",
        "wind": {"max": None, "gust": None, "units": "mph", "direction_cardinal": ""},
    }
    day = {
        "icon": "wi-na",
        "conditions": "",
        "maxtemp": None,
        "mintemp": None,
        "uv_index": None,
        "day_override": None,
        "precip": {"icon": "chance-rain", "units": "mm", "amount": None, "probability": None},
    }
    return {
        "weather_source": {
            "temperature": None,
            "feels_like": None,
            "humidity": None,
            "utc_offset": 0,
            "time_format": "%H:%M",
            "data_provider": "open-meteo",
            "today_conditions": "",
            "right_now_conditions": "",
            "weather_image": "wi-na",
            "today_weather_image": "wi-na",
            "tomorrow_weather_image": "wi-na",
            "forecast": {"right_now": right_now, "today": day, "tomorrow": day},
        },
        "hourly_source": {
            "data": {
                "pill_mode": "point",
                "temp_trend": "steady",
                "current_temp": None,
                "current_time_formatted": "",
                "show_timestamps": True,
                "location_name": "",
                "temperatures": [],
                "timestamps_formatted": [],
                "pill_classes": [],
                "weather_icons": [],
            }
        },
    }


def get_payload() -> dict:
    age = time.time() - _cache["fetched_at"]
    if _cache["payload"] is not None and age < CACHE_TTL_SECONDS:
        return _cache["payload"]

    try:
        payload = _build_payload()
    except Exception as exc:
        log.exception("Failed to build dashboard payload")
        _cache["last_error"] = str(exc)

        if _cache["payload"] is not None:
            log.warning("Serving stale cached payload with an error banner (age=%.0fs)", age)
            degraded = copy.deepcopy(_cache["payload"])
            degraded["calendar_source"]["events"].insert(
                0, _error_banner_event(f"stale {_format_age(age)}")
            )
            return degraded

        log.warning("No cached payload available -- serving an error-only screen")
        return {
            "calendar_source": {
                **_empty_calendar_source(),
                "events": [_error_banner_event("no data")],
            },
            **_empty_weather_payload(),
        }

    _cache["payload"] = payload
    _cache["fetched_at"] = time.time()
    _cache["last_error"] = None
    return payload


@app.get("/data")
def data():
    return jsonify(get_payload())


@app.get("/health")
def health():
    # Reflects whether the payload can actually be built, not just whether
    # the Flask process is alive -- a silent build failure (expired Google
    # token, Open-Meteo down, etc.) previously stayed invisible behind a
    # permanently "ok" health check while Terminus kept re-serving a
    # steadily staler cached screen. Podman's healthcheck (compose.yml)
    # polls this, so a real failure now shows as "unhealthy" in `docker ps`.
    if _cache["last_error"] is not None:
        body = {
            "status": "degraded",
            "last_error": _cache["last_error"],
            "cache_age_seconds": (
                round(time.time() - _cache["fetched_at"]) if _cache["payload"] is not None else None
            ),
        }
        return body, 503
    return {"status": "ok"}


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8090)
