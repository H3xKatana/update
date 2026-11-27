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

# Knobs for write_fixture, reset on every call so a test cannot leak them.
marker='*' # sha256sum binary-mode marker; a single space writes the plain form
omit=''    # one asset to leave out: bin-arm, airgap-arm

write_fixture() {
	version=$1
	airgap_style=$2
	pre=$3
	{
		for arch in amd64 arm64 arm; do
			[ "$omit" = "bin-$arch" ] ||
				printf '%s %s%s\n' 1111111111111111111111111111111111111111111111111111111111111111 \
					"$marker" "k0s-v$version-$arch"
			[ "$omit" = "airgap-$arch" ] && continue
			if [ "$airgap_style" = long ]; then
				name=k0s-airgap-bundle-v$version-linux-$arch.tar
			else
				name=k0s-airgap-bundle-v$version-$arch
			fi
			printf '%s %s%s\n' 2222222222222222222222222222222222222222222222222222222222222222 \
				"$marker" "$name"
		done
	} >"$sums"
	echo '{"tag_name": "v'"$version"'", "prerelease": '"$pre"'}' >"$release"
	marker='*'
	omit=''
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

# --- usage and validation ----------------------------------------------------

if run 2>"$tmp/err"; then
	not_ok "ran without a version"
else
	ok "no version is refused"
fi
grep -q 'usage:' "$tmp/err" && ok "usage error names the usage" || not_ok "unhelpful usage error"

if run 1.2.3 --bogus 2>"$tmp/err"; then
	not_ok "accepted an unknown option"
else
	ok "unknown option is refused"
fi

if run 1.2.3 1.2.4 2>"$tmp/err"; then
	not_ok "accepted two versions"
else
	ok "two versions are refused"
fi

for bad in 1.2 1.2.evil 1.2.3.4 pre1.2.3 1..3 1.2.; do
	if run "$bad" 2>"$tmp/err"; then
		not_ok "accepted version $bad"
	else
		grep -q 'not a k0s version' "$tmp/err" && ok "rejects version $bad" ||
			not_ok "wrong error for $bad: $(cat "$tmp/err")"
	fi
done
[ ! -d "$work/v1.2" ] && ok "no channel written for a bad version" || not_ok "wrote a channel for a bad version"

# --- final release -----------------------------------------------------------

write_fixture 1.37.2+k0s.1 long false
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
grep -q 'k0s-v1.37.2%2Bk0s.1-amd64$' "$work/v1.37/stable/index.yaml" &&
	ok "binary url is the bare asset name" || not_ok "binary url drifted"
grep -q 'k0s-airgap-bundle-v1.37.2%2Bk0s.1-linux-amd64.tar' "$work/v1.37/stable/index.yaml" &&
	ok "long airgap name" || not_ok "airgap name not picked"
grep -q 'airgapSha256: 2222' "$work/v1.37/stable/index.yaml" &&
	ok "airgap checksum recorded" || not_ok "bad airgap checksum"
[ -f "$work/stable/v1.27/index.yaml" ] && ok "existing channel kept" || not_ok "existing channel deleted"
[ ! -d "$work/latest" ] && ok "latest untouched without --latest" || not_ok "latest written unasked"
[ ! -d "$work/v1.37/unstable" ] && ok "no unstable channel created unasked" || not_ok "created v1.37/unstable"

rerun=$(run v1.37.2+k0s.1)
case $rerun in
*"unchanged: v1.37/stable/index.yaml"*) ok "rerun is a no-op" ;;
*) not_ok "rerun rewrote the file: $rerun" ;;
esac

# A later patch release replaces the version in an existing channel.
write_fixture 1.37.3+k0s.0 long false
run 1.37.3+k0s.0 >/dev/null
grep -qx 'version: 1.37.3+k0s.0' "$work/v1.37/stable/index.yaml" &&
	ok "existing vX.Y/stable advances to a newer patch" || not_ok "v1.37/stable did not advance"

# sha256sum.txt without the binary-mode star must parse the same way. A single
# space in the marker knob gives the two-space plain format.
marker=' '
write_fixture 1.37.4+k0s.0 long false
run 1.37.4+k0s.0 >/dev/null
grep -q 'k0sSha256: 1111' "$work/v1.37/stable/index.yaml" &&
	ok "checksum parsed without the star marker" || not_ok "star-less sums not parsed"

# --- latest ------------------------------------------------------------------

write_fixture 1.37.5+k0s.0 long false
run 1.37.5+k0s.0 --latest >/dev/null
grep -qx 'channel: latest/stable' "$work/latest/stable/index.yaml" &&
	ok "latest/stable written" || not_ok "no latest/stable"
grep -qx 'channel: latest' "$work/latest/index.yaml" &&
	ok "latest mirrors latest/stable" || not_ok "no latest"
