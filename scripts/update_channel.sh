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
# is given, so a pre-release cannot reach a stable channel by accident. The
# release metadata is consulted as well, so a version string that disagrees with
# the release itself is refused instead of guessing.
#
# A final release also moves vX.Y/unstable and latest/unstable when those
# channels already exist. They mean "newest release of X.Y, pre-releases
# included", so the final release belongs there too, and the alternative is a
# channel stuck on an older release candidate.
#
# --latest also moves latest/stable for a final release, or latest/unstable for
# a pre-release. latest/stable is mirrored to latest, which released k0s
# versions read for their update notifications.
#
# Channels are never removed. A run creates only the channels this release
# belongs to, and it writes nothing at all when any asset it needs is missing.

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

# Split MAJOR.MINOR.PATCH; PATCH may carry -pre-release or +build metadata. A
# glob alone would also accept 1.2.evil, so each field is checked for digits.
# This runs before anything is fetched or written.
core=${version%%[-+]*}
major=${core%%.*}
rest=${core#*.}
minor=${rest%%.*}
patch=${rest#*.}
case $core in
*.*.*) ;;
*) die "not a k0s version: $version" ;;
esac
for field in "$major" "$minor" "$patch"; do
	case $field in
	'' | *[!0-9]*) die "not a k0s version: $version" ;;
	esac
done
minor_version=$major.$minor

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tag=v$version
qtag=$(printf '%s' "$tag" | sed 's/+/%2B/g')
base_url=https://github.com/$RELEASES_REPO/releases/download/$qtag

prerelease=false
case $version in *-*) prerelease=true ;; esac

if [ "$prerelease" = true ]; then
	[ "$unstable" = true ] ||
		die "$tag is a pre-release, pass --unstable to publish v$minor_version/unstable"
	channel=v$minor_version/unstable
	latest_channel=latest/unstable
else
	channel=v$minor_version/stable
	latest_channel=latest/stable
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

gh api "repos/$RELEASES_REPO/releases/tags/$tag" >"$tmp/release.json" ||
	die "no release $tag in $RELEASES_REPO"

# The release says what it is. A disagreement with the version string is a hard
# stop: picking the channel from a mistyped version is how a pre-release ends up
# in a stable channel.
if grep -q '"prerelease":[[:space:]]*true' "$tmp/release.json"; then
	release_prerelease=true
else
	release_prerelease=false
fi
[ "$prerelease" = "$release_prerelease" ] ||
	die "$RELEASES_REPO reports prerelease=$release_prerelease for $tag, but the version string says prerelease=$prerelease"

gh release download "$tag" --repo "$RELEASES_REPO" \
	--pattern sha256sums.txt --dir "$tmp" --clobber 2>/dev/null ||
	die "$tag publishes no sha256sums.txt asset"
sums=$tmp/sha256sums.txt

# sha256 of one asset, empty when the release does not publish it. The star is
# the binary-mode marker sha256sum writes; both forms name the same file.
sha() {
	awk -v want="$1" '$2 == want || $2 == "*" want { print $1; exit }' "$sums"
}

# URL of one release asset. Both the tag and the asset name carry a "+",
# which is legal in a path segment but is quoted here to match the files that
# are already published.
url() {
	printf '%s/%s' "$base_url" "$(printf '%s' "$1" | sed 's/+/%2B/g')"
}

# Resolve every asset before writing anything, so a release with a missing
# asset leaves the working tree untouched instead of half updated.
: >"$tmp/body.yaml"
for arch in $ARCHES; do
	bin=k0s-v$version-$arch
	# v1.36 renamed the airgap bundle; older releases still use the short
	# name. Pick whichever the release actually publishes.
	airgap=k0s-airgap-bundle-v$version-linux-$arch.tar
	[ -n "$(sha "$airgap")" ] || airgap=k0s-airgap-bundle-v$version-$arch

	bin_sha=$(sha "$bin")
	[ -n "$bin_sha" ] || die "$tag publishes no $bin"
	airgap_sha=$(sha "$airgap")
	[ -n "$airgap_sha" ] || die "$tag publishes no $airgap"

	{
		printf '%s\n' \
			"- arch: $arch" \
			"  os: linux" \
			"  k0s: $(url "$bin")" \
			"  k0sSha256: $bin_sha" \
			"  airgapBundle: $(url "$airgap")" \
			"  airgapSha256: $airgap_sha"
	} >>"$tmp/body.yaml"
done

# emit PATH: write PATH/index.yaml unless it already has this content.
emit() {
	channel_path=$1
	dest=$root/$channel_path/index.yaml

	{
		printf '%s\n' "channel: $channel_path" "version: $version" "downloadURLs:"
		cat "$tmp/body.yaml"
	} >"$tmp/index.yaml"

	mkdir -p "$root/$channel_path"
	if cmp -s "$tmp/index.yaml" "$dest"; then
		echo "unchanged: $channel_path/index.yaml"
	else
		cp "$tmp/index.yaml" "$dest"
		echo "updated: $channel_path/index.yaml"
	fi
}

emit "$channel"

if [ "$prerelease" = false ]; then
	# The final release is newer than any candidate these channels may hold.
	if [ -d "$root/v$minor_version/unstable" ]; then
		emit "v$minor_version/unstable"
	fi
fi

if [ "$latest" = true ]; then
	emit "$latest_channel"
	# latest is what released k0s versions read, and it means the stable one.
	if [ "$latest_channel" = latest/stable ]; then
		emit latest
		if [ -d "$root/latest/unstable" ]; then
			emit latest/unstable
		fi
	fi
fi
