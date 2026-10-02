import ActivityKit
import Foundation

@available(iOS 16.1, *)
struct ReminderActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var dueDate: Date
        var isCompleted: Bool
    }

    var seriesID: String
    var title: String
    var kind: String

    var completionURL: URL {
        var components = URLComponents()
        components.scheme = "dutyping"
        components.host = "complete"
        components.queryItems = [
            URLQueryItem(name: "series", value: seriesID),
            URLQueryItem(name: "kind", value: kind),
            URLQueryItem(name: "title", value: title)
        ]
        return components.url ?? URL(string: "dutyping://complete")!
    }
}
