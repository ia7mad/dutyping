import Foundation

/// Persists confirmed reminder occurrences so rebuilding the notification
/// schedule never brings an already completed occurrence back.
final class AcknowledgementStore {
    static let shared = AcknowledgementStore()

    private let defaults = UserDefaults.standard
    private let key = "completedReminderSeries"
    private let lock = NSLock()
    private let retention: TimeInterval = 120 * 24 * 60 * 60

    private init() {}

    func contains(_ seriesID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return records()[seriesID] != nil
    }

    func markCompleted(_ seriesID: String) {
        lock.lock()
        defer { lock.unlock() }

        let cutoff = Date().addingTimeInterval(-retention).timeIntervalSince1970
        var saved = records().filter { $0.value >= cutoff }
        saved[seriesID] = Date().timeIntervalSince1970
        defaults.set(saved, forKey: key)
    }

    private func records() -> [String: TimeInterval] {
        defaults.dictionary(forKey: key)?.compactMapValues { value in
            if let number = value as? NSNumber { return number.doubleValue }
            return value as? TimeInterval
        } ?? [:]
    }
}
