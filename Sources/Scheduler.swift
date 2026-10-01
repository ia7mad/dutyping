import Foundation
import UserNotifications

enum ReminderKind: String {
    case checkIn
    case checkOut
    case personal

    var firstTitle: String {
        switch self {
        case .checkIn: return "You're on duty"
        case .checkOut: return "Shift over"
        case .personal: return "Reminder"
        }
    }

    var firstBody: String {
        switch self {
        case .checkIn: return "Did you check in?"
        case .checkOut: return "Did you check out?"
        case .personal: return "You asked me to remind you."
        }
    }

    var nagBody: String {
        switch self {
        case .checkIn: return "Still haven't checked in."
        case .checkOut: return "Still haven't checked out."
        case .personal: return "This reminder is still waiting for you."
        }
    }
}

private struct Occurrence {
    let kind: ReminderKind
    let title: String
    let body: String
    let followUpBody: String
    let fireDate: Date
    let seriesID: String
    let nagIndex: Int
    let eventTitle: String?
    let isImportant: Bool
}

/// Maintains the local notification queue for shifts and personal reminders.
/// No reminder data leaves the device.
final class Scheduler: ObservableObject {
    static let shared = Scheduler()

    static let categoryID = "DUTY_REMINDER"
    static let doneActionID = "DUTY_DONE"
    static let snoozeActionID = "DUTY_SNOOZE"

    private static let seriesKey = "series"
    private static let kindKey = "kind"
    private static let titleKey = "eventTitle"
    private static let housekeepingID = "housekeeping"

    /// Leave a few slots below iOS's limit for test, snooze, location, and
    /// housekeeping notifications.
    private let maxPending = 58
    private let shiftHorizonDays = 21
    private let reminderHorizonDays = 90
    private let center = UNUserNotificationCenter.current()

    @Published private(set) var lastScheduledDate: Date?

    private init() {}

    // MARK: - Permissions

