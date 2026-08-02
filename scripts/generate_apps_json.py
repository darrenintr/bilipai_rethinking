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
# Source + App metadata — change here, not in the workflow.
#
# AltSource schema is TWO levels deep (see
# https://faq.altstore.io/developers/make-a-source):
#   • SOURCE_META populates the top-level "source" object (name,
#     subtitle, description, tintColor, …). AltStore displays this in
#     the source's About page.
#   • APP_META populates each entry in the top-level `apps[]` array.
#     Each app carries its own name, bundleIdentifier, versions[], …
#     — fields that don't belong on the source object itself.
# Earlier revisions of this script used a flat object (name /
# bundleIdentifier / versions / appPermissions all at the top
# level). AltStore's parser tolerates that; SideStore's does not and
# silently refuses to add the source. Splitting these two dicts is
# what fixed that.
# ---------------------------------------------------------------------------
SOURCE_META: dict[str, Any] = {
    "name": "Paladala",
    "subtitle": "純淨嘅第三方嗶哩嗶哩 iOS 客戶端 — 自動源",
    "description": (
        "Paladala 嘅官方 AltStore / SideStore 源。每次 push 到 working "
        "分支都會自動出新版本,呢個 apps.json 都會同步更新。"
    ),
    "tintColor": "#FB7299",
    # No source-level iconURL on purpose: per spec it defaults to the
    # first app's iconURL when omitted, so we get the same look without
    # duplicating the URL.
}

APP_META: dict[str, Any] = {
    "name": "Paladala",
    "bundleIdentifier": "com.dt.paladala",
    "developerName": "darrenintr",
    "subtitle": "純淨嘅第三方嗶哩嗶哩 iOS 客戶端",
    "tintColor": "#FB7299",
    "category": "entertainment",
    # PNG, not SVG. iOS UIImage (which both AltStore and SideStore use
    # to load source icons) doesn't support SVG; SideStore rejects the
    # source outright if it can't fetch the icon at add-time. The
    # workflow renders PaladalaMark.svg → icon.png with a brand-pink
    # background so the white stroke reads on AltStore's white UI.
    "iconURL": "https://darrenintr.github.io/pure-bilibili-rethinking/icon.png",
    "localizedDescription": (
        "Paladala 係一個用 SwiftUI 寫嘅第三方嗶哩嗶哩 iOS 客戶端,目標係"
        "「淨」同「快」：\n\n"
        "- 內置 FFmpeg 解冩 DASH 直播流,實時彈幕接力\n"
        "- AVPlayer 全硬件加速播普通視頻,零額外依賴\n"
        "- 完整支援 B 站帳號登入、追番、動態、收藏夾、私訊\n"
        "- 影片可下載到本機離線睇\n"
        "- 對 LiveContainer 友善,塞入 LiveContainer 之後唔佔 iOS 嘅 3 app 側載限額"
    ),
    # `appPermissions` lives inside the App per the AltSource spec.
    # Format: {entitlements: [...], privacy: {...}}. Only entitlements
    # are listed; `privacy` would describe NSUsageDescription keys but
    # Paladala doesn't request any runtime-permission-gated APIs (the
    # LocalHLSProxyServer only opens a loopback port).
    # `get-task-allow` is the debug entitlement Apple injects into
    # debug-signed builds; it's safe to advertise and matches what an
    # unsigned IPAdoesn't actually carry — AltStore only checks this
    # when the user enables "Install Unauthorized Apps".
    "appPermissions": {
        "entitlements": ["get-task-allow"],
    },
    # Empty for now; populate once screenshots are hosted on gh-pages
    # under e.g. screenshots/<name>.png. Per spec, each entry is either
    # a plain URL string (assumed 9:19.5 iPhone portrait) or an object
    # {imageURL, width, height}.
    "screenshots": [],
}


