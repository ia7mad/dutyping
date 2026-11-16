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

    /// One strong alarm per occurrence, never one per follow-up. Snoozes keep
    /// the original identity while replacing their deadline.
    static func alarmOccurrences(_ occurrences: [Occurrence], now: Date,
                                 limit: Int = 20) -> [Occurrence] {
        var seen = Set<String>()
        return Array(occurrences.sorted { $0.dueDate < $1.dueDate }.filter {
            $0.dueDate > now && seen.insert($0.seriesID).inserted
        }.prefix(max(0, limit)))
    }
}
