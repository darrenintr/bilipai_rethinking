#!/usr/bin/env python3
"""Probe Bilibili endpoints for reels-style videos and UP search.

Linux-runnable, no project imports:
  python3 scripts/probe_social_video_endpoints.py
"""

from __future__ import annotations

import hashlib
import json
import re
import time
import urllib.parse
import urllib.request


APP_KEY = "1d8b6e7d45233436"
APP_SEC = "560c52ccd288fed045859ed18bffd973"
UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 BiliApp/84900100"
MIXIN_KEY_ENC_TAB = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
    27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
    37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
    22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52,
]


def fetch_json(url: str, headers: dict[str, str] | None = None) -> dict:
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": UA,
            "Referer": "https://www.bilibili.com",
            **(headers or {}),
        },
    )
    with urllib.request.urlopen(req, timeout=15) as response:
        body = response.read().decode("utf-8", "replace")
        try:
            return json.loads(body)
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"non-JSON response from {url}: {body[:160]!r}") from exc


def app_signed_url(base: str, params: dict[str, str | int]) -> str:
    signed = {key: str(value) for key, value in params.items()}
    signed["appkey"] = APP_KEY
    signed["ts"] = str(int(time.time()))
    query = "&".join(
        f"{key}={urllib.parse.quote(signed[key], safe='')}"
        for key in sorted(signed)
    )
    signed["sign"] = hashlib.md5((query + APP_SEC).encode()).hexdigest()
    return base + "?" + urllib.parse.urlencode(sorted(signed.items()))


def wbi_signed_url(base: str, params: dict[str, str | int]) -> str:
    nav = fetch_json("https://api.bilibili.com/x/web-interface/nav")
    img_url = nav["data"]["wbi_img"]["img_url"]
    sub_url = nav["data"]["wbi_img"]["sub_url"]
    img_key = img_url.rsplit("/", 1)[-1].split(".", 1)[0]
    sub_key = sub_url.rsplit("/", 1)[-1].split(".", 1)[0]
    mixin_key = "".join((img_key + sub_key)[i] for i in MIXIN_KEY_ENC_TAB)[:32]

    signed = {
        key: re.sub(r"[!'()*]", "", str(value))
        for key, value in params.items()
    }
    signed["wts"] = str(int(time.time()))
    query = "&".join(
        f"{key}={urllib.parse.quote(signed[key], safe='-_.~')}"
        for key in sorted(signed)
    )
    signed["w_rid"] = hashlib.md5((query + mixin_key).encode()).hexdigest()
    return base + "?" + urllib.parse.urlencode(sorted(signed.items()))


def print_json_summary(name: str, url: str, payload: dict) -> None:
    print(f"\n== {name} ==")
    print("url:", url)
    print("code:", payload.get("code"), "message:", payload.get("message"))


def probe_story_feed() -> None:
    params = {
        "build": 84900100,
        "mobi_app": "iphone",
        "platform": "ios",
        "idx": int(time.time()),
        "pull": 1,
        "column": 1,
        "device": "phone",
        "flush": 4,
        "fnval": 4048,
        "qn": 64,
        "fourk": 1,
        # App feed's vertical / reels-like lane. Some accounts still receive
        # regular cards, so callers should filter for playable av items.
        "feed_style": "story",
    }
    url = app_signed_url("https://app.bilibili.com/x/v2/feed/index", params)
    payload = fetch_json(url, headers={"mobi_app": "iphone", "platform": "ios"})
    print_json_summary("app story feed", url, payload)
    items = (payload.get("data") or {}).get("items") or []
    print("args:", sorted(params.keys()) + ["appkey", "ts", "sign"])
    print("items:", len(items))
    for item in items[:5]:
        args = item.get("args") or {}
        player_args = item.get("player_args") or {}
        print(
            "-",
            item.get("card_goto"),
            "aid=", args.get("aid") or player_args.get("aid"),
            "cid=", player_args.get("cid"),
            "bvid=", args.get("bvid") or item.get("bvid"),
            "title=", (item.get("title") or "")[:48],
        )


def probe_user_search() -> None:
    params = {
        "search_type": "bili_user",
        "keyword": "罗翔",
        "page": 1,
        "page_size": 5,
        "platform": "pc",
        "web_location": "1430654",
    }
    url = wbi_signed_url("https://api.bilibili.com/x/web-interface/wbi/search/type", params)
    payload = fetch_json(url)
    print_json_summary("UP search", url, payload)
    print("args:", sorted(params.keys()))
    results = ((payload.get("data") or {}).get("result") or [])
    print("users:", len(results))
    for user in results[:5]:
        print(
            "-",
            "mid=", user.get("mid"),
            "uname=", user.get("uname"),
            "fans=", user.get("fans"),
            "videos=", user.get("videos"),
            "face=", user.get("upic") or user.get("face"),
        )


if __name__ == "__main__":
    probe_story_feed()
    probe_user_search()
