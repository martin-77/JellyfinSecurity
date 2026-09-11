#!/usr/bin/env python3
"""Prepend the two dual-ABI release entries to manifest.json.

Jellyfin 12 moved to .NET 10 and a 10.11-built (net9) DLL will not load on it,
so each release ships TWO builds from one source and BOTH live in this one
manifest under the same plugin GUID:

  * net9  -> version X.Y.Z.0, targetAbi 10.11.0.0   (10.11.x hosts)
  * net10 -> version X.Y.Z.1, targetAbi 12.0.0.0    (12.x hosts)

Jellyfin's catalog keeps every version whose targetAbi <= the host version and
installs the highest, so:

  * a 12 host sees both, picks X.Y.Z.1 (net10);
  * a 10.11 host has X.Y.Z.1 filtered out (12 > 10.11) and gets X.Y.Z.0 (net9).

The distinct 4th octet (rather than one shared version on two entries) makes the
choice deterministic instead of leaning on Jellyfin's undocumented same-version
tie-break (manifest input order). Validated live on jellyfin/jellyfin:12.0.

The net10 zip keeps the base X.Y.Z.0 filename with a `-jf12` suffix (so the
release-page asset is human-obvious and release.yml's upload glob still catches
it); only its *internal* meta/assembly version and this manifest entry carry the
.1. build.sh does the .1 stamp on the net10 package.

Run this AFTER build.sh has produced both zips in dist/ (the workflow also
writes the .md5 sidecars this reads). It edits manifest.json in place; commit
the result yourself -- publishing stays a deliberate, manual step.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CSPROJ = REPO / "src" / "Jellyfin.Plugin.TwoFactorAuth" / "Jellyfin.Plugin.TwoFactorAuth.csproj"
MANIFEST = REPO / "manifest.json"
DIST = REPO / "dist"
GUID = "94879a0c-da24-4eb1-aa06-f28b4b9333b1"
ABI_NET9 = "10.11.0.0"
ABI_NET10 = "12.0.0.0"
RELEASE_BASE = "https://github.com/ZL154/JellyfinSecurity/releases/download"


def read_base_version() -> str:
    m = re.search(r"<Version>([^<]+)</Version>", CSPROJ.read_text(encoding="utf-8"))
    if not m:
        sys.exit("Could not read <Version> from the csproj.")
    v = m.group(1).strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+\.0", v):
        sys.exit(f"Expected a canonical X.Y.Z.0 source version, got {v!r}. "
                 "The net10 build derives X.Y.Z.1 from this.")
    return v


def jf12_version(base: str) -> str:
    # X.Y.Z.0 -> X.Y.Z.1 (mirrors the sed in build.sh)
    return re.sub(r"\.\d+$", ".1", base)


def tag_for(base: str) -> str:
    # release.yml strips a single trailing .0 to build the tag (2.6.0.0 -> v2.6.0)
    return "v" + re.sub(r"\.0$", "", base)


def checksum(zip_path: Path) -> str:
    md5_sidecar = zip_path.with_suffix(zip_path.suffix + ".md5")
    # release.yml writes an uppercase md5 sidecar; prefer it, else compute.
    for cand in (zip_path.with_name(zip_path.name).with_suffix(".md5"), md5_sidecar):
        if cand.exists():
            return cand.read_text(encoding="utf-8").strip().split()[0].upper()
    if not zip_path.exists():
        sys.exit(f"Zip not found and no .md5 sidecar: {zip_path}")
    return hashlib.md5(zip_path.read_bytes()).hexdigest().upper()


def load_changelog(base: str, override: str | None, override_file: str | None) -> str:
    if override:
        return override
    if override_file:
        return Path(override_file).read_text(encoding="utf-8").strip()
    # Default: docs/release-notes/v<X.Y.Z>.md (the tag form), else v<base>.md
    tag = tag_for(base)
    for cand in (REPO / "docs" / "release-notes" / f"{tag}.md",
                 REPO / "docs" / "release-notes" / f"v{base}.md"):
        if cand.exists():
            return cand.read_text(encoding="utf-8").strip()
    sys.exit("No changelog: pass --changelog / --changelog-file, or add "
             f"docs/release-notes/{tag_for(base)}.md")


def make_entry(version: str, abi: str, zip_name: str, tag: str,
               chk: str, changelog: str, ts: str) -> dict:
    # Field order mirrors the existing entries for a clean diff.
    return {
        "version": version,
        "changelog": changelog,
        "targetAbi": abi,
        "sourceUrl": f"{RELEASE_BASE}/{tag}/{zip_name}",
        "checksum": chk,
        "timestamp": ts,
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--changelog", help="Changelog text for both entries.")
    ap.add_argument("--changelog-file", help="File to read the changelog from.")
    ap.add_argument("--dry-run", action="store_true",
                    help="Print the two entries; do not write manifest.json.")
    args = ap.parse_args()

    base = read_base_version()          # X.Y.Z.0  (net9 / 10.11)
    jf12 = jf12_version(base)           # X.Y.Z.1  (net10 / 12)
    tag = tag_for(base)                 # vX.Y.Z
    ts = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    net9_zip = f"Jellyfin.Plugin.TwoFactorAuthv{base}.zip"
    net10_zip = f"Jellyfin.Plugin.TwoFactorAuthv{base}-jf12.zip"
    chk_net9 = checksum(DIST / net9_zip)
    chk_net10 = checksum(DIST / net10_zip)
    changelog = load_changelog(base, args.changelog, args.changelog_file)

    # net10 first (higher version = newest), then net9, above the prior newest.
    entry_net10 = make_entry(jf12, ABI_NET10, net10_zip, tag, chk_net10, changelog, ts)
    entry_net9 = make_entry(base, ABI_NET9, net9_zip, tag, chk_net9, changelog, ts)

    # Duplicate guard: parse the JSON only to check we are not re-adding an
    # entry. We do NOT re-serialize the whole file -- the existing manifest
    # mixes \\uXXXX escapes and literal UTF-8 across its accreted entries, so a
    # full re-dump would reformat every line and bury this change. Instead we
    # insert the two new entries textually and leave every existing byte intact.
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    plugin = next((p for p in manifest
                   if p.get("guid", "").replace("-", "").lower() == GUID.replace("-", "")), None)
    if plugin is None:
        sys.exit("Plugin GUID not found in manifest.json.")
    existing = {(v.get("version"), v.get("targetAbi")) for v in plugin["versions"]}
    for e in (entry_net10, entry_net9):
        if (e["version"], e["targetAbi"]) in existing:
            sys.exit(f"Entry already present: {e['version']} / {e['targetAbi']}. Aborting.")

    # Serialize each entry and re-indent to the versions-array item level:
    # json.dumps(indent=2) puts the object brace at column 0 and keys at 2; add
    # 6 spaces to every line so the brace lands at 6 and keys at 8, matching the
    # surrounding entries exactly.
    def block(entry: dict) -> str:
        raw = json.dumps(entry, indent=2, ensure_ascii=False)
        return "\n".join("      " + ln for ln in raw.splitlines())

    insertion = block(entry_net10) + ",\n" + block(entry_net9) + ",\n"

    if args.dry_run:
        print(insertion)
        print(f"\n(dry-run) would insert the two entries above after the "
              f'"versions": [ line in {MANIFEST}', file=sys.stderr)
        return

    lines = MANIFEST.read_text(encoding="utf-8").splitlines(keepends=True)
    for i, ln in enumerate(lines):
        if ln.strip() == '"versions": [':
            lines.insert(i + 1, insertion)
            break
    else:
        sys.exit('Could not find the \'"versions": [\' line to insert after.')
    MANIFEST.write_text("".join(lines), encoding="utf-8")

    # Re-parse to prove the edit produced valid JSON with the entries on top.
    check = json.loads(MANIFEST.read_text(encoding="utf-8"))
    top = check[0]["versions"][:2]
    assert [(t["version"], t["targetAbi"]) for t in top] == \
        [(jf12, ABI_NET10), (base, ABI_NET9)], "post-write ordering check failed"
    print(f"Prepended {jf12}/abi-{ABI_NET10} and {base}/abi-{ABI_NET9} to {MANIFEST.name}")
    print(f"  net9  {chk_net9}  {net9_zip}")
    print(f"  net10 {chk_net10}  {net10_zip}")


if __name__ == "__main__":
    main()
