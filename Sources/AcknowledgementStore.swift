import Foundation

/// Persists confirmed reminder occurrences so rebuilding the notification
/// schedule never brings an already completed occurrence back.
final class AcknowledgementStore {
    static let shared = AcknowledgementStore()

    private let defaults: UserDefaults
    private let key = "completedReminderSeries"
    private let lock = NSLock()
    private let snoozeKey = "snoozedReminderSeries"
    private let dismissedAlarmKey = "dismissedAlarmSeries"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func contains(_ seriesID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return records()[seriesID] != nil
    }

    func markCompleted(_ seriesID: String) {
        lock.lock()
        defer { lock.unlock() }

        var saved = records()
        saved[seriesID] = Date().timeIntervalSince1970
        defaults.set(saved, forKey: key)
        var snoozes = defaults.dictionary(forKey: snoozeKey) ?? [:]
        snoozes.removeValue(forKey: seriesID)
        defaults.set(snoozes, forKey: snoozeKey)
        clearDismissalUnsafe(seriesID)
    }

    func reopen(_ seriesID: String) {
        lock.lock()
        defer { lock.unlock() }
        var saved = records()
        saved.removeValue(forKey: seriesID)
        defaults.set(saved, forKey: key)
        clearDismissalUnsafe(seriesID)
    }

    func snooze(_ seriesID: String, until date: Date) {
        lock.lock()
        defer { lock.unlock() }
        var saved = defaults.dictionary(forKey: snoozeKey) ?? [:]
        saved[seriesID] = date.timeIntervalSince1970
        defaults.set(saved, forKey: snoozeKey)
        clearDismissalUnsafe(seriesID)
    }

    /// Silencing a native alarm is deliberately separate from completing its task.
    func markAlarmDismissed(_ seriesID: String, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard records()[seriesID] == nil else { return }
        var saved = defaults.dictionary(forKey: dismissedAlarmKey) ?? [:]
        saved[seriesID] = date.timeIntervalSince1970
        defaults.set(saved, forKey: dismissedAlarmKey)
    }

    func alarmDismissedAt(_ seriesID: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = defaults.dictionary(forKey: dismissedAlarmKey)?[seriesID] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: value.doubleValue)
    }

    private func clearDismissalUnsafe(_ seriesID: String) {
        var saved = defaults.dictionary(forKey: dismissedAlarmKey) ?? [:]
        saved.removeValue(forKey: seriesID)
        defaults.set(saved, forKey: dismissedAlarmKey)
    }

    func snoozedUntil(_ seriesID: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = defaults.dictionary(forKey: snoozeKey)?[seriesID] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: value.doubleValue)
    }

    private func records() -> [String: TimeInterval] {
        defaults.dictionary(forKey: key)?.compactMapValues { value in
            if let number = value as? NSNumber { return number.doubleValue }
            return value as? TimeInterval
        } ?? [:]
    }
}
