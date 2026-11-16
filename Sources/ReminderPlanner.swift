import Foundation

struct Occurrence {
    let kind: ReminderKind
    let title: String
    let body: String
    let followUpBody: String
    let fireDate: Date
    let dueDate: Date
    let seriesID: String
    let nagIndex: Int
    let eventTitle: String?
    let isImportant: Bool
    let repeatIntervalMinutes: Int
}

/// Pure scheduling rules, shared by the notification queue and regression tests.
struct ReminderPlanner {
    var calendar = Calendar.current
    var isCompleted: (String) -> Bool = { AcknowledgementStore.shared.contains($0) }
    var snoozedUntil: (String) -> Date? = { AcknowledgementStore.shared.snoozedUntil($0) }

    func plan(shifts: [Shift], reminders: [PersonalReminder], settings: Settings,
              now: Date = Date(), limit: Int = 58) -> [Occurrence] {
        let start = max(now, settings.pausedUntil ?? .distantPast)
        var all = shiftOccurrences(shifts, settings: settings, now: start)
        for reminder in reminders where reminder.isEnabled && reminder.hasSchedule && !reminder.cleanTitle.isEmpty {
            for base in dates(for: reminder, settings: settings, now: start) {
                all += series(kind: .personal, title: reminder.cleanTitle,
                              body: reminder.notificationDetail,
                              followUpBody: String(format: String(localized: "Still waiting: %@"), reminder.cleanTitle),
                              base: base, seriesID: reminder.seriesID(for: base),
                              eventTitle: reminder.cleanTitle,
                              isImportant: reminder.priority == .important,
                              settings: settings, now: start,
                              recoverOverdue: reminder.repeatRule == .never)
            }
        }
        all.sort(by: ordered)

        // Reserve one slot per occurrence, including an overdue occurrence whose
        // first alert has already fired. Use spare slots when follow-ups are off.
        var seen = Set<String>()
        let heads = all.filter { seen.insert($0.seriesID).inserted }
        let headBudget = min(limit, max(limit / 2, limit - (all.count - heads.count)))
        let selectedHeads = Array(heads.prefix(headBudget))
        let covered = Set(selectedHeads.map(\.seriesID))
        let headIDs = Set(selectedHeads.map { "\($0.seriesID)#\($0.nagIndex)" })
        let tails = all.filter {
            covered.contains($0.seriesID) && !headIDs.contains("\($0.seriesID)#\($0.nagIndex)")
        }
        return (selectedHeads + tails.prefix(max(0, limit - selectedHeads.count))).sorted(by: ordered)
    }

    static func followUpDelays(settings: Settings) -> [Int] {
        guard settings.nagEnabled else { return [0] }
        let interval = min(30, max(1, settings.nagIntervalMinutes))
        if settings.persistentFollowUps {
            return (Array(0...15) + [20, 30, 45, 60, 90, 120, 180, 240, 360, 480]).map { $0 * interval }
        }
        return (0...min(6, max(0, settings.nagCount))).map { $0 * interval }
    }

    private func ordered(_ left: Occurrence, _ right: Occurrence) -> Bool {
        if left.fireDate != right.fireDate { return left.fireDate < right.fireDate }
        if left.isImportant != right.isImportant { return left.isImportant }
        return "\(left.seriesID)#\(left.nagIndex)" < "\(right.seriesID)#\(right.nagIndex)"
    }

    private func lookbackDays(_ settings: Settings) -> Int {
        let minutes = Self.followUpDelays(settings: settings).last ?? 0
        return max(1, Int(ceil(Double(minutes) / 1440)) + 1)
    }

