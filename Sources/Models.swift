import Foundation

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
        "\(start.display) – \(end.display)" + (crossesMidnight ? " (next day)" : "")
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
        case .personal: return "Personal"
        case .health: return "Health"
        case .medicine: return "Medicine"
        case .work: return "Work"
        case .money: return "Bills"
        case .errands: return "Errands"
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
        case .never: return "Never"
        case .daily: return "Every day"
        case .weekdays: return "Weekdays"
        case .weekly: return "Every week"
        case .monthly: return "Every month"
        }
    }
}

enum ReminderPriority: String, Codable, CaseIterable, Identifiable {
    case normal
    case important

    var id: String { rawValue }
    var label: String { self == .important ? "Important" : "Normal" }
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

    var cleanTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var summary: String {
        if repeatRule == .never {
            return dueDate.formatted(date: .abbreviated, time: .shortened)
        }
        return "\(repeatRule.label) · \(dueDate.formatted(date: .omitted, time: .shortened))"
    }

    static func newDefault(date: Date = Date().addingTimeInterval(60 * 60)) -> PersonalReminder {
        PersonalReminder(title: "", dueDate: date)
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
            case .done: return "Confirmed"
            case .snoozed: return "Snoozed"
            case .opened: return "Opened"
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
        return isCheckIn ? "Check-in" : "Check-out"
    }
}

enum Weekday {
    /// Names indexed so that `names[weekday - 1]` matches `Calendar`'s numbering.
    static let names = ["Sunday", "Monday", "Tuesday", "Wednesday",
                        "Thursday", "Friday", "Saturday"]
    static let short = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    static func name(_ weekday: Int) -> String { names[(weekday - 1) % 7] }
    static func shortName(_ weekday: Int) -> String { short[(weekday - 1) % 7] }
}
