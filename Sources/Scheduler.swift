import Foundation
import UserNotifications

enum ReminderKind: String {
    case checkIn
    case checkOut

    var firstTitle: String {
        switch self {
        case .checkIn: return "You're on duty"
        case .checkOut: return "Shift over"
        }
    }

    var firstBody: String {
        switch self {
        case .checkIn: return "Did you check in?"
        case .checkOut: return "Did you check out?"
        }
    }

    var nagBody: String {
        switch self {
        case .checkIn: return "Still haven't checked in."
        case .checkOut: return "Still haven't checked out."
        }
    }
}

/// One scheduled alert: either the opening reminder (`nagIndex == 0`) or one of
/// its follow-ups.
private struct Occurrence {
    let kind: ReminderKind
    let fireDate: Date
    /// Shared by an opening reminder and its follow-ups, so tapping "Done"
    /// can cancel the rest of the group.
    let seriesID: String
    let nagIndex: Int
}

/// Builds and maintains the pending local-notification queue.
///
/// iOS caps an app at 64 pending notifications, so instead of one repeating
/// weekly trigger per shift we schedule concrete one-shot alerts across a
/// rolling horizon. That is what makes per-occurrence "Done" dismissal
/// possible; the cost is that the queue must be topped up periodically, which
/// `AppDelegate` handles on launch, on foreground, and via background refresh.
final class Scheduler: ObservableObject {
    static let shared = Scheduler()

    static let categoryID = "DUTY_REMINDER"
    static let doneActionID = "DUTY_DONE"
    private static let seriesKey = "series"
    private static let housekeepingID = "housekeeping"

    /// One below the hard limit of 64, leaving room for the housekeeping alert.
    private let maxPending = 60
    private let horizonDays = 21

    private let center = UNUserNotificationCenter.current()

    /// Set once the queue has been built, for the status line in the UI.
    @Published private(set) var lastScheduledDate: Date?

    private init() {}

    // MARK: - Permissions

    func registerCategories() {
        let done = UNNotificationAction(identifier: Self.doneActionID,
                                        title: "Done",
                                        options: [])
        let category = UNNotificationCategory(identifier: Self.categoryID,
                                              actions: [done],
                                              intentIdentifiers: [],
                                              options: [])
        center.setNotificationCategories([category])
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    // MARK: - Scheduling

    func reschedule(shifts: [Shift], settings: Settings) {
        Task { await rescheduleAsync(shifts: shifts, settings: settings) }
    }

    func rescheduleAsync(shifts: [Shift], settings: Settings) async {
        // Geofence alerts are fired live and are not part of the planned queue,
        // so wiping pending requests here never drops one.
        center.removeAllPendingNotificationRequests()

        let occurrences = plan(shifts: shifts, settings: settings, from: Date())
        for occurrence in occurrences {
            guard let request = makeRequest(for: occurrence) else { continue }
            try? await center.add(request)
        }

        let last = occurrences.last?.fireDate
        await MainActor.run { self.lastScheduledDate = last }
        await scheduleHousekeeping(after: last)
    }

    private func plan(shifts: [Shift], settings: Settings, from now: Date) -> [Occurrence] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var result: [Occurrence] = []

        for offset in 0..<horizonDays {
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

                let dayStamp = Int(day.timeIntervalSince1970)
                result += series(kind: .checkIn, base: checkIn,
                                 seriesID: "\(shift.id.uuidString)-in-\(dayStamp)",
                                 settings: settings, now: now)
                result += series(kind: .checkOut, base: checkOut,
                                 seriesID: "\(shift.id.uuidString)-out-\(dayStamp)",
                                 settings: settings, now: now)
            }
        }

        return Array(result.sorted { $0.fireDate < $1.fireDate }.prefix(maxPending))
    }

    /// The opening reminder plus its follow-ups, dropping anything already past.
    private func series(kind: ReminderKind, base: Date, seriesID: String,
                        settings: Settings, now: Date) -> [Occurrence] {
        let nagCount = settings.nagEnabled ? max(0, settings.nagCount) : 0
        var out: [Occurrence] = []

        for index in 0...nagCount {
            let fire = base.addingTimeInterval(Double(index * settings.nagIntervalMinutes) * 60)
            guard fire > now else { continue }
            out.append(Occurrence(kind: kind, fireDate: fire,
                                  seriesID: seriesID, nagIndex: index))
        }
        return out
    }

    private func makeRequest(for occurrence: Occurrence) -> UNNotificationRequest? {
        let content = UNMutableNotificationContent()
        content.title = occurrence.kind.firstTitle
        content.body = occurrence.nagIndex == 0 ? occurrence.kind.firstBody : occurrence.kind.nagBody
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        content.userInfo = [Self.seriesKey: occurrence.seriesID]

        let parts = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: occurrence.fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)

        return UNNotificationRequest(identifier: "\(occurrence.seriesID)#\(occurrence.nagIndex)",
                                     content: content,
                                     trigger: trigger)
    }

    /// A single nudge shortly before the queue runs dry, so reminders never
    /// lapse silently if background refresh never gets a turn.
    private func scheduleHousekeeping(after lastFire: Date?) async {
        guard let lastFire,
              let warn = Calendar.current.date(byAdding: .day, value: -2, to: lastFire),
              warn > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = "DutyPing"
        content.body = "Open the app to extend your reminder schedule."
        content.sound = .default

        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: warn)
        let request = UNNotificationRequest(
            identifier: Self.housekeepingID,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
        try? await center.add(request)
    }

    // MARK: - Live geofence alerts

    /// Fires immediately, with follow-ups relative to now rather than to a
    /// planned shift time.
    func fireNow(kind: ReminderKind, reason: String, settings: Settings) {
        let seriesID = "geo-\(kind.rawValue)-\(Int(Date().timeIntervalSince1970))"
        let nagCount = settings.nagEnabled ? max(0, settings.nagCount) : 0

        for index in 0...nagCount {
            let content = UNMutableNotificationContent()
            content.title = reason
            content.body = index == 0 ? kind.firstBody : kind.nagBody
            content.sound = .default
            content.categoryIdentifier = Self.categoryID
            content.userInfo = [Self.seriesKey: seriesID]

            // A zero interval is rejected, so the opening alert gets one second.
            let delay = Double(index * settings.nagIntervalMinutes) * 60
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay),
                                                            repeats: false)
            center.add(UNNotificationRequest(identifier: "\(seriesID)#\(index)",
                                             content: content,
                                             trigger: trigger))
        }
    }

    /// Cancels the remaining follow-ups in whichever group the user acted on.
    func dismissSeries(for response: UNNotificationResponse) {
        guard let seriesID = response.notification.request.content.userInfo[Self.seriesKey] as? String
        else { return }

        center.getPendingNotificationRequests { requests in
            let doomed = requests
                .map(\.identifier)
                .filter { $0.hasPrefix("\(seriesID)#") }
            self.center.removePendingNotificationRequests(withIdentifiers: doomed)
        }
    }
}
