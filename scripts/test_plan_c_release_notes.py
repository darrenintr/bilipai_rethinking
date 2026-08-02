"""Smoke test for generate_apps_json.py with --release-notes-dir.

Run from the repo root:

    PYTHONIOENCODING=utf-8 python scripts/test_plan_c_release_notes.py

The script builds a synthetic previous apps.json + a release-notes/
directory, then runs generate_apps_json.py in --dry-run mode and
asserts the expected per-version localizedDescription backfill.

This is a Plan C integration check — every entry that has a matching
`v<version>.<build>.md` file under release-notes/ should end up with
its content as `localizedDescription`; entries with no file (or an
empty file) should be left without the field.
"""
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def run_test() -> int:
    test_dir = Path(tempfile.mkdtemp(prefix="paladala-plan-c-"))
    try:
        notes_dir = test_dir / "release-notes"
        notes_dir.mkdir()
        (notes_dir / "v0.5.2.3.md").write_text(
            "iPad sidebar + profile user card iOS Native\n",
            encoding="utf-8",
        )
        (notes_dir / "v0.5.1.2.md").write_text(
            "polished about screen\n- new identifier row\n- fix crash on dark mode",
            encoding="utf-8",
        )
        # v0.5.0.1 exists but is empty — should be skipped.
        (notes_dir / "v0.5.0.1.md").write_text("", encoding="utf-8")
        # v0.4.9.99 has NO file at all — should also be skipped.

        prev = {
            "name": "Paladala",
            "apps": [
                {
                    "name": "Paladala",
                    "bundleIdentifier": "com.dt.paladala",
                    "versions": [
                        {
                            "version": "0.5.1",
                            "buildVersion": "2",
                            "date": "2026-07-15T00:00:00Z",
                            "size": 1,
                            "downloadURL": "https://x/v0.5.1.2.ipa",
                        },
                        {
                            "version": "0.5.0",
                            "buildVersion": "1",
                            "date": "2026-07-01T00:00:00Z",
                            "size": 1,
                            "downloadURL": "https://x/v0.5.0.1.ipa",
                        },
                        {
                            "version": "0.4.9",
                            "buildVersion": "99",
                            "date": "2026-06-01T00:00:00Z",
                            "size": 1,
                            "downloadURL": "https://x/v0.4.9.99.ipa",
                        },
                    ],
                }
            ],
            "news": [],
        }
        prev_file = test_dir / "apps.json"
        prev_file.write_text(json.dumps(prev, indent=2), encoding="utf-8")

        ipa_file = test_dir / "empty.ipa"
        ipa_file.write_bytes(b"x" * 10)

        out_file = test_dir / "out.json"
        script = (
            Path(__file__).resolve().parent.parent
            / "scripts"
            / "generate_apps_json.py"
        )
        env = {
            "TAG": "v0.5.2.3",
            "BUNDLE_VERSION": "3",
            "MARKET_VERSION": "0.5.2",
            "GITHUB_REPOSITORY": "darrenintr/pure-bilibili-rethinking",
            "GITHUB_SHA": "deadbeef0001",
            "GITHUB_RUN_ID": "999",
            "GITHUB_RUN_NUMBER": "999",
            "PYTHONIOENCODING": "utf-8",
        }
        r = subprocess.run(
            [
                sys.executable,
                str(script),
                "--existing", str(prev_file),
                "--release-notes-dir", str(notes_dir),
                "--ipa-path", str(ipa_file),
                "--output", str(out_file),
            ],
            env=env,
            capture_output=True,
            text=True,
        )
        if r.returncode != 0:
            print("STDOUT:", r.stdout)
            print("STDERR:", r.stderr)
            return 1

        # Read the produced apps.json instead of stdout to side-step
        # Windows console-codepage mangling of UTF-8 JSON in cp1252
        # shells. macos-15 (the CI runner) doesn't have this problem.
        out = json.loads(out_file.read_text(encoding="utf-8"))
        versions = out["apps"][0]["versions"]
        print(f"Versions in output: {len(versions)}")
        for v in versions:
            has_desc = "localizedDescription" in v
            preview = v.get("localizedDescription", "<missing>")[:50]
            print(
                f"  v{v['version']}.{v['buildVersion']:>2}: "
                f"desc={has_desc!s:5}  preview={preview!r}"
            )

        # Find each version entry by version+build.
        def find(v: str, b: str) -> dict:
            for entry in versions:
                if entry["version"] == v and entry["buildVersion"] == b:
                    return entry
            raise AssertionError(f"v{v}.{b} not found")

        checks = [
            (
                "v0.5.2.3 (new) gets description from matching file",
                find("0.5.2", "3").get("localizedDescription", "")
                == "iPad sidebar + profile user card iOS Native",
            ),
            (
                "v0.5.1.2 (historical) backfilled",
                "fix crash" in find("0.5.1", "2").get("localizedDescription", ""),
            ),
            (
                "v0.5.0.1 (empty file) skipped",
                "localizedDescription" not in find("0.5.0", "1"),
            ),
            (
                "v0.4.9.99 (no file) skipped",
                "localizedDescription" not in find("0.4.9", "99"),
            ),
            (
                "historical ordering preserved (0.5.1.2 before 0.5.0.1 before 0.4.9.99)",
                (
                    versions[0]["buildVersion"] == "3"
                    and versions[1]["buildVersion"] == "2"
                    and versions[2]["buildVersion"] == "1"
                    and versions[3]["buildVersion"] == "99"
                ),
            ),
        ]
        all_ok = True
        for name, ok in checks:
            print(f"  [{'OK' if ok else 'FAIL'}] {name}")
            all_ok = all_ok and ok
        return 0 if all_ok else 1
    finally:
        shutil.rmtree(test_dir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(run_test())
