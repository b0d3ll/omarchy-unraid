# Omarchy Unraid Companion

Monitor and control an Unraid server from the Omarchy bar without leaving
the desktop.

**Status: v0.5.0.** Onboarding saves a real server URL and
API key (URL in `~/.config/omarchy-unraid/config.json`, key in the system
keyring via `secret-tool`), and the whole panel now runs on live GraphQL:
CPU/RAM, array state and capacity, parity, 30-odd Docker containers, VMs,
and notifications. Verified against Unraid 7.3.2 / API 4.37.4.

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
Notices tab. Notifications can also be archived from there. Only warnings
and alerts are announced — INFO notices are listed, never pushed.

## Requirements

- `secret-tool` (part of `libsecret`) and a running Secret Service provider
  (e.g. `gnome-keyring-daemon`) for API key storage.
- `curl` and `bash` for API requests.

## What works right now

- First run shows a 3-step setup wizard: server address → API key + test
  connection → done. Skipped on subsequent opens once configured.
- Bar widget: real hostname and a health dot that reflects real state
  (disabled/missing array disks, unread alerts, parity errors, auth
  failure, unreachable). Hovering it gives the health line plus running
  Docker and VM counts and the live transport, so the usual question —
  is everything up — is answered without opening the panel.
- Overview: array state with its last parity check, Unraid version and
  uptime, Docker/VM counts, the hottest disk as a value, then
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
  under "More", pause, reset and force stop. That is every VM mutation the
  API exposes. Reset and force stop are each behind a confirmation that
  spells out what they do — reset is libvirt's hard reset (the case's reset
  button, no shutdown sequence), force stop the equivalent of cutting
  power.
- Storage: array state and capacity, the disabled/missing/invalid counts,
  parity status, and a per-disk list — parity, array disks and pools, each
  with its spin state, temperature, usage and status. A spun-down drive is
  shown as "standby" and stays asleep; the section header says how many
  rotating drives are currently spinning. The counters are counted from
  per-disk status rather than read off `vars` — see below.
- Notices: every unread notification, filterable by All / Info / Warnings /
  Critical. Click one to open it in the Unraid WebUI, or archive it.
  "Archive all" clears whatever the active filter shows, behind a
  confirmation — it maps onto `archiveAll(importance)`, whose argument is
  nullable, so the All filter simply omits it.
- Storage also controls the array: start/stop, and parity check start,
  pause, resume and cancel. A read-only check and a correcting one are
  separate buttons, because rewriting parity from the data disks is not the
  same decision as reading them.
- Settings: live Unraid/API version and uptime, plus editing the server
  address, replacing the API key, and allowing a self-signed HTTPS
  certificate.
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
| Parity history | 5 min | 15 min |
| Versions, uptime | on connect and on Refresh only | — |
| Container logs | 5 s while the log view is open | not polled |

Opening the panel, switching to a view, and Refresh each trigger an
immediate re-poll on top of that.

The panel is as tall as its content, up to what fits on screen. It used to
stop at 680px, which only ever bit on the long views — Storage's disk list
and Docker's container list — cutting them off at a height that had
nothing to do with how much room the screen had.

## CPU cores

Clicking the CPU row expands a strip with one column per core — 40 of them
on the machine this was built against — each a miniature track and fill,
red past 90%. It is collapsed by default, because that much panel is only
worth spending once the total has told you to look.

The per-core figures ride along with the CPU total rather than getting
their own query: it is the same resolver, and forty floats is nothing next
to the round trip it would cost.

## Disk temperature

Overview shows the hottest disk that is currently reporting one, as a value
alongside the Docker and VM counts. A temperature is not a percentage of
anything, so it does not get a bar. A parked disk reports no
temperature — the server never woke it to measure — so it is skipped
rather than counted as cold, and an array that is entirely asleep reads
"all disks in standby" with no bar, because an empty bar would say "cold"
instead of "not measured".

Pool devices are included, since they are disks too. Each is judged
against *its own* `warning`/`critical` thresholds where Unraid has them,
falling back to Unraid's defaults of 45 °C and 55 °C — which is also what
Unraid itself applies. That keeps a pool NVMe, which idles warmer than a
platter, from being judged by a platter's standard.

## Keyboard

Omarchy is keyboard-driven, so the panel is too. Everything rides on the
shared `PanelKeyCatcher`, which already maps the arrow keys and `hjkl`, so
vim keys work without asking for them.

| Key | Action |
| --- | --- |
| `1`–`5` | jump to a tab |
| `←` / `→`, `h` / `l` | cycle tabs, wrapping |
| `r` | refresh everything |
| `Esc` | back out one level, or close |

`Esc` leaves a detail view for its list before it closes the panel —
closing outright from a container's log view meant reopening and clicking
back down two levels. `Tab` stays Omarchy's own "move between bar panels";
it is not ours to repurpose.

Shortcuts are inert while a confirmation is up, and while onboarding owns
the panel.

## HTTPS

An address is used exactly as typed — `https://tower.local` stays HTTPS.
A bare host still defaults to `http://`, which is how Unraid ships.

Unraid's HTTPS listener normally presents a self-signed certificate, which
curl rejects, and the panel used to report that as a flat "could not reach
the server" — the opposite of what happened. A certificate failure now says
so and points at the switch, and **Settings > Server > Allow self-signed
certificate** (also offered during onboarding, for an `https://` address)
turns on curl's `insecure` for that endpoint. It applies only to HTTPS
endpoints: setting it on a plain HTTP request is meaningless, and leaving
it permanently on would weaken a properly-certificated server too.

