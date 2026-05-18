#!/usr/bin/env python3
"""Generate the bundled Amtrak catalog from the official GTFS zip.

Usage:
  scripts/generate_amtrak_catalog.py /path/to/GTFS.zip \
    Packages/TransitCore/Sources/TransitModels/Resources/AmtrakCatalog.json
"""

from __future__ import annotations

import csv
import json
import sys
import zipfile
from collections import defaultdict
from pathlib import Path


def rows(zf: zipfile.ZipFile, name: str) -> list[dict[str, str]]:
    try:
        with zf.open(name) as raw:
            text = (line.decode("utf-8-sig") for line in raw)
            return list(csv.DictReader(text))
    except KeyError:
        return []


def seconds(value: str) -> int:
    pieces = value.split(":")
    if len(pieces) != 3:
        return 0
    h, m, s = (int(piece or 0) for piece in pieces)
    return h * 3600 + m * 60 + s


def clean(value: str | None) -> str:
    return (value or "").strip()


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    zip_path = Path(sys.argv[1])
    output_path = Path(sys.argv[2])

    with zipfile.ZipFile(zip_path) as zf:
        agency = rows(zf, "agency.txt")
        feed_info = rows(zf, "feed_info.txt")
        route_rows = rows(zf, "routes.txt")
        stop_rows = rows(zf, "stops.txt")
        trip_rows = rows(zf, "trips.txt")
        stop_time_rows = rows(zf, "stop_times.txt")
        calendar_rows = rows(zf, "calendar.txt")
        exception_rows = rows(zf, "calendar_dates.txt")

    trips = {clean(row.get("trip_id")): row for row in trip_rows}
    served_routes_by_stop: dict[str, set[str]] = defaultdict(set)
    schedule = []

    for row in stop_time_rows:
        trip_id = clean(row.get("trip_id"))
        trip = trips.get(trip_id)
        if not trip:
            continue
        route_id = clean(trip.get("route_id"))
        stop_id = clean(row.get("stop_id"))
        if not route_id or not stop_id:
            continue
        served_routes_by_stop[stop_id].add(route_id)
        schedule.append([
            route_id,
            clean(trip.get("service_id")),
            trip_id,
            clean(trip.get("trip_short_name")),
            clean(trip.get("trip_headsign")),
            int(clean(trip.get("direction_id")) or 0),
            stop_id,
            seconds(clean(row.get("arrival_time"))),
            seconds(clean(row.get("departure_time"))),
            int(clean(row.get("stop_sequence")) or 0),
        ])

    route_type_order = {"2": 0, "3": 1}
    routes = sorted(
        (
            [
                clean(row.get("route_id")),
                clean(row.get("route_short_name")),
                clean(row.get("route_long_name")),
                int(clean(row.get("route_type")) or 0),
                clean(row.get("route_url")),
                clean(row.get("route_color")) or "005DAA",
                clean(row.get("route_text_color")) or "FFFFFF",
            ]
            for row in route_rows
            if clean(row.get("route_id"))
        ),
        key=lambda r: (route_type_order.get(str(r[3]), 9), r[2].lower(), r[0]),
    )

    stations = sorted(
        (
            [
                clean(row.get("stop_id")),
                clean(row.get("stop_name")),
                clean(row.get("stop_url")),
                clean(row.get("stop_timezone")),
                float(clean(row.get("stop_lat")) or 0),
                float(clean(row.get("stop_lon")) or 0),
                sorted(served_routes_by_stop.get(clean(row.get("stop_id")), set())),
            ]
            for row in stop_rows
            if clean(row.get("stop_id"))
        ),
        key=lambda s: s[1].lower(),
    )

    services = sorted(
        (
            [
                clean(row.get("service_id")),
                [
                    clean(row.get("monday")) == "1",
                    clean(row.get("tuesday")) == "1",
                    clean(row.get("wednesday")) == "1",
                    clean(row.get("thursday")) == "1",
                    clean(row.get("friday")) == "1",
                    clean(row.get("saturday")) == "1",
                    clean(row.get("sunday")) == "1",
                ],
                clean(row.get("start_date")),
                clean(row.get("end_date")),
            ]
            for row in calendar_rows
            if clean(row.get("service_id"))
        ),
        key=lambda s: s[0],
    )

    exceptions = sorted(
        (
            [
                clean(row.get("service_id")),
                clean(row.get("date")),
                int(clean(row.get("exception_type")) or 0),
            ]
            for row in exception_rows
            if clean(row.get("service_id"))
        ),
        key=lambda e: (e[1], e[0], e[2]),
    )

    payload = {
        "source": "https://content.amtrak.com/content/gtfs/GTFS.zip",
        "generatedFrom": zip_path.name,
        "agency": agency[0] if agency else {},
        "feedInfo": feed_info[0] if feed_info else {},
        "routes": routes,
        "stations": stations,
        "services": services,
        "exceptions": exceptions,
        "schedule": sorted(schedule, key=lambda s: (s[6], s[0], s[8], s[2], s[9])),
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8") as f:
        json.dump(payload, f, separators=(",", ":"))
        f.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
