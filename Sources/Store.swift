import Foundation
import Combine

/// Everything the user owns: their shifts and their preferences.
/// Persisted as a single JSON file in the app's Documents directory.
@MainActor
final class Store: ObservableObject {
    @Published var shifts: [Shift] = []
    @Published var settings = Settings()

    private static var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("dutyping.json")
    }

    private struct Payload: Codable {
        var shifts: [Shift]
        var settings: Settings
    }

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        shifts = payload.shifts
        settings = payload.settings
    }

    func save() {
        let payload = Payload(shifts: shifts, settings: settings)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    // MARK: - Mutations
    //
    // Every change writes to disk and rebuilds the notification queue, because a
    // stale queue is exactly the failure this app exists to prevent.

    func addShift(_ shift: Shift) {
        shifts.append(shift)
        commit()
    }

    func updateShift(_ shift: Shift) {
        guard let index = shifts.firstIndex(where: { $0.id == shift.id }) else { return }
        shifts[index] = shift
        commit()
    }

    func deleteShifts(at offsets: IndexSet, in sorted: [Shift]) {
        let doomed = Set(offsets.map { sorted[$0].id })
        shifts.removeAll { doomed.contains($0.id) }
        commit()
    }

    func commit() {
        shifts.sort { ($0.weekday, $0.start.minutesFromMidnight) < ($1.weekday, $1.start.minutesFromMidnight) }
        save()
        Scheduler.shared.reschedule(shifts: shifts, settings: settings)
        GeofenceManager.shared.apply(settings: settings)
    }
}
