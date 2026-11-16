import Foundation
import CryptoKit
import SwiftUI
#if canImport(AlarmKit)
import AlarmKit
#endif

enum AlarmIdentity {
    static func id(for seriesID: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(("DutyPing.alarm." + seriesID).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }
        return UUID(uuidString: hex[0..<4].joined() + "-" + hex[4..<6].joined() + "-" +
                    hex[6..<8].joined() + "-" + hex[8..<10].joined() + "-" + hex[10..<16].joined())!
    }
}

enum AlarmControlAction: String, Equatable {
    case silence
    case confirm
    case snooze
}

enum AlarmButtonRole {
    case systemStop
    case confirm
    case snooze

    var action: AlarmControlAction {
        switch self {
        case .systemStop: return .silence
        case .confirm: return .confirm
        case .snooze: return .snooze
        }
    }
}

struct ManagedAlarmRecord: Codable, Equatable {
    let seriesID: String
    let kind: String
    let title: String
    let dueDate: Date
    var fireDate: Date? = nil
    var configurationVersion: Int? = nil
    var scheduledDate: Date { fireDate ?? dueDate }
    var id: UUID { AlarmIdentity.id(for: seriesID) }
}

#if canImport(AlarmKit)
@available(iOS 26.0, *)
struct DutyPingAlarmMetadata: AlarmMetadata {
    let seriesID: String
}
#endif

/// AlarmKit owns sound delivery through Silent Mode and Focus. Ordinary
/// notifications remain the fallback when the OS or permission is unavailable.
@MainActor
final class AlarmController {
    static let shared = AlarmController()
    private let registryKey = "dutyping.managedAlarms"
    private(set) var lastError: String?

    private typealias Record = ManagedAlarmRecord

    var isSupported: Bool {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }

    var authorizationLabel: String {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            switch AlarmManager.shared.authorizationState {
            case .authorized: return String(localized: "Allowed")
            case .denied: return String(localized: "Enable Alarms in iPhone Settings")
            case .notDetermined: return String(localized: "Not asked yet")
            @unknown default: return String(localized: "Unknown")
            }
        }
        #endif
        return String(localized: "Requires iOS 26 or later")
    }

    func requestAuthorization() async -> Bool {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            do { return try await AlarmManager.shared.requestAuthorization() == .authorized }
            catch { lastError = error.localizedDescription }
        }
        #endif
        return false
    }

    func reconcile(occurrences: [Occurrence], enabled: Bool, isPaused: Bool = false,
                   resumeAfter: Date? = nil, persistentFollowUps: Bool = false) async -> [String: Date] {
        lastError = nil
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            let manager = AlarmManager.shared
            var saved = records()
            let existing = Set(((try? manager.alarms) ?? []).map(\.id))
            let allowed = enabled && manager.authorizationState == .authorized
            let desiredEvents = allowed ? ReminderPresentationPolicy.alarmOccurrences(occurrences,
                now: max(Date(), resumeAfter ?? .distantPast),
                dismissedAt: { AcknowledgementStore.shared.alarmDismissedAt($0) },
                persistentFollowUps: persistentFollowUps) : []
            var desired = Dictionary(uniqueKeysWithValues: desiredEvents.map {
                ($0.seriesID, Record(seriesID: $0.seriesID, kind: $0.kind.rawValue,
                                    title: $0.title, dueDate: $0.dueDate,
                                    fireDate: $0.fireDate, configurationVersion: 2))
            })
            // Keep an explicit test alarm until it fires; routine rebuilds must
            // not cancel the user's test halfway through its ten seconds.
            if allowed, !isPaused, let test = saved["test-alarm"], test.dueDate > Date() {
                desired["test-alarm"] = test
            }
            // Opening the app must not stop a currently ringing alarm.
            let store = Store()
            for (series, record) in saved where allowed && !isPaused && record.scheduledDate <= Date() && existing.contains(record.id) {
                let valid = series == "test-alarm" || store.reminders.contains { $0.ownsSeries(series) } ||
                    store.shifts.contains { $0.isEnabled && series.hasPrefix("shift-\($0.id.uuidString)-") }
                let dismissed = AcknowledgementStore.shared.alarmDismissedAt(series)
                let sameDeadline = desired[series].map { $0.dueDate == record.dueDate } ?? true
                if valid && sameDeadline && !AcknowledgementStore.shared.contains(series) &&
                    (dismissed == nil || dismissed! < record.scheduledDate) {
                    desired[series] = record
                }
            }
            for (series, record) in saved where desired[series] != record {
                do {
                    if existing.contains(record.id) { try manager.cancel(id: record.id) }
                    saved.removeValue(forKey: series)
                }
                catch { lastError = error.localizedDescription }
            }
            var covered: [String: Date] = [:]
            for (series, record) in desired {
                if saved[series] == record && existing.contains(record.id) {
                    covered[series] = record.scheduledDate
                    continue
                }
                do {
                    try await schedule(record)
                    saved[series] = record
                    covered[series] = record.scheduledDate
                } catch { lastError = error.localizedDescription }
            }
            save(saved)
            if enabled && !allowed { lastError = String(localized: "Enable Alarms in iPhone Settings") }
            return covered
        }
        #endif
        return [:]
    }

    func sendTest() async {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *), await requestAuthorization() {
            let record = Record(seriesID: "test-alarm", kind: "test",
                                title: String(localized: "Test strong alarm"),
                                dueDate: Date().addingTimeInterval(10))
            do {
                try? AlarmManager.shared.cancel(id: record.id)
                try await schedule(record)
                var saved = records()
                saved[record.seriesID] = record
                save(saved)
            } catch { lastError = error.localizedDescription }
        }
        #endif
    }

    #if canImport(AlarmKit)
    @available(iOS 26.0, *)
    private func schedule(_ record: Record) async throws {
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: record.title),
            stopButton: AlarmButton(text: "Stop sound", textColor: .white, systemImageName: "bell.slash.fill"),
            secondaryButton: record.kind == "test" ? nil : AlarmButton(text: "Confirm done", textColor: .white, systemImageName: "checkmark.circle.fill"),
            secondaryButtonBehavior: record.kind == "test" ? nil : .custom)
        let attributes = AlarmAttributes(presentation: AlarmPresentation(alert: alert),
            metadata: DutyPingAlarmMetadata(seriesID: record.seriesID), tintColor: Color.indigo)
        let config = AlarmManager.AlarmConfiguration.alarm(schedule: .fixed(record.scheduledDate),
            attributes: attributes,
            stopIntent: DutyPingAlarmControlIntent(action: AlarmButtonRole.systemStop.action,
                seriesID: record.seriesID, kind: record.kind, reminderTitle: record.title),
            secondaryIntent: record.kind == "test" ? nil : DutyPingAlarmControlIntent(action: AlarmButtonRole.confirm.action,
                seriesID: record.seriesID, kind: record.kind, reminderTitle: record.title),
            sound: .default)
        _ = try await AlarmManager.shared.schedule(id: record.id, configuration: config)
    }
    #endif

    private func records() -> [String: Record] {
        guard let data = UserDefaults.standard.data(forKey: registryKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Record].self, from: data)) ?? [:]
    }

    private func save(_ records: [String: Record]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: registryKey)
    }
}
