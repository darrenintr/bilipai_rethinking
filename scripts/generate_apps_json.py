#!/usr/bin/env python3
"""
generate_apps_json.py — produce the AltSource manifest (apps.json) for Paladala.

Used by .github/workflows/ios-unsigned-ipa.yml after the unsigned IPA is
packaged and uploaded to a GitHub Release. The workflow feeds the new build
metadata + a copy of the existing apps.json (from the gh-pages branch) into
this script; we merge the new version in (de-duplicating by buildVersion /
tag) and write the result back so the next gh-pages push is incremental.

AltSource schema reference:
  https://faq.altstore.io/altstore-extra/adding-your-own-source
  https://github.com/altstoreio/Docs/blob/master/docs/AltSource.md

All values that the user is expected to want to tweak (description,
screenshot URLs, app permissions, …) live in the APP_META block at the
top of the file so this script never needs to be re-read in anger.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# App metadata — change here, not in the workflow.
# ---------------------------------------------------------------------------
APP_META: dict[str, Any] = {
    "name": "Paladala",
    "bundleIdentifier": "com.dt.paladala",
    "developerName": "darrenintr",
    "subtitle": "純淨嘅第三方嗶哩嗶哩 iOS 客戶端",
    "tintColor": "#FB7299",
    "category": "entertainment",
    # PNG, not SVG. iOS UIImage (and therefore both AltStore and
    # SideStore) loads icons via UIImage, which does NOT support SVG.
    # SideStore in particular rejects the entire source if it can't
    # fetch the icon at add-time, so an SVG iconURL means "can't even
    # add the source". The workflow renders the same brand mark with a
    # brand-pink background so it reads on AltStore's white UI.
    "iconURL": "https://darrenintr.github.io/pure-bilibili-rethinking/icon.png",
    "localizedDescription": (
        "Paladala 係一個用 SwiftUI 寫嘅第三方嗶哩嗶哩 iOS 客戶端,目標係"
        "「淨」同「快」：\n\n"
        "- 內置 FFmpeg 解冩 DASH 直播流,實時彈幕接力\n"
        "- AVPlayer 全硬件加速播普通視頻,零額外依賴\n"
        "- 完整支援 B 站帳號登入、追番、動態、收藏夾、私訊\n"
        "- 影片可下載到本機離線睇\n"
        "- 對 LiveContainer 友善,塞入 LiveContainer 之後唔佔 iOS 嘅 3 app 側載限額\n\n"
        "本 App 通過 AltStore / SideStore 源發佈,每次 push 到 `working` 分支"
        "都會自動出新版本。"
    ),
    # No `appPermissions` field on purpose: SideStore does strict
    # schema validation and `appPermissions` is expected to be a
    # {permission: description} dict. We don't have real per-permission
    # descriptions to publish, and the field is optional, so leaving it
    # off keeps the source compatible with both clients.
    # Add screenshot URLs once they're hosted (e.g. on gh-pages under
    # screenshots/<name>.png). Leave empty for now.
    "screenshotURLs": [],
}


def now_utc_iso() -> str:
    """ISO-8601 UTC timestamp, second precision (e.g. 2026-08-01T12:34:56Z)."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_existing(path: Path) -> dict[str, Any]:
    """Load the previous apps.json, tolerating first-run / 404 cases.

    The workflow passes a file that is either:
      - non-empty and valid JSON: the previous manifest
      - an empty file: created on first run when the gh-pages curl 404s
      - missing: command-line path validation failure (caller's job)
    """
    if not path.exists():
        return {}
    raw = path.read_text(encoding="utf-8").strip()
    if not raw:
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        # Don't silently paper over a corrupt source; the next push will
        # produce a worse bug ("why did all the history disappear?").
        print(
            f"::error::Existing apps.json at {path} is not valid JSON: {exc}",
            file=sys.stderr,
        )
        raise
    if not isinstance(data, dict):
        print(
            f"::error::Existing apps.json at {path} is not a JSON object "
            f"(got {type(data).__name__})",
            file=sys.stderr,
        )
        raise SystemExit(1)
    return data


def file_size(path: Path) -> int:
    """Return the file size in bytes; raise if the file is missing."""
    if not path.exists():
        print(f"::error::IPA not found at {path}", file=sys.stderr)
        raise SystemExit(1)
    return path.stat().st_size


def download_url(repo: str, tag: str, product_name: str) -> str:
    """Construct the GitHub release download URL.

    Mirrors what `.github/workflows/ios-unsigned-ipa.yml` uploads via
    `softprops/action-gh-release@v2` and what
    `scripts/install-latest-ipa-ios.sh:15` parses out of the releases API.
    """
    return (
        f"https://github.com/{repo}/releases/download/{tag}/"
        f"{product_name}-unsigned-{tag}.ipa"
    )


def merge_versions(
    existing_versions: list[dict[str, Any]],
    new_entry: dict[str, Any],
) -> list[dict[str, Any]]:
    """Prepend `new_entry` to the version list, de-duplicating by
    `buildVersion`. If the same buildVersion is already present, the new
    entry wins (downloadURL / date / size / releaseNotes get refreshed in
    place; the position in the list is preserved so historical ordering
    isn't churned by a re-run).
    """
    by_build = {v.get("buildVersion"): v for v in existing_versions}
    by_build[new_entry["buildVersion"]] = new_entry
    # Stable order: newest first, but keep the original position of the
    # updated entry so the array isn't reshuffled on a no-op re-run.
    out: list[dict[str, Any]] = []
    seen: set[str] = set()
    for v in existing_versions:
        bv = v.get("buildVersion")
        if bv in seen:
            continue
        seen.add(bv)
        out.append(by_build[bv])
    if new_entry["buildVersion"] not in seen:
        out.insert(0, new_entry)
    return out


