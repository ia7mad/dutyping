import AppIntents
import Foundation

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
        return .result(dialog: "Saved to your DutyPing inbox.")
    }
}

struct DutyPingShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
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