sed 's/^channel: .*//' "$work/latest/stable/index.yaml" >"$tmp/a"
sed 's/^channel: .*//' "$work/latest/index.yaml" >"$tmp/b"
diff -q "$tmp/a" "$tmp/b" >/dev/null &&
	ok "latest and latest/stable agree on the release" || not_ok "latest drifted"
[ ! -d "$work/latest/unstable" ] && ok "a final release does not invent latest/unstable" ||
	not_ok "created latest/unstable unasked"

# --- pre-release -------------------------------------------------------------

write_fixture 1.38.0-rc.1+k0s.0 long true
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
grep -qx 'version: 1.37.5+k0s.0' "$work/latest/stable/index.yaml" &&
	ok "stable latest left alone by a pre-release" || not_ok "pre-release moved latest/stable"
[ ! -d "$work/v1.38/stable" ] && ok "pre-release did not create v1.38/stable" ||
	not_ok "pre-release created a stable channel"

# A version string that claims to be final while the release is a candidate
# must not reach a stable channel.
write_fixture 1.38.1-rc.1+k0s.0 long true
if run 1.38.1-rc.1+k0s.0 --unstable >/dev/null 2>"$tmp/err"; then
	ok "candidate with a matching release metadata is published"
else
	not_ok "refused a well-formed candidate: $(cat "$tmp/err")"
fi
write_fixture 1.38.2+k0s.0 long true
if run 1.38.2+k0s.0 2>"$tmp/err"; then
	not_ok "published a release the metadata marks as a pre-release to a stable channel"
else
	ok "release metadata outvotes a final-looking version string"
fi
grep -q 'prerelease' "$tmp/err" && ok "metadata error is explicit" || not_ok "unhelpful metadata error"

# --- final release advances the candidate channels ---------------------------

write_fixture 1.38.3+k0s.0 long false
run 1.38.3+k0s.0 --latest >/dev/null
grep -qx 'version: 1.38.3+k0s.0' "$work/v1.38/unstable/index.yaml" &&
	ok "vX.Y/unstable advances to the final release" || not_ok "v1.38/unstable stayed on the candidate"
grep -qx 'version: 1.38.3+k0s.0' "$work/latest/unstable/index.yaml" &&
	ok "latest/unstable advances to the final release" || not_ok "latest/unstable stayed on the candidate"
grep -qx 'channel: v1.38/stable' "$work/v1.38/stable/index.yaml" &&
	ok "vX.Y/stable created for the final release" || not_ok "no v1.38/stable"
[ -f "$work/v1.38/stable/index.yaml" ] && [ -f "$work/v1.38/unstable/index.yaml" ] &&
	ok "candidate channel is kept, not deleted" || not_ok "candidate channel lost"

# --- old airgap naming -------------------------------------------------------

write_fixture 1.27.8+k0s.0 short false
run 1.27.8+k0s.0 >/dev/null
grep -q 'airgapBundle: .*k0s-airgap-bundle-v1.27.8%2Bk0s.0-amd64$' "$work/v1.27/stable/index.yaml" &&
	ok "short airgap name for old releases" || not_ok "wrong airgap name for v1.27"

# --- missing assets ----------------------------------------------------------

omit=bin-arm
write_fixture 1.39.0+k0s.0 long false
if run 1.39.0+k0s.0 2>"$tmp/err"; then
	not_ok "published a release with a missing binary"
else
	ok "missing binary is fatal"
fi
grep -q 'k0s-v1.39.0+k0s.0-arm' "$tmp/err" && ok "error names the missing binary" ||
	not_ok "unhelpful missing-binary error: $(cat "$tmp/err")"
[ ! -d "$work/v1.39" ] && ok "nothing written when a binary is missing" || not_ok "wrote a half channel"

omit=airgap-arm
write_fixture 1.39.1+k0s.0 long false
if run 1.39.1+k0s.0 2>"$tmp/err"; then
	not_ok "published a release with a missing airgap bundle"
else
	ok "missing airgap bundle is fatal"
fi
grep -q 'airgap' "$tmp/err" && ok "error names the missing airgap bundle" ||
	not_ok "unhelpful missing-airgap error: $(cat "$tmp/err")"

# A missing asset on a run that would also move an existing channel must leave
# that channel alone.
before=$(cat "$work/v1.38/stable/index.yaml")
omit=airgap-amd64
write_fixture 1.38.9+k0s.0 long false
if run 1.38.9+k0s.0 --latest 2>/dev/null; then
	not_ok "published despite a missing asset"
else
	ok "missing asset aborts a multi-channel run"
fi
[ "$(cat "$work/v1.38/stable/index.yaml")" = "$before" ] &&
	ok "no channel is half updated" || not_ok "v1.38/stable was rewritten before the failure"

exit "$fail"