def merge_news(
    existing_news: list[dict[str, Any]],
    new_entry: dict[str, Any],
) -> list[dict[str, Any]]:
    """Prepend `new_entry` to the news list, de-duplicating by `identifier`."""
    by_id = {n.get("identifier"): n for n in existing_news}
    by_id[new_entry["identifier"]] = new_entry
    out: list[dict[str, Any]] = []
    seen: set[str] = set()
    for n in existing_news:
        nid = n.get("identifier")
        if nid in seen:
            continue
        seen.add(nid)
        out.append(by_id[nid])
    if new_entry["identifier"] not in seen:
        out.insert(0, new_entry)
    return out


def build_apps_json(
    existing: dict[str, Any],
    *,
    tag: str,
    build_version: str,
    market_version: str,
    repo: str,
    product_name: str,
    commit_sha: str,
    run_id: str,
    run_number: str,
    ipa_path: Path,
    release_notes: str,
) -> dict[str, Any]:
    """Construct the final apps.json: APP_META + the new version + merged
    versions/news history. The top-level `version` / `buildVersion` always
    reflect the freshly produced build so AltStore shows "update available"
    the moment the source is refreshed.
    """
    iso_now = now_utc_iso()
    ipa_bytes = file_size(ipa_path)
    download = download_url(repo, tag, product_name)

    new_version_entry: dict[str, Any] = {
        "version": market_version,
        "buildVersion": build_version,
        "date": iso_now,
        "size": ipa_bytes,
        "downloadURL": download,
    }
    if release_notes:
        new_version_entry["releaseNotes"] = release_notes

    new_news_entry: dict[str, Any] = {
        "title": f"{APP_META['name']} {tag}",
        "date": iso_now,
        "identifier": tag,
        "tintColor": APP_META["tintColor"],
        "caption": f"Build {build_version} ({commit_sha[:7]})",
        "url": f"https://github.com/{repo}/releases/tag/{tag}",
    }

    # Start from APP_META, then layer in any history that was preserved
    # from the previous apps.json. APP_META wins for the keys it sets, so
    # the user can change APP_META in this script and the next push will
    # pick it up.
    out: dict[str, Any] = dict(APP_META)
    out.update(
        {
            "version": market_version,
            "buildVersion": build_version,
            "versions": merge_versions(
                list(existing.get("versions", [])), new_version_entry
            ),
            "news": merge_news(list(existing.get("news", [])), new_news_entry),
        }
    )
    # Tag metadata for triage. AltStore ignores these; humans reading the
    # JSON in a PR review will appreciate them.
    out["_meta"] = {
        "generatedAt": iso_now,
        "githubRunId": run_id,
        "githubRunNumber": run_number,
        "githubSha": commit_sha,
        "sourceScript": "scripts/generate_apps_json.py",
    }
    return out


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument(
        "--existing",
        type=Path,
        default=Path("/dev/null"),
        help="Path to the previous apps.json (may be empty / missing).",
    )
    p.add_argument(
        "--release-notes",
        type=Path,
        default=None,
        help="Path to the release notes markdown (optional).",
    )
    p.add_argument(
        "--ipa-path",
        type=Path,
        required=True,
        help="Path to the unsigned IPA — its file size is included in apps.json.",
    )
    p.add_argument(
        "--output",
        type=Path,
        required=True,
        help="Where to write the merged apps.json.",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Print to stdout instead of writing to --output.",
    )
    return p.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    tag = os.environ.get("TAG", "").strip()
    build_version = os.environ.get("BUNDLE_VERSION", "").strip()
    market_version = os.environ.get("MARKET_VERSION", "").strip()
    repo = os.environ.get("GITHUB_REPOSITORY", "").strip()
    product_name = os.environ.get("PRODUCT_NAME", "Paladala").strip()
    commit_sha = os.environ.get("GITHUB_SHA", "").strip()
    run_id = os.environ.get("GITHUB_RUN_ID", "").strip()
    run_number = os.environ.get("GITHUB_RUN_NUMBER", "").strip()

    missing = [
        n
        for n, v in (
            ("TAG", tag),
            ("BUNDLE_VERSION", build_version),
            ("MARKET_VERSION", market_version),
            ("GITHUB_REPOSITORY", repo),
            ("GITHUB_SHA", commit_sha),
        )
        if not v
    ]
    if missing:
        print(
            f"::error::Required env vars missing: {', '.join(missing)}",
            file=sys.stderr,
        )
        return 1

    release_notes = ""
    if args.release_notes and args.release_notes.exists():
        release_notes = args.release_notes.read_text(encoding="utf-8").rstrip()

    existing = load_existing(args.existing)
    apps_json = build_apps_json(
        existing,
        tag=tag,
        build_version=build_version,
        market_version=market_version,
        repo=repo,
        product_name=product_name,
        commit_sha=commit_sha,
        run_id=run_id,
        run_number=run_number,
        ipa_path=args.ipa_path,
        release_notes=release_notes,
    )

    # ensure_ascii=False so the 繁體中文 description / subtitle don't
    # become \uXXXX escape soup; sort_keys=True for stable diffs across
    # runs that produce functionally identical JSON.
    text = json.dumps(apps_json, indent=2, ensure_ascii=False, sort_keys=True)
    text += "\n"

    if args.dry_run:
        sys.stdout.write(text)
        return 0

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(text, encoding="utf-8")
    print(
        f"Wrote {args.output} "
        f"({len(apps_json['versions'])} version(s), "
        f"{len(apps_json['news'])} news item(s))"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
