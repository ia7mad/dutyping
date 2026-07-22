import Foundation

/// Append-only record of acknowledged reminders.
///
/// Writes happen from the notification delegate, which can run while the app is
/// only briefly awake, so this deliberately avoids the main actor and keeps its
/// own serial queue rather than depending on `Store`.
final class EventLog {
    static let shared = EventLog()

    private static let limit = 40

    private let queue = DispatchQueue(label: "com.dutyping.eventlog")

    private var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("dutyping-events.json")
    }

    private init() {}

    func record(kind: String, action: DutyEvent.Action) {
        queue.async {
            var events = self.loadUnsafe()
            events.insert(DutyEvent(date: Date(), kind: kind, action: action), at: 0)
            if events.count > Self.limit {
                events = Array(events.prefix(Self.limit))
            }
            if let data = try? JSONEncoder().encode(events) {
                try? data.write(to: self.fileURL, options: .atomic)
            }
        }
    }

    func load() -> [DutyEvent] {
        queue.sync { loadUnsafe() }
    }

    func clear() {
        queue.async { try? FileManager.default.removeItem(at: self.fileURL) }
    }

    private func loadUnsafe() -> [DutyEvent] {
        guard let data = try? Data(contentsOf: fileURL),
              let events = try? JSONDecoder().decode([DutyEvent].self, from: data) else { return [] }
        return events
    }
}
