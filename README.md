# k0s Update Server - Reference implementation

This repo serves as k0s update server reference implementation. It provides the basic channels descriptions that is expected from an update server.

## Available channels

- stable
- stable/v1.27
- stable/v1.28
- stable/v1.29

## Channel "protocol"


When autopilot is configred to use a channel called `some-channel`, it will request the information from following URL `<update-server-address/<channel>/index.yaml`
Essentially k0s autopilot assumes the folowing structure for update channels:

```text
<channel-name>/
    index.yaml
```

Each the channel name can contain e.g. forward slashes so you can structure the channels for example like so:

```text
stable/v1.28/
    index.yaml
unstable/v1.28/
    index.yaml
```

Each channel `index.yaml` need to provide following information:

```yaml
channel: v1.27
eolDate: "2024-06-28"
version: 1.27.8+k0s.0
downloadURLs:
- arch: amd64
  os: linux
  k0s: https://github.com/k0sproject/k0s/releases/download/v1.27.0%2Bk0s.0/k0s-v1.27.0+k0s.0-amd64
  k0sSha256: deadbeef
  airgapBundle: someurlhere
  airgapSha256: deadbeef
- arch: arm64
  os: linux
  url: https://github.com/k0sproject/k0s/releases/download/v1.27.0%2Bk0s.0/k0s-v1.27.0+k0s.0-arm64
- arch: arm
  os: linux
  url: https://github.com/k0sproject/k0s/releases/download/v1.27.0%2Bk0s.0/k0s-v1.27.0+k0s.0-arm
- arch: amd64
  os: windows
  url: https://github.com/k0sproject/k0s/releases/download/v1.27.0%2Bk0s.0/k0s-v1.27.0+k0s.0-amd64.exe
```

So each channel can offer only single version to k0s autopilot client. In general the design pattern here is that each major.minor version will have their own channel where the latest patch release is offered.

## Automation

`.github/workflows/update-channels.yml` updates the channel files for a single
k0s release. The k0s repository calls it when a release is published. It also
runs from the Actions tab or from the CLI:

```shell
gh workflow run update-channels.yml -f version=1.37.2+k0s.1
```

The workflow runs `scripts/update_channel.sh`. The version is the only required
input, because the version decides the rest:

- `1.37.2+k0s.1` writes `v1.37/stable`
- `1.38.0-rc.1+k0s.0` writes `v1.38/unstable`, and only when asked for
- `--latest` also writes `latest/stable`, or `latest/unstable` for a pre-release
- `latest` follows `latest/stable`

A final release also moves `vX.Y/unstable` and `latest/unstable` when those
channels already exist, because both mean "newest release of that line,
pre-releases included". Without that, a channel would stay on an older release
candidate for good. A run never creates a channel the release does not belong
to, and never deletes one.

URLs and checksums come from the release asset list and its `sha256sums.txt`, so
no k0s binary or airgap bundle is downloaded. Airgap bundle names changed in
v1.36, so the script picks the name the release publishes. A release that is
missing any asset, or whose release metadata disagrees with the version string,
is refused before a single file is written.

The workflow opens a pull request on a `channel/k0s-<version>` branch and leaves
the merge to a human. It never pushes to `main` and never deletes a channel.
Re-dispatching the same release updates that branch and its pull request.

The script needs only `sh`, `gh`, `awk`, `sed` and `cmp`, so it runs offline
against fixtures: `sh scripts/update_channel_test.sh`.
