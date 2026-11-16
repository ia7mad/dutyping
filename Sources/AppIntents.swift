import AppIntents
import Foundation
#if canImport(AlarmKit)
import AlarmKit
#endif

extension Notification.Name {
    static let dutyPingVoiceCaptureRequested = Notification.Name("dutyPingVoiceCaptureRequested")
}

enum VoiceShortcutRequest {
    static let key = "capture.startRecordingFromShortcut"

    @MainActor
    static func request() {
        UserDefaults.standard.set(true, forKey: key)
        NotificationCenter.default.post(name: .dutyPingVoiceCaptureRequested, object: nil)
    }

    static func consume(defaults: UserDefaults = .standard) -> Bool {
        let requested = defaults.bool(forKey: key)
        defaults.removeObject(forKey: key)
        return requested
    }
}

struct RecordDutyPingTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Record a task by voice"
    static var description = IntentDescription("Opens DutyPing and immediately starts recording a new task.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await VoiceShortcutRequest.request()
        return .result()
    }
}

struct OrganizeDutyPingThoughtIntent: AppIntent {
    static var title: LocalizedStringResource = "Turn speech or text into a task"
    static var description = IntentDescription("Understands a dictated thought and saves its task, time, and checklist.")
    static var openAppWhenRun = false

    @Parameter(title: "What do you want to remember?")
    var thought: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let cleaned = thought.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return .result(dialog: "Tell me what you want to remember.") }
        let context = await MainActor.run {
            (Store().shifts, AssistantConfiguration.shared.isEnabled && AssistantConfiguration.shared.hasAPIKey)
        }
        var reminder = try await ReminderAssistant.organize(cleaned, shifts: context.0, useAI: context.1)
        reminder.source = .siri
        let savedReminder = reminder
        await MainActor.run { Store().addReminder(savedReminder) }
        await Scheduler.shared.waitUntilIdle()
        if reminder.hasSchedule {
            return .result(dialog: "Saved. DutyPing will remind you \(reminder.dueDate.formatted(date: .abbreviated, time: .shortened)).")
        }
        return .result(dialog: "Saved to your DutyPing inbox.")
    }
}

struct NextDutyPingReminderIntent: AppIntent {
    static var title: LocalizedStringResource = "Get my next reminder"
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let diagnostics = await Scheduler.shared.diagnostics()
        guard let next = diagnostics.upcoming.first else {
            return .result(value: String(localized: "Nothing queued"), dialog: "You have no upcoming reminders.")
        }
        let value = "\(next.label) · \(next.date.formatted(date: .abbreviated, time: .shortened))"
        return .result(value: value, dialog: "Your next reminder is \(value).")
    }
}

struct PauseDutyPingRemindersIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause DutyPing reminders"
    static var openAppWhenRun = false

    @Parameter(title: "Minutes", default: 60)
    var minutes: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let duration = min(7 * 24 * 60, max(1, minutes))
        await MainActor.run {
            let store = Store()
            store.settings.pausedUntil = Date().addingTimeInterval(Double(duration) * 60)
            store.commit()
        }
        await Scheduler.shared.waitUntilIdle()
        return .result(dialog: "DutyPing reminders are paused for \(duration) minutes.")
    }
}

struct ResumeDutyPingRemindersIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume DutyPing reminders"
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            let store = Store()
            store.settings.pausedUntil = nil
            store.commit()
        }
        await Scheduler.shared.waitUntilIdle()
        return .result(dialog: "DutyPing reminders are active again.")
    }
}

#if canImport(AlarmKit)
@available(iOS 26.0, *)
struct ConfirmDutyPingAlarmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Confirm done"
    static var openAppWhenRun = false
    @Parameter(title: "Series") var seriesID: String
    @Parameter(title: "Kind") var kind: String
    @Parameter(title: "Reminder") var reminderTitle: String

    init() { seriesID = ""; kind = ""; reminderTitle = "" }
    init(seriesID: String, kind: String, reminderTitle: String) {
        self.seriesID = seriesID; self.kind = kind; self.reminderTitle = reminderTitle
    }

    func perform() async throws -> some IntentResult {
        try? AlarmManager.shared.stop(id: AlarmIdentity.id(for: seriesID))
        if kind != "test", !seriesID.isEmpty {
            await Scheduler.shared.completeAsync(seriesID: seriesID, kind: kind, title: reminderTitle,
                                                  fromLiveActivityIntent: true)
        }
        return .result()
    }
}

