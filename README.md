# k0s Update Server - Reference implementation

This repo serves as k0s update server reference implementation. It provides the basic channels descriptions that is expected from an update server.

## Available channels

| Channel | Content |
|---|---|
| `vX.Y/stable` | Highest released version of minor version X.Y, excluding pre-releases |
| `vX.Y/unstable` | Highest released version of minor version X.Y, including pre-releases |
| `latest/stable` | Highest released version, excluding pre-releases |
| `latest/unstable` | Highest released version, including pre-releases |
| `latest` | Same as `latest/stable`, for backwards compatibility |

A `vX.Y/*` channel only ever moves within its own minor version. A `latest/*`
channel moves across minor versions.

## Choosing a channel

Nothing in k0s checks the version skew between a cluster and an update. A
channel that moves across minor versions can offer a cluster a version it
cannot be upgraded to in one step, whatever it currently runs.

Use a `vX.Y/*` channel for autopilot. It stays within the minor version, so its
plans respect the skew policy. Moving to the next minor version is a manual
switch to another channel.

A `latest/*` channel still moves across minors. Use it when that is what you
want, and expect plans to cross minor versions.

## Deprecated channels

`stable`, `stable/v1.27`, `stable/v1.28`, `stable/v1.29` and `unstable` are
frozen. They keep serving what they serve today and get no further updates.

`stable` and `https://updates.k0sproject.io` are the defaults of the
`UpdateConfig` CRD, and `stable` stays frozen in place until k0s changes its
default; that change is out of scope for this repository.

`latest` is not frozen. Released k0s versions read `latest` for their update
notifications, so it follows `latest/stable` and moves from `1.28.2` to the
current release.

## Channel "protocol"


When autopilot is configred to use a channel called `some-channel`, it will request the information from following URL `<update-server-address/<channel>/index.yaml`
Essentially k0s autopilot assumes the folowing structure for update channels:

```text
<channel-name>/
    index.yaml
```

Each the channel name can contain e.g. forward slashes so you can structure the channels for example like so:

```text
v1.36/stable/
    index.yaml
v1.36/unstable/
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
