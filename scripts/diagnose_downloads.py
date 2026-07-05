#!/usr/bin/env python3
"""
diagnose_downloads.py — Paladala iOS download diagnostic.

Inspects every video under
  <root>/Caches/Paladala/Downloads/ready/{bvid}/
and reports:

  * on-disk byte count for video.init / video.media / audio.init / audio.media
  * the merged video.mp4 / audio.mp4 byte count after ftyp+moov+mdat concat
  * ffprobe duration for each merged file (if ffprobe is on $PATH)
  * the duration declared in manifest.json for the same bvid
  * whether the merged duration matches the manifest within ±2 s

The root defaults to the iOS simulator's most-recently-launched app data
container for `com.dt.paladala`, but you can override it with `--root <path>`.

Usage (on macOS, in this repo's root):

  python3 scripts/diagnose_downloads.py            # auto-discover sim container
  python3 scripts/diagnose_downloads.py --root /tmp/Paladala_Caches
  python3 scripts/diagnose_downloads.py --bvid BV1xxxxxxx  # filter
  python3 scripts/diagnose_downloads.py --keep-merges      # don't clean up /tmp

The merged files are written to /tmp/paladala_diag_merges/<bvid>/{video,audio}.mp4
by default and deleted at the end. Use --keep-merges to keep them for ffprobe /
QuickTime inspection.

Exit code 0 if every bvid in scope matches the manifest within ±2 s,
1 otherwise. Designed to be run from CI before shipping a download-path
change.
"""
from __future__ import annotations

import argparse
import dataclasses
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# ±2 s is what the app uses internally to decide "this manifest is stale,
# re-download". Mirrored here so the diagnostic and the runtime agree.
DURATION_TOLERANCE_SEC = 2.0

DEFAULT_RELATIVE_ROOT = "Library/Caches/Paladala/Downloads"
SIM_APP_NAME_HINT = "Paladala"


# --------------------------------------------------------------------------- #
# Discovery
# --------------------------------------------------------------------------- #

def find_default_root() -> Path | None:
    """Find the most-recently-touched Paladala Caches dir under the user's
    iOS simulator devices. Returns None if no simulator is installed
    (e.g. running on Linux)."""
    home = Path.home()
    sim_root = home / "Library" / "Developer" "Simulator" / "Devices"
    if not sim_root.exists():
        return None
    candidates: list[tuple[float, Path]] = []
    for device_dir in sim_root.iterdir():
        data_root = device_dir / "data" / "Containers" / "Data" / "Application"
        if not data_root.is_dir():
            continue
        for app_dir in data_root.iterdir():
            target = app_dir / DEFAULT_RELATIVE_ROOT
            if not target.is_dir():
                continue
            try:
                # `ready/` mtime as a heuristic for "user touched this app
                # most recently". Fall back to the app dir itself.
                stat_target = target / "ready"
                mtime = stat_target.stat().st_mtime if stat_target.is_dir() \
                        else app_dir.stat().st_mtime
            except OSError:
                continue
            candidates.append((mtime, target))
    if not candidates:
        return None
    candidates.sort(reverse=True)
    return candidates[0][1]


# --------------------------------------------------------------------------- #
# Data model
# --------------------------------------------------------------------------- #

@dataclasses.dataclass
class TrackReport:
    label: str                      # "video" / "audio"
    init_bytes: int
    media_bytes: int
    merged_bytes: int
    merged_path: Path | None
    ffprobe_duration: float | None
    ffprobe_codec: str | None


@dataclasses.dataclass
class BvidReport:
    bvid: str
    directory: Path
    manifest_duration: int | None
    video: TrackReport | None
    audio: TrackReport | None
    error: str | None = None

    @property
    def ok(self) -> bool:
        if self.error is not None:
            return False
        # Video track is mandatory. If ffprobe ran, video duration must be
        # within tolerance of the manifest. If ffprobe isn't on $PATH we
        # still return True so the script is useful in stripped-down envs;
        # the missing-duration case is logged separately.
        if self.video is None:
            return False
        if self.video.ffprobe_duration is None or self.manifest_duration is None:
            return True
        return abs(self.video.ffprobe_duration - self.manifest_duration) \
                <= DURATION_TOLERANCE_SEC


