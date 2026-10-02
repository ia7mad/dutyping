import SwiftUI

extension ReminderCategory {
    var tint: Color {
        switch self {
        case .personal: return Theme.accent
        case .health: return Color(red: 0.95, green: 0.30, blue: 0.43)
        case .medicine: return Color(red: 0.20, green: 0.65, blue: 0.82)
        case .work: return Color(red: 0.28, green: 0.48, blue: 0.88)
        case .money: return Color(red: 0.96, green: 0.61, blue: 0.18)
        case .errands: return Color(red: 0.22, green: 0.72, blue: 0.48)
        }
    }
}

struct ReminderRow: View {
    let reminder: PersonalReminder
    let onTap: () -> Void
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(reminder.category.tint.opacity(0.14))
                        Image(systemName: reminder.category.icon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(reminder.category.tint)
                    }
                    .frame(width: 42, height: 42)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(reminder.cleanTitle)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            if reminder.priority == .important {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(Theme.warn)
                            }
                            if reminder.audioFileName != nil {
                                Image(systemName: "waveform")
                                    .font(.caption)
                                    .foregroundStyle(reminder.category.tint)
                            }
                        }
                        Text(reminder.summary)
                            .font(.caption)
                            .foregroundStyle(dueTint)
                            .lineLimit(1)
                        if let checklist = reminder.checklist, !checklist.isEmpty {
                            Label(String(format: String(localized: "%@ · %d items"),
                                         reminder.contentType.label, checklist.count),
                                  systemImage: reminder.contentType.icon)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(reminder.category.tint)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("", isOn: Binding(get: { reminder.isEnabled }, set: onToggle))
                .labelsHidden()
                .tint(Theme.accent)
        }
        .padding(.vertical, 3)
        .opacity(reminder.isEnabled ? 1 : 0.48)
        .contextMenu {
            Button(action: onTap) {
                Label("Edit reminder", systemImage: "pencil")
            }
            Button(role: .destructive, action: onDelete) {
                Label("Delete reminder", systemImage: "trash")
            }
        }
    }

    private var dueTint: Color {
        if !reminder.hasSchedule { return Theme.warn }
        return reminder.repeatRule == .never && reminder.dueDate < Date() ? Theme.warn : .secondary
    }
}

