import SwiftUI

struct FocusBar: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.pomodoro.isActive {
                activeBar
            } else {
                idleBar
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .padding(.top, 10)
    }

    private var idleBar: some View {
        HStack(spacing: 9) {
            Image(systemName: "timer")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)

            VStack(alignment: .leading, spacing: 1) {
                Text("番茄专注")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(model.nextFocusMinutes) 分钟 · 跟随下一项任务")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                model.togglePomodoro()
            } label: {
                Text("开始")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.accent))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.openTasks.isEmpty)
            .opacity(model.openTasks.isEmpty ? 0.45 : 1)
        }
    }

    private var activeBar: some View {
        VStack(spacing: 7) {
            HStack(spacing: 9) {
                Image(systemName: model.pomodoro.phase == .work ? "timer" : "cup.and.saucer.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)

                VStack(alignment: .leading, spacing: 1) {
                    Text(activeTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(model.pomodoro.phase.title)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

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
            }

            ProgressView(value: model.pomodoro.progress)
                .progressViewStyle(.linear)
                .tint(Theme.accent)
                .controlSize(.mini)
        }
    }

    private var activeTitle: String {
        guard let taskID = model.pomodoro.taskID else {
            return model.pomodoro.phase == .work ? "专注" : "休息一下"
        }
        return model.todayTasks.first { $0.id == taskID }?.title ?? "专注"
    }
}
