"""Google Calendar -> the calendar_source shape src/full.liquid expects.

Aggregates every calendar the authorised account can see (personal, shared,
subscribed -- including the M365 work calendar, which is already subscribed
into this Google account the same way TRMNL's own Google Calendar plugin
sees it today) into one rolling week of events.
"""

from __future__ import annotations

import os
import re
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build

from env import optional_env_list, required_env

# Defaults to the host layout (../secrets relative to this file); the
# container overrides this via SECRETS_DIR since it only copies app/*.py in,
# not the project root.
SECRETS_DIR = Path(
    os.environ.get("SECRETS_DIR", Path(__file__).resolve().parent.parent / "secrets")
)
TOKEN_FILE = SECRETS_DIR / "google_token.json"
TIMEZONE = required_env("LOCAL_TIMEZONE")
DAYS_AHEAD = 7

# Calendars to skip entirely, by summary -- case-insensitive exact match
# (not a pattern like the event filter below: calendar names are short,
# fixed strings, so substring matching risks hiding an unrelated calendar
# with a similar name). Personal preference, so it's an env var, not
# hardcoded here.
EXCLUDED_CALENDAR_SUMMARIES: set[str] = {
    name.lower() for name in optional_env_list("EXCLUDED_CALENDAR_SUMMARIES")
}

# Events to skip, by summary -- case-insensitive substring/regex match
# (e.g. "Complete Timesheet" for a recurring reminder nobody wants on the
# dashboard). Personal preference, so it's an env var, not hardcoded here.
EXCLUDED_EVENT_SUMMARY_PATTERNS: list[re.Pattern] = [
    re.compile(pattern, re.IGNORECASE)
    for pattern in optional_env_list("EXCLUDED_EVENT_SUMMARY_PATTERNS")
]


def _iso_with_offset(dt: datetime) -> str:
    """Match the sample payload's "2026-08-24T00:00:00.000+01:00" shape."""
    return (
        dt.strftime("%Y-%m-%dT%H:%M:%S.")
        + f"{dt.microsecond // 1000:03d}"
        + dt.strftime("%z")[:3]
        + ":"
        + dt.strftime("%z")[3:]
    )


def _localized_event_datetime(node: dict, tz: ZoneInfo) -> datetime | None:
    """None for all-day events (no dateTime, just a bare date)."""
    if "date" in node:
        return None
    dt = datetime.fromisoformat(node["dateTime"])
    # Google returns dateTime with whatever offset the event's own calendar
    # is configured in -- not necessarily LOCAL_TIMEZONE (the M365 work
    # calendar synced into this account, for instance, can come back in
    # UTC). astimezone() converts an aware value properly; a naive one is
    # assumed to already be in tz, matching how Google represents it when
    # a timeZone field accompanies a plain (offset-less) dateTime.
    return dt.astimezone(tz) if dt.tzinfo else dt.replace(tzinfo=tz)


def fetch_calendar_source() -> dict:
    creds = Credentials.from_authorized_user_file(str(TOKEN_FILE))
    service = build("calendar", "v3", credentials=creds)
    tz = ZoneInfo(TIMEZONE)

    today = datetime.now(tz).replace(hour=0, minute=0, second=0, microsecond=0)
    window_end = today + timedelta(days=DAYS_AHEAD)

    calendars = service.calendarList().list().execute().get("items", [])
    # Primary first: the same meeting often exists on more than one calendar
    # (e.g. the M365 work calendar synced into this Google account alongside
    # its own copy), and dedup below keeps whichever copy is seen first.
    calendars.sort(key=lambda cal: not cal.get("primary", False))

    events: list[dict] = []
    for cal in calendars:
        if cal.get("summary", "").lower() in EXCLUDED_CALENDAR_SUMMARIES:
            continue

        page_token = None
        while True:
            resp = (
                service.events()
                .list(
                    calendarId=cal["id"],
                    timeMin=today.isoformat(),
                    timeMax=window_end.isoformat(),
                    singleEvents=True,
                    orderBy="startTime",
                    pageToken=page_token,
                    # No "description": it routinely carries dial-in PINs/passcodes
                    # and attendee lists from Teams/Zoom auto-invites, and the
                    # template doesn't show it by default anyway.
                    fields="nextPageToken,items(summary,status,start,end,location)",
                )
                .execute()
            )

            for evt in resp.get("items", []):
                if "dateTime" not in evt.get("start", {}) and "date" not in evt.get("start", {}):
                    continue  # no start time at all -- skip
                summary = evt.get("summary", "(No title)")
                if any(p.search(summary) for p in EXCLUDED_EVENT_SUMMARY_PATTERNS):
                    continue
                start_dt = _localized_event_datetime(evt["start"], tz)
                end_dt = _localized_event_datetime(evt["end"], tz)
                all_day = start_dt is None

                start_full = _iso_with_offset(start_dt) if start_dt else evt["start"]["date"]
                end_full = _iso_with_offset(end_dt) if end_dt else evt["end"]["date"]
                start_label = start_dt.strftime("%H:%M") if start_dt else None
                end_label = end_dt.strftime("%H:%M") if end_dt else None

                # Descriptions often carry dial-in PINs, passcodes and attendee
                # lists (Teams/Zoom auto-invites in particular). The template
                # only renders these when include_description is on -- which
                # defaults off below -- so nothing is fetched over the wire
                # unless that's deliberately switched on later.
                description = ""

                events.append(
                    {
                        "summary": summary,
                        "all_day": all_day,
                        "status": evt.get("status", "confirmed"),
                        "start": start_label,
                        "end": end_label,
                        "start_full": start_full,
                        "end_full": end_full,
                        "location": evt.get("location"),
                        "description": description,
                        "background_color": cal.get("backgroundColor", "#4986e7"),
                    }
                )

            page_token = resp.get("nextPageToken")
            if not page_token:
                break

    # Same meeting invite landing on more than one calendar (shared/synced
    # accounts) shows up as identical events at the same time with different
    # colours -- which the day grid then draws as a real overlap. Collapse
    # those before the template ever sees them, keeping the first (primary
    # calendar's) copy.
    seen: set[tuple] = set()
    deduped: list[dict] = []
    for evt in events:
        key = (evt["summary"], evt["all_day"], evt["start_full"], evt["end_full"])
        if key in seen:
            continue
        seen.add(key)
        deduped.append(evt)
    events = deduped

    # The day grid's lane-packing layout (Google-Calendar-style, greedy
    # left-to-right by start time) needs events in true chronological order
    # to work -- Google's orderBy=startTime above only sorts each calendar's
    # own results, so events from different calendars still arrive grouped
    # by calendar, not merged by time. Without this, two genuinely
    # overlapping events from different calendars can land in the same
    # lane (the template's greedy algorithm is only correct when fed
    # events in start-time order) and render stacked directly on top of
    # each other -- indistinguishable from a solid block on a 2-bit
    # display -- even though there was actually room for both side by side.
    events.sort(
        key=lambda evt: (
            datetime.strptime(evt["start_full"], "%Y-%m-%d").replace(tzinfo=tz)
            if evt["all_day"]
            else datetime.fromisoformat(evt["start_full"])
        )
    )

    return {
        "tz": TIMEZONE,
        "today_in_tz": _iso_with_offset(today),
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
        "events": events,
    }
