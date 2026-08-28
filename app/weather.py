"""Open-Meteo -> the weather_source / hourly_source shapes src/full.liquid expects.

Icon mapping (WMO weather code -> TRMNL's wi-* names) is our own choice, not an
official crosswalk -- Open-Meteo publishes only the WMO codes and their text
descriptions (see https://open-meteo.com/en/docs), and the wi-* set comes from
trmnl-calendar-weather/src/full.liquid's own icon-mapping block. Adjust
WMO_TO_WI below if a mapping looks wrong for a given code.
"""

from __future__ import annotations

from datetime import datetime
from zoneinfo import ZoneInfo

import requests

from env import required_env

LATITUDE = float(required_env("WEATHER_LATITUDE"))
LONGITUDE = float(required_env("WEATHER_LONGITUDE"))
TIMEZONE = required_env("LOCAL_TIMEZONE")
WEATHER_ICON_BASE = "https://trmnl.com/images/plugins/weather/"

# WMO code -> (day icon, night icon), both bare "wi-*" names (template uses
# these as-is when the slug already contains "wi-").
WMO_TO_WI: dict[int, tuple[str, str]] = {
    0: ("wi-day-sunny", "wi-night-clear"),
    1: ("wi-day-sunny", "wi-night-clear"),
    2: ("wi-day-cloudy", "wi-night-alt-cloudy"),
    3: ("wi-cloudy", "wi-cloudy"),
    45: ("wi-fog", "wi-fog"),
    48: ("wi-fog", "wi-fog"),
    51: ("wi-day-sprinkle", "wi-night-alt-sprinkle"),
    53: ("wi-day-sprinkle", "wi-night-alt-sprinkle"),
    55: ("wi-day-sprinkle", "wi-night-alt-sprinkle"),
    56: ("wi-day-sleet", "wi-night-alt-sleet"),
    57: ("wi-day-sleet", "wi-night-alt-sleet"),
    61: ("wi-day-rain", "wi-night-alt-rain"),
    63: ("wi-day-rain", "wi-night-alt-rain"),
    65: ("wi-day-rain", "wi-night-alt-rain"),
    66: ("wi-day-sleet", "wi-night-alt-sleet"),
    67: ("wi-day-sleet", "wi-night-alt-sleet"),
    71: ("wi-day-snow", "wi-night-alt-snow"),
    73: ("wi-day-snow", "wi-night-alt-snow"),
    75: ("wi-day-snow", "wi-night-alt-snow"),
    77: ("wi-day-snow", "wi-night-alt-snow"),
    80: ("wi-day-showers", "wi-night-alt-showers"),
    81: ("wi-day-showers", "wi-night-alt-showers"),
    82: ("wi-day-showers", "wi-night-alt-showers"),
    85: ("wi-day-snow", "wi-night-alt-snow"),
    86: ("wi-day-snow", "wi-night-alt-snow"),
    95: ("wi-day-thunderstorm", "wi-night-alt-thunderstorm"),
    96: ("wi-hail", "wi-hail"),
    99: ("wi-hail", "wi-hail"),
}

WMO_DESCRIPTIONS: dict[int, str] = {
    0: "Clear sky",
    1: "Mainly clear",
    2: "Partly cloudy",
    3: "Overcast",
    45: "Fog",
    48: "Depositing rime fog",
    51: "Light drizzle",
    53: "Moderate drizzle",
    55: "Dense drizzle",
    56: "Light freezing drizzle",
    57: "Dense freezing drizzle",
    61: "Slight rain",
    63: "Moderate rain",
    65: "Heavy rain",
    66: "Light freezing rain",
    67: "Heavy freezing rain",
    71: "Slight snow",
    73: "Moderate snow",
    75: "Heavy snow",
    77: "Snow grains",
    80: "Slight rain showers",
    81: "Moderate rain showers",
    82: "Violent rain showers",
    85: "Slight snow showers",
    86: "Heavy snow showers",
    95: "Thunderstorm",
    96: "Thunderstorm with hail",
    99: "Thunderstorm with heavy hail",
}


def _wi_icon(code: int, is_night: bool) -> str:
    day, night = WMO_TO_WI.get(code, ("wi-na", "wi-na"))
    return night if is_night else day


def _wi_icon_url(code: int, is_night: bool) -> str:
    return f"{WEATHER_ICON_BASE}{_wi_icon(code, is_night)}.svg"


def _description(code: int) -> str:
    return WMO_DESCRIPTIONS.get(code, "Unknown")


def _compass(degrees: float) -> str:
    directions = [
        "N",
        "NNE",
        "NE",
        "ENE",
        "E",
        "ESE",
        "SE",
        "SSE",
        "S",
        "SSW",
        "SW",
        "WSW",
        "W",
        "WNW",
        "NW",
        "NNW",
    ]
    return directions[round(degrees / 22.5) % 16]


CURRENT_FIELDS = [
    "temperature_2m",
    "apparent_temperature",
    "relative_humidity_2m",
    "weather_code",
    "wind_speed_10m",
    "wind_gusts_10m",
    "wind_direction_10m",
]
DAILY_FIELDS = [
    "weather_code",
    "temperature_2m_max",
    "temperature_2m_min",
    "sunrise",
    "sunset",
    "uv_index_max",
    "precipitation_probability_max",
]


