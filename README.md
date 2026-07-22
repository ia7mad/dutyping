# DutyPing

A standalone iPhone app that reminds you to check in and out of duty. It has
nothing to do with the fingerprint kiosk in the parent folder — no network, no
server, no account. Everything stays on the phone.

## What it does

- **Weekly schedule.** Add shifts (day, start, end). Reminders fire a few
  minutes after a shift starts and at the end of it.
- **Follow-ups.** If you ignore the first alert it re-asks every few minutes,
  up to a limit you set. Tapping **Done** stops that day's remaining nags.
- **Location.** Optionally watch a circle around your workplace and remind you
  on arrival and departure, regardless of the clock. iOS wakes the app for
  region crossings even when it isn't running.

## Building the `.ipa` without a Mac

1. Push this folder to GitHub as its own repository (the workflow expects it at
   the repo root).
2. GitHub Actions runs `.github/workflows/build-ipa.yml` on a macOS runner,
   builds with code signing disabled, and uploads `DutyPing.ipa` as a build
   artifact.
3. Download the artifact and unzip it to get the `.ipa`.

macOS runners burn GitHub Actions minutes at 10× the Linux rate. A build is
short, but on a private repo keep an eye on the free monthly allowance — or make
the repo public, where minutes are free.

## Installing it

The `.ipa` is unsigned on purpose. **SideStore** or **AltStore** re-signs it on
device with your free Apple ID; no paid developer account is needed.

The catch with a free Apple ID: the signature expires every **7 days**.
SideStore refreshes it over Wi-Fi automatically, but if the phone goes a week
without reaching the refresh service the app stops opening until you refresh it
by hand. Reminders already handed to iOS keep firing regardless.

## Permissions to grant

- **Notifications** — without this the app does nothing at all.
- **Location: Always** — only if you turn on the workplace trigger. iOS asks for
  "While Using" first and offers "Always" as a follow-up prompt, sometimes a day
  later. Accept it, or arrivals won't register while the app is closed.

## How scheduling works, and why it matters

iOS caps an app at 64 pending local notifications. Rather than one repeating
weekly trigger per shift, the app schedules concrete one-shot alerts across a
rolling ~3-week horizon, newest first, truncated to fit the cap. That is what
makes per-occurrence "Done" dismissal possible.

The cost is that the queue has to be topped up. Three things do that: opening
the app, bringing it to the foreground, and a background-refresh task. If all
three somehow fail, a housekeeping notification fires two days before the queue
runs dry telling you to open the app. If you run many shifts with many
follow-ups you will hit the 64-notification cap sooner and the horizon shortens
automatically — the Status section shows the date reminders are covered through.

## Layout

| Path | What's in it |
| --- | --- |
| `project.yml` | XcodeGen spec; CI generates the `.xcodeproj` from it |
| `Sources/Models.swift` | `Shift`, `TimeOfDay`, `Settings` |
| `Sources/Store.swift` | JSON persistence; every write reschedules |
| `Sources/Scheduler.swift` | Builds the notification queue |
| `Sources/GeofenceManager.swift` | Workplace region monitoring |
| `Sources/ContentView.swift` | The whole UI |
| `Sources/App.swift` | Entry point, notification delegate, background refresh |
