import SwiftUI
import CoreLocation

// MARK: - Design tokens

enum Theme {
    static let accent = Color(red: 0.36, green: 0.42, blue: 0.95)
    static let accentSoft = Color(red: 0.55, green: 0.45, blue: 0.98)
    static let warn = Color(red: 0.98, green: 0.62, blue: 0.20)
    static let good = Color(red: 0.20, green: 0.78, blue: 0.55)

    static let cardRadius: CGFloat = 22
    static let gradient = LinearGradient(colors: [accent, accentSoft],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing)
}

/// A rounded surface that adapts to light and dark automatically.
struct Card<Content: View>: View {
    var title: String? = nil
    var icon: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                HStack(spacing: 8) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    Text(title.uppercased())
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.06), radius: 12, y: 4))
    }
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject private var store: Store
    @StateObject private var geofence = GeofenceManager.shared

    @State private var editingShift: Shift?
    @State private var diagnostics = Scheduler.Diagnostics()
    @State private var testSent = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    if !diagnostics.isAuthorized { permissionBanner }
                    shiftsCard
                    timingCard
                    nagCard
                    locationCard
                    diagnosticsCard
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 40)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $editingShift) { shift in
                ShiftEditor(shift: shift) { saved in
                    if store.shifts.contains(where: { $0.id == saved.id }) {
                        store.updateShift(saved)
                    } else {
                        store.addShift(saved)
                    }
                    refresh()
                }
            }
            .task {
                _ = await Scheduler.shared.requestAuthorization()
                store.commit()
                await reloadDiagnostics()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DutyPing")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.gradient)

            Text(nextAlertSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private var nextAlertSummary: String {
        guard let next = diagnostics.upcoming.first else {
            return store.shifts.isEmpty ? "Add a shift to get started"
                                        : "No reminders queued"
        }
        return "Next reminder \(next.date.formatted(.relative(presentation: .named)))"
    }

    private var permissionBanner: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bell.slash.fill")
                    .foregroundStyle(Theme.warn)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notifications are \(diagnostics.authorizationLabel.lowercased())")
                        .font(.subheadline.weight(.semibold))
                    Text("Without them this app cannot remind you of anything. Enable DutyPing in iOS Settings → Notifications.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Shifts

    private var shiftsCard: some View {
        Card(title: "Shifts", icon: "calendar") {
            if store.shifts.isEmpty {
                Text("No shifts yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }

            ForEach(store.shifts) { shift in
                ShiftRow(shift: shift) {
                    editingShift = shift
                } onToggle: { isOn in
                    var updated = shift
                    updated.isEnabled = isOn
                    store.updateShift(updated)
                    refresh()
                }
            }

            Button {
                let today = Calendar.current.component(.weekday, from: Date())
                editingShift = Shift.newDefault(weekday: today)
            } label: {
                Label("Add shift", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.accent.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .tint(Theme.accent)
        }
    }

    // MARK: - Settings cards

    private var timingCard: some View {
        Card(title: "Timing", icon: "clock") {
            SliderRow(label: "Ask after start",
                      value: intBinding(\.checkInDelayMinutes),
                      range: 0...60, unit: "min")
            Divider()
            SliderRow(label: "Ask before end",
                      value: intBinding(\.checkOutLeadMinutes),
                      range: 0...60, unit: "min")
            Text("A short delay gives you a chance to check in on your own first.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var nagCard: some View {
        Card(title: "Follow-ups", icon: "bell.badge") {
            Toggle(isOn: binding(\.nagEnabled)) {
                Text("Keep nagging").font(.subheadline.weight(.medium))
            }
            .tint(Theme.accent)

            if store.settings.nagEnabled {
                Divider()
                SliderRow(label: "Repeat every",
                          value: intBinding(\.nagIntervalMinutes),
                          range: 1...30, unit: "min")
                SliderRow(label: "Up to",
                          value: intBinding(\.nagCount),
                          range: 1...6, unit: "times")
                Text("Tap Done on a reminder to stop that day's follow-ups.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var locationCard: some View {
        Card(title: "Workplace", icon: "location") {
            Toggle(isOn: binding(\.geofenceEnabled)) {
                Text("Remind me on arrival and exit")
                    .font(.subheadline.weight(.medium))
            }
            .tint(Theme.accent)

            if store.settings.geofenceEnabled {
                Divider()

                Button {
                    geofence.requestAuthorization()
                    geofence.captureCurrentLocation()
                } label: {
                    Label(store.settings.hasGeofenceLocation ? "Update to current location"
                                                             : "Use my current location",
                          systemImage: "scope")
                        .font(.subheadline.weight(.medium))
                }
                .tint(Theme.accent)

                if store.settings.hasGeofenceLocation {
                    HStack {
                        Text("Saved").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.4f, %.4f",
                                    store.settings.geofenceLatitude ?? 0,
                                    store.settings.geofenceLongitude ?? 0))
                            .font(.caption.monospaced())
                    }
                    SliderRow(label: "Radius",
                              value: doubleBinding(\.geofenceRadius),
                              range: 50...500, unit: "m")
                } else {
                    Text("No location saved yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if geofence.authorizationStatus != .authorizedAlways {
                    Label("Grant \"Always\" location so arrivals register while the app is closed.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.warn)
                }
            }
        }
        .onChange(of: geofence.capturedLocation?.latitude) { _ in
            guard let coordinate = geofence.capturedLocation else { return }
            store.settings.geofenceLatitude = coordinate.latitude
            store.settings.geofenceLongitude = coordinate.longitude
            store.commit()
            refresh()
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsCard: some View {
        Card(title: "Status", icon: "stethoscope") {
            statusRow("Permission", diagnostics.authorizationLabel,
                      good: diagnostics.isAuthorized)
            statusRow("Queued alerts", "\(diagnostics.pendingCount)",
                      good: diagnostics.pendingCount > 0)
            if store.settings.geofenceEnabled {
                statusRow("Workplace watch", geofence.isMonitoring ? "Active" : "Inactive",
                          good: geofence.isMonitoring)
            }

            if !diagnostics.upcoming.isEmpty {
                Divider()
                Text("NEXT UP")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)

                ForEach(diagnostics.upcoming) { alert in
                    HStack {
                        Text(alert.label).font(.caption)
                        Spacer()
                        Text(alert.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            Button {
                Scheduler.shared.sendTest(after: 10)
                withAnimation { testSent = true }
            } label: {
                Label(testSent ? "Sent — lock your phone and wait 10s"
                               : "Send a test reminder",
                      systemImage: testSent ? "checkmark.circle.fill" : "paperplane.fill")
                    .font(.subheadline.weight(.medium))
            }
            .tint(testSent ? Theme.good : Theme.accent)
            .disabled(testSent)

            Button("Refresh") { refresh() }
                .font(.caption)
                .tint(.secondary)
        }
    }

    private func statusRow(_ label: String, _ value: String, good: Bool) -> some View {
        HStack {
            Circle()
                .fill(good ? Theme.good : Theme.warn)
                .frame(width: 8, height: 8)
            Text(label).font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Plumbing

    private func refresh() {
        Task { await reloadDiagnostics() }
    }

    private func reloadDiagnostics() async {
        diagnostics = await Scheduler.shared.diagnostics()
    }

    private func binding<T>(_ keyPath: WritableKeyPath<Settings, T>) -> Binding<T> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { store.settings[keyPath: keyPath] = $0; store.commit(); refresh() })
    }

    /// Sliders work in `Double`, settings are stored as `Int`.
    private func intBinding(_ keyPath: WritableKeyPath<Settings, Int>) -> Binding<Double> {
        Binding(
            get: { Double(store.settings[keyPath: keyPath]) },
            set: { store.settings[keyPath: keyPath] = Int($0); store.commit(); refresh() })
    }

    private func doubleBinding(_ keyPath: WritableKeyPath<Settings, Double>) -> Binding<Double> {
        binding(keyPath)
    }
}

// MARK: - Components

private struct ShiftRow: View {
    let shift: Shift
    let onTap: () -> Void
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onTap) {
                HStack(spacing: 14) {
                    Text(Weekday.shortName(shift.weekday).uppercased())
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(Theme.gradient, in: Circle())
                        .opacity(shift.isEnabled ? 1 : 0.35)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(shift.start.display) – \(shift.end.display)")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                        if shift.crossesMidnight {
                            Text("ends next day")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            Toggle("", isOn: Binding(get: { shift.isEnabled }, set: onToggle))
                .labelsHidden()
                .tint(Theme.accent)
        }
        .padding(.vertical, 4)
    }
}

/// A labelled slider with the current value shown as a pill.
private struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text("\(Int(value)) \(unit)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Theme.accent.opacity(0.14), in: Capsule())
                    .foregroundStyle(Theme.accent)
            }
            Slider(value: $value, in: range, step: 1)
                .tint(Theme.accent)
        }
    }
}

// MARK: - Editor

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
            ScrollView {
                VStack(spacing: 18) {
                    Card(title: "Day", icon: "calendar") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                                  spacing: 8) {
                            ForEach(1...7, id: \.self) { day in
                                dayChip(day)
                            }
                        }
                    }

                    Card(title: "Hours", icon: "clock") {
                        DatePicker("Start", selection: timeBinding(\.start),
                                   displayedComponents: .hourAndMinute)
                        Divider()
                        DatePicker("End", selection: timeBinding(\.end),
                                   displayedComponents: .hourAndMinute)
                        if draft.crossesMidnight {
                            Label("This shift ends the next morning.",
                                  systemImage: "moon.stars.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Card {
                        Toggle(isOn: $draft.isEnabled) {
                            Text("Enabled").font(.subheadline.weight(.medium))
                        }
                        .tint(Theme.accent)
                    }
                }
                .padding(18)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Shift")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(draft); dismiss() }
                        .font(.body.weight(.semibold))
                }
            }
        }
    }

    private func dayChip(_ day: Int) -> some View {
        let selected = draft.weekday == day
        return Button {
            withAnimation(.snappy) { draft.weekday = day }
        } label: {
            Text(Weekday.shortName(day))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(selected ? AnyShapeStyle(Theme.gradient)
                                     : AnyShapeStyle(Color(.tertiarySystemFill)),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private func timeBinding(_ keyPath: WritableKeyPath<Shift, TimeOfDay>) -> Binding<Date> {
        Binding(
            get: { draft[keyPath: keyPath].asPickerDate },
            set: { draft[keyPath: keyPath] = TimeOfDay.from($0) })
    }
}
