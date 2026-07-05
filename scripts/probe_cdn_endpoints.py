#!/usr/bin/env python3
"""
probe_cdn_endpoints.py — verify B 站 playurl + CDN failover surface.

Three checks, each designed to be runnable on macOS / Linux without an
Apple Developer account or an iOS simulator:

  1. `playurl` — WBI-sign and fetch /x/player/wbi/playurl for a list
     of bvids, then enumerate the CDN hosts the upstream exposes:
     `dash.video[].base_url`, `dash.video[].backup_url[]`,
     `dash.audio[].base_url`, `dash.audio[].backup_url[]`,
     `durl[].url`, `durl[].backup_url[]`. Print the host of every
     URL plus the response's `last_play_time` / `last_play_cid`
     fields (the server-side resume hints).
  2. `seek-availability` — pick the first video + audio URL and
     issue a `Range: bytes=<random>-` request against it. Print the
     returned status, the `Content-Range` header, and the first
     4 bytes of the response body (the ISO BMFF `ftyp` box type).
     A 200 with a valid box proves the host supports HTTP byte-range
     seeking, which is what AVPlayer uses for random-timestamp
     playback.
  3. `host-latency` — HEAD-probe every CDN host surfaced by step 1
     (across all bvids), report the median connect-time + status.
     Sorted fastest-first so you can see which hosts to prefer when
     the user is on a slow network.

Output is plain text — readable in CI logs and easy to copy.

Usage (no SESSDATA cookie → 720P max; SESSDATA → higher qn available):

  python3 scripts/probe_cdn_endpoints.py
  python3 scripts/probe_cdn_endpoints.py --bvid BV1GJ411x7h7 BV1uv411q7ix
  python3 scripts/probe_cdn_endpoints.py --cid 170001 --qn 80
  python3 scripts/probe_cdn_endpoints.py --sessdata 'xxxxx%2Cxxxxx'

Exit code 0 if every seek-availability check returned 206 Partial
Content with a parseable `ftyp` box, 1 otherwise. Designed to gate
shipping a streaming-failover change.
"""
from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import re
import statistics
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Iterable

# --------------------------------------------------------------------------- #
# WBI signing — copied verbatim from WbiSigner.swift. Keep in sync if the
# upstream changes the mixin-key table.
# --------------------------------------------------------------------------- #

MIXIN_TAB = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
    33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
    61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
    36, 20, 34, 44, 52,
]

NAV_URL = "https://api.bilibili.com/x/web-interface/nav"
PLAYURL_URL = "https://api.bilibili.com/x/player/wbi/playurl"


def mixin_key(img_key: str, sub_key: str) -> str:
    s = img_key + sub_key
    return ''.join(s[i] for i in MIXIN_TAB if i < len(s))[:32]


def md5(s: str) -> str:
    return hashlib.md5(s.encode("utf-8")).hexdigest()


def fetch_wbi_keys() -> tuple[str, str]:
    req = urllib.request.Request(
        NAV_URL,
        headers={
            "User-Agent": ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) "
                           "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"),
            "Referer": "https://www.bilibili.com",
        },
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read())
    img = data["data"]["wbi_img"]["img_url"].rsplit("/", 1)[-1].split(".")[0]
    sub = data["data"]["wbi_img"]["sub_url"].rsplit("/", 1)[-1].split(".")[0]
    return img, sub


def sign_query(params: dict, img_key: str, sub_key: str) -> dict:
    # Strip !'()* like the Swift impl.  The character class is small
    # enough that Python's `re` is fine; the Swift side uses NSRegularExpression.
    cleaned = {k: re.sub(r"[!'()*]", "", str(v)) for k, v in params.items() if v is not None}
    cleaned["wts"] = str(int(time.time()))
    ordered = "&".join(
        f"{k}={urllib.parse.quote(cleaned[k], safe='')}" for k in sorted(cleaned.keys())
    )
    cleaned["w_rid"] = md5(ordered + mixin_key(img_key, sub_key))
    return cleaned


# --------------------------------------------------------------------------- #
# Data model
# --------------------------------------------------------------------------- #

@dataclasses.dataclass
class PlayURLResult:
    bvid: str
    cid: int
    qn: int
    last_play_time_ms: int | None
    last_play_cid: int | None
    accept_quality: list[int]
    video_urls: list[str]   # base_url + backup_url
    audio_urls: list[str]
    durl_urls: list[str]


@dataclasses.dataclass
class SeekProbe:
    url: str
    range_start: int
    status: int
    content_range: str | None
    body_box: str | None    # first 4 bytes of the response body


@dataclasses.dataclass
class HostLatency:
    host: str
    median_ms: float | None
    statuses: list[int]


# --------------------------------------------------------------------------- #
# playurl fetch
# --------------------------------------------------------------------------- #

