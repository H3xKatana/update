#!/bin/sh
# SPDX-FileCopyrightText: 2026 k0s authors
# SPDX-License-Identifier: Apache-2.0
#
# Update the update channels for one k0s release.
#
#   scripts/update_channel.sh VERSION [--latest] [--unstable]
#
# VERSION is a k0s release version, with or without the leading "v"
# (1.37.2+k0s.1 or v1.37.2+k0s.1).
#
# The version decides the channel. A release without a pre-release suffix goes
# to vX.Y/stable. A pre-release goes to vX.Y/unstable, and only when --unstable
# is given, so a pre-release cannot reach a stable channel by accident.
#
# --latest also moves latest/stable for a stable release, or latest/unstable for
# a pre-release. latest/stable is mirrored to latest, which released k0s
# versions read for their update notifications.
#
# Existing channels are never rewritten or removed. Dropping a channel is a
# separate decision, not a side effect of publishing a release.

set -eu

RELEASES_REPO=k0sproject/k0s
ARCHES="amd64 arm64 arm"

die() {
	echo "error: $*" >&2
	exit 1
}

version=
latest=false
unstable=false

for arg in "$@"; do
	case $arg in
	--latest) latest=true ;;
	--unstable) unstable=true ;;
	-*) die "unknown option: $arg" ;;
	*)
		[ -z "$version" ] || die "version given twice"
		version=${arg#v}
		;;
	esac
done

[ -n "$version" ] || die "usage: update_channel.sh VERSION [--latest] [--unstable]"
case $version in
[0-9]*.[0-9]*.[0-9]*) ;;
*) die "not a k0s version: $version" ;;
esac

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tag=v$version
minor=$(printf '%s' "$version" | cut -d. -f1,2)
qtag=$(printf '%s' "$tag" | sed 's/+/%2B/g')
base_url=https://github.com/$RELEASES_REPO/releases/download/$qtag

prerelease=false
case $version in *-*) prerelease=true ;; esac

if [ "$prerelease" = true ]; then
	[ "$unstable" = true ] ||
		die "$tag is a pre-release, pass --unstable to publish v$minor/unstable"
	channel=v$minor/unstable
	latest_channel=latest/unstable
else
	channel=v$minor/stable
	latest_channel=latest/stable
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

gh api "repos/$RELEASES_REPO/releases/tags/$tag" >"$tmp/release.json" ||
	die "no release $tag in $RELEASES_REPO"

gh release download "$tag" --repo "$RELEASES_REPO" \
	--pattern sha256sums.txt --dir "$tmp" --clobber 2>/dev/null ||
	die "$tag publishes no sha256sums.txt asset"
sums=$tmp/sha256sums.txt

# sha256 of one asset, empty when the release does not publish it. The star is
# the binary-mode marker some tools write; both forms name the same file.
sha() {
	awk -v want="$1" '$2 == want || $2 == "*" want { print $1; exit }' "$sums"
}

# URL of one release asset. Both the tag and the asset name carry a "+",
# which is legal in a path segment but is quoted here to match the files that
# are already published.
url() {
	printf '%s/%s' "$base_url" "$(printf '%s' "$1" | sed 's/+/%2B/g')"
}

# emit PATH NAME: write PATH/index.yaml unless it already has this content.
emit() {
	path=$1
	name=$2
	dest=$root/$path/index.yaml

	{
		printf '%s\n' "channel: $name" "version: $version" "downloadURLs:"
		for arch in $ARCHES; do
			bin=k0s-v$version-$arch
			# v1.36 renamed the airgap bundle; older releases still use the
			# short name. Pick whichever the release actually publishes.
			airgap=k0s-airgap-bundle-v$version-linux-$arch.tar
			[ -n "$(sha "$airgap")" ] || airgap=k0s-airgap-bundle-v$version-$arch

			bin_sha=$(sha "$bin")
			[ -n "$bin_sha" ] || die "$tag publishes no $bin"
			airgap_sha=$(sha "$airgap")
			[ -n "$airgap_sha" ] || die "$tag publishes no airgap bundle for $arch"

			printf '%s\n' \
				"- arch: $arch" \
				"  os: linux" \
				"  k0s: $(url "$bin")" \
				"  k0sSha256: $bin_sha" \
				"  airgapBundle: $(url "$airgap")" \
				"  airgapSha256: $airgap_sha"
		done
	} >"$tmp/index.yaml"

	mkdir -p "$root/$path"
	if cmp -s "$tmp/index.yaml" "$dest"; then
		echo "unchanged: $path/index.yaml"
	else
		cp "$tmp/index.yaml" "$dest"
		echo "updated: $path/index.yaml"
	fi
}

emit "$channel" "$channel"

if [ "$latest" = true ]; then
	emit "$latest_channel" "$latest_channel"
	# latest is what released k0s versions read, and it means the stable one.
	if [ "$latest_channel" = latest/stable ]; then
		emit latest latest
	fi
fi
