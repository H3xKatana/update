#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 k0s authors
# SPDX-License-Identifier: Apache-2.0
"""Regenerate the k0s update channels from GitHub releases.

The update server is served by GitHub Pages from this repository. This script
rewrites the channel directories in place:

    stable/index.yaml           newest stable release
    stable/vMAJOR.MINOR/...     newest stable release of each supported minor
    latest/index.yaml           newest stable release (read by the update prober)
    unstable/index.yaml         newest pre-release

Download URLs and checksums are taken from the release assets and from the
release's sha256sums.txt, so no artifact is downloaded.
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://api.github.com"
RELEASES_REPO = "k0sproject/k0s"
KEEP_MINORS = 4
ARCHES = ("amd64", "arm64", "arm")

ROOT = Path(__file__).resolve().parent.parent
TAG_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?\+k0s\.\d+$")


def api_get(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read()


def fetch_releases() -> list[dict]:
    releases: list[dict] = []
    page = 1
    while True:
        url = f"{API}/repos/{RELEASES_REPO}/releases?per_page=100&page={page}"
        batch = json.loads(api_get(url))
        if not batch:
            return releases
        releases.extend(batch)
        page += 1
        if page > 10:
            raise RuntimeError("refusing to paginate more than 1000 releases")


def version_key(tag: str) -> tuple:
    match = TAG_RE.match(tag)
    if not match:
        raise ValueError(f"unexpected release tag: {tag}")
    major, minor, patch = (int(match.group(i)) for i in (1, 2, 3))
    prerelease = match.group(4)
    if prerelease is None:
        pre: tuple = (1,)
    else:
        pre = (0,) + tuple(
            (0, int(part)) if part.isdigit() else (1, part)
            for part in prerelease.split(".")
        )
    return (major, minor, patch, pre)


def is_prerelease(release: dict) -> bool:
    return bool(release["prerelease"]) or TAG_RE.match(release["tag_name"]).group(4) is not None


def select_channels(releases: list[dict]) -> dict[str, tuple[str, dict]]:
    """Map channel name to (tag, release)."""
    by_tag = {
        release["tag_name"]: release
        for release in releases
        if TAG_RE.match(release["tag_name"])
    }
    stable = [tag for tag in by_tag if not is_prerelease(by_tag[tag])]
    unstable = [tag for tag in by_tag if is_prerelease(by_tag[tag])]

    if not stable:
        raise RuntimeError("no stable releases found")

    stable.sort(key=version_key)
    channels: dict[str, tuple[str, dict]] = {}

    newest = stable[-1]
    channels["stable"] = (newest, by_tag[newest])

    def minor_of(tag: str) -> tuple[int, int]:
        return version_key(tag)[:2]
    supported: list[tuple[int, int]] = []
    for tag in reversed(stable):
        if minor_of(tag) not in supported:
            supported.append(minor_of(tag))
        if len(supported) == KEEP_MINORS:
            break
    for major, minor in supported:
        tag = max((t for t in stable if minor_of(t) == (major, minor)), key=version_key)
        channels[f"stable/v{major}.{minor}"] = (tag, by_tag[tag])

    # The update prober reads "latest". Keep pre-releases out of it so a
    # stable cluster is not notified about an alpha or release candidate.
    channels["latest"] = (newest, by_tag[newest])

    if unstable:
        newest_pre = max(unstable, key=version_key)
        channels["unstable"] = (newest_pre, by_tag[newest_pre])

    return channels


def fetch_checksums(release: dict) -> dict[str, str]:
    assets = {asset["name"]: asset["browser_download_url"] for asset in release["assets"]}
    sums_url = assets.get("sha256sums.txt")
    if sums_url is None:
        raise RuntimeError(f"{release['tag_name']}: no sha256sums.txt asset")
    checksums: dict[str, str] = {}
    for line in api_get(sums_url).decode().splitlines():
        match = re.match(r"^([0-9a-f]{64})\s+\*?(.+)$", line.strip())
        if match:
            checksums[match.group(2)] = match.group(1)
    return checksums


def pick_asset(available: set[str], candidates: list[str]) -> str:
    for candidate in candidates:
        if candidate in available:
            return candidate
    raise RuntimeError(
        f"none of these assets exists: {', '.join(candidates)} "
        f"(available: {', '.join(sorted(available))})"
    )


def build_channel(channel: str, tag: str, release: dict) -> str:
    checksums = fetch_checksums(release)
    available = set(checksums)
    version = tag[1:]  # drop the leading "v"
    quoted_tag = urllib.parse.quote(tag, safe="")

    def url(asset: str) -> str:
        return (
            f"https://github.com/{RELEASES_REPO}/releases/download/"
            f"{quoted_tag}/{urllib.parse.quote(asset, safe='')}"
        )

    lines = [f"channel: {channel}", f"version: {version}", "downloadURLs:"]
    for arch in ARCHES:
        k0s = pick_asset(available, [f"k0s-v{version}-{arch}"])
        airgap = pick_asset(
            available,
            [
                f"k0s-airgap-bundle-v{version}-linux-{arch}.tar",
                f"k0s-airgap-bundle-v{version}-{arch}",
            ],
        )
        lines.extend(
            [
                f"- arch: {arch}",
                "  os: linux",
                f"  k0s: {url(k0s)}",
                f"  k0sSha256: {checksums[k0s]}",
                f"  airgapBundle: {url(airgap)}",
                f"  airgapSha256: {checksums[airgap]}",
            ]
        )
    return "\n".join(lines) + "\n"


def write_if_changed(path: Path, content: str) -> bool:
    if path.exists() and path.read_text() == content:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    print(f"wrote {path.relative_to(ROOT)}")
    return True


def prune_minor_channels(keep: set[str]) -> None:
    stable_dir = ROOT / "stable"
    if not stable_dir.is_dir():
        return
    for child in stable_dir.iterdir():
        if child.is_dir() and f"stable/{child.name}" not in keep:
            for stale in sorted(child.rglob("*"), reverse=True):
                if stale.is_file():
                    stale.unlink()
                else:
                    stale.rmdir()
            child.rmdir()
            print(f"removed stable/{child.name}")


def main() -> int:
    channels = select_channels(fetch_releases())
    for channel, (tag, release) in sorted(channels.items()):
        write_if_changed(ROOT / channel / "index.yaml", build_channel(channel, tag, release))
    prune_minor_channels(set(channels))
    return 0


if __name__ == "__main__":
    sys.exit(main())
