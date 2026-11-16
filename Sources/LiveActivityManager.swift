import ActivityKit
import Foundation
import UIKit
import UserNotifications

@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()
    private let center = UNUserNotificationCenter.current()
    private init() {}

    private(set) var lastError: String?

    func end(seriesID: String) async {
        guard #available(iOS 16.2, *) else { return }
        for activity in Activity<ReminderActivityAttributes>.activities
        where activity.attributes.seriesID == seriesID {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    func syncToNextReminder(paused: Bool = false, fromLiveActivityIntent: Bool = false) async {
        guard #available(iOS 16.2, *) else { return }
        lastError = nil
        let current = Activity<ReminderActivityAttributes>.activities
        guard !paused, ActivityAuthorizationInfo().areActivitiesEnabled else {
            for activity in current { await activity.end(nil, dismissalPolicy: .immediate) }
            return
        }

        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        let now = Date()
        var candidates = (pending + delivered.map(\.request)).compactMap { request -> ActivityCandidate? in
            guard let series = request.content.userInfo["series"] as? String,
                  !AcknowledgementStore.shared.contains(series) else { return nil }
            let stamp = request.content.userInfo["activityDate"] as? TimeInterval
                ?? request.content.userInfo["dueDate"] as? TimeInterval
            guard let due = stamp.map({ Date(timeIntervalSince1970: $0) }) ?? request.scheduledFireDate else { return nil }
            return ActivityCandidate(seriesID: series,
                                     kind: request.content.userInfo["kind"] as? String ?? "personal",
                                     title: request.content.userInfo["eventTitle"] as? String ?? request.content.title,
                                     dueDate: due,
                                     repeatIntervalMinutes: request.content.userInfo["repeatIntervalMinutes"] as? Int ?? 0)
        }

        // Dismissing a banner must not dismiss an unconfirmed, valid activity.
        let store = Store()
        for activity in current where activity.activityState == .active || activity.activityState == .stale {
            let series = activity.attributes.seriesID
            let expected = ReminderPresentationPolicy.currentDate(seriesID: series, kind: activity.attributes.kind,
                reminders: store.reminders, shifts: store.shifts,
                snoozedUntil: AcknowledgementStore.shared.snoozedUntil(series))
            let stillExists = expected.map { abs($0.timeIntervalSince(activity.content.state.dueDate)) < 1 } ??
                (series.hasPrefix("geo-") && store.settings.geofenceEnabled)
            if stillExists && !AcknowledgementStore.shared.contains(series) {
                candidates.append(ActivityCandidate(seriesID: series, kind: activity.attributes.kind,
                    title: activity.attributes.title, dueDate: activity.content.state.dueDate,
                    repeatIntervalMinutes: activity.content.state.repeatIntervalMinutes))
            }
        }

        let canSchedule: Bool
        if #available(iOS 26.0, *) { canSchedule = true } else { canSchedule = false }
        let active = current.first { $0.activityState == .active || $0.activityState == .stale }
        guard let next = ReminderPresentationPolicy.next(candidates, now: now,
                    canSchedule: canSchedule, currentSeries: active?.attributes.seriesID) else {
            for activity in current { await activity.end(nil, dismissalPolicy: .immediate) }
            return
        }

        let matching = current.first {
            guard isOngoing($0), $0.attributes.seriesID == next.seriesID,
                  $0.attributes.title == next.title else { return false }
            if next.startDate > now {
                // Convert activities created by older versions into a hidden
                // scheduled activity, rather than leaving an hour-long timer.
                return isPending($0) && $0.content.state.dueDate == next.dueDate
            }
            return true
        }
        for activity in current where activity.id != matching?.id {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        let state = ReminderActivityAttributes.ContentState(dueDate: next.dueDate, isCompleted: false,
            repeatIntervalMinutes: next.repeatIntervalMinutes, startedAt: next.startDate)
        let content = ActivityContent(state: state, staleDate: next.dueDate)
        if let matching {
            if matching.content.state != state { await matching.update(content) }
            return
        }
        guard UIApplication.shared.applicationState == .active || fromLiveActivityIntent else { return }
        let attributes = ReminderActivityAttributes(seriesID: next.seriesID, title: next.title, kind: next.kind)
        do {
            if #available(iOS 26.0, *), next.startDate > now {
                _ = try Activity.request(attributes: attributes, content: content, pushType: nil,
                    style: .standard,
                    alertConfiguration: AlertConfiguration(
                        title: LocalizedStringResource(stringLiteral: next.title),
                        body: "Starts in 10 minutes", sound: .named("quiet.wav")),
                    start: next.startDate)
            } else {
                _ = try Activity.request(attributes: attributes, content: content, pushType: nil)
            }
        } catch { lastError = error.localizedDescription }
    }

    @available(iOS 16.2, *)
    private func isPending(_ activity: Activity<ReminderActivityAttributes>) -> Bool {
        if #available(iOS 26.0, *) { return activity.activityState == .pending }
        return false
    }

    @available(iOS 16.2, *)
    private func isOngoing(_ activity: Activity<ReminderActivityAttributes>) -> Bool {
        activity.activityState == .active || activity.activityState == .stale || isPending(activity)
    }
}
