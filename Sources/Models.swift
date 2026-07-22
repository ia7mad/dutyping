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

    var isCheckIn: Bool { kind == ReminderKind.checkIn.rawValue }

    var title: String { isCheckIn ? "Check-in" : "Check-out" }
}

enum Weekday {
    /// Names indexed so that `names[weekday - 1]` matches `Calendar`'s numbering.
    static let names = ["Sunday", "Monday", "Tuesday", "Wednesday",
                        "Thursday", "Friday", "Saturday"]
    static let short = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    static func name(_ weekday: Int) -> String { names[(weekday - 1) % 7] }
    static func shortName(_ weekday: Int) -> String { short[(weekday - 1) % 7] }
}