struct ReminderEditor: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var audioPlayer = VoiceNotePlayer()
    @State private var draft: PersonalReminder
    private let isNew: Bool
    private let onSave: (PersonalReminder) -> Void

    init(reminder: PersonalReminder, isNew: Bool,
         onSave: @escaping (PersonalReminder) -> Void) {
        _draft = State(initialValue: reminder)
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    titleCard
                    if draft.audioFileName != nil || !(draft.checklist ?? []).isEmpty {
                        memoryCard
                    }
                    whenCard
                    categoryCard
                    optionsCard
                }
                .padding(18)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(isNew ? "New reminder" : "Edit reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        draft.title = draft.cleanTitle
                        onSave(draft)
                        dismiss()
                    }
                    .font(.body.weight(.semibold))
                    .disabled(draft.cleanTitle.isEmpty)
                }
            }
        }
    }

    private var titleCard: some View {
        Card(title: "Reminder", icon: "text.cursor") {
            TextField("What should I remind you about?", text: $draft.title,
                      axis: .vertical)
                .font(.headline)
                .lineLimit(1...3)

            Divider()

            TextField("Notes (optional)", text: $draft.notes, axis: .vertical)
                .font(.subheadline)
                .lineLimit(2...5)
        }
    }

    private var whenCard: some View {
        Card(title: "When", icon: "calendar.badge.clock") {
            Toggle("Schedule a notification", isOn: scheduleBinding)
                .tint(Theme.accent)

            if draft.hasSchedule {
                Divider()
                DatePicker("Date and time", selection: $draft.dueDate)

                Divider()

                Picker("Repeat", selection: $draft.repeatRule) {
                    ForEach(ReminderRepeat.allCases) { rule in
                        Text(rule.label).tag(rule)
                    }
                }
                .pickerStyle(.menu)

                if draft.repeatRule != .never {
                    Text(repeatExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("This stays in your inbox until you choose a time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var memoryCard: some View {
        Card(title: "Captured with it", icon: "paperclip") {
            if let fileName = draft.audioFileName {
                Button {
                    audioPlayer.toggle(fileName: fileName)
                } label: {
                    Label {
                        Text(L10n.text(audioPlayer.isPlaying
                                       ? "Stop voice note" : "Play original voice note"))
                    } icon: {
                        Image(systemName: audioPlayer.isPlaying
                              ? "stop.circle.fill" : "play.circle.fill")
                    }
                        .font(.subheadline.weight(.medium))
                }
                .tint(Theme.accent)
            }

            if let checklist = draft.checklist, !checklist.isEmpty {
                if draft.audioFileName != nil { Divider() }
                HStack {
                    Label(draft.contentType.label, systemImage: draft.contentType.icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(draft.category.tint)
                    Spacer()
                    if let progress = draft.checklistProgress {
                        Text(progress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(checklist.enumerated()), id: \.offset) { _, item in
                    let completed = draft.completedItems.contains(item)
                    Button {
                        var items = draft.completedItems
                        if completed { items.remove(item) } else { items.insert(item) }
                        draft.completedItems = items
                        Haptics.tap()
                    } label: {
                        HStack {
                            Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(completed ? Theme.good : .secondary)
                            Text(item)
                                .strikethrough(completed)
                                .foregroundStyle(completed ? .secondary : .primary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var categoryCard: some View {
        Card(title: "Category", icon: "square.grid.2x2") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()),
                                GridItem(.flexible())], spacing: 10) {
                ForEach(ReminderCategory.allCases) { category in
                    categoryButton(category)
                }
            }
        }
    }

    private func categoryButton(_ category: ReminderCategory) -> some View {
        let selected = draft.category == category
        return Button {
            Haptics.tap()
            withAnimation(.snappy) { draft.category = category }
        } label: {
            VStack(spacing: 7) {
                Image(systemName: category.icon)
                    .font(.system(size: 17, weight: .semibold))
                Text(category.label)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(selected ? .white : category.tint)
            .background(selected ? AnyShapeStyle(category.tint)
                                 : AnyShapeStyle(category.tint.opacity(0.12)),
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var optionsCard: some View {
        Card(title: "Options", icon: "slider.horizontal.3") {
            Toggle(isOn: $draft.isEnabled) {
                Label("Reminder enabled", systemImage: "bell.fill")
                    .font(.subheadline.weight(.medium))
            }
            .tint(Theme.accent)

            Divider()

            Toggle(isOn: importantBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Important", systemImage: "exclamationmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                    Text("Delivered as a time-sensitive notification")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(Theme.warn)
        }
    }

    private var importantBinding: Binding<Bool> {
        Binding(
            get: { draft.priority == .important },
            set: { draft.priority = $0 ? .important : .normal })
    }

    private var scheduleBinding: Binding<Bool> {
        Binding(
            get: { draft.hasSchedule },
            set: { enabled in
                draft.hasSchedule = enabled
                if enabled && draft.dueDate < Date() {
                    draft.dueDate = Date().addingTimeInterval(60 * 60)
                }
            })
    }

    private var repeatExplanation: String {
        switch draft.repeatRule {
        case .never: return ""
        case .daily: return String(localized: "Repeats every day at the selected time.")
        case .weekdays: return String(localized: "Repeats on weekdays, using your region's weekend.")
        case .weekly:
            return String(format: String(localized: "Repeats every %@."),
                          draft.dueDate.formatted(.dateTime.weekday(.wide)))
        case .monthly:
            return String(format: String(localized: "Repeats on day %d of each month."),
                          Calendar.current.component(.day, from: draft.dueDate))
        }
    }
}
