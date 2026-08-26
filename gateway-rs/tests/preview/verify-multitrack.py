#!/usr/bin/env python3
"""Verifica progreso real de los cuatro Tracks mediante la API del supervisor."""

import json
import sys
import time
import urllib.request


SNAPSHOT_URL = "http://127.0.0.1:19080/api/v1/snapshot"
OBSERVATION_SECONDS = 5


def snapshot():
    with urllib.request.urlopen(SNAPSHOT_URL, timeout=3) as response:
        if response.status != 200:
            raise RuntimeError(f"snapshot devolvió HTTP {response.status}")
        return json.load(response)


def tracks_by_id(value):
    return {track["track"]: track for track in value.get("tracks", [])}


def main():
    before = snapshot()
    time.sleep(OBSERVATION_SECONDS)
    after = snapshot()
    before_tracks = tracks_by_id(before)
    after_tracks = tracks_by_id(after)
    active_sources = [source for source in after.get("sources", []) if source.get("status") == "active"]
    failures = []

    for track_id in range(4):
        current = after_tracks.get(track_id)
        previous = before_tracks.get(track_id)
        if current is None or previous is None:
            failures.append(f"Track {track_id} no aparece en el snapshot")
            continue
        if current.get("status") != "active":
            failures.append(f"Track {track_id} no está activo: {current.get('status')}")
        if current.get("objects", 0) <= previous.get("objects", 0):
            failures.append(f"Track {track_id} no progresó durante {OBSERVATION_SECONDS}s")

    if len(active_sources) < 3:
        failures.append("se esperaban al menos tres sesiones SRT activas")
    if not after.get("moq", {}).get("connected"):
        failures.append("el publisher MoQT no está conectado")
    if after.get("scheduler", {}).get("queued_objects", 0) > 256:
        failures.append("la cola del scheduler superó su límite configurado")

    result = {
        "observation_seconds": OBSERVATION_SECONDS,
        "active_sources": len(active_sources),
        "tracks": {
            str(track_id): {
                "codec": after_tracks.get(track_id, {}).get("codec"),
                "objects_delta": after_tracks.get(track_id, {}).get("objects", 0)
                - before_tracks.get(track_id, {}).get("objects", 0),
                "status": after_tracks.get(track_id, {}).get("status"),
            }
            for track_id in range(4)
        },
        "scheduler": after.get("scheduler"),
        "moq_connected": after.get("moq", {}).get("connected"),
        "failures": failures,
    }
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 1 if failures else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(json.dumps({"failures": [str(error)]}, ensure_ascii=False), file=sys.stderr)
        sys.exit(2)
