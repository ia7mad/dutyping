import Foundation
import Security

enum AssistantError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case service(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return String(localized: "Add your DeepSeek API key in Assistant settings.")
        case .invalidResponse: return String(localized: "The assistant returned an answer I couldn't understand.")
        case .service(let message): return message
        }
    }
}

enum KeychainStore {
    private static let service = "com.dutyping.app.assistant"
    private static let account = "deepseek-api-key"

    static func readAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveAPIKey(_ key: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        guard !key.isEmpty, let data = key.data(using: .utf8) else { return true }

        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

@MainActor
final class AssistantConfiguration: ObservableObject {
    static let shared = AssistantConfiguration()

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "assistant.deepseek.enabled") }
    }
    @Published private(set) var hasAPIKey: Bool

    private init() {
        hasAPIKey = !(KeychainStore.readAPIKey() ?? "").isEmpty
        isEnabled = UserDefaults.standard.bool(forKey: "assistant.deepseek.enabled")
    }

    func saveAPIKey(_ rawKey: String) -> Bool {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = KeychainStore.saveAPIKey(key)
        hasAPIKey = saved && !key.isEmpty
        if !hasAPIKey { isEnabled = false }
        return saved
    }
}

/// Converts an unstructured thought into a validated app model. DeepSeek only
/// interprets text; notification scheduling always stays inside DutyPing.
enum ReminderAssistant {
    static func organize(_ text: String, shifts: [Shift], useAI: Bool) async throws
        -> PersonalReminder {
        if useAI, let key = KeychainStore.readAPIKey(), !key.isEmpty {
            do { return try await DeepSeekClient.organize(text, apiKey: key) }
            catch {
                // Capturing a thought must never fail because the network or AI
                // provider is unavailable. Fall through to the local parser.
                return LocalReminderParser.organize(text, shifts: shifts)
            }
        }
        return LocalReminderParser.organize(text, shifts: shifts)
    }
}

private enum DeepSeekClient {
    private struct Message: Encodable {
        let role: String
        let content: String
    }

    private struct RequestBody: Encodable {
        struct ResponseFormat: Encodable { let type = "json_object" }
        let model = "deepseek-flash"
        let messages: [Message]
        let responseFormat = ResponseFormat()

        enum CodingKeys: String, CodingKey {
            case model, messages
            case responseFormat = "response_format"
        }
    }

    private struct Envelope: Decodable {
        struct Choice: Decodable {
            struct Reply: Decodable { let content: String? }
            let message: Reply
        }
        let choices: [Choice]
    }

    private struct Parsed: Decodable {
        let title: String
        let notes: String?
        let dueAt: String?
        let repeatRule: String?
        let category: String?
        let priority: String?
        let checklist: [String]?

        enum CodingKeys: String, CodingKey {
            case title, notes, category, priority, checklist
            case dueAt = "due_at"
            case repeatRule = "repeat_rule"
        }
    }

