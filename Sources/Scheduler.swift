import Foundation
import Combine
import UserNotifications

extension UNNotificationRequest {
    var scheduledFireDate: Date? {
        switch trigger {
        case let calendar as UNCalendarNotificationTrigger: return calendar.nextTriggerDate()
        case let interval as UNTimeIntervalNotificationTrigger: return interval.nextTriggerDate()
        default: return nil
        }
    }
}

enum ReminderKind: String {
    case checkIn
    case checkOut
    case personal

    var firstTitle: String {
        switch self {
        case .checkIn: return String(localized: "You're on duty")
        case .checkOut: return String(localized: "Shift over")
        case .personal: return String(localized: "Reminder")
        }
    }

    var firstBody: String {
        switch self {
        case .checkIn: return String(localized: "Did you check in?")
        case .checkOut: return String(localized: "Did you check out?")
        case .personal: return String(localized: "You asked me to remind you.")
        }
    }

    var nagBody: String {
        switch self {
        case .checkIn: return String(localized: "Still haven't checked in.")
        case .checkOut: return String(localized: "Still haven't checked out.")
        case .personal: return String(localized: "This reminder is still waiting for you.")
        }
    }
}

extension Notification.Name {
    static let dutyPingScheduleChanged = Notification.Name("dutyPingScheduleChanged")
}

/// All queue mutations run in order, including completion and snooze actions.
/// MainActor alone is insufficient because notification-center awaits reenter it.
@MainActor
final class Scheduler: ObservableObject {
    static let shared = Scheduler()
    static let categoryID = "DUTY_REMINDER"
    static let doneActionID = "DUTY_DONE"
    static let snoozeActionID = "DUTY_SNOOZE"
    private let center = UNUserNotificationCenter.current()
    private var queueTail: Task<Void, Never>?
    @Published private(set) var lastScheduledDate: Date?
    @Published private(set) var lastError: String?

    private init() {}

    func waitUntilIdle() async { await queueTail?.value }

    func refreshLiveActivity(paused: Bool) async {
        await enqueue { await LiveActivityManager.shared.syncToNextReminder(paused: paused) }.value
    }

