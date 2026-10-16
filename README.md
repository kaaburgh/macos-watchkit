# macOS WatchKit

A small, native **macOS menu bar system-health monitor**. The first diagnostic checks for macOS TCC/Sandbox authorization watchdog timeouts. More independent checks can be added without changing the menu bar lifecycle.

## What it does today

- Checks every **2 minutes** for TCC/Sandbox watchdogs using a persisted coverage checkpoint, starting from an initial 3-minute baseline.
- After sleep, errors or offline time, scans bounded 10-minute intervals (`--start`/`--end`), subdivides slow or noisy intervals, and advances coverage after each successful interval. Maximum historical catch-up age is 24 hours; unverified gaps never show green.
- Summarizes first and last event, service counts, and top affected PIDs. A truncated query with confirmed watchdogs produces a warning even when historical coverage is incomplete.
- Shows a menu bar shield: checkmark (no events observed), warning (events found), question mark (check unavailable). **No events observed is not a guarantee the TCC system is healthy.**
- Gives a manual **Check now** action and a **Copy report** action.
- Keeps the most recent 100 diagnostic snapshots locally in `~/Library/Application Support/macos-watchkit/history.json` (only counts, status, and timestamps; **not** raw system logs or accessed paths).
- Does not require `sudo`, read private TCC databases, reset TCC permissions, or automatically touch protected `Desktop`, `Documents`, or `Downloads` folders.
- Each log query times out after 20 seconds and captures at most 1 MiB in memory. Incomplete coverage without detected watchdogs shows **unknown**; partial output containing watchdogs shows a **warning**. Queries never write unbounded temporary files.
- Stale health automatically becomes unknown on wake or after a delayed refresh; old per-diagnostic results are labeled historical.

## Install and run (macOS 13+)

Requires Xcode or Swift tools. This is a source-built app; no notarized binary is distributed yet.

```bash
 git clone https://github.com/kaaburgh/macos-watchkit.git
 cd macos-watchkit
 ./scripts/build-app.sh --open
```

The app bundle is written to `.build/dist/macOS WatchKit.app`. Rebuilds stage and sign a new bundle before replacing the old path, avoiding in-place modification of a running executable. Quit an already running copy before using `--open` to ensure you launch the newly built version. It runs only in the menu bar (no Dock icon). To start it on login, add that `.app` under **System Settings → General → Login Items**. Moving the built app to `~/Applications` first is recommended if you want a stable path across clean builds.

For local tests:

```bash
swift test
```

## How the monitor works

The incident motivating this tool produced messages like:

```text
kernel (Sandbox) watchdog expired for approval entry 3174168 (kTCCServiceSystemPolicyDownloadsFolder, pid 85402)
```

The checker uses `/usr/bin/log show --start … --end …` with a narrow kernel watchdog predicate. It intentionally **does not** scrape every TCC request, because the original incident produced enormous volumes of messages and logging was eventually quarantined. No polling of private files or protected paths is needed for passive detection.

Only events still retained in Unified Logging can be detected. If a query fails or times out, already-proven watchdogs remain warnings; otherwise status is unknown until coverage can be established. Historical queries proceed in bounded chunks (retries split difficult chunks), preserving the successful checkpoint across launches. Counts are **per check**, not cumulative unique incidents, and duplicate approval-entry IDs are removed within a multi-chunk check. It is possible for events not to have been persisted or to be hidden by access policy.

To add another diagnostic, implement the `SystemDiagnostic` protocol in `Sources/WatchCore/` and register it in `MonitorStore.checkNow()`. Every result supports a named status, summary and optional per-category counts.

## Limitations

- The graphical app can be built by macOS CI, but an interactive menu bar smoke test on the user's Mac remains necessary; core model/parser tests are also Linux-compatible.
- There are no notifications yet: a warning changes the menu bar symbol and is visible when opening the popover.
- Not all symptoms of TCC malfunction result in watchdog messages, so absence of them is not a full health check.
- No privileged helper, persistent daemon, automatic repair, or system setting changes.
