#!/usr/bin/env python3
"""
probe_live_endpoints.py — verify the B 站 live stream fetch surface
end-to-end and decide which permutations AVPlayer can natively play.

Five checks, each runnable on macOS / Linux without an Apple Developer
account or an iOS simulator:

  1. `room-list` — GET `/room/v3/area/getRoomList` (anon works).
     Print the first N room IDs so a follow-up probe has something
     to hit without manual lookup.
  2. `playinfo` — for every (room_id × qn × protocol × format ×
     codec) combo the iOS app could ask for, GET
     `/xlive/web-room/v2/index/getRoomPlayInfo` and walk the
     `data.playurl_info.playurl.stream[] → format[] → codec[] →
     url_info[]` tree. For each leaf URL, classify it as
     AVPlayer-native / AVPlayer-conditional / AVPlayer-incompatible
     based on (protocol_name, format_name, codec_name) and print a
     one-line summary per URL.
  3. `m3u8-shape` — fetch the first HLS candidate the upstream
     returns and parse the m3u8: media vs master playlist, segment
     count, presence of #EXT-X-KEY (AES-128), #EXT-X-MAP (fMP4
     init), #EXT-X-ENDLIST (VOD-ended flag), MEDIA-SEQUENCE and
     target duration. This is what decides whether the proxy needs
     the master-playlist rewrite logic — see
     `LocalHLSProxyServer.rewriteLiveManifest` (currently only
     handles media-playlist URI rewrites; master playlists pass
     through unsynthesised and AVPlayer falls back to the first
     rendition only).
  4. `cdn-failover` — for every host the playinfo response
     surfaced, HEAD-probe with the upstream-style Referer + UA,
     report HTTP status + median connect-time. Sorted fastest-first
     so we can see whether the current "return upstream order"
     strategy is actually optimal.
  5. `avplayer-verdict` — collapse everything into a short report:
     "does the live fetch output need translation to be AVPlayer
     compatible? if yes, which transformations?"

Exit codes:
  0 — every probed URL was either AVPlayer-native or AVPlayer-
      conditional on a current iPhone; no translation strictly
      required.
  1 — at least one variant needs translation that the current
      proxy does NOT perform. Caller should look at the verdict
      block before shipping.
  2 — probe could not run (no live rooms surfaced, network down).

Usage:

  python3 scripts/probe_live_endpoints.py
  python3 scripts/probe_live_endpoints.py --room 12345
  python3 scripts/probe_live_endpoints.py --qn 10000 250
  python3 scripts/probe_live_endpoints.py --sessdata 'xxxxx%2Cxxxxx'
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
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Iterable

LIVE_BASE = "https://api.live.bilibili.com"
ROOM_LIST_PATH = "/room/v3/area/getRoomList"
PLAY_INFO_PATH = "/xlive/web-room/v2/index/getRoomPlayInfo"

DEFAULT_ROOM_COUNT = 10
DEFAULT_QN_LADDER = [10000, 250]
DEFAULT_PROTOCOL_BITMASK = "0,1"   # 0=FLV, 1=HLS
DEFAULT_FORMAT_BITMASK = "0,1,2"   # 0=FLV, 1=TS, 2=fMP4
DEFAULT_CODEC_BITMASK = "0,1"      # 0=AVC, 1=HEVC

# ---- AVPlayer compatibility table ----------------------------------------
#
# iOS 17.5 / 18.0 reference (matches the Paladala deployment floor).
# `native`  = AVPlayer plays it out of the box, no proxy translation.
# `hevc`    = AVPlayer plays it on iPhone XS+; the iPad mini 5 and older
#             cannot decode HEVC Main10 in software, so a runtime
#             capability check is required.
# `flv`     = AVPlayer CANNOT play FLV (no native demuxer).  Requires
#             a transcoding proxy (out of scope for the Paladala
#             server, which is byte-passthrough).
# `rtmp`    = Out-of-band; not consumable by URLSession.
AVPLAYER_TABLE: dict[tuple[str, str, str], str] = {
    # HLS — AVPlayer-native (TS) and AVPlayer-native (fMP4).
    ("http_hls",   "ts",   "avc"): "native",
    ("http_hls",   "fmp4", "avc"): "native",
    ("https_hls",  "ts",   "avc"): "native",
    ("https_hls",  "fmp4", "avc"): "native",
    # HLS — AVPlayer-conditional (HEVC Main10; iPhone XS+ only).
    ("http_hls",   "ts",   "hevc"): "hevc",
    ("http_hls",   "fmp4", "hevc"): "hevc",
    ("https_hls",  "ts",   "hevc"): "hevc",
    ("https_hls",  "fmp4", "hevc"): "hevc",
    # FLV (any container) — AVPlayer cannot decode; the iOS app
    # surfaces a friendly error and skips controller init.
    ("http_flv",   "flv",  "avc"):  "flv",
    ("https_flv",  "flv",  "avc"):  "flv",
    ("http_flv",   "flv",  "hevc"): "flv",
    ("https_flv",  "flv",  "hevc"): "flv",
    # Bilibili also returns a `http_stream` protocol that's
    # functionally identical to `http_flv` (no HLS/DASH in it).
    # Treat the same — AVPlayer cannot consume it.
    ("http_stream", "flv",  "avc"):  "flv",
    ("http_stream", "flv",  "hevc"): "flv",
    # RTMP — out-of-band, never consumable via URLSession.
    ("rtmp_flv",   "flv",  "avc"):  "rtmp",
    ("rtmp_flv_h265", "flv", "hevc"): "rtmp",
}

# Translate AVPlayer verdict → emoji for the console summary.
VERDICT_GLYPH = {"native": "✓", "hevc": "△", "flv": "✗", "rtmp": "✗"}
VERDICT_RANK = {"native": 0, "hevc": 1, "flv": 2, "rtmp": 3}


# ---- data classes --------------------------------------------------------

@dataclasses.dataclass
class RoomSummary:
    room_id: int
    title: str
    uname: str
    area_name: str
    online: int


@dataclasses.dataclass
class LiveCandidate:
    protocol_name: str
    format_name: str
    codec_name: str
    host: str
    base_url: str
    extra: str
    full_url: str
    avplayer: str

    @property
    def rank(self) -> int:
        return VERDICT_RANK.get(self.avplayer, 99)


@dataclasses.dataclass
class ManifestShape:
    url: str
    is_master: bool
    extinf_count: int
    has_key: bool           # #EXT-X-KEY (AES-128)
    has_map: bool           # #EXT-X-MAP (fMP4 init)
    has_endlist: bool       # #EXT-X-ENDLIST (VOD-ended)
    target_duration: int | None
    media_sequence: int | None
    raw_excerpt: str


@dataclasses.dataclass
class HostLatency:
    host: str
    median_ms: float | None
    statuses: str


# ---- HTTP helpers --------------------------------------------------------

LIVE_UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
           "AppleWebKit/605.1.15 (KHTML, like Gecko) "
           "Version/18.0 Mobile/15E148 Safari/604.1")


def _request(url: str, *, referer: str = "https://live.bilibili.com",
             sessdata: str | None = None,
             timeout: float = 10.0) -> tuple[int, bytes, dict[str, str]]:
    req = urllib.request.Request(url, headers={
        "User-Agent": LIVE_UA,
        "Referer": referer,
        "Origin": "https://live.bilibili.com",
        **({"Cookie": f"SESSDATA={sessdata}"} if sessdata else {}),
    })
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return (resp.status, resp.read(), dict(resp.headers))
    except urllib.error.HTTPError as e:
        return (e.code, e.read() if e.fp else b"", dict(e.headers or {}))
    except urllib.error.URLError as e:
        return (-1, str(e).encode(), {})


def _build_live_url(path: str, params: dict[str, str]) -> str:
    qs = urllib.parse.urlencode(params)
    return f"{LIVE_BASE}{path}?{qs}"


# ---- step 1: room list ---------------------------------------------------

def fetch_room_list(page_size: int = 30,
                    sessdata: str | None = None) -> list[RoomSummary]:
    url = _build_live_url(ROOM_LIST_PATH, {
        "parent_area_id": "0",
        "area_id": "0",
        "page_size": str(page_size),
        "sort_type": "online",
        "page": "1",
    })
    status, body, _ = _request(url, sessdata=sessdata)
    if status != 200:
        print(f"  room-list HTTP {status}; body[:200]={body[:200]!r}")
        return []
    payload = json.loads(body)
    rooms: list[RoomSummary] = []
    for item in (payload.get("data") or {}).get("list") or []:
        rooms.append(RoomSummary(
            room_id=int(item.get("roomid") or 0),
            title=item.get("title") or "",
            uname=item.get("uname") or "",
            area_name=item.get("area_name") or "",
            online=int(item.get("online") or 0),
        ))
    return rooms


# ---- step 2: playinfo walk ----------------------------------------------

def _compose_url(url_info: dict, base_url: str) -> str:
    """Mirror BilibiliAPIClient.composeStreamURL (Swift:972-980).

    The Swift side picks `https` when the host field already starts
    with `https://`; otherwise `http`. We do the same.

    NB: `base_url` typically ends in `?` already (Bilibili's
    pre-signed pattern is `<path>?`), so we join with `&` when
    that is the case — appending a literal `?` would produce
    `<path>??<extra>`, which the live CDN rejects with 403.
    This is the same fix the iOS proxy needs.
    """
    host = url_info.get("host") or ""
    extra = url_info.get("extra") or ""
    scheme = "https" if host.lower().startswith("https://") else "http"
    prefix = f"{scheme}://"
    host_part = host[len(prefix):] if host.startswith(prefix) else host
    raw = f"{scheme}://{host_part}{base_url}"
    if extra:
        joiner = "&" if base_url.endswith("?") else "?"
        raw += joiner + extra
    return raw


def _avplayer_verdict(protocol_name: str, format_name: str, codec_name: str) -> str:
    return AVPLAYER_TABLE.get(
        (protocol_name, format_name, codec_name),
        # Unknown combinations default to "incompatible" — the iOS code
        # already skips anything that isn't HLS or FLV, so any new
        # permutation surfacing here is a server-side change worth
        # catching.
        "rtmp",
    )


def fetch_play_info(room_id: int, qn: int, *,
                    protocol: str = DEFAULT_PROTOCOL_BITMASK,
                    fmt: str = DEFAULT_FORMAT_BITMASK,
                    codec: str = DEFAULT_CODEC_BITMASK,
                    platform: str = "web", ptype: str = "8",
                    sessdata: str | None = None) -> dict | None:
    url = _build_live_url(PLAY_INFO_PATH, {
        "room_id": str(room_id),
        "protocol": protocol,
        "format": fmt,
        "codec": codec,
        "qn": str(qn),
        "platform": platform,
        "ptype": ptype,
    })
    status, body, _ = _request(url, sessdata=sessdata)
    if status != 200:
        print(f"    HTTP {status} for qn={qn} protocol={protocol} format={fmt} codec={codec}")
        return None
    payload = json.loads(body)
    code = payload.get("code")
    if code is None or int(code) != 0:
        # `code != 0` typically means the room is offline; expected
        # behaviour, not an error. Print and skip.  NB: we use
        # `code is None` instead of `code or -1` because `0` is
        # falsy and would short-circuit the or-expression.
        print(f"    upstream code={code} msg={payload.get('message')!r}")
        return None
    return payload


def extract_candidates(payload: dict) -> list[LiveCandidate]:
    """Walk the (stream → format → codec → url_info) tree exactly the
    way BilibiliAPIClient.livePlaybackURL does (Swift:919-945).

    Returns one LiveCandidate per CDN host so the verdict reflects
    every edge AVPlayer could be pointed at.
    """
    out: list[LiveCandidate] = []
    info = (payload.get("data") or {}).get("playurl_info") or {}
    streams = (info.get("playurl") or {}).get("stream") or []
    for s in streams:
        proto = s.get("protocol_name") or ""
        for f in s.get("format") or []:
            fmt_name = f.get("format_name") or ""
            for c in f.get("codec") or []:
                codec_name = c.get("codec_name") or ""
                base_url = c.get("base_url") or ""
                verdict = _avplayer_verdict(proto, fmt_name, codec_name)
                for ui in c.get("url_info") or []:
                    host = ui.get("host") or ""
                    extra = ui.get("extra") or ""
                    if not host or not base_url:
                        continue
                    full = _compose_url(ui, base_url)
                    out.append(LiveCandidate(
                        protocol_name=proto,
                        format_name=fmt_name,
                        codec_name=codec_name,
                        host=host,
                        base_url=base_url,
                        extra=extra,
                        full_url=full,
                        avplayer=verdict,
                    ))
    return out


# ---- step 3: m3u8 shape --------------------------------------------------

_EXTINF = re.compile(r"^#EXTINF", re.MULTILINE)
_EXT_STREAM_INF = re.compile(r"^#EXT-X-STREAM-INF", re.MULTILINE)
_EXT_KEY = re.compile(r"^#EXT-X-KEY", re.MULTILINE)
_EXT_MAP = re.compile(r"^#EXT-X-MAP", re.MULTILINE)
_EXT_ENDLIST = re.compile(r"^#EXT-X-ENDLIST", re.MULTILINE)
_TARGET_DUR = re.compile(r"^#EXT-X-TARGETDURATION\s*:\s*(\d+)", re.MULTILINE)
_MEDIA_SEQ = re.compile(r"^#EXT-X-MEDIA-SEQUENCE\s*:\s*(\d+)", re.MULTILINE)


def probe_m3u8_shape(url: str) -> ManifestShape | None:
    status, body_bytes, _ = _request(url, referer="https://live.bilibili.com")
    if status != 200:
        return None
    try:
        body = body_bytes.decode("utf-8")
    except UnicodeDecodeError:
        return None
    return ManifestShape(
        url=url,
        is_master=bool(_EXT_STREAM_INF.search(body)),
        extinf_count=len(_EXTINF.findall(body)),
        has_key=bool(_EXT_KEY.search(body)),
        has_map=bool(_EXT_MAP.search(body)),
        has_endlist=bool(_EXT_ENDLIST.search(body)),
        target_duration=int(m.group(1)) if (m := _TARGET_DUR.search(body)) else None,
        media_sequence=int(m.group(1)) if (m := _MEDIA_SEQ.search(body)) else None,
        raw_excerpt="\n".join(body.splitlines()[:8]),
    )


# ---- step 4: CDN latency -------------------------------------------------

def host_latency(host: str, sample: str | None = None) -> HostLatency:
    """5× HEAD probes against `host`, report median connect-time.

    `sample` is a full URL whose path we re-use so we don't accidentally
    hit a non-CDN endpoint when the host has many services on it.
    """
    if sample:
        parsed = urllib.parse.urlparse(sample)
        path = parsed.path or "/"
    else:
        path = "/"
    timings: list[float] = []
    statuses: list[int] = []
    for _ in range(5):
        url = f"https://{host}{path}"
        try:
            req = urllib.request.Request(url, method="HEAD", headers={
                "User-Agent": LIVE_UA,
                "Referer": "https://live.bilibili.com",
            })
            t0 = time.perf_counter()
            with urllib.request.urlopen(req, timeout=4) as resp:
                resp.read(0)
            timings.append((time.perf_counter() - t0) * 1000)
            statuses.append(resp.status)
        except urllib.error.HTTPError as e:
            timings.append((time.perf_counter() - t0) * 1000)
            statuses.append(e.code)
        except Exception:
            continue
    median = statistics.median(timings) if timings else None
    return HostLatency(
        host=host, median_ms=median,
        statuses=",".join(str(s) for s in statuses) or "-",
    )


# ---- main ----------------------------------------------------------------

def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--room", type=int, default=None,
                   help="Room ID to probe.  Default: first from /getRoomList.")
    p.add_argument("--qn", type=int, nargs="+", default=DEFAULT_QN_LADDER,
                   help="qn ladder to try (10000=原画, 250=流畅, …).")
    p.add_argument("--protocol", default=DEFAULT_PROTOCOL_BITMASK,
                   help="protocol bitmask (0=FLV, 1=HLS). Default '0,1'.")
    p.add_argument("--format", dest="fmt", default=DEFAULT_FORMAT_BITMASK,
                   help="format bitmask (0=FLV, 1=TS, 2=fMP4). Default '0,1,2'.")
    p.add_argument("--codec", default=DEFAULT_CODEC_BITMASK,
                   help="codec bitmask (0=AVC, 1=HEVC). Default '0,1'.")
    p.add_argument("--sessdata", default=None,
                   help="Optional SESSDATA cookie for higher-qn requests.")
    p.add_argument("--rooms-to-list", type=int, default=DEFAULT_ROOM_COUNT,
                   help="How many rooms to print from /getRoomList.")
    args = p.parse_args(argv)

    # ---- step 1 ----------------------------------------------------------
    print("=" * 78)
    print("STEP 1 — /room/v3/area/getRoomList (anon)")
    print("=" * 78)
    rooms = fetch_room_list(page_size=max(args.rooms_to_list, 5),
                            sessdata=args.sessdata)
    if not rooms:
        print("  no rooms returned.  Bailing.")
        return 2
    for r in rooms[:args.rooms_to_list]:
        print(f"  room={r.room_id:>10}  online={r.online:>7}  "
              f"area={r.area_name[:14]:<14}  title={r.title[:36]}")
    target = args.room or rooms[0].room_id
    print(f"\nProbing room_id={target}\n")

    # ---- step 2 ----------------------------------------------------------
    print("=" * 78)
    print(f"STEP 2 — /xlive/web-room/v2/index/getRoomPlayInfo "
          f"(protocol={args.protocol} format={args.fmt} codec={args.codec})")
    print("=" * 78)
    all_candidates: list[LiveCandidate] = []
    for qn in args.qn:
        print(f"\n  -- qn={qn}")
        payload = fetch_play_info(
            target, qn,
            protocol=args.protocol, fmt=args.fmt, codec=args.codec,
            sessdata=args.sessdata,
        )
        if payload is None:
            continue
        cands = extract_candidates(payload)
        all_candidates.extend(cands)
        # Group by (protocol, format, codec) and print a one-liner per
        # host so the output stays readable.
        seen_groups: dict[tuple[str, str, str], list[LiveCandidate]] = {}
        for c in cands:
            seen_groups.setdefault((c.protocol_name, c.format_name, c.codec_name), []).append(c)
        for (proto, fmt_name, codec_name), group in sorted(seen_groups.items()):
            verdict = group[0].avplayer
            glyph = VERDICT_GLYPH[verdict]
            print(f"    {glyph} {proto:<14} fmt={fmt_name:<5} codec={codec_name:<5} "
                  f"verdict={verdict:<6} hosts={len(group)}")
            for c in group[:3]:
                host_disp = c.host[:42]
                print(f"        {host_disp:<42}  {urllib.parse.urlparse(c.full_url).path[:48]}")
            if len(group) > 3:
                print(f"        … ({len(group) - 3} more CDN edge(s))")
    if not all_candidates:
        print("\n  no candidates surfaced (room likely offline).  Bailing.")
        return 2

    # ---- step 3: m3u8 shape ----------------------------------------------
    print()
    print("=" * 78)
    print("STEP 3 — m3u8 shape (first HLS candidate per qn)")
    print("=" * 78)
    shapes: list[ManifestShape] = []
    hls_candidates = [c for c in all_candidates if c.protocol_name.endswith("hls") and c.avplayer != "rtmp"]
    seen_urls: set[str] = set()
    for c in hls_candidates:
        if c.full_url in seen_urls:
            continue
        seen_urls.add(c.full_url)
        s = probe_m3u8_shape(c.full_url)
        if s is None:
            print(f"  cannot fetch {c.host}{urllib.parse.urlparse(c.full_url).path[:48]}")
            continue
        shapes.append(s)
        kind = "MASTER" if s.is_master else "MEDIA "
        print(f"  [{kind}] extinf={s.extinf_count:>3}  target_dur={s.target_duration}  "
              f"media_seq={s.media_sequence}  key={s.has_key}  map={s.has_map}  "
              f"endlist={s.has_endlist}  ← {c.host[:32]}")
        for line in s.raw_excerpt.splitlines()[:6]:
            print(f"      | {line[:80]}")

    # ---- step 4: CDN latency ---------------------------------------------
    print()
    print("=" * 78)
    print("STEP 4 — CDN host latency (5 HEAD probes, median ms)")
    print("=" * 78)
    hosts = sorted({c.host for c in all_candidates})
    sample_by_host = {c.host: c.full_url for c in all_candidates}
    latencies: list[HostLatency] = []
    with ThreadPoolExecutor(max_workers=8) as ex:
        futs = {ex.submit(host_latency, h, sample_by_host.get(h)): h for h in hosts}
        for fut in as_completed(futs):
            latencies.append(fut.result())
    latencies.sort(key=lambda l: l.median_ms if l.median_ms is not None else 1e9)
    print(f"\n{'host':<42} {'median ms':>10}  statuses")
    print("-" * 90)
    for l in latencies:
        ms = f"{l.median_ms:.0f}" if l.median_ms is not None else "—"
        print(f"{l.host:<42} {ms:>10}  {l.statuses}")

    # ---- step 5: verdict --------------------------------------------------
    print()
    print("=" * 78)
    print("STEP 5 — AVPlayer verdict + translation requirements")
    print("=" * 78)
    avplayer_counts: dict[str, int] = {}
    for c in all_candidates:
        avplayer_counts[c.avplayer] = avplayer_counts.get(c.avplayer, 0) + 1
    print("  AVPlayer verdict histogram (per CDN edge):")
    for verdict in ("native", "hevc", "flv", "rtmp"):
        if verdict in avplayer_counts:
            print(f"    {VERDICT_GLYPH[verdict]} {verdict:<7} = {avplayer_counts[verdict]} edge(s)")

    master_shapes = [s for s in shapes if s.is_master]
    map_shapes = [s for s in shapes if s.has_map]
    key_shapes = [s for s in shapes if s.has_key]

    needs: list[str] = []
    if master_shapes:
        needs.append(
            f"master-playlist handling: {len(master_shapes)}/{len(shapes)} m3u8(s) are "
            f"masters with multiple #EXT-X-STREAM-INF variants — current "
            f"`rewriteLiveManifest` only handles media-playlist URIs; AVPlayer "
            f"will pick the first rendition only.  Synthesise per-rendition "
            f"media playlists (one per #EXT-X-STREAM-INF) so the player can "
            f"step between qualities.")
    if map_shapes:
        needs.append(
            f"fMP4 init segment (#EXT-X-MAP): {len(map_shapes)}/{len(shapes)} m3u8(s) "
            f"reference an init segment via EXT-X-MAP — the byte-passthrough "
            f"proxy must forward that init fetch with the same Referer/UA "
            f"treatment as live segments, otherwise AVPlayer will log "
            f"'m3u8 EXT-X-MAP not loadable' and stall on the first keyframe.")
    if key_shapes:
        needs.append(
            f"AES-128 (#EXT-X-KEY): {len(key_shapes)}/{len(shapes)} m3u8(s) carry "
            f"EXT-X-KEY — keys must be proxied the same way as segments (referer + UA).")
    if any(c.avplayer == "hevc" for c in all_candidates):
        needs.append(
            "HEVC variants surfaced: AVPlayer supports HEVC Main10 on iPhone XS+; "
            "consider preferring AVC (qn ladder step-down) when the device's "
            "AVAssetDownloadStorageManagementPolicy reports HEVC = false.")
    if any(c.avplayer == "flv" for c in all_candidates):
        needs.append(
            "FLV-only rooms: AVPlayer cannot decode FLV.  The current player UI "
            "surfaces a friendly error — keep that path but optionally fall "
            "back to HEVC if the room offers HLS-HEVC only.")
    if not needs:
        print("  ✓ no translation required — every probed edge is AVPlayer-native.")
        return 0

    print("\n  Translation requirements the HLS proxy must implement:")
    for i, need in enumerate(needs, 1):
        print(f"    {i}. {need}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))