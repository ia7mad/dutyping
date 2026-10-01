import Foundation
import Combine

/// Everything the user owns: their shifts and their preferences.
/// Persisted as a single JSON file in the app's Documents directory.
@MainActor
final class Store: ObservableObject {
    @Published var shifts: [Shift] = []
    @Published var reminders: [PersonalReminder] = []
    @Published var settings = Settings()

    private static var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("dutyping.json")
    }

    private struct Payload: Codable {
        var shifts: [Shift]
        var reminders: [PersonalReminder]
        var settings: Settings

        enum CodingKeys: String, CodingKey {
            case shifts, reminders, settings
        }

        init(shifts: [Shift], reminders: [PersonalReminder], settings: Settings) {
            self.shifts = shifts
            self.reminders = reminders
            self.settings = settings
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            shifts = try container.decodeIfPresent([Shift].self, forKey: .shifts) ?? []
            reminders = try container.decodeIfPresent([PersonalReminder].self, forKey: .reminders) ?? []
            settings = try container.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
        }
    }

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        shifts = payload.shifts
        reminders = payload.reminders
        settings = payload.settings
    }

    func save() {
        let payload = Payload(shifts: shifts, reminders: reminders, settings: settings)
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

    /// Used when one editor session spans several days at once.
    func addShifts(_ newShifts: [Shift]) {
        shifts.append(contentsOf: newShifts)
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

    func addReminder(_ reminder: PersonalReminder) {
        reminders.append(reminder)
        commit()
    }

    func updateReminder(_ reminder: PersonalReminder) {
        guard let index = reminders.firstIndex(where: { $0.id == reminder.id }) else { return }
        reminders[index] = reminder
        commit()
    }

    func deleteReminder(id: UUID) {
        reminders.removeAll { $0.id == id }
        commit()
    }

    func commit() {
        shifts.sort { ($0.weekday, $0.start.minutesFromMidnight) < ($1.weekday, $1.start.minutesFromMidnight) }
        reminders.sort {
            if $0.hasSchedule != $1.hasSchedule { return !$0.hasSchedule }
            if !$0.hasSchedule { return $0.createdAt > $1.createdAt }
            return $0.dueDate < $1.dueDate
        }
        save()
        Scheduler.shared.reschedule(shifts: shifts, reminders: reminders, settings: settings)
        GeofenceManager.shared.apply(settings: settings)
    }
}
