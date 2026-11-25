#!/bin/sh
# SPDX-FileCopyrightText: 2026 k0s authors
# SPDX-License-Identifier: Apache-2.0
#
# Tests for update_channel.sh. Runs offline: gh is replaced by a shim that
# serves a fixture release and its sha256sums.txt.
#
#   scripts/update_channel_test.sh

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail=0
ok() { echo "ok: $*"; }
not_ok() { echo "not ok: $*" >&2; fail=1; }

# --- fixture -----------------------------------------------------------------

work=$tmp/work
mkdir -p "$work/scripts" "$tmp/bin" "$tmp/fixture"
cp "$here/update_channel.sh" "$work/scripts/"

# Channels that exist before any run. They must survive untouched.
mkdir -p "$work/stable/v1.27"
echo "channel: stable/v1.27" >"$work/stable/v1.27/index.yaml"

sums=$tmp/fixture/sha256sums.txt
release=$tmp/fixture/release.json

write_fixture() {
	version=$1
	airgap_style=$2
	{
		for arch in amd64 arm64 arm; do
			echo "1111111111111111111111111111111111111111111111111111111111111111  k0s-v$version-$arch"
			if [ "$airgap_style" = long ]; then
				echo "2222222222222222222222222222222222222222222222222222222222222222  k0s-airgap-bundle-v$version-linux-$arch.tar"
			else
				echo "2222222222222222222222222222222222222222222222222222222222222222  k0s-airgap-bundle-v$version-$arch"
			fi
		done
	} >"$sums"
	echo '{"tag_name": "v'"$version"'", "prerelease": false}' >"$release"
}

cat >"$tmp/bin/gh" <<'EOF'
#!/bin/sh
case $1 in
api)
	cat "$FIXTURE/release.json"
	;;
release)
	# gh release download TAG --repo R --pattern P --dir DIR --clobber
	shift
	while [ $# -gt 0 ]; do
		case $1 in
		--dir) dir=$2; shift 2 ;;
		*) shift ;;
		esac
	done
	cp "$FIXTURE/sha256sums.txt" "$dir/sha256sums.txt"
	;;
*)
	echo "shim: unsupported gh call: $*" >&2
	exit 1
	;;
esac
EOF
chmod +x "$tmp/bin/gh"

run() {
	PATH="$tmp/bin:$PATH" FIXTURE="$tmp/fixture" \
		sh "$work/scripts/update_channel.sh" "$@"
}

# --- stable release ----------------------------------------------------------

write_fixture 1.37.2+k0s.1 long
out=$(run 1.37.2+k0s.1) || not_ok "stable run failed"
[ -f "$work/v1.37/stable/index.yaml" ] && ok "writes v1.37/stable" || not_ok "no v1.37/stable"
grep -qx 'channel: v1.37/stable' "$work/v1.37/stable/index.yaml" &&
	ok "channel field matches the path" || not_ok "wrong channel field"
grep -qx 'version: 1.37.2+k0s.1' "$work/v1.37/stable/index.yaml" &&
	ok "version recorded" || not_ok "wrong version"
[ "$(grep -c '^- arch:' "$work/v1.37/stable/index.yaml")" = 3 ] &&
	ok "three architectures" || not_ok "wrong arch count"
grep -q 'releases/download/v1.37.2%2Bk0s.1/k0s-v1.37.2%2Bk0s.1-amd64' "$work/v1.37/stable/index.yaml" &&
	ok "download url quoted" || not_ok "bad download url"
grep -q 'k0sSha256: 1111' "$work/v1.37/stable/index.yaml" &&
	ok "checksum from sha256sums.txt" || not_ok "bad checksum"
grep -q 'k0s-airgap-bundle-v1.37.2%2Bk0s.1-linux-amd64.tar' "$work/v1.37/stable/index.yaml" &&
	ok "long airgap name" || not_ok "airgap name not picked"
[ -f "$work/stable/v1.27/index.yaml" ] && ok "existing channel kept" || not_ok "existing channel deleted"
[ ! -d "$work/latest" ] && ok "latest untouched without --latest" || not_ok "latest written unasked"

rerun=$(run v1.37.2+k0s.1)
case $rerun in
*"unchanged: v1.37/stable/index.yaml"*) ok "rerun is a no-op" ;;
*) not_ok "rerun rewrote the file: $rerun" ;;
esac

# --- latest ------------------------------------------------------------------

run 1.37.2+k0s.1 --latest >/dev/null
grep -qx 'channel: latest/stable' "$work/latest/stable/index.yaml" &&
	ok "latest/stable written" || not_ok "no latest/stable"
grep -qx 'channel: latest' "$work/latest/index.yaml" &&
	ok "latest mirrors latest/stable" || not_ok "no latest"
sed 's/^channel: .*//' "$work/latest/stable/index.yaml" >"$tmp/a"
sed 's/^channel: .*//' "$work/latest/index.yaml" >"$tmp/b"
diff -q "$tmp/a" "$tmp/b" >/dev/null &&
	ok "latest and latest/stable agree on the release" || not_ok "latest drifted"

# --- pre-release -------------------------------------------------------------

write_fixture 1.38.0-rc.1+k0s.0 long
if run 1.38.0-rc.1+k0s.0 2>"$tmp/err"; then
	not_ok "pre-release published without --unstable"
else
	ok "pre-release refused without --unstable"
fi
grep -q 'pass --unstable' "$tmp/err" && ok "error names the fix" || not_ok "unhelpful error: $(cat "$tmp/err")"
[ ! -d "$work/v1.38" ] && ok "nothing written on refusal" || not_ok "wrote a channel anyway"

run 1.38.0-rc.1+k0s.0 --unstable --latest >/dev/null
grep -qx 'channel: v1.38/unstable' "$work/v1.38/unstable/index.yaml" &&
	ok "v1.38/unstable written" || not_ok "no v1.38/unstable"
grep -qx 'channel: latest/unstable' "$work/latest/unstable/index.yaml" &&
	ok "latest/unstable written" || not_ok "no latest/unstable"
grep -qx 'channel: latest/stable' "$work/latest/stable/index.yaml" &&
	ok "stable latest left alone by a pre-release" || not_ok "pre-release moved latest/stable"

# --- old airgap naming -------------------------------------------------------

write_fixture 1.27.8+k0s.0 short
run 1.27.8+k0s.0 >/dev/null
grep -q 'airgapBundle: .*k0s-airgap-bundle-v1.27.8%2Bk0s.0-amd64$' "$work/v1.27/stable/index.yaml" &&
	ok "short airgap name for old releases" || not_ok "wrong airgap name for v1.27"

# --- missing asset -----------------------------------------------------------

write_fixture 1.39.0+k0s.0 long
sed -i '/arm$/d' "$sums"
if run 1.39.0+k0s.0 2>"$tmp/err"; then
	not_ok "published a release with a missing asset"
else
	ok "missing asset is fatal"
fi

exit "$fail"