The failure *reason* stays `unreachable` internally even for a certificate
error. That string is the connection layer's vocabulary — `ConnectionManager`
only counts `unreachable` toward failover — so a separate `tls` reason would
have quietly stopped a certificate-broken endpoint from ever failing over to
a working one.

Replies are capped with `curl --max-filesize`. A reply is a GraphQL
document, never a payload; the largest legitimate one here is the parity log
at ~8.5 KB.

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

## Notifications

The panel lists every unread notification, not just warnings and alerts.
It used to query `notifications.warningsAndAlerts`, which meant a notice
could resolve an alarm without the panel ever saying so: "Disk-Clear
started" sat on screen as a warning while "Disk-Clear finished (0 errors)"
was filtered out. `notifications.list(filter: { type: UNREAD, … })` with no
`importance` returns every level.

What stays keyed to warnings and alerts only: the health dot, the Overview
banner, and desktop notifications. Listing an INFO notice should not make
the bar look alarmed or ping the desktop three times a week.

## What drives the health dot, and how to clear it

The bar's dot, its label, and Overview's banner are three renderings of one
ladder in `Panel.qml`'s `healthState`, checked top down:

| Condition | State |
| --- | --- |
| Not configured / API key rejected / unreachable / stale | own states |
| A missing array disk | CRITICAL |
| An unread **alert** | CRITICAL |
| The last parity check found errors | WARNING |
| An unread **warning** | WARNING |
| A disabled or invalid array disk | NOTICE |
| Parity check running, or array not started | NOTICE |
| otherwise | HEALTHY |

So it is state, not a message: nothing is dismissible on its own, and each
rung clears when the condition underneath it stops being true. The unread
rungs are the ones under your control — archive the notification (in
Notices, or in the Unraid WebUI) and the dot drops to the next true rung.
An "attention needed" that will not go away usually means an old unread
warning is still sitting in the list — "Archive all" on the Warnings filter
clears exactly that.

Its count comes from the server's own unread counters rather than from the
rows on screen: the list is fetched with `limit: 50`, so on a larger
backlog the visible rows would understate what the button is about to
archive.

The tab carries no count. The dot and the banner already say that
something needs attention, and all three read the same unread
warning+alert figure — a third copy of one number said nothing new.

Compact rows show a notification's `subject` ("Docker Auto Update",
"Disk-Clear finished (0 errors)") rather than its `title` ("Community
Applications"), which is the component that raised it and repeats across
everything it sends.

## State vocabulary

Three different enums reach the panel raw, and all three now get labels
from the same source Unraid's own webGUI words them with.

`VmState` is libvirt's domain-state enum passed through unchanged, so a VM
that is off reports `SHUTOFF`. Unraid's VM manager calls that "Stopped",
which is the word the panel uses — "Offline" would suggest the VM can't be
reached rather than that it simply isn't running. All eight states have
labels.

`ContainerState` is Docker's vocabulary — `RUNNING` / `PAUSED` / `EXITED`.
Unraid's Docker page words these as started/stopped/paused, so a stopped
container reads "Stopped" rather than "Exited". `RESTARTING` and `DEAD`
aren't in the enum but are real Docker states that the sort order already
accounts for, so they get labels too.

`array.state` is likewise the API's `ArrayState` enum, straight from
emhttp's `mdState` — "Started" and "Stopped" are the Unraid webGUI's own
wording, which is why the panel keeps them. Its other nine values are error
states (`TOO_MANY_MISSING_DISKS`, `PARITY_NOT_BIGGEST`, …) that used to
render raw. All three fall back to a sentence-cased version of an
unknown future value rather than shouting it.

## Roadmap

Every milestone in the v0.1 spec is now implemented. Deliberately out of
scope for v0.1:
multiple servers, container updates/installs, share management, SMART
monitoring, and Unraid Connect as a transport.

## Parity reporting

`array.parityCheckStatus` declares `running`, `paused`, `correcting` and
`errors`, but the API never assigns any of them: `getParityCheckStatus`
(`api/src/core/modules/array/parity-check-status.ts`) returns only
`status`, `speed`, `date`, `duration` and `progress`, so the other four are
always null. Reading them as booleans meant `running` was permanently
false and the parity progress bar was dead code that could not appear
during a real check; `errors` was worse, because `num(errors, 0)` turned a
null into a confident `0` and printed "Errors: 0" whether or not the last
check had found any.

Running and paused are now derived from `status`, which does carry
`RUNNING` and `PAUSED`. Real error counts come from `parityHistory`, which
parses the parity log — that is also where "last check" comes from. Note
that `parityCheckStatus.date` is when a check *started* while
`parityHistory[].date` is when it *finished*; they differ by `duration`.

A running check reports no error count anywhere, so the progress view
shows percentage and speed and says nothing about errors.

## Dead weight removed in 0.2.0

`vars.cacheNumDevices` is gone from the array query. It is the legacy
single-cache count and answers `NaN` on any server with named pools, which
meant a partial GraphQL error on *every* array poll for a number that then
rendered as "—". The pool count comes from the pool list instead.

`configStore.apiVersion` and `configStore.lastTestedAt` are gone too.
Neither was ever read — Settings shows the live `service.system.apiVersion`
from the running poll — and `apiVersion` was never even written, so it sat
empty in every config file on disk. Old keys are dropped on the next save.

The About line reads its name and version from `manifest.json` at runtime
rather than repeating them, so bumping the manifest can no longer leave it
quietly claiming the old version.

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