    private func shiftOccurrences(_ shifts: [Shift], settings: Settings, now: Date) -> [Occurrence] {
        let today = calendar.startOfDay(for: now)
        var result: [Occurrence] = []
        for offset in -lookbackDays(settings)..<21 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            for shift in shifts where shift.isEnabled && shift.weekday == calendar.component(.weekday, from: day) {
                let start = shift.start.date(on: day).addingTimeInterval(Double(settings.checkInDelayMinutes) * 60)
                let endDay = shift.crossesMidnight ? calendar.date(byAdding: .day, value: 1, to: day) ?? day : day
                let end = shift.end.date(on: endDay).addingTimeInterval(Double(-settings.checkOutLeadMinutes) * 60)
                let stamp = Int(day.timeIntervalSince1970)
                for (kind, base, suffix) in [(ReminderKind.checkIn, start, "in"), (.checkOut, end, "out")] {
                    result += series(kind: kind, title: kind.firstTitle, body: kind.firstBody,
                                     followUpBody: kind.nagBody, base: base,
                                     seriesID: "shift-\(shift.id.uuidString)-\(suffix)-\(stamp)",
                                     eventTitle: nil, isImportant: true, settings: settings, now: now)
                }
            }
        }
        return result
    }

    private func dates(for reminder: PersonalReminder, settings: Settings, now: Date) -> [Date] {
        // Keep the original date so that remaining follow-ups survive a rebuild.
        if reminder.repeatRule == .never { return [reminder.dueDate] }
        let today = calendar.startOfDay(for: now)
        let anchorWeekday = calendar.component(.weekday, from: reminder.dueDate)
        let anchorDay = calendar.component(.day, from: reminder.dueDate)
        let time = calendar.dateComponents([.hour, .minute, .second], from: reminder.dueDate)
        return (-lookbackDays(settings)..<90).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let candidate = calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0,
                                                second: time.second ?? 0, of: day),
                  candidate >= reminder.dueDate else { return nil }
            switch reminder.repeatRule {
            case .never: return nil
            case .daily: return candidate
            case .weekdays: return calendar.isDateInWeekend(candidate) ? nil : candidate
            case .weekly: return calendar.component(.weekday, from: candidate) == anchorWeekday ? candidate : nil
            case .monthly: return calendar.component(.day, from: candidate) == anchorDay ? candidate : nil
            }
        }
    }

    private func series(kind: ReminderKind, title: String, body: String, followUpBody: String,
                        base: Date, seriesID: String, eventTitle: String?, isImportant: Bool,
                        settings: Settings, now: Date, recoverOverdue: Bool = false) -> [Occurrence] {
        guard !isCompleted(seriesID) else { return [] }
        let snooze = snoozedUntil(seriesID)
        let effectiveBase = snooze ?? base
        let delays = Self.followUpDelays(settings: settings)
        var events = delays.enumerated().compactMap { index, minutes -> Occurrence? in
            let fire = effectiveBase.addingTimeInterval(Double(minutes) * 60)
            guard fire > now else { return nil }
            return Occurrence(kind: kind, title: title, body: body, followUpBody: followUpBody,
                              fireDate: fire, dueDate: effectiveBase, seriesID: seriesID,
                              nagIndex: index, eventTitle: eventTitle, isImportant: isImportant,
                              repeatIntervalMinutes: settings.nagEnabled ? min(30, max(1, settings.nagIntervalMinutes)) : 0)
        }
        // Recover an unconfirmed one-time reminder after the finite iOS queue
        // runs out. Repeating shifts retain a bounded lookback instead.
        if events.isEmpty, settings.nagEnabled, settings.persistentFollowUps,
           recoverOverdue, effectiveBase < now {
            events = delays.enumerated().map { index, minutes in
                Occurrence(kind: kind, title: title, body: body, followUpBody: followUpBody,
                           fireDate: now.addingTimeInterval(Double(minutes) * 60 + 1),
                           dueDate: effectiveBase, seriesID: seriesID, nagIndex: index,
                           eventTitle: eventTitle, isImportant: isImportant,
                           repeatIntervalMinutes: min(30, max(1, settings.nagIntervalMinutes)))
            }
        }
        return events
    }
}
