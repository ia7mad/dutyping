import SwiftUI
import CoreLocation

struct ContentView: View {
    @EnvironmentObject private var store: Store
    @StateObject private var scheduler = Scheduler.shared
    @StateObject private var geofence = GeofenceManager.shared

    @State private var editingShift: Shift?
    @State private var notificationsAllowed = true

    var body: some View {
        NavigationStack {
            List {
                if !notificationsAllowed {
                    Section {
                        Label("Notifications are turned off. Enable them in Settings, or this app can't remind you of anything.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                shiftsSection
                timingSection
                nagSection
                locationSection
                statusSection
            }
            .navigationTitle("DutyPing")
            .toolbar {
                Button {
                    editingShift = Shift.newDefault(weekday: Calendar.current.component(.weekday, from: Date()))
                } label: {
                    Label("Add shift", systemImage: "plus")
                }
            }
            .sheet(item: $editingShift) { shift in
                ShiftEditor(shift: shift) { saved in
                    if store.shifts.contains(where: { $0.id == saved.id }) {
                        store.updateShift(saved)
                    } else {
                        store.addShift(saved)
                    }
                }
            }
            .task {
                notificationsAllowed = await Scheduler.shared.requestAuthorization()
                store.commit()
            }
        }
    }

    // MARK: - Sections

    private var shiftsSection: some View {
        Section("Shifts") {
            if store.shifts.isEmpty {
                Text("No shifts yet. Tap + to add one.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.shifts) { shift in
                Button {
                    editingShift = shift
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Weekday.name(shift.weekday))
                                .font(.body)
                            Text(shift.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !shift.isEnabled {
                            Text("Off").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .tint(.primary)
            }
            .onDelete { offsets in
                store.deleteShifts(at: offsets, in: store.shifts)
            }
        }
    }

    private var timingSection: some View {
        Section {
            Stepper("Ask \(store.settings.checkInDelayMinutes) min after start",
                    value: binding(\.checkInDelayMinutes), in: 0...60)
            Stepper("Ask \(store.settings.checkOutLeadMinutes) min before end",
                    value: binding(\.checkOutLeadMinutes), in: 0...60)
        } header: {
            Text("Timing")
        } footer: {
            Text("A short delay after the shift starts gives you a chance to check in on your own first.")
        }
    }

    private var nagSection: some View {
        Section {
            Toggle("Keep nagging", isOn: binding(\.nagEnabled))
            if store.settings.nagEnabled {
                Stepper("Every \(store.settings.nagIntervalMinutes) min",
                        value: binding(\.nagIntervalMinutes), in: 1...30)
                Stepper("Up to \(store.settings.nagCount) times",
                        value: binding(\.nagCount), in: 1...6)
            }
        } header: {
            Text("Follow-ups")
        } footer: {
            Text("Tap Done on a reminder to stop that day's follow-ups.")
        }
    }

    private var locationSection: some View {
        Section {
            Toggle("Remind me at the workplace", isOn: binding(\.geofenceEnabled))

            if store.settings.geofenceEnabled {
                Button("Use my current location") {
                    geofence.requestAuthorization()
                    geofence.captureCurrentLocation()
                }

                if store.settings.hasGeofenceLocation {
                    LabeledContent("Saved") {
                        Text(String(format: "%.4f, %.4f",
                                    store.settings.geofenceLatitude ?? 0,
                                    store.settings.geofenceLongitude ?? 0))
                            .font(.caption.monospaced())
                    }
                    VStack(alignment: .leading) {
                        Text("Radius: \(Int(store.settings.geofenceRadius)) m")
                        Slider(value: binding(\.geofenceRadius), in: 50...500, step: 10)
                    }
                } else {
                    Text("No location saved yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if geofence.authorizationStatus != .authorizedAlways {
                    Text("Grant \"Always\" location access so arrivals register while the app is closed.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Location")
        }
        .onChange(of: geofence.capturedLocation?.latitude) { _ in
            guard let coordinate = geofence.capturedLocation else { return }
            store.settings.geofenceLatitude = coordinate.latitude
            store.settings.geofenceLongitude = coordinate.longitude
            store.commit()
        }
    }

    private var statusSection: some View {
        Section("Status") {
            if let last = scheduler.lastScheduledDate {
                LabeledContent("Reminders set through",
                               value: last.formatted(date: .abbreviated, time: .omitted))
            } else {
                Text("Nothing scheduled.").foregroundStyle(.secondary)
            }
            if store.settings.geofenceEnabled {
                LabeledContent("Workplace watch",
                               value: geofence.isMonitoring ? "Active" : "Inactive")
            }
        }
    }

    /// Settings live in a struct, so each control needs a binding that also
    /// persists and reschedules on write.
    private func binding<T>(_ keyPath: WritableKeyPath<Settings, T>) -> Binding<T> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { store.settings[keyPath: keyPath] = $0; store.commit() })
    }
}

struct ShiftEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Shift
    private let onSave: (Shift) -> Void

    init(shift: Shift, onSave: @escaping (Shift) -> Void) {
        _draft = State(initialValue: shift)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Day", selection: $draft.weekday) {
                    ForEach(1...7, id: \.self) { day in
                        Text(Weekday.name(day)).tag(day)
                    }
                }
                DatePicker("Start", selection: timeBinding(\.start), displayedComponents: .hourAndMinute)
                DatePicker("End", selection: timeBinding(\.end), displayedComponents: .hourAndMinute)
                Toggle("Enabled", isOn: $draft.isEnabled)

                if draft.crossesMidnight {
                    Text("This shift ends the next morning.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Shift")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(draft); dismiss() }
                }
            }
        }
    }

    private func timeBinding(_ keyPath: WritableKeyPath<Shift, TimeOfDay>) -> Binding<Date> {
        Binding(
            get: { draft[keyPath: keyPath].asPickerDate },
            set: { draft[keyPath: keyPath] = TimeOfDay.from($0) })
    }
}