    func registerCategories() {
        let done = UNNotificationAction(identifier: Self.doneActionID,
                                        title: "Done",
                                        options: [])
        let snooze = UNNotificationAction(identifier: Self.snoozeActionID,
                                          title: "Snooze 10 min",
                                          options: [])
        let category = UNNotificationCategory(identifier: Self.categoryID,
                                              actions: [done, snooze],
                                              intentIdentifiers: [],
                                              options: [])
        center.setNotificationCategories([category])
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    // MARK: - Scheduling

    func reschedule(shifts: [Shift], reminders: [PersonalReminder], settings: Settings) {
        Task {
            await rescheduleAsync(shifts: shifts, reminders: reminders, settings: settings)
        }
    }

    func rescheduleAsync(shifts: [Shift], reminders: [PersonalReminder],
                         settings: Settings) async {
        let stale = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter {
                !$0.hasPrefix("geo-") &&
                !$0.hasPrefix("snooze-") &&
                !$0.hasPrefix("test-")
            }
        center.removePendingNotificationRequests(withIdentifiers: stale)

        let start = max(Date(), settings.pausedUntil ?? .distantPast)
        let occurrences = plan(shifts: shifts, reminders: reminders,
                               settings: settings, from: start)
        for occurrence in occurrences {
            try? await center.add(makeRequest(for: occurrence))
        }

        let last = occurrences.last?.fireDate
        await MainActor.run { self.lastScheduledDate = last }
        await scheduleHousekeeping(after: last)
    }

    private func plan(shifts: [Shift], reminders: [PersonalReminder],
                      settings: Settings, from now: Date) -> [Occurrence] {
        var result = shiftOccurrences(shifts: shifts, settings: settings, from: now)
        result += reminderOccurrences(reminders: reminders, settings: settings, from: now)
        result.sort {
            if $0.fireDate == $1.fireDate { return $0.isImportant && !$1.isImportant }
            return $0.fireDate < $1.fireDate
        }
        return Array(result.prefix(maxPending))
    }

    private func shiftOccurrences(shifts: [Shift], settings: Settings,
                                  from now: Date) -> [Occurrence] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var result: [Occurrence] = []

        for offset in 0..<shiftHorizonDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let weekday = calendar.component(.weekday, from: day)

            for shift in shifts where shift.isEnabled && shift.weekday == weekday {
                let checkIn = shift.start.date(on: day)
                    .addingTimeInterval(Double(settings.checkInDelayMinutes) * 60)
                var checkOutDay = day
                if shift.crossesMidnight,
                   let next = calendar.date(byAdding: .day, value: 1, to: day) {
                    checkOutDay = next
                }
                let checkOut = shift.end.date(on: checkOutDay)
                    .addingTimeInterval(Double(-settings.checkOutLeadMinutes) * 60)
                let stamp = Int(day.timeIntervalSince1970)

                result += series(kind: .checkIn,
                                 title: ReminderKind.checkIn.firstTitle,
                                 body: ReminderKind.checkIn.firstBody,
                                 followUpBody: ReminderKind.checkIn.nagBody,
                                 base: checkIn,
                                 seriesID: "shift-\(shift.id.uuidString)-in-\(stamp)",
                                 eventTitle: nil, isImportant: true,
                                 settings: settings, now: now)
                result += series(kind: .checkOut,
                                 title: ReminderKind.checkOut.firstTitle,
                                 body: ReminderKind.checkOut.firstBody,
                                 followUpBody: ReminderKind.checkOut.nagBody,
                                 base: checkOut,
                                 seriesID: "shift-\(shift.id.uuidString)-out-\(stamp)",
                                 eventTitle: nil, isImportant: true,
                                 settings: settings, now: now)
            }
        }
        return result
    }

    private func reminderOccurrences(reminders: [PersonalReminder], settings: Settings,
                                     from now: Date) -> [Occurrence] {
        var result: [Occurrence] = []
        for reminder in reminders where reminder.isEnabled && !reminder.cleanTitle.isEmpty {
            for base in dates(for: reminder, from: now) {
                let stamp = Int(base.timeIntervalSince1970)
                let notes = reminder.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                result += series(kind: .personal,
                                 title: reminder.cleanTitle,
                                 body: notes.isEmpty ? reminder.category.label : notes,
                                 followUpBody: "Still waiting: \(reminder.cleanTitle)",
                                 base: base,
                                 seriesID: "reminder-\(reminder.id.uuidString)-\(stamp)",
                                 eventTitle: reminder.cleanTitle,
                                 isImportant: reminder.priority == .important,
                                 settings: settings, now: now)
            }
        }
        return result
    }

    private func dates(for reminder: PersonalReminder, from now: Date) -> [Date] {
        if reminder.repeatRule == .never {
            return reminder.dueDate > now ? [reminder.dueDate] : []
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let anchorWeekday = calendar.component(.weekday, from: reminder.dueDate)
        let anchorDay = calendar.component(.day, from: reminder.dueDate)
        let time = calendar.dateComponents([.hour, .minute], from: reminder.dueDate)
        var dates: [Date] = []

        for offset in 0..<reminderHorizonDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let candidate = calendar.date(bySettingHour: time.hour ?? 9,
                                                minute: time.minute ?? 0,
                                                second: 0, of: day),
                  candidate > now,
                  candidate >= reminder.dueDate else { continue }

            let weekday = calendar.component(.weekday, from: candidate)
            let matches: Bool
            switch reminder.repeatRule {
            case .never: matches = false
            case .daily: matches = true
            case .weekdays: matches = !calendar.isDateInWeekend(candidate)
            case .weekly: matches = weekday == anchorWeekday
            case .monthly: matches = calendar.component(.day, from: candidate) == anchorDay
            }
            if matches { dates.append(candidate) }
        }
        return dates
    }

    private func series(kind: ReminderKind, title: String, body: String,
                        followUpBody: String, base: Date, seriesID: String,
                        eventTitle: String?, isImportant: Bool,
                        settings: Settings, now: Date) -> [Occurrence] {
        let followUpCount = settings.nagEnabled ? max(0, settings.nagCount) : 0
        return (0...followUpCount).compactMap { index in
            let fire = base.addingTimeInterval(Double(index * settings.nagIntervalMinutes) * 60)
            guard fire > now else { return nil }
            return Occurrence(kind: kind, title: title, body: body,
                              followUpBody: followUpBody, fireDate: fire,
                              seriesID: seriesID, nagIndex: index,
                              eventTitle: eventTitle, isImportant: isImportant)
        }
    }

    private func makeRequest(for occurrence: Occurrence) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = occurrence.title
        content.body = occurrence.nagIndex == 0 ? occurrence.body : occurrence.followUpBody
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        if occurrence.isImportant { content.interruptionLevel = .timeSensitive }

        var info: [AnyHashable: Any] = [
            Self.seriesKey: occurrence.seriesID,
            Self.kindKey: occurrence.kind.rawValue
        ]
        if let eventTitle = occurrence.eventTitle { info[Self.titleKey] = eventTitle }
        content.userInfo = info

        let parts = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: occurrence.fireDate)
        return UNNotificationRequest(
            identifier: "\(occurrence.seriesID)#\(occurrence.nagIndex)",
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
    }

    private func scheduleHousekeeping(after lastFire: Date?) async {
        guard let lastFire else { return }
        let coverageEnd = min(lastFire, Date().addingTimeInterval(21 * 24 * 60 * 60))
        guard let warn = Calendar.current.date(byAdding: .day, value: -2, to: coverageEnd),
              warn > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = "DutyPing"
        content.body = "Open the app to extend your reminder schedule."
        content.sound = .default
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: warn)
        try? await center.add(UNNotificationRequest(
            identifier: Self.housekeepingID,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
    }

    // MARK: - Diagnostics

    struct Diagnostics {
        var authorizationStatus: UNAuthorizationStatus = .notDetermined
        var pendingCount = 0
        var upcoming: [UpcomingAlert] = []

        var isAuthorized: Bool {
            authorizationStatus == .authorized || authorizationStatus == .provisional
        }

        var authorizationLabel: String {
            switch authorizationStatus {
            case .authorized: return "Allowed"
            case .provisional: return "Quiet delivery"
            case .denied: return "Blocked in iOS Settings"
            case .notDetermined: return "Not asked yet"
            case .ephemeral: return "Temporary"
            @unknown default: return "Unknown"
            }
        }
    }

    struct UpcomingAlert: Identifiable {
        let id: String
        let label: String
        let date: Date
    }

    func diagnostics() async -> Diagnostics {
        let notificationSettings = await center.notificationSettings()
        let pending = await center.pendingNotificationRequests()
        let upcoming = pending.compactMap { request -> UpcomingAlert? in
            let fire: Date?
            switch request.trigger {
            case let calendar as UNCalendarNotificationTrigger: fire = calendar.nextTriggerDate()
            case let interval as UNTimeIntervalNotificationTrigger: fire = interval.nextTriggerDate()
            default: fire = nil
            }
            guard let fire else { return nil }
            return UpcomingAlert(id: request.identifier,
                                 label: request.content.title,
                                 date: fire)
        }
        .sorted { $0.date < $1.date }

        return Diagnostics(authorizationStatus: notificationSettings.authorizationStatus,
                           pendingCount: pending.count,
                           upcoming: Array(upcoming.prefix(8)))
    }

    func sendTest(after seconds: TimeInterval = 10) {
        let content = UNMutableNotificationContent()
        content.title = "Test reminder"
        content.body = "If you can see this, DutyPing can reach you."
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        center.add(UNNotificationRequest(
            identifier: "test-\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)))
    }

    // MARK: - Live geofence alerts

    func fireNow(kind: ReminderKind, reason: String, settings: Settings) {
        let seriesID = "geo-\(kind.rawValue)-\(Int(Date().timeIntervalSince1970))"
        let followUpCount = settings.nagEnabled ? max(0, settings.nagCount) : 0

        for index in 0...followUpCount {
            let content = UNMutableNotificationContent()
            content.title = reason
            content.body = index == 0 ? kind.firstBody : kind.nagBody
            content.sound = .default
            content.categoryIdentifier = Self.categoryID
            content.userInfo = [Self.seriesKey: seriesID, Self.kindKey: kind.rawValue]
            let delay = Double(index * settings.nagIntervalMinutes) * 60
            center.add(UNNotificationRequest(
                identifier: "\(seriesID)#\(index)",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay),
                                                            repeats: false)))
        }
    }

    func handle(response: UNNotificationResponse) {
        let info = response.notification.request.content.userInfo
        let kind = info[Self.kindKey] as? String ?? ReminderKind.checkIn.rawValue
        let eventTitle = info[Self.titleKey] as? String

        if let seriesID = info[Self.seriesKey] as? String {
            center.getPendingNotificationRequests { requests in
                let identifiers = requests.map(\.identifier)
                    .filter { $0.hasPrefix("\(seriesID)#") }
                self.center.removePendingNotificationRequests(withIdentifiers: identifiers)
            }
        }

        switch response.actionIdentifier {
        case Self.snoozeActionID:
            snooze(kind: kind,
                   title: response.notification.request.content.title,
                   body: response.notification.request.content.body,
                   eventTitle: eventTitle)
            EventLog.shared.record(kind: kind, action: .snoozed, title: eventTitle)
        case Self.doneActionID:
            EventLog.shared.record(kind: kind, action: .done, title: eventTitle)
        default:
            EventLog.shared.record(kind: kind, action: .opened, title: eventTitle)
        }
    }

    private func snooze(kind: String, title: String, body: String,
                        eventTitle: String?, minutes: Double = 10) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = kind == ReminderKind.personal.rawValue
            ? "Snoozed — \(title)"
            : "Snoozed — \(body)"
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        let series = "snooze-\(Int(Date().timeIntervalSince1970))"
        var info: [AnyHashable: Any] = [Self.seriesKey: series, Self.kindKey: kind]
        if let eventTitle { info[Self.titleKey] = eventTitle }
        content.userInfo = info

        center.add(UNNotificationRequest(
            identifier: "\(series)#0",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: minutes * 60,
                                                        repeats: false)))
    }
}