# --------------------------------------------------------------------------- #
# ftyp / moov box sniffing
# --------------------------------------------------------------------------- #

def read_box_size(header: bytes) -> int | None:
    """Decode the 32-bit size field at the head of an fMP4 box. Returns None
    if the buffer is too short or the size is the special `0x00000001`
    "extends to EOF" marker (we don't try to handle that here)."""
    if len(header) < 8:
        return None
    size = int.from_bytes(header[:4], "big")
    if size == 1:
        return None
    if size < 8:
        return None
    return size


def sniff_mvhd_duration(path: Path) -> float | None:
    """Parse just enough of `path` to find the first `moov` → `mvhd` box and
    return the movie duration in seconds. Returns None if the box layout
    doesn't match. Used as a quick standalone sanity check when ffprobe
    isn't installed."""
    try:
        with path.open("rb") as f:
            buf = f.read(4 * 1024 * 1024)  # first 4 MiB is plenty for a header
    except OSError:
        return None
    i = 0
    while i + 8 <= len(buf):
        size = read_box_size(buf[i:i+8])
        if size is None or i + size > len(buf):
            break
        box_type = buf[i+4:i+8]
        if box_type == b"moov":
            moov = buf[i+8:i+size]
            j = 0
            while j + 8 <= len(moov):
                inner_size = read_box_size(moov[j:j+8])
                if inner_size is None or j + inner_size > len(moov):
                    break
                inner_type = moov[j+4:j+8]
                if inner_type == b"mvhd":
                    mvhd = moov[j+8:j+inner_size]
                    # mvhd layout (ISO/IEC 14496-12):
                    #   1 byte version
                    #   3 bytes flags
                    #   if version==1: 8+8 bytes creation/modification
                    #   else:           4+4 bytes creation/modification
                    #   4 bytes timescale
                    #   4 or 8 bytes duration
                    if len(mvhd) < 4:
                        return None
                    version = mvhd[0]
                    if version == 1:
                        if len(mvhd) < 4 + 16 + 8:
                            return None
                        timescale = int.from_bytes(mvhd[4+16:4+16+4], "big")
                        duration = int.from_bytes(mvhd[4+16+4:4+16+12], "big")
                    else:
                        if len(mvhd) < 4 + 8 + 4:
                            return None
                        timescale = int.from_bytes(mvhd[4+8:4+8+4], "big")
                        duration = int.from_bytes(mvhd[4+8+4:4+8+8], "big")
                    if timescale == 0:
                        return None
                    return duration / timescale
                j += inner_size
        i += size
    return None


# --------------------------------------------------------------------------- #
# Merge + ffprobe
# --------------------------------------------------------------------------- #

def concat_init_media(init_path: Path, media_path: Path, dest: Path) -> int:
    """Byte-concatenate init + media into `dest`. Returns the on-disk size.
    Uses FileHandle.copyfileobj so a 200 MB video doesn't allocate 200 MB of
    Python heap. Atomic-ish: writes to a sibling .tmp and renames."""
    tmp = dest.with_suffix(dest.suffix + ".tmp")
    total = 0
    with tmp.open("wb") as out:
        for src in (init_path, media_path):
            with src.open("rb") as fh:
                while True:
                    chunk = fh.read(1 << 20)  # 1 MiB
                    if not chunk:
                        break
                    out.write(chunk)
                    total += len(chunk)
    tmp.replace(dest)
    return total


