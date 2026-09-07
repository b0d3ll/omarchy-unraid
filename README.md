# Omarchy Unraid Companion

Monitor and control an Unraid server from the Omarchy bar without leaving
the desktop.

**Status: v0.1 feature-complete.** Onboarding saves a real server URL and
API key (URL in `~/.config/omarchy-unraid/config.json`, key in the system
keyring via `secret-tool`), and the whole panel now runs on live GraphQL:
CPU/RAM, array state and capacity, parity, 30-odd Docker containers, VMs,
and notifications. Verified against Unraid 7.3.2 / API 4.37.3.

Clicking a container or VM opens a detail view with controls — containers
get Start / Stop / Restart, Open WebUI and a log viewer; VMs get Start /
Stop / Reboot plus Pause, Resume and Force stop. Controlling anything
needs an API key with the matching update permission (Unraid → Settings →
Management Access → API Keys); a read-only key still gets everything else,
and the controls say exactly what's missing instead of failing silently.

Connections are managed automatically: several endpoints can be
configured with a priority order, and the plugin moves between them on its
own — LAN at home, Tailscale away — without any interaction. Endpoints can
be auto-detected (from what the server advertises and from the local
Tailscale client) and tested individually.

Still to come: desktop notifications and polish (Milestone 7).

## Requirements

- `secret-tool` (part of `libsecret`) and a running Secret Service provider
  (e.g. `gnome-keyring-daemon`) for API key storage.
- `curl` and `bash` for API requests.

## What works right now

- First run shows a 3-step setup wizard: server address → API key + test
  connection → done. Skipped on subsequent opens once configured.
- Bar widget: real hostname and a health dot that reflects real state
  (disabled/missing array disks, unread alerts, parity errors, auth
  failure, unreachable).
- Overview: array state, capacity, CPU/RAM, parity progress, recent
  notifications, and working WebUI / Terminal / Refresh actions.
- Docker: live container list with state, update badges and search, plus a
  per-container detail view with controls and logs.
- VMs: live list plus a per-VM detail view with start/stop/reboot and,
  under "More", pause and force stop — the latter behind a confirmation
  that spells out that it's the equivalent of cutting power.
- Storage (incl. disabled/missing/invalid disk counts) and Alerts (click a
  notification to open it in the Unraid WebUI).
- Settings: live Unraid/API version and uptime, plus editing the server
  address and replacing the API key.
- "Load disk details" shows the disk-sleep warning dialog (loads nothing
  yet — per-disk queries stay strictly user-initiated).

- Settings > Connections: the endpoint list with priority order, live
  endpoint and latency, per-endpoint reachability test, and endpoint
  auto-detection.

Polling slows down while the panel is closed and speeds up while it's
open; each resource is queried independently, so one unavailable subsystem
(say Docker) never blanks the rest or reports the server as offline.

## Connection handling

Endpoints are tried in priority order. A working one is kept until it
fails twice in a row, and a better one is only adopted back after it
succeeds twice — so a flapping link can't make the plugin oscillate. When
nothing answers, the panel keeps showing the last known state with its
age, disables the controls, and retries on an escalating 15s→5min backoff;
opening the panel or hitting Refresh retries immediately.

The selection rules live in `Selection.js` as pure functions with no QML
in them, so they're unit-tested rather than eyeballed:

```bash
node tests/selection.test.js
```

## Disk-sleep safety

Current Unraid API versions can spin up sleeping HDDs when asked for
per-disk or temperature data, so no background query ever asks for it.
`tests/no-disk-queries.sh` enforces that statically — run it before
committing changes to `Api.js`.

## Local development

```bash
# Validate the manifest
omarchy plugin validate .

# qmllint needs a directory that has a "qs" entry pointing at the Omarchy
# shell root — Quickshell's qs.Commons/qs.Ui module resolution is its own
# thing, not something plain `-I "$OMARCHY_PATH/shell"` resolves on its
# own. One-time setup, then lint:
mkdir -p /tmp/omarchy-lint-root
ln -sfn "$OMARCHY_PATH/shell" /tmp/omarchy-lint-root/qs
/usr/lib/qt6/bin/qmllint -I /tmp/omarchy-lint-root -I /usr/lib/qt6/qml \
  Panel.qml UnraidService.qml ConfigStore.qml SecretStore.qml \
  views/*.qml components/*.qml onboarding/*.qml

# `Style.font.*`/`Color.popups.*`-style warnings ([missing-property] on a
# singleton's nested QtObject) are a known qmllint limitation, not a real
# bug — Omarchy's own first-party plugins (e.g. weather/Panel.qml) produce
# the same warnings under this exact command. Only worry about anything
# that isn't in that category.

# omarchy plugin add only takes a git URL, so local development is a
# symlink: drop this repo into ~/.config/omarchy/plugins/<id>, then enable
# and reload. `omarchy plugin validate` will complain about the top-level
# symlink (it's meant to catch symlinks *inside* a plugin folder) — that
# complaint doesn't affect the running shell.
ln -s "$(pwd)" ~/.config/omarchy/plugins/io.github.b0d3ll.omarchy-unraid
omarchy plugin enable io.github.b0d3ll.omarchy-unraid
omarchy restart shell
```

## Roadmap

Every milestone in the v0.1 spec is now implemented. What's left is
Milestone 7: desktop notifications for new warnings and alerts, and the
remaining empty/error-state polish. Deliberately out of scope for v0.1:
multiple servers, container updates/installs, share management, SMART and
temperature monitoring, and Unraid Connect as a transport.
