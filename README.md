# Omarchy Unraid Companion

Monitor and control an Unraid server from the Omarchy bar without leaving
the desktop.

**Status: v0.1 complete.** Onboarding saves a real server URL and
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

Newly arrived warnings and alerts can raise a desktop notification (off by
default, under Settings > Behavior); clicking one opens the panel on the
Alerts tab. Notifications can also be archived from there.

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
- Overview: array state, Unraid version and uptime, Docker/VM counts, then
  CPU / RAM / storage as bars, parity progress, recent notifications, and
  WebUI / Terminal actions. Storage is a bar rather than a tile because
  "5.0 / 14.4 TB" on its own never said which number was which — next to a
  bar that is 35% full it can only be read one way.
- Refresh is the circular arrow next to the gear, so the one control that
  applies to every view no longer lives inside one of them. Its tooltip
  carries the polling cadence.
- Docker: live container list with state, update badges and search, plus a
  per-container detail view with controls and logs.
- VMs: live list plus a per-VM detail view with start/stop/reboot and,
  under "More", pause and force stop — the latter behind a confirmation
  that spells out that it's the equivalent of cutting power.
- Storage: array state and capacity, the disabled/missing/invalid counts,
  parity status, and a per-disk list — parity, array disks and pools, each
  with its spin state, temperature, usage and status. A spun-down drive is
  shown as "standby" and stays asleep; the section header says how many
  rotating drives are currently spinning. The counters are counted from
  per-disk status rather than read off `vars` — see below.
- Alerts — click a notification to open it in the Unraid WebUI, or archive
  it.
- Settings: live Unraid/API version and uptime, plus editing the server
  address and replacing the API key.
- Settings > Connections: the endpoint list with priority order, live
  endpoint and latency, per-endpoint reachability test, and endpoint
  auto-detection.

Polling slows down while the panel is closed and speeds up while it's
open; each resource is queried independently, so one unavailable subsystem
(say Docker) never blanks the rest or reports the server as offline.

| Resource | Panel open | Panel closed |
| --- | --- | --- |
| CPU / RAM metrics | 10 s | 60 s |
| Array, capacity, disks, parity | 15 s | 60 s |
| Docker containers | 10 s | 60 s |
| VMs | 10 s | 60 s |
| Notifications | 15 s | 30 s |
| Versions, uptime | on connect and on Refresh only | — |
| Container logs | 5 s while the log view is open | not polled |

Opening the panel, switching to a view, and Refresh each trigger an
immediate re-poll on top of that.

The panel is as tall as its content, up to what fits on screen. It used to
stop at 680px, which only ever bit on the long views — Storage's disk list
and Docker's container list — cutting them off at a height that had
nothing to do with how much room the screen had.

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

What actually wakes a sleeping HDD is the API's `DisksService`, behind the
top-level `disks`/`disk` query root: it shells out to `smartctl` and to
systeminformation's `diskLayout()`, so `Disk.temperature` and
`Disk.smartStatus` cost a spin-up. No query in the plugin may go near
those.

`array { parities/disks/caches }` is *not* in that category, which is why
the Storage view can list every drive without touching one. Those fields
are read out of the emhttp state the API already holds in memory, parsed
from `/var/local/emhttp/disks.ini` — see `get-array-data.ts` and
`state-parsers/slots.ts` in [unraid/api](https://github.com/unraid/api).
Every `ArrayDisk` field comes from that file, `temp` and `isSpinning`
included, so a parked drive answers `temp: null` instead of being woken to
report a number. It is the same data the Unraid Main page renders.

The plugin's original rule banned the word `disks` outright, which was
wider than the real hazard and cost the Storage view its whole disk list.
`tests/no-disk-queries.sh` now enforces the narrow version — it evaluates
`Api.js` and checks the operations that are actually sent, so a query
assembled from fragments is judged whole. Run it before committing changes
to `Api.js`:

```bash
./tests/no-disk-queries.sh
```

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

Every milestone in the v0.1 spec is now implemented. Deliberately out of
scope for v0.1:
multiple servers, container updates/installs, share management, SMART
monitoring, and Unraid Connect as a transport.

## Disk counters

`vars.mdNumDisabled` and `vars.mdNumInvalid` can report a count while every
disk in the array reports `DISK_OK`, with the array started and a clean
parity check behind it. The API passes those numbers through from `var.ini`
untouched (`state-parsers/var.ts` is a plain `toNumber` per field), so the
disagreement is emhttp's own bookkeeping rather than anything in transit —
but it was enough to keep the bar's health dot permanently on "attention
needed".

So Disabled / Missing / Invalid / Cache devices are now counted from the
per-disk `status` in the array's own disk list, which is what the Unraid
Main page draws. `vars` stays the fallback for a server that answers the
array summary but not the disk lists, and `arrayInfo.countsDerived` says
which of the two a given reading came from. Counting from the list also
fixes the cache count: `vars.cacheNumDevices` answers `NaN` on a server
with pools — a partial GraphQL error and a null field — which used to
render as "—" next to two plainly present pool devices.

This is why the disk lists ride along with the array summary in one query
instead of being fetched only while the Storage tab is open: the health dot
is derived from them and is on screen whether or not anyone has that tab
open.
