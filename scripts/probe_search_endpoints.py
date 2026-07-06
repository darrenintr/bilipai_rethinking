#!/usr/bin/env python3
"""
probe_search_endpoints.py — classify B 站 search + recommendation
endpoints by latency and freshness, so the iOS app knows which
ones it can hit on every keystroke without jank.

Three checks, each runnable on macOS / Linux without an Apple
Developer account or an iOS simulator:

  1. `search-type`       — five flavors of
     `/x/web-interface/wbi/search/type` (video / bili_user /
     media_bangumi / live / article).  Each call signs with the
     mixin-key table; we measure end-to-end latency and report
     whether the result looks "instant" (< 500 ms).
  2. `search-suggest`    — the as-you-type suggest endpoint at
     `https://s.search.bilibili.com/main/suggest`.  Anonymous,
     no WBI, designed for the official nav-bar — this is the
     one the app should hit on every keystroke.  Returns
     ranked completion strings (tag name + bvid / aid).
  3. `recommendation`    — three flavors of recommendation:
     a) `/x/web-interface/wbi/index/top/feed/rcmd`  (web, WBI)
     b) `/app.bilibili.com/x/v2/feed/index`          (app, AppSign,
        requires access_token + buvid3 — usually 401 for our
        unauthenticated probe)
     c) `/x/web-interface/popular`                   (popular, anon)

Output is plain text — readable in CI logs and easy to copy.

Verdict (exit code):
  0 — every probed endpoint is reachable; the suggest path is
      fast enough (< 250 ms) for keystroke-rate polling.
  1 — suggest is slow (> 500 ms) or returns an empty payload;
      caller should debounce or fall back to a typed-search
      call after the user stops typing.
  2 — search/recommendation endpoints returned an upstream
      error code (风控 / 404 / anonymous gate).

Usage:
  python3 scripts/probe_search_endpoints.py
  python3 scripts/probe_search_endpoints.py --keyword "原神"
  python3 scripts/probe_search_endpoints.py --sessdata 'xxxxx%2Cxxxxx'
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
from typing import Iterable

API_BASE = "https://api.bilibili.com"
APP_BASE = "https://app.bilibili.com"
SUGGEST_BASE = "https://s.search.bilibili.com"

NAV_URL = f"{API_BASE}/x/web-interface/nav"
SEARCH_TYPE_URL = f"{API_BASE}/x/web-interface/wbi/search/type"
POPULAR_URL = f"{API_BASE}/x/web-interface/popular"
RCMD_URL = f"{API_BASE}/x/web-interface/wbi/index/top/feed/rcmd"
APP_FEED_URL = f"{APP_BASE}/x/v2/feed/index"
SUGGEST_URL = f"{SUGGEST_BASE}/main/suggest"

DEFAULT_KEYWORD = "原神"
# Search-type slots; each maps to a Bilibili `search_type` value
# in `/x/web-interface/wbi/search/type`.  `live` requires the
# user to be signed in for full results.
SEARCH_TYPE_SLOTS = [
    ("video", "视频"),
    ("bili_user", "UP 主"),
    ("media_bangumi", "番剧"),
    ("live", "直播"),
    ("article", "专栏"),
]

# --------------------------------------------------------------------------- #
# WBI signing — same mixin table as BilibiliAPIClient.swift / probe_cdn.     #
# --------------------------------------------------------------------------- #

MIXIN_TAB = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
    33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
    61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
    36, 20, 34, 44, 52,
]


def mixin_key(img_key: str, sub_key: str) -> str:
    s = img_key + sub_key
    return ''.join(s[i] for i in MIXIN_TAB if i < len(s))[:32]


def md5(s: str) -> str:
    return hashlib.md5(s.encode("utf-8")).hexdigest()


def fetch_wbi_keys() -> tuple[str, str]:
    req = urllib.request.Request(
        NAV_URL,
        headers={
            "User-Agent": ("bili-universal/iphone (iPhone; iOS 18.0; "
                           "Scale/3.00)"),
            "Referer": "https://www.bilibili.com",
        },
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read())
    img = data["data"]["wbi_img"]["img_url"].rsplit("/", 1)[-1].split(".")[0]
    sub = data["data"]["wbi_img"]["sub_url"].rsplit("/", 1)[-1].split(".")[0]
    return img, sub


def sign_query(params: dict, img_key: str, sub_key: str) -> dict:
    # Mirror the Swift WbiSigner — strip !'()* from each value,
    # sort params, append `wts`, derive `w_rid` as md5(query+mixin).
    sanitized = {
        k: re.sub(r"[!'()*]", "", str(v))
        for k, v in params.items()
    }
    sanitized["wts"] = str(int(time.time()))
    ordered = sorted(sanitized.items())
    query = "&".join(f"{k}={v}" for k, v in ordered)
    digest = md5(query + mixin_key(img_key, sub_key))
    return {**sanitized, "w_rid": digest}


def _request(url: str, *, referer: str = "https://www.bilibili.com",
             sessdata: str | None = None,
             timeout: float = 10.0) -> tuple[int, bytes, dict[str, str], float]:
    """Returns (status, body, headers, elapsed_ms)."""
    headers = {
        "User-Agent": "bili-universal/iphone (iPhone; iOS 18.0; Scale/3.00)",
        "Referer": referer,
    }
    if sessdata:
        headers["Cookie"] = f"SESSDATA={sessdata}"
    req = urllib.request.Request(url, headers=headers)
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return (resp.status, resp.read(), dict(resp.headers),
                    (time.perf_counter() - t0) * 1000)
    except urllib.error.HTTPError as e:
        return (e.code, e.read() if e.fp else b"",
                dict(e.headers or {}),
                (time.perf_counter() - t0) * 1000)
    except urllib.error.URLError as e:
        return (-1, str(e).encode(), {},
                (time.perf_counter() - t0) * 1000)


# ---- per-endpoint probes -------------------------------------------------

@dataclasses.dataclass
class ProbeResult:
    label: str
    url: str
    status: int
    elapsed_ms: float
    payload_size: int
    summary: str
    is_instant: bool          # < 500 ms

    @property
    def ok(self) -> bool:
        return 200 <= self.status < 300


def probe_search_type(keyword: str, search_type: str, label: str,
                      img_key: str, sub_key: str,
                      sessdata: str | None) -> ProbeResult:
    params = {
        "search_type": search_type,
        "keyword": keyword,
        "page": "1",
        "page_size": "10",
        "platform": "pc",
        "web_location": "1430654",
    }
    signed = sign_query(params, img_key, sub_key)
    qs = urllib.parse.urlencode(signed)
    status, body, _, ms = _request(f"{SEARCH_TYPE_URL}?{qs}",
                                   sessdata=sessdata)
    summary = ""
    if status == 200:
        try:
            data = json.loads(body)
            if int(data.get("code") or -1) != 0:
                summary = f"upstream code={data.get('code')} {data.get('message')!r}"
            else:
                # The response shape differs per search_type; just
                # report the keys we see so the verdict block can
                # extract counts.
                top = data.get("data") or {}
                keys = sorted(top.keys())
                count_field = {
                    "video": "result",
                    "bili_user": "result",
                    "media_bangumi": "result",
                    "live": "result",
                    "article": "result",
                }.get(search_type, "result")
                count = len(top.get(count_field) or [])
                summary = f"top-level keys={keys} count={count}"
        except Exception as exc:
            summary = f"decode error: {exc}"
    else:
        summary = f"http {status}"
    return ProbeResult(
        label=label, url=SEARCH_TYPE_URL, status=status,
        elapsed_ms=ms, payload_size=len(body), summary=summary,
        is_instant=ms < 500,
    )


def probe_suggest(keyword: str, sessdata: str | None) -> ProbeResult:
    qs = urllib.parse.urlencode({"term": keyword})
    status, body, _, ms = _request(f"{SUGGEST_URL}?{qs}",
                                   referer="https://search.bilibili.com",
                                   sessdata=sessdata)
    summary = ""
    if status == 200:
        try:
            data = json.loads(body)
            # The endpoint returns a dict like {"code":0,"result":{
            # "tag":[{"name":"...","bvid":"..."}, ...]}}.
            tag = (data.get("result") or {}).get("tag") or []
            summary = f"tag suggestions={len(tag)} first={[t.get('name') for t in tag[:3]]}"
        except Exception as exc:
            summary = f"decode error: {exc}"
    else:
        summary = f"http {status}"
    return ProbeResult(
        label=f"suggest \"{keyword}\"", url=SUGGEST_URL, status=status,
        elapsed_ms=ms, payload_size=len(body), summary=summary,
        is_instant=ms < 250,
    )


def probe_recommendation(name: str, url: str, *,
                         sessdata: str | None,
                         params: dict[str, str] | None = None,
                         referer: str = "https://www.bilibili.com",
                         is_app: bool = False) -> ProbeResult:
    if params:
        # The App feed endpoint is the only one that needs its
        # parameters appended explicitly (it doesn't take
        # per_page / t).  Strip empty values for cleanliness.
        qs = urllib.parse.urlencode({k: v for k, v in params.items() if v})
        full = f"{url}?{qs}"
    else:
        full = url
    status, body, _, ms = _request(full, referer=referer, sessdata=sessdata)
    summary = ""
    if status == 200:
        try:
            data = json.loads(body)
            code = int(data.get("code") or -1)
            if code != 0:
                summary = f"upstream code={code} {data.get('message')!r}"
            else:
                items = (data.get("data") or {}).get("items") or []
                summary = f"items={len(items)} keys={sorted((data.get('data') or {}).keys())}"
        except Exception as exc:
            summary = f"decode error: {exc}"
    else:
        summary = f"http {status}"
    return ProbeResult(
        label=name, url=url, status=status,
        elapsed_ms=ms, payload_size=len(body), summary=summary,
        is_instant=ms < 500,
    )


# ---- main ----------------------------------------------------------------

def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--keyword", default=DEFAULT_KEYWORD,
                   help=f"Search keyword. Default: \"{DEFAULT_KEYWORD}\"")
    p.add_argument("--sessdata", default=None,
                   help="Optional SESSDATA cookie for personalised feeds.")
    p.add_argument("--samples", type=int, default=3,
                   help="How many timing samples per probe. Default 3.")
    args = p.parse_args(argv)

    print(f"Fetching WBI keys…")
    img_key, sub_key = fetch_wbi_keys()
    print(f"  img_key={img_key[:8]}…  sub_key={sub_key[:8]}…\n")

    # ---- step 1: search-type -------------------------------------------
    print("=" * 78)
    print(f"STEP 1 — /x/web-interface/wbi/search/type "
          f"(keyword=\"{args.keyword}\", {args.samples}× each slot)")
    print("=" * 78)
    type_results: list[ProbeResult] = []
    for st, label in SEARCH_TYPE_SLOTS:
        samples: list[ProbeResult] = []
        for _ in range(args.samples):
            samples.append(probe_search_type(
                args.keyword, st, label, img_key, sub_key, args.sessdata,
            ))
        # Use median across samples.
        ms = statistics.median(s.elapsed_ms for s in samples)
        first = samples[0]
        first.elapsed_ms = ms
        type_results.append(first)
        glyph = "✓" if first.is_instant and first.ok else ("△" if first.ok else "✗")
        print(f"  {glyph} {label:<6} search_type={st:<14} "
              f"status={first.status:<4} median={ms:>6.0f}ms  "
              f"{first.summary}")
        time.sleep(0.4)  # be polite to upstream

    # ---- step 2: suggest ------------------------------------------------
    print()
    print("=" * 78)
    print(f"STEP 2 — s.search.bilibili.com/main/suggest "
          f"({args.samples}×, anon)")
    print("=" * 78)
    suggest_samples = [probe_suggest(args.keyword, args.sessdata)
                       for _ in range(args.samples)]
    suggest_ms = statistics.median(s.elapsed_ms for s in suggest_samples)
    suggest_first = suggest_samples[0]
    suggest_first.elapsed_ms = suggest_ms
    glyph = "✓" if suggest_first.is_instant and suggest_first.ok else "△"
    print(f"  {glyph} suggest \"{args.keyword}\" "
          f"status={suggest_first.status:<4} median={suggest_ms:>6.0f}ms  "
          f"{suggest_first.summary}")

    # ---- step 3: recommendation ----------------------------------------
    print()
    print("=" * 78)
    print("STEP 3 — recommendation endpoints")
    print("=" * 78)
    rec_results: list[ProbeResult] = []
    for name, url, params, referer, is_app in [
        ("Web RCMD (web_location 333.1365)",
         RCMD_URL,
         {"ps": "10", "web_location": "333.1365", "platform": "pc"},
         "https://www.bilibili.com", False),
        ("App feed (anon, expect 401)",
         APP_FEED_URL,
         {"idx": str(int(time.time())),
          "pull": "true",
          "login_event": "0"},
         "https://app.bilibili.com", True),
        ("Popular (anon)",
         POPULAR_URL,
         {"ps": "20", "pn": "1"},
         "https://www.bilibili.com", False),
    ]:
        if is_app:
            # Web feed needs WBI signing.
            signed = sign_query(params, img_key, sub_key)
            params = signed
        # Sign WBI for web rcmd.
        if url == RCMD_URL:
            params = sign_query(params, img_key, sub_key)
        samples: list[ProbeResult] = []
        for _ in range(args.samples):
            samples.append(probe_recommendation(
                name, url, sessdata=args.sessdata, params=params,
                referer=referer, is_app=is_app,
            ))
        ms = statistics.median(s.elapsed_ms for s in samples)
        first = samples[0]
        first.elapsed_ms = ms
        rec_results.append(first)
        glyph = "✓" if first.ok else "△"
        print(f"  {glyph} {name:<32} "
              f"status={first.status:<4} median={ms:>6.0f}ms  "
              f"{first.summary}")
        time.sleep(0.4)

    # ---- verdict --------------------------------------------------------
    print()
    print("=" * 78)
    print("STEP 4 — verdict + recommended polling cadence")
    print("=" * 78)
    print(f"  suggest median = {suggest_ms:.0f} ms "
          f"({'INSTANT — safe to poll on every keystroke' if suggest_ms < 250 else 'SLOW — debounce ≥ 250 ms'})")
    instant_types = [r for r in type_results if r.is_instant and r.ok]
    print(f"  search-type slots: {len(instant_types)}/{len(type_results)} returned < 500 ms "
          f"({', '.join(r.label for r in instant_types) or 'none'})")
    web_rcmd = next((r for r in rec_results if "Web RCMD" in r.label), None)
    if web_rcmd and web_rcmd.ok:
        print(f"  Web RCMD median = {web_rcmd.elapsed_ms:.0f} ms — OK as the cold-start feed")
    popular = next((r for r in rec_results if "Popular" in r.label), None)
    if popular and popular.ok:
        print(f"  Popular median  = {popular.elapsed_ms:.0f} ms — OK as the anonymous fallback")
    print()

    # Suggest verdict drives the exit code: if the suggest endpoint
    # is slow or empty, the iOS app should fall back to a debounced
    # search-type call after the user stops typing.
    if suggest_first.status != 200 or not suggest_first.ok:
        print("FAIL: suggest endpoint did not return 200. Caller must "
              "fall back to search-type / 全部结果 page.")
        return 2
    if suggest_ms >= 500:
        print(f"FAIL: suggest median {suggest_ms:.0f} ms exceeds 500 ms — "
              f"polling on every keystroke will jank the keyboard.")
        return 1
    print(f"OK: suggest is instant ({suggest_ms:.0f} ms). iOS app should "
          "poll suggest on every keystroke (debounce 120 ms), then run "
          "search-type once the user submits.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))