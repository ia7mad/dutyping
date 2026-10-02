import Foundation

enum L10n {
    static func text(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}

/// A wall-clock time with no date attached.
struct TimeOfDay: Codable, Hashable {
    var hour: Int
    var minute: Int

    var minutesFromMidnight: Int { hour * 60 + minute }

    var display: String { String(format: "%02d:%02d", hour, minute) }

    static func from(_ date: Date) -> TimeOfDay {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return TimeOfDay(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
    }

    /// Resolves this time against a particular calendar day.
    func date(on day: Date) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    /// A `Date` carrying only this hour/minute, for binding to a `DatePicker`.
    var asPickerDate: Date { date(on: Date()) }
}

/// One recurring weekly shift.
struct Shift: Codable, Identifiable, Hashable {
    var id = UUID()
    /// 1 = Sunday … 7 = Saturday, matching `Calendar`'s `weekday` component.
    var weekday: Int
    var start: TimeOfDay
    var end: TimeOfDay
    var isEnabled = true

    /// A shift that ends at or before its start time runs past midnight.
    var crossesMidnight: Bool { end.minutesFromMidnight <= start.minutesFromMidnight }

    var summary: String {
        "\(start.display) – \(end.display)" + (crossesMidnight ? String(localized: " (next day)") : "")
    }

    static func newDefault(weekday: Int) -> Shift {
        Shift(weekday: weekday,
              start: TimeOfDay(hour: 8, minute: 0),
              end: TimeOfDay(hour: 16, minute: 0))
    }
}

// MARK: - Personal reminders

/// A small set of useful buckets keeps the reminder list scannable without
/// making people maintain a second filing system inside the app.
enum ReminderCategory: String, Codable, CaseIterable, Identifiable {
    case personal
    case health
    case medicine
    case work
    case money
    case errands

    var id: String { rawValue }

    var label: String {
        switch self {
        case .personal: return String(localized: "Personal")
        case .health: return String(localized: "Health")
        case .medicine: return String(localized: "Medicine")
        case .work: return String(localized: "Work")
        case .money: return String(localized: "Bills")
        case .errands: return String(localized: "Errands")
        }
    }

    var icon: String {
        switch self {
        case .personal: return "sparkles"
        case .health: return "heart.fill"
        case .medicine: return "pills.fill"
        case .work: return "briefcase.fill"
        case .money: return "creditcard.fill"
        case .errands: return "cart.fill"
        }
    }
}

enum ReminderRepeat: String, Codable, CaseIterable, Identifiable {
    case never
    case daily
    case weekdays
    case weekly
    case monthly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .never: return String(localized: "Never")
        case .daily: return String(localized: "Every day")
        case .weekdays: return String(localized: "Weekdays")
        case .weekly: return String(localized: "Every week")
        case .monthly: return String(localized: "Every month")
        }
    }
}

enum ReminderPriority: String, Codable, CaseIterable, Identifiable {
    case normal
    case important

    var id: String { rawValue }
    var label: String {
        self == .important ? String(localized: "Important") : String(localized: "Normal")
    }
}

enum ReminderContentType: Equatable {
    case reminder
    case checklist
    case shopping

    var label: String {
        switch self {
        case .reminder: return String(localized: "Reminder")
        case .checklist: return String(localized: "Checklist")
        case .shopping: return String(localized: "Shopping list")
        }
    }

    var icon: String {
        switch self {
        case .reminder: return "bell.fill"
        case .checklist: return "checklist"
        case .shopping: return "cart.fill"
        }
    }
}

enum ReminderSource: String, Codable {
    case manual
    case voice
    case siri
    case shared
}