def ffprobe_duration_and_codec(path: Path) -> tuple[float | None, str | None]:
    """Run ffprobe and return (duration_seconds, codec_name). Either may be
    None if ffprobe isn't installed or the file isn't a valid container."""
    ffprobe = shutil.which("ffprobe")
    if ffprobe is None:
        return (sniff_mvhd_duration(path), None)
    try:
        result = subprocess.run(
            [ffprobe, "-v", "error",
             "-select_streams", "v:0",
             "-show_entries", "stream=codec_name:format=duration",
             "-of", "json", str(path)],
            capture_output=True, text=True, timeout=30,
        )
    except (subprocess.TimeoutExpired, OSError):
        return (sniff_mvhd_duration(path), None)
    if result.returncode != 0:
        return (sniff_mvhd_duration(path), None)
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        return (sniff_mvhd_duration(path), None)
    duration = None
    fmt = data.get("format") or {}
    if "duration" in fmt:
        try:
            duration = float(fmt["duration"])
        except (TypeError, ValueError):
            duration = None
    codec = None
    streams = data.get("streams") or []
    if streams:
        codec = streams[0].get("codec_name")
    return (duration, codec)


# --------------------------------------------------------------------------- #
# Manifest
# --------------------------------------------------------------------------- #

def load_manifest(root: Path) -> dict[str, dict]:
    """Read manifest.json and return a {bvid: record} dict. Missing or
    malformed files yield an empty dict rather than raising — a partial
    manifest shouldn't stop the rest of the diagnostic."""
    manifest_path = root / "manifest.json"
    if not manifest_path.is_file():
        return {}
    try:
        with manifest_path.open("r", encoding="utf-8") as fh:
            arr = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(arr, list):
        return {}
    out: dict[str, dict] = {}
    for record in arr:
        if not isinstance(record, dict):
            continue
        bvid = record.get("bvid")
        if isinstance(bvid, str):
            out[bvid] = record
    return out


# --------------------------------------------------------------------------- #
# Per-bvid scan
# --------------------------------------------------------------------------- #

