# macOS WatchKit

A small, native **macOS menu bar system-health monitor**. The first diagnostic checks for macOS TCC/Sandbox authorization watchdog timeouts. More independent checks can be added without changing the menu bar lifecycle.

## What it does today

- Checks every **2 minutes** for `watchdog expired for approval` messages in the **last 3 minutes** of Unified Logging, counting events and affected TCC services.
- Shows a menu bar shield: checkmark (no events observed), warning (events found), question mark (check unavailable). **No events observed is not a guarantee the TCC system is healthy.**
- Gives a manual **Check now** action and a **Copy report** action.
- Keeps the most recent 100 diagnostic snapshots locally in `~/Library/Application Support/macos-watchkit/history.json` (only counts, status, and timestamps; **not** raw system logs or accessed paths).
- Does not require `sudo`, read private TCC databases, reset TCC permissions, or automatically touch protected `Desktop`, `Documents`, or `Downloads` folders.
- Each log query times out after 20 seconds; failed, truncated, or timed-out queries show **unknown**, not a false green status.

## Install and run (macOS 13+)

Requires Xcode or Swift tools. This is a source-built app; no notarized binary is distributed yet.

```bash
 git clone https://github.com/kaaburgh/macos-watchkit.git
 cd macos-watchkit
 ./scripts/build-app.sh --open
```

The app bundle is written to `.build/dist/macOS WatchKit.app`. It runs only in the menu bar (no Dock icon). To start it on login, add that `.app` under **System Settings → General → Login Items**. Moving the built app to `~/Applications` first is recommended if you want a stable path across clean builds.

For local tests:

```bash
swift test
```

## How the monitor works

The incident motivating this tool produced messages like:

```text
kernel (Sandbox) watchdog expired for approval entry 3174168 (kTCCServiceSystemPolicyDownloadsFolder, pid 85402)
```

The checker uses `/usr/bin/log show --last 3m` and a narrow kernel watchdog predicate. It intentionally **does not** scrape every TCC request, because the original incident produced enormous volumes of messages and logging was eventually quarantined. No polling of private files or protected paths is needed for passive detection.

Only events still retained in Unified Logging can be detected. If the query fails or times out, status is unknown. The rolling lookback overlaps adjacent two-minute checks; counts are **per window**, not cumulative unique incidents. It is possible for events not to have been persisted or to be hidden by access policy.

To add another diagnostic, implement the `SystemDiagnostic` protocol in `Sources/WatchCore/` and register it in `MonitorStore.checkNow()`. Every result supports a named status, summary and optional per-category counts.

## Limitations

- Building and launching the graphical menu bar app must be verified on macOS; core model/parser tests are also Linux-compatible.
- There are no notifications yet: a warning changes the menu bar symbol and is visible when opening the popover.
- Not all symptoms of TCC malfunction result in watchdog messages, so absence of them is not a full health check.
- No privileged helper, persistent daemon, automatic repair, or system setting changes.
