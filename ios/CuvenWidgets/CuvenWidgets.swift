import WidgetKit
import SwiftUI
import ActivityKit
import AppIntents

@main
struct CuvenWidgets: WidgetBundle {
    var body: some Widget {
        CallLiveActivity()
    }
}

/// A call in the Dynamic Island and on the Lock Screen: who, how long (or
/// how it's going), and Mute and End within reach.
struct CallLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CallActivityAttributes.self) { context in
            LockScreenCall(context: context)
                .activityBackgroundTint(Color.black.opacity(0.72))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Initials(text: context.attributes.initials, size: 44)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Button(intent: ToggleMuteIntent()) {
                        Image(systemName: context.state.muted ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(context.state.muted ? .black : .white)
                    .background(context.state.muted ? Color.white : Color.white.opacity(0.18), in: Circle())
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.attributes.name).font(.headline).lineLimit(1)
                        Elapsed(state: context.state, video: context.attributes.video)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Button(intent: EndCallIntent()) {
                        Label("End Call", systemImage: "phone.down.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(Color.red, in: Capsule())
                    .padding(.top, 6)
                }
            } compactLeading: {
                Image(systemName: context.attributes.video ? "video.fill" : "phone.fill")
                    .foregroundStyle(.green)
            } compactTrailing: {
                if let since = context.state.liveSince {
                    Text(since, style: .timer)
                        .monospacedDigit()
                        .frame(maxWidth: 44)
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "ellipsis").foregroundStyle(.green)
                }
            } minimal: {
                Image(systemName: context.attributes.video ? "video.fill" : "phone.fill")
                    .foregroundStyle(.green)
            }
            .keylineTint(.green)
        }
    }
}

private struct LockScreenCall: View {
    let context: ActivityViewContext<CallActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            Initials(text: context.attributes.initials, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.name).font(.headline).foregroundStyle(.white).lineLimit(1)
                Elapsed(state: context.state, video: context.attributes.video)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
            }
            Spacer(minLength: 0)
            Button(intent: ToggleMuteIntent()) {
                Image(systemName: context.state.muted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(context.state.muted ? .black : .white)
            .background(context.state.muted ? Color.white : Color.white.opacity(0.18), in: Circle())
            Button(intent: EndCallIntent()) {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(Color.red, in: Circle())
        }
        .padding(16)
    }
}

/// How long it has been live, counting up; until then, how it's going.
private struct Elapsed: View {
    let state: CallActivityAttributes.ContentState
    let video: Bool

    var body: some View {
        if let since = state.liveSince {
            Text(since, style: .timer)
        } else {
            Text(state.status.isEmpty ? (video ? String(localized: "Video call") : String(localized: "Voice call")) : state.status)
        }
    }
}

private struct Initials: View {
    let text: String
    let size: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: size * 0.38, weight: .semibold, design: .serif))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color.white.opacity(0.2), in: Circle())
    }
}