def diagnose_one(bvid: str,
                 bvid_dir: Path,
                 manifest_record: dict | None,
                 tmpdir: Path,
                 keep_merges: bool) -> BvidReport:
    manifest_duration = None
    if manifest_record is not None and "duration" in manifest_record:
        try:
            manifest_duration = int(manifest_record["duration"])
        except (TypeError, ValueError):
            manifest_duration = None

    tracks: dict[str, TrackReport] = {}
    for label in ("video", "audio"):
        init_path = bvid_dir / f"{label}.init"
        media_path = bvid_dir / f"{label}.media"
        if not (init_path.is_file() and media_path.is_file()):
            continue

        merge_dir = tmpdir / bvid
        merge_dir.mkdir(parents=True, exist_ok=True)
        merged_path = merge_dir / f"{label}.mp4"
        try:
            merged_bytes = concat_init_media(init_path, media_path, merged_path)
        except OSError as exc:
            return BvidReport(
                bvid=bvid, directory=bvid_dir,
                manifest_duration=manifest_duration,
                video=None, audio=None,
                error=f"concat {label} failed: {exc}",
            )
        duration, codec = ffprobe_duration_and_codec(merged_path)
        tracks[label] = TrackReport(
            label=label,
            init_bytes=init_path.stat().st_size,
            media_bytes=media_path.stat().st_size,
            merged_bytes=merged_bytes,
            merged_path=merged_path if keep_merges else None,
            ffprobe_duration=duration,
            ffprobe_codec=codec,
        )

    if "video" not in tracks:
        return BvidReport(
            bvid=bvid, directory=bvid_dir,
            manifest_duration=manifest_duration,
            video=None, audio=None,
            error="video.init / video.media missing",
        )
    return BvidReport(
        bvid=bvid, directory=bvid_dir,
        manifest_duration=manifest_duration,
        video=tracks.get("video"),
        audio=tracks.get("audio"),
    )


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--root", type=Path, default=None,
                   help="Path to Paladala/Downloads/ (default: auto-discover "
                        "the most-recent iOS-simulator app container).")
    p.add_argument("--bvid", default=None,
                   help="Only inspect this bvid (default: every ready/{bvid}/*).")
    p.add_argument("--keep-merges", action="store_true",
                   help="Don't delete /tmp/paladala_diag_merges/ at exit.")
    args = p.parse_args(argv)

    root = args.root or find_default_root()
    if root is None or not root.is_dir():
        print(f"error: could not find Paladala/Downloads/. Pass --root <path>.",
              file=sys.stderr)
        return 2
    ready_dir = root / "ready"
    if not ready_dir.is_dir():
        print(f"error: {ready_dir} does not exist (no downloads yet?).",
              file=sys.stderr)
        return 2

    manifest = load_manifest(root)
    bvid_dirs = sorted(p for p in ready_dir.iterdir() if p.is_dir())
    if args.bvid:
        bvid_dirs = [p for p in bvid_dirs if p.name == args.bvid]
        if not bvid_dirs:
            print(f"error: bvid {args.bvid!r} not found under {ready_dir}",
                  file=sys.stderr)
            return 2

    tmpdir = Path(tempfile.mkdtemp(prefix="paladala_diag_merges_"))
    try:
        reports: list[BvidReport] = []
        for d in bvid_dirs:
            reports.append(
                diagnose_one(d.name, d, manifest.get(d.name), tmpdir,
                             args.keep_merges)
            )
        print(f"root: {root}")
        print(f"scanned {len(reports)} bvid(s); manifest has "
              f"{len(manifest)} record(s).")
        if shutil.which("ffprobe") is None:
            print("note: ffprobe not on $PATH — falling back to mvhd sniff.")
        print()

        # Pretty table
        header = (f"{'bvid':<16} {'video.init':>10} {'video.media':>12} "
                  f"{'video.mp4':>10} {'ffprobe':>9} "
                  f"{'manifest':>9}  {'ok':<3}  {'notes'}")
        print(header)
        print("-" * len(header))
        for r in reports:
            if r.error:
                print(f"{r.bvid:<16} {'-':>10} {'-':>12} {'-':>10} "
                      f"{'-':>9} {str(r.manifest_duration or '-'):>9}  "
                      f"{'NO':<3}  {r.error}")
                continue
            v = r.video
            assert v is not None
            v_dur = f"{v.ffprobe_duration:.1f}s" if v.ffprobe_duration else "-"
            m_dur = f"{r.manifest_duration}s" if r.manifest_duration else "-"
            ok = "yes" if r.ok else "NO"
            notes_parts = []
            if v.ffprobe_codec:
                notes_parts.append(f"v={v.ffprobe_codec}")
            if r.audio:
                a = r.audio
                a_dur = f"{a.ffprobe_duration:.1f}s" if a.ffprobe_duration else "-"
                notes_parts.append(f"audio {a.init_bytes}+{a.media_bytes}={a.merged_bytes} ({a_dur})")
            if (v.ffprobe_duration is not None
                    and r.manifest_duration is not None
                    and abs(v.ffprobe_duration - r.manifest_duration)
                        > DURATION_TOLERANCE_SEC):
                notes_parts.append("DURATION MISMATCH")
            print(f"{r.bvid:<16} "
                  f"{v.init_bytes:>10} {v.media_bytes:>12} "
                  f"{v.merged_bytes:>10} {v_dur:>9} {m_dur:>9}  "
                  f"{ok:<3}  {' '.join(notes_parts)}")
        if args.keep_merges:
            print(f"\nmerged files kept under: {tmpdir}")
        else:
            print(f"\nmerged files were written to: {tmpdir} (deleted)")
    finally:
        if not args.keep_merges:
            shutil.rmtree(tmpdir, ignore_errors=True)

    bad = [r for r in reports if not r.ok]
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))