def now_utc_iso() -> str:
    """ISO-8601 UTC timestamp, second precision (e.g. 2026-08-01T12:34:56Z)."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def attach_release_notes(
    versions: list[dict[str, Any]],
    notes_dir: Path,
) -> list[dict[str, Any]]:
    """For each version in `versions`, look up a matching
    `v<version>.<build>.md` file under `notes_dir` and attach the
    file's content as `localizedDescription`.

    The lookup is by `<version>.<buildVersion>` joined with a dot
    (e.g. version=`0.5.2`, buildVersion=`3` → `v0.5.2.3.md`).
    Missing or empty files are skipped silently — the resulting
    entry simply omits `localizedDescription`, which is the
    spec-allowed behaviour for a version with no per-version
    changelog.

    Plan C wires this to a per-CI-run file written from the
    trigger commit's message; future invocations backfill
    historical versions as their files are committed.
    """
    if not notes_dir.is_dir():
        return versions
    out: list[dict[str, Any]] = []
    for v in versions:
        version = str(v.get("version", "")).strip()
        build_version = str(v.get("buildVersion", "")).strip()
        if not version or not build_version:
            out.append(v)
            continue
        notes_file = notes_dir / f"v{version}.{build_version}.md"
        if not notes_file.is_file():
            out.append(v)
            continue
        content = notes_file.read_text(encoding="utf-8").rstrip()
        if not content:
            out.append(v)
            continue
        # Don't clobber a localizedDescription that was already
        # set on the entry (e.g. by the legacy --release-notes
        # CLI flag) — that flag is the explicit human override
        # path and should win over the auto-derived file.
        if "localizedDescription" in v:
            out.append(v)
            continue
        out.append({**v, "localizedDescription": content})
    return out


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
    release_notes_dir: Path | None = None,
) -> dict[str, Any]:
    """Construct the final apps.json per the AltSource schema:

        {
          "name": ..., "subtitle": ..., "tintColor": ...,        ← source
          "apps": [
            {
              "name": ..., "bundleIdentifier": ...,               ← app
              "versions": [{...}, ...]                            ← version
            }
          ],
          "news": [...]
        }

    The latest version is always apps[0].versions[0]; per spec,
    "AltStore uses the order to determine which version is the latest
    release". merge_versions() prepends the new version and
    de-duplicates by buildVersion so re-running for the same
    BUNDLE_VERSION updates the entry in place.
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
    # Legacy per-invocation release notes. Kept for back-compat
    # with manual `python3 generate_apps_json.py` invocations;
    # the iOS CI path uses `release_notes_dir` instead so every
    # historical version, not just the new one, gets a
    # localizedDescription.
    #
    # Per the App Versions spec the per-version changelog field
    # is `localizedDescription`, NOT `releaseNotes` (the docs are
    # explicit on this). Earlier revisions of this script used
    # `releaseNotes` and SideStore silently dropped it.
    if release_notes:
        new_version_entry["localizedDescription"] = release_notes

    new_news_entry: dict[str, Any] = {
        "title": f"{APP_META['name']} {tag}",
        "identifier": tag,
        "caption": f"Build {build_version} ({commit_sha[:7]})",
        "date": iso_now,
        "tintColor": APP_META["tintColor"],
        "url": f"https://github.com/{repo}/releases/tag/{tag}",
        # `appID` ties the news item to the app so AltStore can show
        # the app's info banner under the news card.
        "appID": APP_META["bundleIdentifier"],
    }

    # Top-level (source) — start from SOURCE_META, layer news on top.
    out: dict[str, Any] = dict(SOURCE_META)
    out["news"] = merge_news(list(existing.get("news", [])), new_news_entry)

    # Find our app's existing versions inside the apps[] array (by
    # bundleIdentifier). Any other apps in the source are kept
    # untouched — we never delete apps we didn't add.
    existing_apps = list(existing.get("apps", []))
    our_versions: list[dict[str, Any]] = []
    other_apps: list[dict[str, Any]] = []
    for app in existing_apps:
        if app.get("bundleIdentifier") == APP_META["bundleIdentifier"]:
            our_versions = list(app.get("versions", []))
        else:
            other_apps.append(app)

    # Build the new app entry — APP_META wins for all app-level fields,
    # so editing APP_META in this script takes effect on next push.
    new_app_entry: dict[str, Any] = dict(APP_META)
    new_app_entry["versions"] = merge_versions(our_versions, new_version_entry)

    # Backfill per-version `localizedDescription` from the
    # `release-notes/` directory. Plan C: every CI run writes a
    # `release-notes/v<version>.<build>.md` file derived from the
    # trigger commit's message; this step walks all version
    # entries (new + historical) and attaches the file's content
    # so AltStore / SideStore can render a full version history
    # with a changelog per entry instead of just the latest.
    if release_notes_dir is not None:
        new_app_entry["versions"] = attach_release_notes(
            new_app_entry["versions"], release_notes_dir
        )

    # Reassemble: our app first (AltStore highlights the first app),
    # then any other apps that were previously in the source.
    out["apps"] = [new_app_entry] + other_apps

    # Diagnostic metadata, ignored by AltStore/SideStore. Kept for
    # humans diffing the JSON to see which CI run produced it.
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
        help=(
            "Path to the release notes markdown (optional, legacy). "
            "When set, the file's contents are attached as the NEW "
            "version's `localizedDescription`. The iOS CI path uses "
            "`--release-notes-dir` instead so historical versions "
            "also get per-version changelogs."
        ),
    )
    p.add_argument(
        "--release-notes-dir",
        type=Path,
        default=None,
        help=(
            "Directory containing one `v<version>.<build>.md` file "
            "per release. The script walks every version entry "
            "(new and historical) and attaches the matching file's "
            "content as `localizedDescription`. Missing or empty "
            "files are skipped silently."
        ),
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
        release_notes_dir=args.release_notes_dir,
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
    # With the nested schema, `versions` lives on each App, not at the
    # top level. Sum across apps so the log line still tells the user
    # how many version entries survived the merge.
    total_versions = sum(
        len(a.get("versions", [])) for a in apps_json.get("apps", [])
    )
    print(
        f"Wrote {args.output} "
        f"({len(apps_json.get('apps', []))} app(s), "
        f"{total_versions} version(s), "
        f"{len(apps_json['news'])} news item(s))"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
