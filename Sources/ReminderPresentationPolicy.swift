import Foundation

struct ActivityCandidate: Equatable {
    let seriesID: String
    let kind: String
    let title: String
    let dueDate: Date
    let repeatIntervalMinutes: Int

    var startDate: Date { dueDate.addingTimeInterval(-10 * 60) }
}

enum ReminderPresentationPolicy {
    static func currentDate(seriesID: String, kind: String, reminders: [PersonalReminder],
                            shifts: [Shift], snoozedUntil: Date? = nil) -> Date? {
        if reminders.contains(where: { $0.ownsSeries(seriesID) }),
           let stamp = seriesID.split(separator: "-").last.flatMap({ TimeInterval($0) }) {
            return snoozedUntil ?? Date(timeIntervalSince1970: stamp)
        }
        if let shift = shifts.first(where: { $0.isEnabled && seriesID.hasPrefix("shift-\($0.id.uuidString)-") }),
           let stamp = seriesID.split(separator: "-").last.flatMap({ TimeInterval($0) }) {
            if let snoozedUntil { return snoozedUntil }
            let day = Date(timeIntervalSince1970: stamp)
            guard Calendar.current.component(.weekday, from: day) == shift.weekday else { return nil }
            if kind == ReminderKind.checkIn.rawValue { return shift.start.date(on: day) }
            let endDay = shift.crossesMidnight ? Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day : day
            return shift.end.date(on: endDay)
        }
        return nil
    }

    /// Keep the current overdue task until confirmation. Future tasks should
    /// only occupy the Island during their final ten minutes.
    static func next(_ candidates: [ActivityCandidate], now: Date,
                     canSchedule: Bool, currentSeries: String? = nil) -> ActivityCandidate? {
        let eligible = candidates.filter {
            $0.dueDate > now.addingTimeInterval(-8 * 3600) &&
                (canSchedule || $0.startDate <= now)
        }
        if let current = eligible.first(where: { $0.seriesID == currentSeries && $0.dueDate <= now }) {
            return current
        }
        return eligible.sorted {
            if $0.dueDate != $1.dueDate { return $0.dueDate < $1.dueDate }
            return $0.seriesID < $1.seriesID
        }.first
    }

    /// Only one native alarm is armed per task. Dismissing it arms the next
    /// follow-up without changing the task's identity or acknowledgement.
    static func alarmOccurrences(_ occurrences: [Occurrence], now: Date,
                                 dismissedAt: (String) -> Date? = { _ in nil },
                                 persistentFollowUps: Bool = false,
                                 limit: Int = 20) -> [Occurrence] {
        let grouped = Dictionary(grouping: occurrences, by: \.seriesID)
        let next = grouped.values.compactMap { events -> Occurrence? in
            guard let first = events.sorted(by: { $0.fireDate < $1.fireDate }).first else { return nil }
            if first.dueDate > now { return first }
            guard let dismissed = dismissedAt(first.seriesID), dismissed >= first.dueDate,
                  first.repeatIntervalMinutes > 0 else { return nil }
            let cutoff = max(now, dismissed)
            if persistentFollowUps {
                let interval = Double(first.repeatIntervalMinutes) * 60
                let index = max(1, Int(floor(cutoff.timeIntervalSince(first.dueDate) / interval)) + 1)
                return Occurrence(kind: first.kind, title: first.title, body: first.body,
                    followUpBody: first.followUpBody,
                    fireDate: first.dueDate.addingTimeInterval(Double(index) * interval),
                    dueDate: first.dueDate, seriesID: first.seriesID, nagIndex: index,
                    eventTitle: first.eventTitle, isImportant: first.isImportant,
                    repeatIntervalMinutes: first.repeatIntervalMinutes, activityDate: first.activityDate)
            }
            return events.filter { $0.fireDate > cutoff }.min { $0.fireDate < $1.fireDate }
        }
        return Array(next.sorted {
            if $0.fireDate != $1.fireDate { return $0.fireDate < $1.fireDate }
            return $0.seriesID < $1.seriesID
        }.prefix(max(0, limit)))
    }

    /// Native repeats can fall between the sparse safety-tail notifications.
    /// Replace that series' nearest alert so the dashboard and fallback banner
    /// agree with the native alarm, without consuming another OS queue slot.
    static func alignNotifications(_ occurrences: [Occurrence], alarms: [String: Date]) -> [Occurrence] {
        var result = occurrences
        for (series, fireDate) in alarms {
            guard !result.contains(where: { $0.seriesID == series && abs($0.fireDate.timeIntervalSince(fireDate)) < 1 }),
                  let index = result.firstIndex(where: { $0.seriesID == series }) else { continue }
            let original = result[index]
            let interval = Double(max(1, original.repeatIntervalMinutes)) * 60
            let repeatIndex = max(1, Int(round(fireDate.timeIntervalSince(original.dueDate) / interval)))
            result[index] = Occurrence(kind: original.kind, title: original.title, body: original.body,
                followUpBody: original.followUpBody, fireDate: fireDate, dueDate: original.dueDate,
                seriesID: series, nagIndex: 1_000_000 + repeatIndex,
                eventTitle: original.eventTitle, isImportant: original.isImportant,
                repeatIntervalMinutes: original.repeatIntervalMinutes, activityDate: original.activityDate)
        }
        return result.sorted { $0.fireDate < $1.fireDate }
    }
}