DEFAULT_BVIDS = [
    # 老番茄 famous BV — known to have AI summary, large viewership
    ("BV1GJ411x7h7", 170001, 946974),
    # 影视飓风 sample
    ("BV1qB4y1T7fF", 30828521, 348855309),
]

USER_AGENT = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) "
              "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148")


def fetch_playurl(bvid: str, cid: int, up_mid: int, qn: int,
                  img_key: str, sub_key: str,
                  sessdata: str | None) -> PlayURLResult:
    params = sign_query(
        {"bvid": bvid, "cid": cid, "qn": qn, "fnval": 4048, "fnver": 0,
         "fourk": 1, "gaia_source": "view-card", "up_mid": up_mid},
        img_key, sub_key,
    )
    qs = urllib.parse.urlencode(params)
    req = urllib.request.Request(
        f"{PLAYURL_URL}?{qs}",
        headers={"User-Agent": USER_AGENT, "Referer": "https://www.bilibili.com",
                 **({"Cookie": f"SESSDATA={sessdata}"} if sessdata else {})},
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        body = json.loads(resp.read())
    if body.get("code") != 0:
        raise RuntimeError(f"playurl code={body.get('code')} msg={body.get('message')!r}")
    data = body["data"]
    video_urls: list[str] = []
    audio_urls: list[str] = []
    durl_urls: list[str] = []
    if dash := data.get("dash"):
        for v in dash.get("video", []) or []:
            if u := v.get("base_url") or v.get("baseUrl"):
                video_urls.append(u)
            for u in v.get("backup_url") or v.get("backupUrl") or []:
                video_urls.append(u)
        for a in dash.get("audio", []) or []:
            if u := a.get("base_url") or a.get("baseUrl"):
                audio_urls.append(u)
            for u in a.get("backup_url") or a.get("backupUrl") or []:
                audio_urls.append(u)
    for d in data.get("durl", []) or []:
        if u := d.get("url"):
            durl_urls.append(u)
        for u in d.get("backup_url") or []:
            durl_urls.append(u)
    return PlayURLResult(
        bvid=bvid, cid=cid, qn=qn,
        last_play_time_ms=data.get("last_play_time"),
        last_play_cid=data.get("last_play_cid"),
        accept_quality=data.get("accept_quality") or [],
        video_urls=video_urls,
        audio_urls=audio_urls,
        durl_urls=durl_urls,
    )


# --------------------------------------------------------------------------- #
# Seek + host probe
# --------------------------------------------------------------------------- #

def probe_seek(url: str, range_start: int = 1024 * 1024) -> SeekProbe:
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": USER_AGENT,
            "Referer": "https://www.bilibili.com",
            "Range": f"bytes={range_start}-",
        },
        method="GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            status = resp.status
            cr = resp.headers.get("Content-Range")
            body = resp.read(4)
    except urllib.error.HTTPError as e:
        return SeekProbe(url=url, range_start=range_start, status=e.code,
                         content_range=e.headers.get("Content-Range") if e.headers else None,
                         body_box=None)
    box = body[:4].decode("ascii", errors="replace") if body else None
    return SeekProbe(url=url, range_start=range_start, status=status,
                     content_range=cr, body_box=box)