    @discardableResult
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = queueTail
        let work = Task { @MainActor in
            await previous?.value
            await operation()
        }
        queueTail = work
        return work
    }

    func registerCategories() {
        let done = UNNotificationAction(identifier: Self.doneActionID,
                                        title: String(localized: "Confirm done"), options: [],
                                        icon: UNNotificationActionIcon(systemImageName: "checkmark.circle.fill"))
        let snooze = UNNotificationAction(identifier: Self.snoozeActionID,
                                          title: String(localized: "Snooze 10 min"), options: [],
                                          icon: UNNotificationActionIcon(systemImageName: "clock.arrow.circlepath"))
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryID, actions: [done, snooze],
                                   intentIdentifiers: [], options: [])
        ])
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func reschedule(shifts: [Shift], reminders: [PersonalReminder], settings: Settings) {
        enqueue { await self.rebuild(shifts: shifts, reminders: reminders, settings: settings) }
    }

    func rescheduleAsync(shifts: [Shift], reminders: [PersonalReminder], settings: Settings) async {
        await enqueue {
            await self.rebuild(shifts: shifts, reminders: reminders, settings: settings)
        }.value
    }

    private func rebuild(shifts: [Shift], reminders: [PersonalReminder], settings: Settings,
                         fromLiveActivityIntent: Bool = false) async {
        lastError = nil
        let pending = await center.pendingNotificationRequests()
        let preserved = pending.filter {
            $0.identifier.hasPrefix("test-") ||
                ($0.identifier.hasPrefix("geo-") && settings.geofenceEnabled && !settings.isPaused)
        }
        let preservedIDs = Set(preserved.map(\.identifier))
        center.removePendingNotificationRequests(withIdentifiers:
            pending.map(\.identifier).filter { !preservedIDs.contains($0) })

        let occurrences = ReminderPlanner().plan(shifts: shifts, reminders: reminders,
                                                settings: settings,
                                                limit: max(0, 58 - preserved.count))
        let alarms = await AlarmController.shared.reconcile(occurrences: occurrences,
                                                            enabled: settings.usesSilentModeAlarms,
                                                            isPaused: settings.isPaused)
        var added: [Occurrence] = []
        for occurrence in occurrences {
            guard !AcknowledgementStore.shared.contains(occurrence.seriesID) else { continue }
            do {
                try await center.add(makeRequest(for: occurrence,
                    hasStrongAlarm: occurrence.nagIndex == 0 && alarms.contains(occurrence.seriesID)))
                added.append(occurrence)
            } catch {
                lastError = error.localizedDescription
            }
        }
        lastScheduledDate = added.last?.fireDate
        await scheduleHousekeeping(after: lastScheduledDate)

        // Remove delivered banners for deleted, disabled, or confirmed tasks.
        let delivered = await center.deliveredNotifications()
        let obsolete = delivered.filter { notification in
            guard let series = notification.request.content.userInfo["series"] as? String else { return false }
            if settings.isPaused || AcknowledgementStore.shared.contains(series) { return true }
            if series.hasPrefix("geo-") && !settings.geofenceEnabled { return true }
            let info = notification.request.content.userInfo
            if series.hasPrefix("shift-") {
                guard let expected = ReminderPresentationPolicy.currentDate(seriesID: series,
                    kind: info["kind"] as? String ?? "", reminders: reminders, shifts: shifts,
                    snoozedUntil: AcknowledgementStore.shared.snoozedUntil(series)) else { return true }
                if let stamp = info["activityDate"] as? TimeInterval {
                    return abs(expected.timeIntervalSince1970 - stamp) >= 1
                }
            }
            return series.hasPrefix("reminder-") &&
                !reminders.contains { $0.ownsSeries(series) }
        }
        center.removeDeliveredNotifications(withIdentifiers: obsolete.map { $0.request.identifier })
        await LiveActivityManager.shared.syncToNextReminder(paused: settings.isPaused,
                                                            fromLiveActivityIntent: fromLiveActivityIntent)
        NotificationCenter.default.post(name: .dutyPingScheduleChanged, object: nil)
    }

    private func rebuildSavedSchedule(fromLiveActivityIntent: Bool = false) async {
        let store = Store()
        await rebuild(shifts: store.shifts, reminders: store.reminders, settings: store.settings,
                      fromLiveActivityIntent: fromLiveActivityIntent)
    }

    func makeRequest(for occurrence: Occurrence, hasStrongAlarm: Bool = false) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = occurrence.title
        content.body = occurrence.nagIndex == 0 ? occurrence.body : occurrence.followUpBody
        content.sound = hasStrongAlarm ? nil : .default
        content.badge = 1
        content.categoryIdentifier = Self.categoryID
        if occurrence.isImportant { content.interruptionLevel = .timeSensitive }
        var info: [AnyHashable: Any] = [
            "series": occurrence.seriesID, "kind": occurrence.kind.rawValue,
            "dueDate": occurrence.dueDate.timeIntervalSince1970,
            "activityDate": (occurrence.activityDate ?? occurrence.dueDate).timeIntervalSince1970,
            "repeatIntervalMinutes": occurrence.repeatIntervalMinutes
        ]
        if let title = occurrence.eventTitle { info["eventTitle"] = title }
        content.userInfo = info
        // Include seconds: relative voice reminders must not fire a minute early.
        let parts = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: occurrence.fireDate)
        return UNNotificationRequest(identifier: "\(occurrence.seriesID)#\(occurrence.nagIndex)",
                                     content: content,
                                     trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
    }

    private func scheduleHousekeeping(after lastFire: Date?) async {
        guard let lastFire else { return }
        let coverageEnd = min(lastFire, Date().addingTimeInterval(21 * 86400))
        let warn = coverageEnd.addingTimeInterval(-2 * 86400)
        guard warn > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = "DutyPing"
        content.body = String(localized: "Open the app to extend your reminder schedule.")
        content.sound = .default
        let parts = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: warn)
        do {
            try await center.add(UNNotificationRequest(identifier: "housekeeping", content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
        } catch { lastError = error.localizedDescription }
    }

    struct Diagnostics {
        var authorizationStatus: UNAuthorizationStatus = .notDetermined
        var pendingCount = 0
        var upcoming: [UpcomingAlert] = []
        var error: String?
        var isAuthorized: Bool {
            authorizationStatus == .authorized || authorizationStatus == .provisional
        }
        var authorizationLabel: String {
            switch authorizationStatus {
            case .authorized: return String(localized: "Allowed")
            case .provisional: return String(localized: "Quiet delivery")
            case .denied: return String(localized: "Blocked in iOS Settings")
            case .notDetermined: return String(localized: "Not asked yet")
            case .ephemeral: return String(localized: "Temporary")
            @unknown default: return String(localized: "Unknown")
            }
        }
    }

    struct UpcomingAlert: Identifiable {
        let id: String
        let label: String
        let date: Date
    }

    func diagnostics() async -> Diagnostics {
        await queueTail?.value
        let settings = await center.notificationSettings()
        let pending = await center.pendingNotificationRequests()
        let upcoming = pending.compactMap { request -> UpcomingAlert? in
            guard request.identifier != "housekeeping",
                  let fire = request.scheduledFireDate, fire > Date() else { return nil }
            return UpcomingAlert(id: request.identifier, label: request.content.title, date: fire)
        }.sorted { $0.date < $1.date }
        return Diagnostics(authorizationStatus: settings.authorizationStatus,
                           pendingCount: pending.count, upcoming: Array(upcoming.prefix(8)),
                           error: lastError ?? AlarmController.shared.lastError ?? LiveActivityManager.shared.lastError)
    }

    func sendTest(after seconds: TimeInterval = 10) {
        enqueue {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Test reminder")
            content.body = String(localized: "If you can see this, DutyPing can reach you.")
            content.sound = .default
            // Test notifications deliberately have no task-completion buttons.
            do {
                try await self.center.add(UNNotificationRequest(identifier: "test-diagnostic",
                    content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)))
            } catch { self.lastError = error.localizedDescription }
            NotificationCenter.default.post(name: .dutyPingScheduleChanged, object: nil)
        }
    }

    func sendStrongTest() async {
        await enqueue {
            await AlarmController.shared.sendTest()
            NotificationCenter.default.post(name: .dutyPingScheduleChanged, object: nil)
        }.value
    }

    func fireNow(kind: ReminderKind, reason: String, settings: Settings) {
        enqueue {
            guard !settings.isPaused, settings.geofenceEnabled else { return }
            let series = "geo-\(kind.rawValue)-\(UUID().uuidString)"
            let now = Date()
            // Region bursts must not exceed the OS queue cap.
            let pending = await self.center.pendingNotificationRequests()
            let liveCount = pending.filter { $0.identifier.hasPrefix("geo-") || $0.identifier.hasPrefix("test-") }.count
            let delays = ReminderPlanner.followUpDelays(settings: settings).prefix(max(0, 58 - liveCount))
            self.center.removePendingNotificationRequests(withIdentifiers:
                pending.filter { !$0.identifier.hasPrefix("geo-") && !$0.identifier.hasPrefix("test-") }.map(\.identifier))
            for (index, delay) in delays.enumerated() {
                let occurrence = Occurrence(kind: kind, title: reason, body: kind.firstBody,
                    followUpBody: kind.nagBody, fireDate: now.addingTimeInterval(max(1, Double(delay) * 60)),
                    dueDate: now, seriesID: series, nagIndex: index, eventTitle: nil,
                    isImportant: true, repeatIntervalMinutes: settings.nagEnabled ? max(1, settings.nagIntervalMinutes) : 0)
                do { try await self.center.add(self.makeRequest(for: occurrence)) }
                catch { self.lastError = error.localizedDescription }
            }
            await self.rebuildSavedSchedule()
        }
    }

    func handle(response: UNNotificationResponse) async {
        await enqueue {
            let request = response.notification.request
            let info = request.content.userInfo
            guard let series = info["series"] as? String,
                  let kind = info["kind"] as? String else { return }
            let title = info["eventTitle"] as? String
            switch response.actionIdentifier {
            case Self.snoozeActionID:
                await self.snoozeNow(seriesID: series, kind: kind, title: request.content.title,
                                     eventTitle: title, originalContent: request.content)
            case Self.doneActionID:
                await self.completeNow(seriesID: series, kind: kind, title: title)
            default:
                EventLog.shared.record(kind: kind, action: .opened, title: title)
            }
        }.value
    }

    func handleDeepLink(_ url: URL) {
        guard url.scheme == "dutyping", url.host == "complete",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let series = components.queryItems?.first(where: { $0.name == "series" })?.value,
              !series.isEmpty else { return }
        let kind = components.queryItems?.first(where: { $0.name == "kind" })?.value ?? "personal"
        let title = components.queryItems?.first(where: { $0.name == "title" })?.value
        complete(seriesID: series, kind: kind, title: title)
    }

    func complete(seriesID: String, kind: String, title: String?) {
        enqueue { await self.completeNow(seriesID: seriesID, kind: kind, title: title) }
    }

    func completeAsync(seriesID: String, kind: String, title: String?, fromLiveActivityIntent: Bool = false) async {
        await enqueue {
            await self.completeNow(seriesID: seriesID, kind: kind, title: title,
                                   fromLiveActivityIntent: fromLiveActivityIntent)
        }.value
    }

    func snoozeAsync(seriesID: String, kind: String, title: String, fromLiveActivityIntent: Bool = false) async {
        await enqueue {
            await self.snoozeNow(seriesID: seriesID, kind: kind, title: title,
                                 eventTitle: kind == "personal" ? title : nil,
                                 fromLiveActivityIntent: fromLiveActivityIntent)
        }.value
    }

    private func snoozeNow(seriesID: String, kind: String, title: String, eventTitle: String?,
                           originalContent: UNNotificationContent? = nil,
                           fromLiveActivityIntent: Bool = false) async {
        guard !AcknowledgementStore.shared.contains(seriesID) else { return }
        let until = Date().addingTimeInterval(600)
        AcknowledgementStore.shared.snooze(seriesID, until: until)
        await cancelSeries(seriesID)
        if seriesID.hasPrefix("geo-") {
            let settings = Store().settings
            if settings.geofenceEnabled && !settings.isPaused {
                let pending = await center.pendingNotificationRequests()
                let live = pending.filter { $0.identifier.hasPrefix("geo-") || $0.identifier.hasPrefix("test-") }
                center.removePendingNotificationRequests(withIdentifiers:
                    pending.filter { !$0.identifier.hasPrefix("geo-") && !$0.identifier.hasPrefix("test-") }.map(\.identifier))
                let delays = ReminderPlanner.followUpDelays(settings: settings).prefix(max(0, 58 - live.count))
                for (index, delay) in delays.enumerated() {
                    let content = originalContent?.mutableCopy() as? UNMutableNotificationContent ?? UNMutableNotificationContent()
                    content.title = title
                    content.sound = .default
                    content.categoryIdentifier = Self.categoryID
                    content.userInfo["series"] = seriesID
                    content.userInfo["kind"] = kind
                    content.userInfo["dueDate"] = until.timeIntervalSince1970
                    content.userInfo["activityDate"] = until.timeIntervalSince1970
                    do {
                        try await center.add(UNNotificationRequest(identifier: "\(seriesID)#\(index)", content: content,
                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 600 + Double(delay) * 60, repeats: false)))
                    } catch { lastError = error.localizedDescription }
                }
            }
        }
        EventLog.shared.record(kind: kind, action: .snoozed, title: eventTitle)
        await rebuildSavedSchedule(fromLiveActivityIntent: fromLiveActivityIntent)
    }

    private func completeNow(seriesID: String, kind: String, title: String?,
                              fromLiveActivityIntent: Bool = false) async {
        guard !AcknowledgementStore.shared.contains(seriesID) else { return }
        AcknowledgementStore.shared.markCompleted(seriesID)
        await cancelSeries(seriesID)
        center.setBadgeCount(0) { _ in }
        await LiveActivityManager.shared.end(seriesID: seriesID)
        EventLog.shared.record(kind: kind, action: .done, title: title)
        await rebuildSavedSchedule(fromLiveActivityIntent: fromLiveActivityIntent)
    }

    private func cancelSeries(_ series: String) async {
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers:
            pending.filter { $0.content.userInfo["series"] as? String == series }.map(\.identifier))
        let delivered = await center.deliveredNotifications()
        center.removeDeliveredNotifications(withIdentifiers:
            delivered.filter { $0.request.content.userInfo["series"] as? String == series }.map { $0.request.identifier })
    }
}