/// A general-purpose reminder. Repeating reminders keep their original date as
/// an anchor so weekly and monthly rules remain predictable.
struct PersonalReminder: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var notes = ""
    var dueDate: Date
    var repeatRule: ReminderRepeat = .never
    var category: ReminderCategory = .personal
    var priority: ReminderPriority = .normal
    var isEnabled = true
    var createdAt = Date()
    /// Optional fields preserve compatibility with reminder files created by
    /// older versions. A missing schedule flag means the reminder is scheduled.
    var scheduleEnabled: Bool?
    var audioFileName: String?
    var checklist: [String]?
    var completedChecklistItems: [String]?
    var source: ReminderSource?

    var hasSchedule: Bool {
        get { scheduleEnabled ?? true }
        set { scheduleEnabled = newValue }
    }

    var cleanTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var contentType: ReminderContentType {
        guard let checklist, !checklist.isEmpty else { return .reminder }
        return category == .errands ? .shopping : .checklist
    }

    var completedItems: Set<String> {
        get { Set(completedChecklistItems ?? []) }
        set { completedChecklistItems = Array(newValue) }
    }

    var checklistProgress: String? {
        guard let checklist, !checklist.isEmpty else { return nil }
        return String(format: String(localized: "%d of %d completed"),
                      completedItems.count, checklist.count)
    }

    var notificationDetail: String {
        guard let checklist, !checklist.isEmpty else {
            let cleanNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleanNotes.isEmpty ? category.label : cleanNotes
        }
        let prefix = contentType == .shopping
            ? String(localized: "Shopping") : String(localized: "Items")
        return "\(prefix): \(checklist.joined(separator: "، "))"
    }

    var summary: String {
        if !hasSchedule { return String(localized: "Inbox · choose a time later") }
        if repeatRule == .never {
            return dueDate.formatted(date: .abbreviated, time: .shortened)
        }
        return "\(repeatRule.label) · \(dueDate.formatted(date: .omitted, time: .shortened))"
    }

    static func newDefault(date: Date = Date().addingTimeInterval(60 * 60)) -> PersonalReminder {
        PersonalReminder(title: "", dueDate: date)
    }

    static func inbox(title: String, notes: String = "",
                      source: ReminderSource = .manual) -> PersonalReminder {
        var reminder = PersonalReminder(title: title, notes: notes,
                                        dueDate: Date().addingTimeInterval(60 * 60))
        reminder.scheduleEnabled = false
        reminder.source = source
        return reminder
    }
}

struct Settings: Codable {
    /// How long after the shift starts to ask "did you check in?".
    var checkInDelayMinutes = 3
    /// How long before the shift ends to ask "did you check out?".
    var checkOutLeadMinutes = 0

    var nagEnabled = true
    var nagIntervalMinutes = 5
    var nagCount = 3
    /// Optional for backwards compatibility. Missing values adopt the safer
    /// confirmation-first behavior introduced in version 2.2.
    var persistentFollowUpsEnabled: Bool? = true

    var persistentFollowUps: Bool {
        get { persistentFollowUpsEnabled ?? true }
        set { persistentFollowUpsEnabled = newValue }
    }

    var geofenceEnabled = false
    var geofenceLatitude: Double?
    var geofenceLongitude: Double?
    var geofenceRadius: Double = 150

    /// Reminders stay silent until this moment. Nil means active.
    var pausedUntil: Date?

    var hasGeofenceLocation: Bool { geofenceLatitude != nil && geofenceLongitude != nil }

    var isPaused: Bool {
        guard let pausedUntil else { return false }
        return pausedUntil > Date()
    }
}

/// A reminder the user acknowledged, kept so the app can show what it caught.
struct DutyEvent: Codable, Identifiable, Hashable {
    enum Action: String, Codable {
        case done
        case snoozed
        case opened

        var label: String {
            switch self {
            case .done: return String(localized: "Confirmed")
            case .snoozed: return String(localized: "Snoozed")
            case .opened: return String(localized: "Opened")
            }
        }

        var icon: String {
            switch self {
            case .done: return "checkmark.circle.fill"
            case .snoozed: return "moon.zzz.fill"
            case .opened: return "hand.tap.fill"
            }
        }
    }

    var id = UUID()
    var date: Date
    var kind: String
    var action: Action
    /// Set for general reminders. Older event files decode this as nil.
    var reminderTitle: String? = nil

    var isCheckIn: Bool { kind == ReminderKind.checkIn.rawValue }

    var title: String {
        if let reminderTitle, !reminderTitle.isEmpty { return reminderTitle }
        return isCheckIn ? String(localized: "Check-in") : String(localized: "Check-out")
    }
}

enum Weekday {
    /// Names indexed so that `names[weekday - 1]` matches `Calendar`'s numbering.
    static let names = [String(localized: "Sunday"), String(localized: "Monday"),
                        String(localized: "Tuesday"), String(localized: "Wednesday"),
                        String(localized: "Thursday"), String(localized: "Friday"),
                        String(localized: "Saturday")]
    static let short = [String(localized: "Sun"), String(localized: "Mon"),
                        String(localized: "Tue"), String(localized: "Wed"),
                        String(localized: "Thu"), String(localized: "Fri"),
                        String(localized: "Sat")]

    static func name(_ weekday: Int) -> String { names[(weekday - 1) % 7] }
    static func shortName(_ weekday: Int) -> String { short[(weekday - 1) % 7] }
}
