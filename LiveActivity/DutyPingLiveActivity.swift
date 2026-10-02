import ActivityKit
import SwiftUI
import WidgetKit

@main
struct DutyPingWidgetBundle: WidgetBundle {
    var body: some Widget {
        DutyPingLiveActivity()
    }
}

struct DutyPingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ReminderActivityAttributes.self) { context in
            lockScreen(context)
                .activityBackgroundTint(Color(red: 0.06, green: 0.10, blue: 0.28))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image("Logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.dueDate, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Waiting for confirmation", systemImage: "exclamationmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            if context.state.repeatIntervalMinutes > 0 {
                                Text(String(format: String(localized: "Every %d min first · until confirmed"),
                                            context.state.repeatIntervalMinutes))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Link(destination: context.attributes.completionURL) {
                            Label("Confirm", systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.mint, in: Capsule())
                                .foregroundStyle(.black)
                        }
                    }
                }
            } compactLeading: {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } compactTrailing: {
                Text(context.state.dueDate, style: .timer)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.orange)
            } minimal: {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .widgetURL(context.attributes.completionURL)
            .keylineTint(.mint)
        }
    }

    private func lockScreen(_ context: ActivityViewContext<ReminderActivityAttributes>) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(LinearGradient(colors: [.indigo, .purple],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(context.attributes.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("Waiting for your confirmation")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                if context.state.repeatIntervalMinutes > 0 {
                    Text(String(format: String(localized: "Every %d min first · until confirmed"),
                                context.state.repeatIntervalMinutes))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.62))
                }
            }
            Spacer()
            VStack(spacing: 5) {
                Text(context.state.dueDate, style: .timer)
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(.white)
                Link(destination: context.attributes.completionURL) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.mint)
                }
            }
        }
        .padding(16)
    }
}
