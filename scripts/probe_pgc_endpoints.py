#!/usr/bin/env python3
"""
probe_pgc_endpoints.py — sanity-check the public Bilibili
PGC (番剧 / 国创) endpoints the iOS app needs before
writing the DTO.  Saves a copy of the raw JSON to
`/tmp/pgc_*.json` so the upstream schema can be diffed
against `BilibiliAPIClient.swift`'s private DTOs.

Endpoints probed (all anonymous, no WBI signing needed):

  1. `/pgc/web/timeline`           — the weekly 追番
     timeline.  Returns seven "days" (周一 … 周日), each
     with the season cards that update that day.  This
     is the only endpoint the 追番 first-pass surface
     hits; later passes may add 1–3 below.

  2. `/pgc/web/home`               — the PGC home page
     ("番剧" tab on bilibili.com).  Returns a list of
     modules (banner + 连载中 / 完结 / 资讯 / 国产 etc.).
     Probed but not yet consumed by the iOS app.

  3. `/pgc/web/index/result`       — the season index
     (按类型 / 按地区 / 按季度 / 按状态).  Probed but
     not yet consumed by the iOS app.

  4. `/pgc/view/web/season`        — single-season detail
     page (used by the in-app detail view if/when we add
     one).  Probed but not yet consumed by the iOS app.

  5. `/pgc/view/web/ep/list`       — episode list for a
     season.  Probed but not yet consumed by the iOS app.

Each call:
  - Uses an iPhone User-Agent so the upstream returns the
    mobile payload (some fields differ vs. web).
  - Sets `Referer: https://www.bilibili.com` because
    several PGC endpoints reject the request without it.
  - Prints the HTTP status, the JSON `code` field, the
    response size, and a truncated body preview.
  - Writes the full response to /tmp/pgc_<endpoint>.json
    for inspection.

Exit code 0 if every endpoint returned `code == 0`,
non-zero otherwise.  Used to catch upstream breakage in
CI before the iOS app fails with "the data couldn't be
read" at runtime.

Usage:
  python3 scripts/probe_pgc_endpoints.py            # all 5
  python3 scripts/probe_pgc_endpoints.py timeline   # one
  python3 scripts/probe_pgc_endpoints.py --dry     # skip
                                                   # network
"""

import argparse
import json
import sys
import time
import urllib.error
import urllib.request

UA = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)"
    " AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
)
HEADERS = {
    "User-Agent": UA,
    "Referer": "https://www.bilibili.com",
    "Accept": "application/json, text/plain, */*",
}

ENDPOINTS = [
    {
        "name": "timeline",
        "label": "周时间表 (番剧)",
        "url": "https://api.bilibili.com/pgc/web/timeline",
        "query": {"types": "1", "before": "6", "after": "6"},
    },
    {
        "name": "home",
        "label": "PGC home",
        "url": "https://api.bilibili.com/pgc/web/home",
        "query": {},
    },
    {
        "name": "index",
        "label": "番剧索引",
        "url": "https://api.bilibili.com/pgc/web/index/result",
        "query": {"index_type": "1", "weekday": "-1"},
    },
    {
        # Probed but not yet consumed. Uses a known
        # season_id (109700, "假面骑士ZZZ" from the
        # timeline probe) so the upstream returns a real
        # payload.
        "name": "season",
        "label": "番剧详情",
        "url": "https://api.bilibili.com/pgc/view/web/season",
        "query": {"season_id": "109700"},
    },
    {
        # Same — probed but not yet consumed.
        "name": "ep_list",
        "label": "剧集列表",
        "url": "https://api.bilibili.com/pgc/view/web/ep/list",
        "query": {"season_id": "109700"},
    },
]


def probe(endpoint, dry=False):
    qs = "&".join(f"{k}={v}" for k, v in endpoint["query"].items())
    url = endpoint["url"] + ("?" + qs if qs else "")
    out_path = f"/tmp/pgc_{endpoint['name']}.json"

    if dry:
        print(f"[dry] {endpoint['name']:10s}  {url}")
        return True

    started = time.time()
    try:
        req = urllib.request.Request(url, headers=HEADERS)
        with urllib.request.urlopen(req, timeout=10) as resp:
            status = resp.status
            body = resp.read()
    except urllib.error.HTTPError as e:
        print(f"[fail] {endpoint['name']:10s}  HTTP {e.code}  {url}")
        return False
    except Exception as e:
        print(f"[fail] {endpoint['name']:10s}  {type(e).__name__}: {e}  {url}")
        return False
    elapsed_ms = int((time.time() - started) * 1000)

    with open(out_path, "wb") as f:
        f.write(body)

    try:
        data = json.loads(body)
    except json.JSONDecodeError as e:
        print(f"[fail] {endpoint['name']:10s}  json error: {e}  {out_path}")
        return False

    code = data.get("code", "n/a")
    ok = code == 0
    tag = "ok" if ok else "BAD"
    print(
        f"[{tag:3s}] {endpoint['name']:10s}  "
        f"code={code}  HTTP={status}  "
        f"{elapsed_ms:>4d}ms  {len(body):>6d}B  "
        f"{endpoint['label']}"
    )
    # Truncate the body to a single line for log-friendliness.
    preview = body[:160].decode("utf-8", errors="replace").replace("\n", " ")
    print(f"        preview: {preview}{'…' if len(body) > 160 else ''}")
    print(f"        saved:   {out_path}")
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "target", nargs="?", default="all",
        help="endpoint name (timeline / home / index / season / ep_list) or 'all'"
    )
    ap.add_argument("--dry", action="store_true")
    args = ap.parse_args()

    targets = (
        [e for e in ENDPOINTS if e["name"] == args.target]
        if args.target != "all" else ENDPOINTS
    )
    if not targets:
        sys.exit(f"unknown endpoint: {args.target}")

    print(f"Probing {len(targets)} PGC endpoint(s)…")
    print()
    results = [probe(e, dry=args.dry) for e in targets]
    print()
    if all(results):
        print(f"All {len(targets)} endpoint(s) returned code=0.")
        sys.exit(0)
    else:
        print(f"{results.count(False)}/{len(results)} endpoint(s) failed.")
        sys.exit(1)


if __name__ == "__main__":
    main()