def fetch_weather() -> dict:
    resp = requests.get(
        "https://api.open-meteo.com/v1/forecast",
        params={
            "latitude": LATITUDE,
            "longitude": LONGITUDE,
            "current": ",".join(CURRENT_FIELDS),
            "hourly": "temperature_2m,weather_code",
            "daily": ",".join(DAILY_FIELDS),
            "timezone": TIMEZONE,
            "forecast_days": 3,
            "wind_speed_unit": "mph",
        },
        timeout=10,
    )
    resp.raise_for_status()
    data = resp.json()

    tz = ZoneInfo(TIMEZONE)
    current = data["current"]
    # Anchored to Open-Meteo's own clock, not this machine's -- a self-hosted
    # server that sleeps can have a container clock that's transiently stale
    # for a while right after waking (a known suspend/resume quirk), and this
    # value drives which hours count as "upcoming" below. datetime.now(tz)
    # looked fine in isolation but, following exactly that kind of wake, put
    # the whole hourly window in the past relative to the *template's* own
    # (separately evaluated, already-resynced) idea of "now" -- correct data,
    # anchored to the wrong instant.
    now = datetime.fromisoformat(current["time"]).replace(tzinfo=tz)
    daily = data["daily"]
    hourly = data["hourly"]

    sunrise_today = datetime.fromisoformat(daily["sunrise"][0]).replace(tzinfo=tz)
    sunset_today = datetime.fromisoformat(daily["sunset"][0]).replace(tzinfo=tz)
    is_night_now = now < sunrise_today or now > sunset_today

    now_code = current["weather_code"]
    today_code = daily["weather_code"][0]
    tomorrow_code = daily["weather_code"][1]

    weather_source = {
        "temperature": current["temperature_2m"],
        "feels_like": current["apparent_temperature"],
        "humidity": current["relative_humidity_2m"],
        "utc_offset": int(now.utcoffset().total_seconds()),
        "time_format": "%H:%M",
        "data_provider": "open-meteo",
        "today_conditions": _description(today_code),
        "right_now_conditions": _description(now_code),
        "weather_image": _wi_icon(now_code, is_night_now),
        "today_weather_image": _wi_icon(today_code, False),
        "tomorrow_weather_image": _wi_icon(tomorrow_code, False),
        "forecast": {
            "right_now": {
                "icon": _wi_icon(now_code, is_night_now),
                "conditions": _description(now_code),
                "temperature": current["temperature_2m"],
                "feels_like": current["apparent_temperature"],
                "humidity": current["relative_humidity_2m"],
                "sunrise": sunrise_today.strftime("%H:%M"),
                "sunset": sunset_today.strftime("%H:%M"),
                "wind": {
                    "max": current["wind_speed_10m"],
                    "gust": current["wind_gusts_10m"],
                    "units": "mph",
                    "direction_cardinal": _compass(current["wind_direction_10m"]),
                },
            },
            "today": {
                "icon": _wi_icon(today_code, False),
                "conditions": _description(today_code),
                "maxtemp": daily["temperature_2m_max"][0],
                "mintemp": daily["temperature_2m_min"][0],
                "uv_index": daily["uv_index_max"][0],
                "day_override": None,
                "precip": {
                    "icon": "chance-rain",
                    "units": "mm",
                    "amount": None,
                    "probability": daily["precipitation_probability_max"][0],
                },
            },
            "tomorrow": {
                "icon": _wi_icon(tomorrow_code, False),
                "conditions": _description(tomorrow_code),
                "maxtemp": daily["temperature_2m_max"][1],
                "mintemp": daily["temperature_2m_min"][1],
                "uv_index": daily["uv_index_max"][1],
                "day_override": None,
                "precip": {
                    "icon": "chance-rain",
                    "probability": daily["precipitation_probability_max"][1],
                },
            },
        },
    }

    # Hourly strip: next 7 readings, 2-hour steps, matching the dashboard's own
    # refresh cadence.
    hourly_times = [datetime.fromisoformat(t).replace(tzinfo=tz) for t in hourly["time"]]
    start_idx = next(i for i, t in enumerate(hourly_times) if t >= now)
    step = 2
    picks = list(range(start_idx, min(start_idx + step * 7, len(hourly_times)), step))[:7]

    temps = [hourly["temperature_2m"][i] for i in picks]
    trend = "steady"
    if len(temps) >= 2:
        trend = (
            "rising"
            if temps[-1] > temps[0] + 0.5
            else "falling"
            if temps[-1] < temps[0] - 0.5
            else "steady"
        )

    hourly_source = {
        "data": {
            "pill_mode": "point",
            "temp_trend": trend,
            "current_temp": current["temperature_2m"],
            "current_time_formatted": now.strftime("%H:%M"),
            "show_timestamps": True,
            "location_name": "",
            "temperatures": [[t] for t in temps],
            "timestamps_formatted": [hourly_times[i].strftime("%H:%M") for i in picks],
            "pill_classes": ["bg--gray-70"] * len(picks),
            "weather_icons": [
                _wi_icon_url(
                    hourly["weather_code"][i],
                    hourly_times[i] < sunrise_today or hourly_times[i] > sunset_today,
                )
                for i in picks
            ],
        }
    }

    return {"weather_source": weather_source, "hourly_source": hourly_source}
