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
        let reminder = PersonalReminder(title: cleaned, dueDate: dueDate)
        await store.addReminder(reminder)

        return .result(dialog: "Done. DutyPing will remind you \(dueDate.formatted(date: .abbreviated, time: .shortened)).")
    }
}

struct DutyPingShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
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
