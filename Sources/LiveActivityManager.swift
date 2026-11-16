import ActivityKit
import Foundation
import UIKit
import UserNotifications

@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()
    private let center = UNUserNotificationCenter.current()
    private init() {}

    func end(seriesID: String) async {
        guard #available(iOS 16.2, *) else { return }
        for activity in Activity<ReminderActivityAttributes>.activities
        where activity.attributes.seriesID == seriesID {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    func syncToNextReminder(paused: Bool = false) async {
        guard #available(iOS 16.2, *) else { return }
        let current = Activity<ReminderActivityAttributes>.activities
        guard !paused, ActivityAuthorizationInfo().areActivitiesEnabled else {
            for activity in current { await activity.end(nil, dismissalPolicy: .immediate) }
            return
        }

        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        let now = Date()
        let candidates = (pending + delivered.map(\.request)).compactMap { request -> Candidate? in
            guard let series = request.content.userInfo["series"] as? String,
                  !AcknowledgementStore.shared.contains(series) else { return nil }
            let stamp = request.content.userInfo["dueDate"] as? TimeInterval
            guard let due = stamp.map({ Date(timeIntervalSince1970: $0) }) ?? request.scheduledFireDate,
                  due > now.addingTimeInterval(-8 * 3600),
                  due <= now.addingTimeInterval(8 * 3600) else { return nil }
            return Candidate(seriesID: series,
                             kind: request.content.userInfo["kind"] as? String ?? "personal",
                             title: request.content.userInfo["eventTitle"] as? String ?? request.content.title,
                             dueDate: due,
                             repeatIntervalMinutes: request.content.userInfo["repeatIntervalMinutes"] as? Int ?? 0)
        }.sorted {
            if $0.dueDate != $1.dueDate { return $0.dueDate < $1.dueDate }
            return $0.seriesID < $1.seriesID
        }

        guard let next = candidates.first else {
            for activity in current { await activity.end(nil, dismissalPolicy: .immediate) }
            return
        }

        let matching = current.first {
            ($0.activityState == .active || $0.activityState == .stale) &&
                $0.attributes.seriesID == next.seriesID && $0.attributes.title == next.title
        }
        for activity in current where activity.id != matching?.id {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        let state = ReminderActivityAttributes.ContentState(
            dueDate: next.dueDate, isCompleted: false,
            repeatIntervalMinutes: next.repeatIntervalMinutes,
            startedAt: matching?.content.state.startedAt ?? min(now, next.dueDate))
        let content = ActivityContent(state: state, staleDate: next.dueDate)
        if let matching {
            await matching.update(content)
        } else if UIApplication.shared.applicationState == .active {
            // iOS only permits a local start in the foreground. Updates and
            // endings remain valid from background notification actions.
            do {
                _ = try Activity.request(
                    attributes: ReminderActivityAttributes(seriesID: next.seriesID,
                                                            title: next.title, kind: next.kind),
                    content: content, pushType: nil)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private(set) var lastError: String?

    private struct Candidate {
        let seriesID: String
        let kind: String
        let title: String
        let dueDate: Date
        let repeatIntervalMinutes: Int
    }
}
