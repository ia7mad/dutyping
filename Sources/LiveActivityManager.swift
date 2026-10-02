import ActivityKit
import Foundation
import UserNotifications

/// Best-effort local Live Activity support. DutyPing starts the next reminder
/// when it falls within iOS's Live Activity window. Truly automatic starts
/// while the app has not run require APNs push-to-start and a remote server.
final class LiveActivityManager {
    static let shared = LiveActivityManager()
    private let center = UNUserNotificationCenter.current()

    private init() {}

    func syncToNextReminder() {
        guard #available(iOS 16.2, *) else { return }
        Task { await sync() }
    }

    func end(seriesID: String) {
        guard #available(iOS 16.2, *) else { return }
        Task {
            for activity in Activity<ReminderActivityAttributes>.activities
            where activity.attributes.seriesID == seriesID {
                let final = ReminderActivityAttributes.ContentState(
                    dueDate: activity.content.state.dueDate,
                    isCompleted: true)
                await activity.end(ActivityContent(state: final, staleDate: nil),
                                   dismissalPolicy: .immediate)
            }
        }
    }

    @available(iOS 16.2, *)
    private func sync() async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let requests = await center.pendingNotificationRequests()
        let candidates = requests.compactMap { request -> Candidate? in
            guard request.identifier != "housekeeping",
                  let series = request.content.userInfo["series"] as? String,
                  let fire = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
                    ?? (request.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
            else { return nil }
            return Candidate(seriesID: series,
                             kind: request.content.userInfo["kind"] as? String ?? "personal",
                             title: request.content.userInfo["eventTitle"] as? String
                                ?? request.content.title,
                             fireDate: fire)
        }
        .sorted { $0.fireDate < $1.fireDate }

        guard let next = candidates.first,
              next.fireDate.timeIntervalSinceNow <= 8 * 60 * 60 else {
            return
        }

        let current = Activity<ReminderActivityAttributes>.activities
        if let matching = current.first(where: { $0.attributes.seriesID == next.seriesID }) {
            let state = ReminderActivityAttributes.ContentState(
                dueDate: next.fireDate, isCompleted: false)
            await matching.update(ActivityContent(state: state,
                                                  staleDate: next.fireDate.addingTimeInterval(8 * 3600)))
            return
        }

        for activity in current {
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        let attributes = ReminderActivityAttributes(seriesID: next.seriesID,
                                                    title: next.title,
                                                    kind: next.kind)
        let state = ReminderActivityAttributes.ContentState(
            dueDate: next.fireDate, isCompleted: false)
        _ = try? Activity.request(
            attributes: attributes,
            content: ActivityContent(state: state,
                                     staleDate: next.fireDate.addingTimeInterval(8 * 3600)),
            pushType: nil)
    }

    private struct Candidate {
        let seriesID: String
        let kind: String
        let title: String
        let fireDate: Date
    }
}
