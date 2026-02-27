import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct RelayWidgetBundle: WidgetBundle {
    var body: some Widget {
        RelayLiveActivity()
    }
}

struct RelayLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RelayActivityAttributes.self) { context in
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text("Live")
                            .font(.system(size: 14, weight: .semibold))
                    } icon: {
                        Image(systemName: "waveform")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(relayBlue)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 8) {
                        Button(intent: ToggleMuteIntent()) {
                            Image(systemName: context.state.isMuted ? "mic.slash.fill" : "mic.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(context.state.isMuted ? .red : .white)
                        }
                        .buttonStyle(.plain)

                        Button(intent: ExitLiveIntent()) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }

                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.agentName)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    Text(statusText(context.state))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Circle()
                    .fill(relayBlue)
                    .frame(width: 10, height: 10)
            } compactTrailing: {
                EmptyView()
            } minimal: {
                Circle()
                    .fill(relayBlue)
                    .frame(width: 10, height: 10)
            }
        }
    }

    // MARK: - Lock Screen View

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<RelayActivityAttributes>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(relayBlue)
                        .frame(width: 10, height: 10)
                    Text("Live")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(relayBlue)
                }

                Text(context.state.agentName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)

                Text(statusText(context.state))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Button(intent: ToggleMuteIntent()) {
                    Image(systemName: context.state.isMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(context.state.isMuted ? .red : .white)
                        .frame(width: 44, height: 44)
                        .background(context.state.isMuted ? Color.red.opacity(0.3) : Color.white.opacity(0.15))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Button(intent: ExitLiveIntent()) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.red)
                        .frame(width: 44, height: 44)
                        .background(Color.red.opacity(0.15))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(Color(red: 0.067, green: 0.094, blue: 0.153))
    }

    // MARK: - Helpers

    private var relayBlue: Color {
        Color(red: 37.0 / 255, green: 99.0 / 255, blue: 235.0 / 255)
    }

    private func statusText(_ state: RelayActivityAttributes.ContentState) -> String {
        switch state.status {
        case "processing": "Thinking..."
        case "speaking": "Speaking..."
        default: state.isMuted ? "Microphone muted" : "Listening..."
        }
    }
}
