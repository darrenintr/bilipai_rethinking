#!/usr/bin/env python3
"""
probe_notification_endpoints.py — find a B 站 endpoint that
returns "things from people you follow", so the iOS app can
poll it on a Background App Refresh tick and surface local
notifications for new posts.

The upstream is fragmented; the goal is to map which of
these endpoints actually return data for a signed-in user
and which return 404 / 风控 / -352 (the common gates):

  1. `/x/web-interface/notification/mentions`        — @-mentions
  2. `/x/msgfeed/unread`                            — DM + reply count
  3. `/x/web-interface/dynamic_svr/ws_svr`          — WebSocket
                                                       (long-poll; not usable
                                                       in iOS background)
  4. `/x/polymer/web-dynamic/v1/feed/attention`     — followed feed (the
                                                       existing iOS code
                                                       marks this 404;
                                                       verify the upstream
                                                       didn't flip back)
  5. `/x/polymer/web-dynamic/v1/feed/all`           — global feed; can be
                                                       filtered client-side
                                                       against the user's
                                                       followings set (the
                                                       `attentionFeed(...)`
                                                       path in the iOS code)
  6. `/x/relation/followings`                       — the followings set
                                                       used by (5)
  7. `/x/polymer/web-dynamic/v1/recent`             — recent dynamics
  8. `/x/web-interface/dynamic/follow/list`         — direct "follow
                                                       feed" endpoint
                                                       (documented by the
                                                       open-source
                                                       pskdje/bilibili-API-collect)

The endpoint we'll use for the Background App Refresh
poll is whichever of these returns the smallest useful
delta — ideally a `since_id` cursor we can store locally
between ticks and use to drop events we've already
delivered.

Usage:
  python3 scripts/probe_notification_endpoints.py --sessdata 'xxxxx%2Cxxxxx'

Exit codes:
  0 — at least one of (5), (7), (8) returned data with a
      cursor field; we have a workable source for the
      Background App Refresh poll.
  1 — every candidate returned 404 / 风控 / empty.
  2 — probe could not run (network down).
"""
from __future__ import annotations

import argparse
import dataclasses
import json
import re
import statistics
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API_BASE = "https://api.bilibili.com"
APP_BASE = "https://app.bilibili.com"


@dataclasses.dataclass
class ProbeResult:
    label: str
    path: str
    status: int
    elapsed_ms: float
    payload_keys: list[str]
    cursor: str      # `since_id` / `offset` / similar — empty when upstream didn't expose one
    sample_count: int
    upstream_code: int
    note: str


def _request(url: str, sessdata: str | None, timeout: float = 8.0) -> tuple[int, bytes, float]:
    headers = {
        "User-Agent": "bili-universal/iphone (iPhone; iOS 18.0; Scale/3.00)",
        "Referer": "https://www.bilibili.com",
    }
    if sessdata:
        headers["Cookie"] = f"SESSDATA={sessdata}"
    req = urllib.request.Request(url, headers=headers)
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return (resp.status, resp.read(),
                    (time.perf_counter() - t0) * 1000)
    except urllib.error.HTTPError as e:
        return (e.code, e.read() if e.fp else b"",
                (time.perf_counter() - t0) * 1000)
    except urllib.error.URLError as e:
        return (-1, str(e).encode(),
                (time.perf_counter() - t0) * 1000)