@available(iOS 26.0, *)
struct SnoozeDutyPingAlarmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Snooze 10 min"
    static var openAppWhenRun = false
    @Parameter(title: "Series") var seriesID: String
    @Parameter(title: "Kind") var kind: String
    @Parameter(title: "Reminder") var reminderTitle: String

    init() { seriesID = ""; kind = ""; reminderTitle = "" }
    init(seriesID: String, kind: String, reminderTitle: String) {
        self.seriesID = seriesID; self.kind = kind; self.reminderTitle = reminderTitle
    }

    func perform() async throws -> some IntentResult {
        try? AlarmManager.shared.stop(id: AlarmIdentity.id(for: seriesID))
        if kind != "test", !seriesID.isEmpty {
            await Scheduler.shared.snoozeAsync(seriesID: seriesID, kind: kind, title: reminderTitle,
                                                fromLiveActivityIntent: true)
        }
        return .result()
    }
}
#endif

/// Makes DutyPing available to Siri, Spotlight, and the Shortcuts app without
/// requiring an account or a network service.
struct AddDutyPingReminderIntent: AppIntent {
    static var title: LocalizedStringResource = "Add a DutyPing reminder"
    static var description = IntentDescription(
        "Creates a private personal reminder in DutyPing.")
    static var openAppWhenRun = false

    @Parameter(title: "Reminder")
    var reminderTitle: String

    @Parameter(title: "When")
    var dueDate: Date

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let cleaned = reminderTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return .result(dialog: "Tell me what you want to remember.")
        }

        let store = await Store()
        var reminder = PersonalReminder(title: cleaned, dueDate: dueDate)
        reminder.source = .siri
        await store.addReminder(reminder)
        await Scheduler.shared.waitUntilIdle()

        return .result(dialog: "Done. DutyPing will remind you \(dueDate.formatted(date: .abbreviated, time: .shortened)).")
    }
}

/// A zero-friction inbox action. Siri handles speech-to-text and DutyPing keeps
/// the thought safe even when the user does not know the due date yet.
struct CaptureDutyPingThoughtIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture a thought in DutyPing"
    static var description = IntentDescription(
        "Saves something to your DutyPing inbox before you forget it.")
    static var openAppWhenRun = false

    @Parameter(title: "What do you want to remember?")
    var thought: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let cleaned = thought.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return .result(dialog: "Tell me what you want to remember.")
        }
        let store = await Store()
        let reminder = PersonalReminder.inbox(title: cleaned, notes: cleaned, source: .siri)
        await store.addReminder(reminder)
        await Scheduler.shared.waitUntilIdle()
        return .result(dialog: "Saved to your DutyPing inbox.")
    }
}

struct DutyPingShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RecordDutyPingTaskIntent(), phrases: [
            "Record a task in \(.applicationName)", "سجل مهمة في \(.applicationName)"
        ], shortTitle: "Record a task by voice", systemImageName: "mic.fill")
        AppShortcut(intent: OrganizeDutyPingThoughtIntent(), phrases: [
            "Create a smart task in \(.applicationName)", "ذكرني مع \(.applicationName)"
        ], shortTitle: "Smart task", systemImageName: "wand.and.stars")
        AppShortcut(intent: NextDutyPingReminderIntent(), phrases: [
            "What is next in \(.applicationName)", "وش تذكيري الجاي في \(.applicationName)"
        ], shortTitle: "Next reminder", systemImageName: "clock.badge.questionmark")
        AppShortcut(intent: PauseDutyPingRemindersIntent(), phrases: [
            "Pause reminders in \(.applicationName)", "وقف تذكيرات \(.applicationName)"
        ], shortTitle: "Pause reminders", systemImageName: "pause.circle.fill")
        AppShortcut(intent: ResumeDutyPingRemindersIntent(), phrases: [
            "Resume reminders in \(.applicationName)", "شغل تذكيرات \(.applicationName)"
        ], shortTitle: "Resume reminders", systemImageName: "play.circle.fill")
        AppShortcut(
            intent: CaptureDutyPingThoughtIntent(),
            phrases: [
                "Capture a thought in \(.applicationName)",
                "Remember this with \(.applicationName)",
                "سجل هذا في \(.applicationName)",
                "لا تنسيني هذا يا \(.applicationName)"
            ],
            shortTitle: "Capture thought",
            systemImageName: "mic.badge.plus"
        )
        AppShortcut(
            intent: AddDutyPingReminderIntent(),
            phrases: [
                "Add a reminder in \(.applicationName)",
                "Remember something with \(.applicationName)",
                "أضف تذكير في \(.applicationName)"
            ],
            shortTitle: "Add reminder",
            systemImageName: "bell.badge.fill"
        )
    }
}
