#!/usr/bin/env python3
"""
Probe Bilibili subtitle endpoints and print the required arguments.

This is intentionally small and dependency-free so it can run from a
fresh checkout:

  python3 scripts/probe_subtitle_endpoints.py --bvid BV1GJ411x7h7 --cid 946974
  python3 scripts/probe_subtitle_endpoints.py --aid 170001 --cid 946974 --sessdata '...'

The script checks the known player subtitle surfaces:

  * /x/player/wbi/v2     args: cid, bvid or aid, wts, w_rid
  * /x/player/v2         args: cid, bvid or aid

For each successful response it prints available subtitle tracks and, unless
--no-fetch is passed, fetches the first track's subtitle_url to verify the body
shape ({body:[{from,to,content}]} or LRC text).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any

API_BASE = "https://api.bilibili.com"
NAV_URL = f"{API_BASE}/x/web-interface/nav"
USER_AGENT = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
)

MIXIN_TAB = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
    33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
    61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
    36, 20, 34, 44, 52,
]


@dataclass(frozen=True)
class Endpoint:
    name: str
    path: str
    wbi: bool


ENDPOINTS = [
    Endpoint("player-wbi-v2", "/x/player/wbi/v2", True),
    Endpoint("player-v2", "/x/player/v2", False),
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Probe Bilibili subtitle endpoints and argument shapes."
    )
    identity = parser.add_mutually_exclusive_group(required=True)
    identity.add_argument("--bvid", help="Bilibili BV id, e.g. BV1GJ411x7h7")
    identity.add_argument("--aid", type=int, help="Bilibili numeric aid")
    parser.add_argument("--cid", type=int, required=True, help="Bilibili page cid")
    parser.add_argument("--sessdata", help="Optional SESSDATA cookie for gated tracks")
    parser.add_argument("--no-fetch", action="store_true", help="Do not fetch subtitle_url bodies")
    return parser.parse_args()


def mixin_key(img_key: str, sub_key: str) -> str:
    source = img_key + sub_key
    return "".join(source[i] for i in MIXIN_TAB if i < len(source))[:32]


def md5(text: str) -> str:
    return hashlib.md5(text.encode("utf-8")).hexdigest()


def fetch_json(url: str, sessdata: str | None = None) -> dict[str, Any]:
    headers = {
        "User-Agent": USER_AGENT,
        "Referer": "https://www.bilibili.com",
    }
    if sessdata:
        headers["Cookie"] = f"SESSDATA={sessdata}"
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=15) as response:
        return json.loads(response.read())


def fetch_text(url: str, sessdata: str | None = None) -> str:
    headers = {
        "User-Agent": USER_AGENT,
        "Referer": "https://www.bilibili.com",
    }
    if sessdata:
        headers["Cookie"] = f"SESSDATA={sessdata}"
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=15) as response:
        return response.read().decode("utf-8", errors="replace")


def fetch_wbi_keys(sessdata: str | None) -> tuple[str, str]:
    body = fetch_json(NAV_URL, sessdata)
    data = body["data"]["wbi_img"]
    img_key = data["img_url"].rsplit("/", 1)[-1].split(".", 1)[0]
    sub_key = data["sub_url"].rsplit("/", 1)[-1].split(".", 1)[0]
    return img_key, sub_key


def sign_query(params: dict[str, str], img_key: str, sub_key: str) -> dict[str, str]:
    cleaned = {
        key: re.sub(r"[!'()*]", "", value)
        for key, value in params.items()
        if value
    }
    cleaned["wts"] = str(int(time.time()))
    ordered = "&".join(
        f"{key}={urllib.parse.quote(cleaned[key], safe='')}"
        for key in sorted(cleaned)
    )
    cleaned["w_rid"] = md5(ordered + mixin_key(img_key, sub_key))
    return cleaned


def endpoint_url(endpoint: Endpoint, args: argparse.Namespace, keys: tuple[str, str] | None) -> str:
    params: dict[str, str] = {"cid": str(args.cid)}
    if args.bvid:
        params["bvid"] = args.bvid
    if args.aid:
        params["aid"] = str(args.aid)
    if endpoint.wbi:
        if keys is None:
            raise RuntimeError("WBI endpoint requires nav keys")
        params = sign_query(params, keys[0], keys[1])
    return f"{API_BASE}{endpoint.path}?{urllib.parse.urlencode(params)}"


def subtitle_tracks(body: dict[str, Any]) -> list[dict[str, Any]]:
    data = body.get("data") or {}
    subtitle = data.get("subtitle") or {}
    tracks = subtitle.get("subtitles") or []
    return [track for track in tracks if isinstance(track, dict)]


def absolute_url(raw: str) -> str:
    if raw.startswith("//"):
        return f"https:{raw}"
    return raw


def describe_body(text: str) -> str:
    stripped = text.strip()
    if not stripped:
        return "empty"
    if stripped.startswith("{"):
        try:
            body = json.loads(stripped)
            entries = body.get("body") or []
            return f"json body entries={len(entries)}"
        except json.JSONDecodeError:
            return "json-like but invalid"
    if stripped.startswith("["):
        return f"lrc/text lines={len(stripped.splitlines())}"
    return f"text bytes={len(text.encode('utf-8'))}"


def main() -> int:
    args = parse_args()
    keys = fetch_wbi_keys(args.sessdata)
    print("Subtitle endpoint candidates")
    print("required identity: cid + one of bvid/aid")
    print("wbi args: wts + w_rid on /x/player/wbi/v2")
    print()

    any_track = False
    for endpoint in ENDPOINTS:
        url = endpoint_url(endpoint, args, keys if endpoint.wbi else None)
        printable = re.sub(r"w_rid=[^&]+", "w_rid=<signed>", url)
        print(f"[{endpoint.name}] {printable}")
        try:
            body = fetch_json(url, args.sessdata)
        except Exception as error:
            print(f"  request failed: {error}")
            continue

        print(f"  code={body.get('code')} message={body.get('message')!r}")
        tracks = subtitle_tracks(body)
        print(f"  subtitle.subtitles count={len(tracks)}")
        for index, track in enumerate(tracks, start=1):
            subtitle_url = track.get("subtitle_url") or track.get("subtitleUrl") or ""
            print(
                "  "
                f"{index}. id={track.get('id')} lan={track.get('lan')!r} "
                f"lan_doc={track.get('lan_doc')!r} url={subtitle_url}"
            )
        if tracks:
            any_track = True
        if tracks and not args.no_fetch:
            subtitle_url = tracks[0].get("subtitle_url") or tracks[0].get("subtitleUrl") or ""
            if subtitle_url:
                try:
                    text = fetch_text(absolute_url(subtitle_url), args.sessdata)
                    print(f"  first body: {describe_body(text)}")
                except Exception as error:
                    print(f"  first body fetch failed: {error}")
        print()

    return 0 if any_track else 2


if __name__ == "__main__":
    sys.exit(main())
