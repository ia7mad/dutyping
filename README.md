# DutyPing

A private, on-device reminder assistant for iPhone. DutyPing began as a way to
remember work check-in and check-out, and now also handles everyday personal
reminders. Reminders and recordings stay on the phone. No server or account is
required; optional DeepSeek organization sends captured text to its API.

## What it does

- **Personal reminders.** Create one-time, daily, weekday, weekly, or monthly
  reminders with notes, categories, and an optional important priority.
- **Voice capture.** Record a thought in Arabic or English, keep the original
  audio locally, and turn the transcript into a reminder in seconds.
- **Inbox.** Thoughts without a date stay safely in an inbox instead of being
  assigned an invented time or silently discarded.
- **Smart organization.** A built-in offline parser recognizes common Arabic
  and English phrases such as "tomorrow", "in an hour", and "after work".
  Optional DeepSeek support can organize more natural or complex captures into
  titles, schedules, categories, priorities, and checklists.
- **Quick templates.** Start common medicine, water, bill, errand, and call
  reminders in one tap, then adjust the details.
- **Siri and Shortcuts.** Run **Add reminder** from Siri, Spotlight, or the
  Shortcuts app, or use **Capture thought** to save something immediately
  without deciding its time first.
- **Weekly duty schedule.** Add shifts (day, start, end). Reminders fire a few
  minutes after a shift starts and at the end of it.
- **Persistent follow-ups.** Keep a reminder active with expanding follow-ups
  until you explicitly confirm it. Tapping **Confirm done** permanently closes
  that occurrence; merely opening the notification does not. **Snooze** brings
  it back in ten minutes.
- **Live Activity.** The next nearby reminder appears on the Lock Screen and,
  on supported iPhones, in the Dynamic Island with the DutyPing logo and a
  one-tap confirmation action.
- **Full Arabic experience.** The interface, notification actions, voice
  capture, and offline parsing support Arabic, including spoken shopping lists
  such as "جيب حليب وخبز وبطاريات".
- **Structured capture.** A sentence such as "ذكرني بأغراض البقاله، رز، بصل،
  ثوم، عصير، الساعة 4:10 م" becomes a scheduled shopping list with a clean
  title, category, item count, and individually checkable items.
- **At-a-glance timing.** The Lock Screen and Dynamic Island show the reminder
  timer, follow-up interval, and confirmation state.
- **Location.** Optionally watch a circle around your workplace and remind you
  on arrival and departure, regardless of the clock. iOS wakes the app for
  region crossings even when it isn't running.
- **Dashboard and history.** See the next reminder countdown, notification
  health, upcoming alerts, and what you completed or snoozed.
- **Pause mode.** Mute everything for an hour, the rest of the day, or a week
  without deleting any reminders.

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
- **Microphone and Speech Recognition** — only when you use voice capture.
- **Location: Always** — only if you turn on the workplace trigger. iOS asks for
  "While Using" first and offers "Always" as a follow-up prompt, sometimes a day
  later. Accept it, or arrivals won't register while the app is closed.

## How scheduling works, and why it matters

iOS caps an app at 64 pending local notifications. Rather than one repeating
trigger, the app schedules concrete one-shot alerts for shifts and personal
reminders across a rolling horizon, ordered by fire date and truncated to fit
the cap. That is what makes per-occurrence "Done" dismissal possible.

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
| `Sources/Models.swift` | Shift, reminder, schedule, and settings models |
| `Sources/Store.swift` | JSON persistence; every write reschedules |
| `Sources/Scheduler.swift` | Builds the unified reminder queue |
| `Sources/ReminderPlanner.swift` | Testable calendar, follow-up, and snooze rules |
| `Sources/LiveActivityManager.swift` | Starts and closes the next local Live Activity |
| `LiveActivity/` | Lock Screen and Dynamic Island presentation |
| `Sources/GeofenceManager.swift` | Workplace region monitoring |
| `Sources/ContentView.swift` | Dashboard, quick add, duty, and settings UI |
| `Sources/ReminderViews.swift` | Reminder list and editor UI |
| `Sources/AppIntents.swift` | Siri and Shortcuts integration |
| `Sources/QuickCaptureView.swift` | Voice/text capture and assistant settings |
| `Sources/VoiceCaptureService.swift` | Local audio recording and transcription |
| `Sources/AssistantService.swift` | Local parser, Keychain, and optional DeepSeek client |
| `Sources/App.swift` | Entry point, notification delegate, background refresh |

## Optional DeepSeek setup

DutyPing works without an AI account. To enable smarter organization, open
**AI optional** on the Quick Add card, paste your own DeepSeek API key, and turn
the assistant on. The key is stored in the iOS Keychain and is never committed
to this repository. Only the captured text is sent to DeepSeek; recordings,
location, history, and notification scheduling remain local. If the service is
offline or rejects a request, DutyPing automatically uses its local parser.

## Version 2.4 reliability fixes

- Opening the app after a deadline retains that occurrence's remaining follow-ups.
- Overnight shift checkout is retained when the app opens after midnight.
- Snooze keeps the original occurrence identity and survives app relaunches.
- Completed one-time tasks show **Completed** in the list. Turn the task back on
  to reopen it; recurring confirmations close only that occurrence.
- Tapping the Live Activity opens the app. Only **Confirm** completes a task.
- Deleted or disabled tasks remove their pending alerts, delivered banners, and
  Live Activity. Moving a task to a new time invalidates its old occurrence.
- Countdown text stops at zero and the dashboard advances to the next alert.
- Queue mutations run serially, and relative reminders retain their seconds.

Live Activities start locally while the app is in the foreground and last up to
the system's activity limit. Opening the app refreshes the next eligible activity;
local notifications continue independently while it is closed. Automatic remote
starts require an APNs service, which this app does not include. Persistent
follow-ups use a finite notification queue; reopening the app replenishes it.

Regression tests cover overdue tasks, recurrence, overnight shifts, queue
capacity, snooze persistence, completion, date edits, second precision, upgrades,
and Arabic capture. GitHub Actions builds the IPA and runs these tests on an
available iPhone simulator before publishing the installation artifact.

Before installing over your daily-use copy, check these flows on an iPhone:

1. Schedule a reminder a minute ahead; leave and reopen the app after it fires.
2. Snooze it, reopen the app, and confirm that its original follow-ups stay muted.
3. Tap the Dynamic Island body, then its explicit confirmation button separately.
4. Edit, disable, and delete an active task; verify the old activity disappears.
5. Complete a one-time task, relaunch, and verify its completed state remains.
6. Pause reminders and cross the workplace boundary; verify no location alert fires.