    static func organize(_ text: String, apiKey: String) async throws -> PersonalReminder {
        guard let url = URL(string: "https://api.deepseek.com/chat/completions") else {
            throw AssistantError.invalidResponse
        }

        let now = ISO8601DateFormatter().string(from: Date())
        let zone = TimeZone.current.identifier
        let system = """
        You organize Arabic or English thoughts into reminders. Return JSON only.
        Current date/time is \(now), timezone \(zone).
        Schema: {"title":"short action", "notes":"useful original detail", "due_at":"ISO-8601 with timezone or null", "repeat_rule":"never|daily|weekdays|weekly|monthly", "category":"personal|health|medicine|work|money|errands", "priority":"normal|important", "checklist":["item"]}.
        Never invent a date or time. If the user did not express one, due_at must be null. Understand Saudi Arabic expressions such as اليوم، بكرة، بعد الدوام، بعد ساعة. Keep names and requested items. Split shopping or packing items into checklist.
        """
        let body = RequestBody(messages: [
            Message(role: "system", content: system),
            Message(role: "user", content: "Organize this as json: \(text)")
        ])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AssistantError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AssistantError.service("DeepSeek returned status \(http.statusCode).")
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard let content = envelope.choices.first?.message.content,
              let json = content.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(Parsed.self, from: json) else {
            throw AssistantError.invalidResponse
        }

        let cleanTitle = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { throw AssistantError.invalidResponse }
        var reminder = PersonalReminder(title: cleanTitle,
                                        notes: parsed.notes ?? text,
                                        dueDate: parseDate(parsed.dueAt) ?? Date().addingTimeInterval(3600))
        reminder.scheduleEnabled = parseDate(parsed.dueAt) != nil
        reminder.repeatRule = ReminderRepeat(rawValue: parsed.repeatRule ?? "") ?? .never
        reminder.category = ReminderCategory(rawValue: parsed.category ?? "") ?? .personal
        reminder.priority = ReminderPriority(rawValue: parsed.priority ?? "") ?? .normal
        reminder.checklist = parsed.checklist?.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        reminder.source = .voice
        return reminder
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

enum LocalReminderParser {
    static func organize(_ rawText: String, shifts: [Shift]) -> PersonalReminder {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = checklist(from: text)
        var reminder = PersonalReminder.inbox(title: title(from: text, hasChecklist: items != nil),
                                              notes: text, source: .voice)
        reminder.category = category(for: text)
        reminder.priority = containsAny(text, ["مهم", "ضروري", "عاجل", "urgent", "important"])
            ? .important : .normal
        reminder.repeatRule = repeatRule(for: text)
        reminder.checklist = items

        if let date = relativeDate(in: text) ?? dateAfterDuty(in: text, shifts: shifts) {
            reminder.dueDate = date
            reminder.scheduleEnabled = true
        }
        return reminder
    }

    private static func title(from text: String, hasChecklist: Bool) -> String {
        var first = text.components(separatedBy: CharacterSet(charactersIn: ",،\n")).first ?? text
        first = replacing(pattern: "^(?:ذك(?:ّ)?رني|remind me(?: to)?)\\s*(?:ب)?",
                          in: first, with: "")
        first = replacing(
            pattern: "\\s*(?:اليوم|بكرة|غد(?:ا|اً))?\\s*(?:الساعة|الساعه|at)\\s*\\d{1,2}(?::\\d{1,2})?\\s*(?:ص|صباح|م|مساء|am|pm)?\\s*$",
            in: first, with: "")
        first = first.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if first.isEmpty, hasChecklist {
            return text.range(of: "[\\p{Arabic}]", options: .regularExpression) != nil
                ? "أغراض البقالة" : "Shopping list"
        }
        return compactTitle(first.isEmpty ? text : first)
            .replacingOccurrences(of: "البقاله", with: "البقالة")
    }

    private static func compactTitle(_ text: String) -> String {
        let first = text.split(whereSeparator: { ".!?؟\n".contains($0) }).first.map(String.init) ?? text
        return first.count > 90 ? String(first.prefix(87)) + "…" : first
    }

    private static func category(for text: String) -> ReminderCategory {
        if containsAny(text, ["دواء", "حبوب", "علاج", "medicine", "pill"]) { return .medicine }
        if containsAny(text, ["تمرين", "ماء", "اشرب", "صحة", "موعد طبي", "health"]) { return .health }
        if containsAny(text, ["فاتورة", "سداد", "ادفع", "بنك", "bill", "pay"]) { return .money }
        if containsAny(text, ["دوام", "عمل", "اجتماع", "مدير", "work", "meeting"]) { return .work }
        if containsAny(text, ["اشتري", "أشتري", "جيب", "اغراض", "أغراض", "بقالة", "بقاله",
                              "سوبرماركت", "مشتريات", "قائمة", "سوق", "buy", "shopping", "grocery"]) {
            return .errands
        }
        return .personal
    }

    private static func repeatRule(for text: String) -> ReminderRepeat {
        if containsAny(text, ["كل يوم", "يوميا", "يوميًا", "daily"]) { return .daily }
        if containsAny(text, ["ايام الدوام", "أيام الدوام", "weekdays"]) { return .weekdays }
        if containsAny(text, ["كل اسبوع", "كل أسبوع", "weekly"]) { return .weekly }
        if containsAny(text, ["كل شهر", "شهريا", "شهريًا", "monthly"]) { return .monthly }
        return .never
    }

    private static func relativeDate(in text: String) -> Date? {
        let normalized = westernDigits(text.lowercased())
        let now = Date()
        if containsAny(normalized, ["بعد ساعة", "in an hour"]) {
            return now.addingTimeInterval(3600)
        }
        if containsAny(normalized, ["بعد ساعتين", "in two hours"]) {
            return now.addingTimeInterval(7200)
        }
        if let amount = captureNumber(pattern: "بعد\\s+(\\d+)\\s*(?:دقيقة|دقائق)", in: normalized) {
            return now.addingTimeInterval(Double(amount) * 60)
        }
        if let amount = captureNumber(pattern: "بعد\\s+(\\d+)\\s*(?:ساعة|ساعات)", in: normalized) {
            return now.addingTimeInterval(Double(amount) * 3600)
        }
        if let amount = captureNumber(pattern: "in\\s+(\\d+)\\s+minutes?", in: normalized) {
            return now.addingTimeInterval(Double(amount) * 60)
        }
        if let amount = captureNumber(pattern: "in\\s+(\\d+)\\s+hours?", in: normalized) {
            return now.addingTimeInterval(Double(amount) * 3600)
        }

        let calendar = Calendar.current
        let isTomorrow = containsAny(normalized, ["بكرة", "غدا", "غداً", "tomorrow"])
        let isToday = containsAny(normalized, ["اليوم", "today"])
        let explicitHour = clockHour(in: normalized)
        guard isTomorrow || isToday || explicitHour != nil else { return nil }
        let base = isTomorrow
            ? calendar.date(byAdding: .day, value: 1, to: now) ?? now
            : now
        let hour = explicitHour ?? (isTomorrow ? 9 : calendar.component(.hour, from: now) + 1)
        let minute = clockMinute(in: normalized) ?? 0
        guard var result = calendar.date(bySettingHour: min(hour, 23), minute: minute,
                                         second: 0, of: base) else { return nil }
        if !isToday && !isTomorrow && result <= now {
            result = calendar.date(byAdding: .day, value: 1, to: result) ?? result
        }
        return result
    }

    private static func dateAfterDuty(in text: String, shifts: [Shift]) -> Date? {
        guard containsAny(text, ["بعد الدوام", "لما اطلع من الدوام", "عند الخروج من العمل", "after work"]) else {
            return nil
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        for offset in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            for shift in shifts where shift.isEnabled && shift.weekday == weekday {
                var endDay = day
                if shift.crossesMidnight {
                    endDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day
                }
                let end = shift.end.date(on: endDay)
                if end > Date() { return end }
            }
        }
        return nil
    }

    private static func checklist(from text: String) -> [String]? {
        let commands = ["اشتري", "أشتري", "جيب", "قائمة", "اغراض", "أغراض", "مشتريات",
                        "بقالة", "بقاله", "سوبرماركت", "buy", "get", "shopping", "grocery"]
        guard let command = commands.first(where: { text.localizedCaseInsensitiveContains($0) }) else {
            return nil
        }
        var listText: String
        if let separator = text.firstIndex(where: { $0 == "," || $0 == "،" }) {
            let heading = String(text[..<separator])
            let genericHeading = containsAny(heading, ["أغراض البقالة", "أغراض البقاله", "اغراض البقالة",
                                                        "اغراض البقاله", "قائمة", "مشتريات",
                                                        "shopping list", "grocery list"])
            if genericHeading {
                listText = String(text[text.index(after: separator)...])
            } else {
                let listStart = text.range(of: command, options: [.caseInsensitive])?.upperBound
                    ?? text.startIndex
                listText = String(text[listStart...])
            }
        } else {
            let listStart = text.range(of: command, options: [.caseInsensitive])?.upperBound
                ?? text.startIndex
            listText = String(text[listStart...])
        }
        let separator = try? NSRegularExpression(pattern: "[,،\\n]|\\s+و(?=\\S)")
        listText = separator?.stringByReplacingMatches(
            in: listText,
            range: NSRange(listText.startIndex..., in: listText),
            withTemplate: "|") ?? listText
        let timingWords = try? NSRegularExpression(
            pattern: "(?:\\s+)?(?:بكرة|غد(?:ا|اً)|اليوم|بعد الدوام|tomorrow|today|after work)?\\s*(?:الساعة|الساعه|at)\\s*\\d{1,2}(?::\\d{1,2})?\\s*(?:ص|صباح|م|مساء|am|pm)?.*$|\\s+(?:بكرة|غد(?:ا|اً)|اليوم|بعد الدوام|tomorrow|today|after work).*$",
            options: [.caseInsensitive])
        let pieces = listText.split(separator: "|")
            .map { part -> String in
                let value = String(part)
                return timingWords?.stringByReplacingMatches(
                    in: value,
                    range: NSRange(value.startIndex..., in: value),
                    withTemplate: "") ?? value
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return pieces.isEmpty ? nil : pieces
    }

    private static func clockHour(in text: String) -> Int? {
        guard let match = firstMatch(pattern: "(?:الساعة|الساعه|at)\\s*(\\d{1,2})(?::(\\d{2}))?\\s*(ص|صباح|م|مساء|am|pm)?", in: text),
              let range = Range(match.range(at: 1), in: text),
              var hour = Int(text[range]) else { return nil }
        if match.numberOfRanges > 3,
           let suffixRange = Range(match.range(at: 3), in: text) {
            let suffix = String(text[suffixRange])
            if ["م", "مساء", "pm"].contains(suffix), hour < 12 { hour += 12 }
            if ["ص", "صباح", "am"].contains(suffix), hour == 12 { hour = 0 }
        }
        return hour
    }

    private static func clockMinute(in text: String) -> Int? {
        guard let match = firstMatch(pattern: "(?:الساعة|الساعه|at)\\s*\\d{1,2}(?::(\\d{2}))?", in: text),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }

    private static func captureNumber(pattern: String, in text: String) -> Int? {
        guard let match = firstMatch(pattern: pattern, in: text),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }

    private static func firstMatch(pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func replacing(pattern: String, in text: String,
                                  with template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern,
                                                        options: [.caseInsensitive]) else {
            return text
        }
        return expression.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func westernDigits(_ text: String) -> String {
        let arabic = Array("٠١٢٣٤٥٦٧٨٩")
        let persian = Array("۰۱۲۳۴۵۶۷۸۹")
        return String(text.map { character in
            if let index = arabic.firstIndex(of: character) { return Character(String(index)) }
            if let index = persian.firstIndex(of: character) { return Character(String(index)) }
            return character
        })
    }

    private static func containsAny(_ text: String, _ terms: [String]) -> Bool {
        let lower = text.lowercased()
        return terms.contains { lower.contains($0.lowercased()) }
    }
}
