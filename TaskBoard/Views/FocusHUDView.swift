import SwiftUI

struct FocusHUDView: View {
    @Bindable var model: AppModel

    private var taskTitle: String {
        model.focusTask?.title ?? "专注中"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "timer")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.accentSoft))

            VStack(alignment: .leading, spacing: 1) {
                Text(taskTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("专注中")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            Text(model.pomodoro.timeText)
                .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.accent)

            Button {
                model.togglePomodoro()
            } label: {
                Image(systemName: model.pomodoro.state == .running ? "pause.fill" : "play.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Theme.accentSoft))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(model.pomodoro.state == .running ? "暂停专注" : "继续专注")

            Button {
                model.pomodoro.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("结束专注")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