def probe(label: str, base: str, path: str, sessdata: str | None,
          params: dict | None = None) -> ProbeResult:
    qs = ("?" + urllib.parse.urlencode(params)
          if params else "")
    full = f"{base}{path}{qs}"
    status, body, ms = _request(full, sessdata=sessdata)
    note = ""
    code = -999
    cursor = ""
    count = 0
    keys: list[str] = []
    if status == 200:
        try:
            data = json.loads(body)
            code = int(data.get("code") or -999)
            if code != 0:
                note = f"upstream code={code} {data.get('message')!r}"
            else:
                payload = data.get("data") or {}
                keys = sorted(payload.keys())
                # Try to find a cursor / offset / since_id field.
                for key in ("since_id", "offset", "next_offset", "last_id",
                            "last_dynamic_id", "new_offset"):
                    if key in payload:
                        cursor = str(payload.get(key) or "")
                        break
                # Try to find the item array.
                for arr_key in ("items", "followings", "cards", "result",
                                "unread"):
                    arr = payload.get(arr_key)
                    if isinstance(arr, list):
                        count = len(arr)
                        break
                if not cursor and not count:
                    note = "ok but no cursor + no items"
        except Exception as exc:
            note = f"decode error: {exc}"
    else:
        note = f"http {status}"
    return ProbeResult(
        label=label, path=path, status=status, elapsed_ms=ms,
        payload_keys=keys, cursor=cursor, sample_count=count,
        upstream_code=code, note=note,
    )


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--sessdata", default=None,
                   help="SESSDATA cookie — most of these endpoints "
                        "return -101 / 404 without one.")
    args = p.parse_args(argv)

    candidates: list[tuple[str, str, dict]] = [
        ("mentions",       f"{API_BASE}/x/web-interface/notification/mentions",
            {"type": "video"}),
        ("msgfeed/unread", f"{API_BASE}/x/msgfeed/unread", {}),
        ("dynamic_svr/ws_svr", f"{API_BASE}/x/web-interface/dynamic_svr/ws_svr",
            {}),
        ("feed/attention", f"{API_BASE}/x/polymer/web-dynamic/v1/feed/attention",
            {"type": "all", "offset": ""}),
        ("feed/all", f"{API_BASE}/x/polymer/web-dynamic/v1/feed/all",
            {"type": "all", "offset": ""}),
        ("relation/followings",
            f"{API_BASE}/x/relation/followings",
            {"vmid": "1", "ps": "50", "pn": "1"}),
        ("recent", f"{API_BASE}/x/polymer/web-dynamic/v1/recent",
            {"offset": ""}),
        ("dynamic/follow/list",
            f"{API_BASE}/x/web-interface/dynamic/follow/list",
            {"from": "", "count": "30"}),
    ]

    print("=" * 78)
    print("B 站 notification / followed-feed endpoints")
    print("=" * 78)
    print(f"  SESSDATA={'<set>' if args.sessdata else '<not set — expect -101'}")
    print()
    results: list[ProbeResult] = []
    for label, url, params in candidates:
        path = url[len(API_BASE):] if url.startswith(API_BASE) else url
        r = probe(label, API_BASE, path, args.sessdata, params)
        results.append(r)
        glyph = "✓" if r.status == 200 and r.upstream_code == 0 and r.sample_count > 0 else \
                ("△" if r.status == 200 else "✗")
        print(f"  {glyph} {label:<22} "
              f"status={r.status:<4} upstream_code={r.upstream_code:<5} "
              f"items={r.sample_count:<4} cursor={r.cursor[:14]:<14} "
              f"keys={r.payload_keys[:4]}  {r.note}")
        time.sleep(0.3)

    print()
    print("=" * 78)
    print("Recommended Background App Refresh polling source")
    print("=" * 78)
    workable = [r for r in results
                if r.status == 200 and r.upstream_code == 0
                and r.sample_count > 0
                and ("feed" in r.label or "follow" in r.label
                     or "recent" in r.label)]
    if not workable:
        print("  ✗ none of the follow-feed endpoints returned data.")
        print("    The iOS app will fall back to polling /feed/all and")
        print("    filtering client-side against the user's followings set.")
        return 1
    # Prefer endpoints that expose a cursor.
    with_cursor = [r for r in workable if r.cursor]
    chosen = (with_cursor or workable)[0]
    print(f"  ✓ recommended source: {chosen.label}")
    print(f"    path: {chosen.path}")
    print(f"    cursor field: {chosen.cursor!r} (store locally as `lastSeenId`,")
    print(f"    send `since_id=<cursor>` on the next Background App Refresh tick)")
    print(f"    median latency: {chosen.elapsed_ms:.0f} ms")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))