import SwiftUI

struct QuickCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var assistant = AssistantConfiguration.shared
    @StateObject private var voice = VoiceCaptureService()

    let shifts: [Shift]
    let onSave: (PersonalReminder) -> Void

    @State private var text = ""
    @State private var preview: PersonalReminder?
    @State private var isOrganizing = false
    @State private var saved = false
    @AppStorage("capture.speechLanguage") private var speechLanguage = "auto"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    captureCard
                    if let error = voice.errorMessage { messageCard(error) }
                    if let preview { previewCard(preview) }
                    else { actionCard }
                }
                .padding(18)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Quick capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }
                }
            }
            .onChange(of: voice.transcript) { transcript in
                guard !transcript.isEmpty else { return }
                text = transcript
            }
            .onDisappear {
                if !saved { voice.discardRecording() }
            }
        }
    }

    private var captureCard: some View {
        Card {
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(voice.isRecording ? Color.red.opacity(0.14)
                                                : Theme.accent.opacity(0.12))
                        .frame(width: 104, height: 104)
                    Circle()
                        .fill(voice.isRecording ? Color.red : Theme.accent)
                        .frame(width: 76, height: 76)
                        .shadow(color: (voice.isRecording ? Color.red : Theme.accent).opacity(0.3),
                                radius: 12, y: 5)
                    Image(systemName: voice.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .contentShape(Circle())
                .onTapGesture {
                    Haptics.tap()
                    Task { await voice.toggle(localeIdentifier: selectedSpeechLocale) }
                }

                VStack(spacing: 4) {
                    Text(voice.isRecording ? "Listening… tap to stop" : "Say it before it slips away")
                        .font(.headline)
                    Text("Arabic and English are supported. The original audio stays on your phone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Picker("Speech language", selection: $speechLanguage) {
                    Text("Automatic").tag("auto")
                    Text("Arabic").tag("ar-SA")
                    Text("English").tag("en-US")
                }
                .pickerStyle(.segmented)

                TextField("Or type anything…", text: $text, axis: .vertical)
                    .lineLimit(3...7)
                    .padding(14)
                    .background(Color(.tertiarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private var actionCard: some View {
        Card(title: "Save", icon: "tray.and.arrow.down.fill") {
            Button {
                organize()
            } label: {
                HStack {
                    if isOrganizing { ProgressView().tint(.white) }
                    Label {
                        Text(L10n.text(assistant.isEnabled && assistant.hasAPIKey
                                       ? "Organize with AI" : "Organize locally"))
                    } icon: {
                        Image(systemName: "wand.and.stars")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .foregroundStyle(.white)
                .background(Theme.gradient,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isOrganizing || cleanText.isEmpty)

            Button {
                var reminder = PersonalReminder.inbox(
                    title: cleanText.isEmpty ? "Voice note" : cleanText,
                    notes: cleanText,
                    source: voice.audioFileName == nil ? .manual : .voice)
                reminder.audioFileName = voice.audioFileName
                finish(reminder)
            } label: {
                Label("Save to inbox — choose a time later", systemImage: "tray.fill")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.accent.opacity(0.11),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .tint(Theme.accent)
            .disabled(cleanText.isEmpty && voice.audioFileName == nil)

            Text("If no time was mentioned, DutyPing keeps it in your inbox instead of guessing.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func previewCard(_ reminder: PersonalReminder) -> some View {
        Card(title: "Ready to save", icon: "checkmark.seal.fill") {
            Text(reminder.cleanTitle)
                .font(.headline)

            Label(reminder.category.label, systemImage: reminder.category.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(reminder.category.tint)

            if reminder.hasSchedule {
                Label(reminder.summary, systemImage: "calendar.badge.clock")
                    .font(.subheadline)
            } else {
                Label("Inbox — no time was invented", systemImage: "tray.fill")
                    .font(.subheadline)
                    .foregroundStyle(Theme.warn)
            }

            if let checklist = reminder.checklist, !checklist.isEmpty {
                Divider()
                ForEach(checklist, id: \.self) { item in
                    Label(item, systemImage: "circle")
                        .font(.subheadline)
                }
            }

            Button {
                finish(reminder)
            } label: {
                Label("Save reminder", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .foregroundStyle(.white)
                    .background(Theme.gradient,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            Button("Start over") {
                withAnimation { preview = nil }
            }
            .font(.caption)
            .tint(.secondary)
            .frame(maxWidth: .infinity)
        }
    }

    private func messageCard(_ message: String) -> some View {
        Card {
            Label(message, systemImage: "info.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var cleanText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedSpeechLocale: String? {
        speechLanguage == "auto" ? nil : speechLanguage
    }

    private func organize() {
        guard !cleanText.isEmpty else { return }
        if voice.isRecording { voice.stop() }
        isOrganizing = true
        Task {
            let reminder: PersonalReminder
            do {
                var organized = try await ReminderAssistant.organize(
                    cleanText,
                    shifts: shifts,
                    useAI: assistant.isEnabled && assistant.hasAPIKey)
                organized.audioFileName = voice.audioFileName
                organized.source = voice.audioFileName == nil ? .manual : .voice
                reminder = organized
            } catch {
                var fallback = LocalReminderParser.organize(cleanText, shifts: shifts)
                fallback.audioFileName = voice.audioFileName
                reminder = fallback
            }
            await MainActor.run {
                withAnimation { preview = reminder }
                isOrganizing = false
            }
        }
    }

    private func finish(_ reminder: PersonalReminder) {
        if voice.isRecording { voice.stop() }
        saved = true
        onSave(reminder)
        Haptics.success()
        dismiss()
    }

    private func cancel() {
        voice.discardRecording()
        dismiss()
    }
}

struct AssistantSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var configuration = AssistantConfiguration.shared
    @State private var key = ""
    @State private var savedMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Card(title: "Smart assistant", icon: "brain.head.profile") {
                        Toggle("Use DeepSeek to organize captures",
                               isOn: $configuration.isEnabled)
                            .tint(Theme.accent)
                            .disabled(!configuration.hasAPIKey)

                        Text("AI only receives the text you capture. Audio, location, reminder history, and notification scheduling stay on your iPhone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Card(title: "DeepSeek API key", icon: "key.fill") {
                        SecureField(configuration.hasAPIKey
                                    ? L10n.text("Key saved in Keychain") : "sk-…",
                                    text: $key)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(12)
                            .background(Color(.tertiarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: 12))

                        Button("Save key") {
                            if configuration.saveAPIKey(key) {
                                savedMessage = key.isEmpty
                                    ? String(localized: "Key removed")
                                    : String(localized: "Saved securely")
                                key = ""
                                if configuration.hasAPIKey { configuration.isEnabled = true }
                                Haptics.success()
                            }
                        }
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if configuration.hasAPIKey {
                            Button("Remove saved key", role: .destructive) {
                                _ = configuration.saveAPIKey("")
                                savedMessage = String(localized: "Key removed")
                            }
                            .font(.caption)
                        }

                        if let savedMessage {
                            Label(savedMessage, systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.good)
                        }

                        Link("Create or manage a DeepSeek API key",
                             destination: URL(string: "https://platform.deepseek.com/api_keys")!)
                            .font(.caption)
                    }

                    Card {
                        Label("DutyPing always falls back to its local Arabic/English parser if AI is disabled, offline, or unavailable.",
                              systemImage: "lock.shield.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(18)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Assistant settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
