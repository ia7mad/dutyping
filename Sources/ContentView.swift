import SwiftUI
import CoreLocation
import UIKit

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

enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
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
    @State private var events: [DutyEvent] = []
    @State private var testSent = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    countdownCard
                    if !diagnostics.isAuthorized { permissionBanner }
                    shiftsCard
                    pauseCard
                    timingCard
                    nagCard
                    locationCard
                    if !events.isEmpty { historyCard }
                    diagnosticsCard
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 40)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $editingShift) { shift in
                ShiftEditor(shift: shift,
                            isNew: !store.shifts.contains { $0.id == shift.id }) { saved in
                    if store.shifts.contains(where: { $0.id == saved[0].id }) {
                        store.updateShift(saved[0])
                    } else {
                        store.addShifts(saved)
                    }
                    Haptics.success()
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
        HStack(spacing: 14) {
            Image("Logo")
                .resizable()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .shadow(color: Theme.accent.opacity(0.35), radius: 8, y: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text("DutyPing")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.gradient)
                Text(store.settings.isPaused ? "Paused" : "\(diagnostics.pendingCount) reminders queued")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 12)
    }

    /// The hero: a live countdown so it is always obvious whether the app is
    /// actually going to do something, and when.
    private var countdownCard: some View {
        Card {
            if store.settings.isPaused, let until = store.settings.pausedUntil {
                labelled(icon: "pause.circle.fill", tint: Theme.warn,
                         title: "Reminders paused",
                         detail: "Resuming \(until.formatted(date: .abbreviated, time: .shortened))")
            } else if let next = diagnostics.upcoming.first {
                VStack(alignment: .leading, spacing: 8) {
                    Text("NEXT REMINDER")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)

                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(countdown(to: next.date, now: context.date))
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Theme.gradient)
                            .contentTransition(.numericText())
                    }

                    Text("\(next.label) · \(next.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                labelled(icon: "moon.zzz.fill", tint: .secondary,
                         title: store.shifts.isEmpty ? "No shifts yet" : "Nothing queued",
                         detail: store.shifts.isEmpty ? "Add a shift to get started"
                                                      : "Check your shifts are enabled")
            }
        }
    }

    private func labelled(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func countdown(to date: Date, now: Date) -> String {
        let remaining = max(0, Int(date.timeIntervalSince(now)))
        let days = remaining / 86400
        let hours = (remaining % 86400) / 3600
        let minutes = (remaining % 3600) / 60
        let seconds = remaining % 60

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        return String(format: "%02d:%02d", minutes, seconds)
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
                    Haptics.tap()
                    editingShift = shift
                } onToggle: { isOn in
                    var updated = shift
                    updated.isEnabled = isOn
                    store.updateShift(updated)
                    Haptics.tap()
                    refresh()
                } onDelete: {
                    store.shifts.removeAll { $0.id == shift.id }
                    store.commit()
                    refresh()
                }
            }

            Button {
                let today = Calendar.current.component(.weekday, from: Date())
                Haptics.tap()
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

    // MARK: - Pause

    private var pauseCard: some View {
        Card(title: "Pause", icon: "pause.circle") {
            if store.settings.isPaused {
                Button {
                    store.settings.pausedUntil = nil
                    store.commit()
                    Haptics.success()
                    refresh()
                } label: {
                    Label("Resume reminders", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.good.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .tint(Theme.good)
            } else {
                Text("Going off duty for a while? Mute everything without deleting your shifts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    pauseButton("1 hour", hours: 1)
                    pauseButton("Today", hours: nil)
                    pauseButton("1 week", hours: 24 * 7)
                }
            }
        }
    }

    private func pauseButton(_ label: String, hours: Int?) -> some View {
        Button {
            let until: Date
            if let hours {
                until = Date().addingTimeInterval(Double(hours) * 3600)
            } else {
                // "Today" means until tomorrow morning.
                let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
                until = Calendar.current.startOfDay(for: tomorrow)
            }
            store.settings.pausedUntil = until
            store.commit()
            Haptics.success()
            refresh()
        } label: {
            Text(label)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Theme.accent.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .tint(Theme.accent)
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
            Text("Set the first to 0 to be pinged the moment your shift starts.")
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
                Text("Reminders carry Done and Snooze buttons — swipe down on one to see them.")
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
                    Haptics.tap()
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
                              value: binding(\.geofenceRadius),
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
            Haptics.success()
            refresh()
        }
    }

    // MARK: - History

    private var historyCard: some View {
        Card(title: "Recent", icon: "clock.arrow.circlepath") {
            ForEach(events.prefix(6)) { event in
                HStack(spacing: 10) {
                    Image(systemName: event.action.icon)
                        .font(.system(size: 14))
                        .foregroundStyle(event.action == .done ? Theme.good : Theme.accent)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(event.title) · \(event.action.label)")
                            .font(.subheadline)
                        Text(event.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            Button("Clear history") {
                EventLog.shared.clear()
                withAnimation { events = [] }
            }
            .font(.caption)
            .tint(.secondary)
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

            if diagnostics.upcoming.count > 1 {
                Divider()
                Text("ALSO COMING UP")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)

                ForEach(diagnostics.upcoming.dropFirst()) { alert in
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
                Haptics.success()
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
        events = EventLog.shared.load()
    }

    private func binding<T>(_ keyPath: WritableKeyPath<Settings, T>) -> Binding<T> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { store.settings[keyPath: keyPath] = $0; store.commit(); refresh() })
    }

    /// Sliders work in `Double`, these settings are stored as `Int`.
    private func intBinding(_ keyPath: WritableKeyPath<Settings, Int>) -> Binding<Double> {
        Binding(
            get: { Double(store.settings[keyPath: keyPath]) },
            set: { store.settings[keyPath: keyPath] = Int($0); store.commit(); refresh() })
    }
}

// MARK: - Components

private struct ShiftRow: View {
    let shift: Shift
    let onTap: () -> Void
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void

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
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("Delete shift", systemImage: "trash")
            }
        }
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
    @State private var selectedDays: Set<Int>
    private let isNew: Bool
    private let onSave: ([Shift]) -> Void

    init(shift: Shift, isNew: Bool, onSave: @escaping ([Shift]) -> Void) {
        _draft = State(initialValue: shift)
        _selectedDays = State(initialValue: [shift.weekday])
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Card(title: isNew ? "Days" : "Day", icon: "calendar") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                                  spacing: 8) {
                            ForEach(1...7, id: \.self) { day in
                                dayChip(day)
                            }
                        }

                        if isNew {
                            HStack(spacing: 8) {
                                presetButton("Mon–Fri", days: [2, 3, 4, 5, 6])
                                presetButton("Weekend", days: [1, 7])
                                presetButton("Every day", days: Set(1...7))
                            }
                            Text("Pick several days to create one shift for each.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
            .navigationTitle(isNew ? "New shift" : "Edit shift")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .font(.body.weight(.semibold))
                        .disabled(selectedDays.isEmpty)
                }
            }
        }
    }

    private func save() {
        let days = selectedDays.sorted()
        guard !days.isEmpty else { return }

        if isNew {
            onSave(days.map { day in
                Shift(weekday: day, start: draft.start, end: draft.end,
                      isEnabled: draft.isEnabled)
            })
        } else {
            var updated = draft
            updated.weekday = days[0]
            onSave([updated])
        }
        dismiss()
    }

    private func dayChip(_ day: Int) -> some View {
        let selected = selectedDays.contains(day)
        return Button {
            Haptics.tap()
            withAnimation(.snappy) {
                if isNew {
                    if selected { selectedDays.remove(day) } else { selectedDays.insert(day) }
                } else {
                    selectedDays = [day]
                }
            }
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

    private func presetButton(_ label: String, days: Set<Int>) -> some View {
        Button {
            Haptics.tap()
            withAnimation(.snappy) { selectedDays = days }
        } label: {
            Text(label)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Theme.accent.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .tint(Theme.accent)
    }

    private func timeBinding(_ keyPath: WritableKeyPath<Shift, TimeOfDay>) -> Binding<Date> {
        Binding(
            get: { draft[keyPath: keyPath].asPickerDate },
            set: { draft[keyPath: keyPath] = TimeOfDay.from($0) })
    }
}