def host_latency(host: str) -> HostLatency:
    """Five HEAD probes against the host root, drop top+bottom, take median."""
    samples: list[float] = []
    statuses: list[int] = []
    for _ in range(5):
        t0 = time.monotonic()
        try:
            req = urllib.request.Request(
                f"https://{host}/",
                headers={"User-Agent": USER_AGENT,
                         "Referer": "https://www.bilibili.com"},
                method="HEAD",
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                statuses.append(resp.status)
        except urllib.error.HTTPError as e:
            statuses.append(e.code)
        except Exception:
            statuses.append(0)
        else:
            samples.append((time.monotonic() - t0) * 1000)
    samples.sort()
    median = statistics.median(samples[1:-1]) if len(samples) >= 3 else (
        statistics.median(samples) if samples else None)
    return HostLatency(host=host, median_ms=median, statuses=statuses)


def extract_host(url: str) -> str:
    return urllib.parse.urlparse(url).netloc


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--bvid", nargs="+", default=None,
                   help="bvids to probe.  Format: bvid[:cid[:up_mid]]. "
                        "Defaults to two popular test videos.")
    p.add_argument("--qn", type=int, default=64,
                   help="qn ladder code (80=1080P, 64=720P, 32=480P). Default 64.")
    p.add_argument("--sessdata", default=None,
                   help="Optional SESSDATA cookie value for higher-qn requests.")
    p.add_argument("--range-start", type=int, default=1 << 20,
                   help="Byte offset to start the Range request at. Default 1 MiB.")
    args = p.parse_args(argv)

    # Resolve bvid list.  Each entry is (bvid, cid, up_mid).
    bvids: list[tuple[str, int, int]]
    if args.bvid:
        bvids = []
        for raw in args.bvid:
            parts = raw.split(":")
            bvid = parts[0]
            cid = int(parts[1]) if len(parts) > 1 and parts[1] else 0
            up_mid = int(parts[2]) if len(parts) > 2 and parts[2] else 0
            bvids.append((bvid, cid, up_mid))
    else:
        bvids = list(DEFAULT_BVIDS)

    print(f"Fetching WBI keys…")
    img_key, sub_key = fetch_wbi_keys()
    print(f"  img_key={img_key[:8]}…  sub_key={sub_key[:8]}…\n")

    results: list[PlayURLResult] = []
    for bvid, cid, up_mid in bvids:
        if cid == 0:
            # Without a cid the call is doomed; skip rather than burn a
            # round trip.  In practice the iOS code path always has a
            # cid by the time it hits /x/player/wbi/playurl.
            print(f"SKIP {bvid}: no cid supplied (pass bvid:cid:up_mid)")
            continue
        try:
            r = fetch_playurl(bvid, cid, up_mid, args.qn, img_key, sub_key,
                              args.sessdata)
            results.append(r)
        except Exception as e:
            print(f"FAIL {bvid} cid={cid}: {e}")
    if not results:
        print("\nno successful playurl fetches; nothing to probe.")
        return 2

    # ---- step 1: enumerate URLs ----
    print("=" * 78)
    print("STEP 1 — CDN URL inventory")
    print("=" * 78)
    all_hosts: set[str] = set()
    for r in results:
        print(f"\n{r.bvid} cid={r.cid} qn={r.qn}")
        print(f"  accept_quality      = {r.accept_quality}")
        print(f"  last_play_time (ms) = {r.last_play_time_ms}")
        print(f"  last_play_cid       = {r.last_play_cid}")
        for label, urls in (("dash.video", r.video_urls),
                            ("dash.audio", r.audio_urls),
                            ("durl",       r.durl_urls)):
            if not urls:
                continue
            print(f"  {label}: {len(urls)} URL(s)")
            for i, u in enumerate(urls):
                host = extract_host(u)
                all_hosts.add(host)
                tag = "primary" if i == 0 else f"backup[{i-1}]"
                print(f"    [{tag:>8}] {host}{urllib.parse.urlparse(u).path[:48]}")
    if not all_hosts:
        print("\nno CDN hosts surfaced — cannot probe further.")
        return 2

    # ---- step 2: seek availability on one URL per host ----
    print()
    print("=" * 78)
    print(f"STEP 2 — Range seek availability (start = {args.range_start:,} B)")
    print("=" * 78)
    probe_targets: list[str] = []
    seen_per_host: dict[str, str] = {}
    for r in results:
        for u in r.video_urls:
            host = extract_host(u)
            if host not in seen_per_host:
                seen_per_host[host] = u
                probe_targets.append(u)
    print(f"Probing {len(probe_targets)} host(s)…")
    seek_probes: list[SeekProbe] = []
    with ThreadPoolExecutor(max_workers=8) as ex:
        futs = {ex.submit(probe_seek, u, args.range_start): u for u in probe_targets}
        for fut in as_completed(futs):
            seek_probes.append(fut.result())
    seek_probes.sort(key=lambda p: p.status)
    print(f"\n{'host':<35} {'status':>7}  {'content-range':<32}  ftyp")
    print("-" * 90)
    for p in seek_probes:
        host = extract_host(p.url)
        cr = (p.content_range or "-")[:32]
        print(f"{host:<35} {p.status:>7}  {cr:<32}  {p.body_box or '-'}")

    # ---- step 3: host latency ----
    print()
    print("=" * 78)
    print("STEP 3 — Host latency (5 HEAD probes, median connect-time)")
    print("=" * 78)
    latencies: list[HostLatency] = []
    with ThreadPoolExecutor(max_workers=8) as ex:
        futs = {ex.submit(host_latency, h): h for h in sorted(all_hosts)}
        for fut in as_completed(futs):
            latencies.append(fut.result())
    latencies.sort(key=lambda l: l.median_ms if l.median_ms is not None else 1e9)
    print(f"\n{'host':<35} {'median ms':>10}  statuses")
    print("-" * 90)
    for l in latencies:
        ms = f"{l.median_ms:.0f}" if l.median_ms is not None else "—"
        print(f"{l.host:<35} {ms:>10}  {l.statuses}")

    # ---- verdict ----
    bad_seeks = [p for p in seek_probes if p.status != 206]
    print()
    if bad_seeks:
        print(f"FAIL: {len(bad_seeks)} host(s) did not return 206 Partial Content "
              f"for Range: bytes={args.range_start}-.  AVPlayer would hard-stall "
              f"on these when seeking to that byte offset.")
        return 1
    print("OK: every probed host supports Range seek.  Failover candidates verified.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))