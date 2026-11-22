import SwiftUI

struct TimelineView: View {
    @Bindable var model: AppModel
    @Binding var showDone: Bool

    var body: some View {
        if model.stageGroups.isEmpty && model.doneTasks.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(width: 1)
                        .padding(.leading, 3.5)
                        .padding(.top, 12)

                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(model.stageGroups.enumerated()), id: \.element.id) { index, group in
                            StageSection(
                                model: model,
                                group: group,
                                index: index
                            )
                        }
                    }
                    .padding(.bottom, model.doneTasks.isEmpty ? 0 : 10)
                }

                if !model.doneTasks.isEmpty {
                    doneSection
                        .padding(.top, 6)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checklist")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.75))
            Text("今天还没有任务")
                .font(.system(size: 12.5, weight: .medium))
            Text("在上方输入，按回车即可添加")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    private var doneSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showDone.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: showDone ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Text("已完成 \(model.doneTasks.count)")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showDone {
                VStack(spacing: 6) {
                    ForEach(model.doneTasks) { task in
                        TaskCard(model: model, task: task)
                    }
                }
            }
        }
        .padding(.leading, 18)
    }

}

struct StageSection: View {
    @Bindable var model: AppModel
    let group: StageGroup
    let index: Int
    @State private var dropTargeted = false

    private var isUnplanned: Bool { group.id == 99_999 }
    private var isSingleImplicit: Bool { group.title == "今天" && group.tasks.allSatisfy { $0.stageIndex == nil } }
    private var isPlanned: Bool { group.tasks.contains { $0.stageIndex != nil } }

    private var moveStageIndex: Int? { group.tasks.first?.stageIndex }
    private var moveStageTitle: String? { group.tasks.first?.stageTitle }

    private var stageLabel: String {
        if isUnplanned || isSingleImplicit { return group.title }
        return "阶段 \(index + 1) · \(group.title)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
                .frame(width: 8)

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(stageLabel)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if isPlanned && group.tasks.count > 1 {
                            Text("并行")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(Theme.accentSoft))
                        }
                    }

                    if let rationale = group.rationale, !rationale.isEmpty {
                        Text(rationale)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { items, _ in
                    guard let raw = items.first, let draggedID = UUID(uuidString: raw) else { return false }
                    return model.moveTask(id: draggedID, toStage: moveStageIndex, stageTitle: moveStageTitle)
                } isTargeted: { targeted in
                    dropTargeted = targeted
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            Theme.accent.opacity(0.55),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                        .opacity(dropTargeted ? 1 : 0)
                        .allowsHitTesting(false)
                )
                .animation(.easeOut(duration: 0.12), value: dropTargeted)

                VStack(spacing: 7) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: 7) {
                            ForEach(row) { task in
                                TaskCard(model: model, task: task, compact: row.count > 1)
                            }
                        }
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var dotColor: Color {
        if isUnplanned { return Color.primary.opacity(0.22) }
        if isSingleImplicit { return Theme.accent }
        return Theme.accent
    }

    private var rows: [[TodoTask]] {
        let columnCount = isPlanned ? 2 : 1
        return stride(from: 0, to: group.tasks.count, by: columnCount).map { start in
            Array(group.tasks[start..<min(start + columnCount, group.tasks.count)])
        }
    }
}

struct TaskCard: View {
    @Bindable var model: AppModel
    let task: TodoTask
    var compact = false
    @State private var hovering = false
    @State private var dropTargeted = false
    @State private var cardHeight: CGFloat = 0

    private var isFocusing: Bool {
        model.pomodoro.taskID == task.id && model.pomodoro.state != .idle
    }

    private var priority: TaskPriority? {
        TaskPriority(rawValue: task.priority)
    }

    private var status: TaskStatus {
        TaskStatus(rawValue: task.status) ?? .todo
    }

    private var hasMetadata: Bool {
        task.focusMinutes != nil || task.estimateMinutes != nil || task.originDay != nil
            || isFocusing || (priority != nil && priority != .normal)
    }

    var body: some View {
        Group {
            if task.isDone {
                card
            } else {
                card
                    .draggable(task.id.uuidString) {
                        Text(task.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(2)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: 200, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(.thinMaterial)
                            )
                    }
                    .dropDestination(for: String.self) { items, location in
                        guard let raw = items.first,
                              let draggedID = UUID(uuidString: raw)
                        else { return false }
                        return model.moveTask(
                            id: draggedID,
                            relativeTo: task.id,
                            placeAfter: location.y > cardHeight / 2
                        )
                    } isTargeted: { targeted in
                        dropTargeted = targeted
                    }
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            cardHeight = height
        }
        .animation(.easeOut(duration: 0.12), value: dropTargeted)
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 9) {
            Button {
                model.toggle(task)
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(
                            task.isDone ? Theme.success : Color.primary.opacity(hovering ? 0.42 : 0.28),
                            lineWidth: 1.4
                        )
                        .frame(width: 18, height: 18)
                    if task.isDone {
                        Circle().fill(Theme.success).frame(width: 18, height: 18)
                        Image(systemName: "checkmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 1)
            .accessibilityLabel(task.isDone ? "标记为未完成" : "标记为完成")

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top, spacing: 6) {
                    Text(task.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(task.isDone ? .secondary : .primary)
                        .strikethrough(task.isDone, color: .secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .onTapGesture(count: 2) { model.beginEditTitle(task) }
                        .help("双击重命名")

                    Spacer(minLength: 0)

                    trailingAccessory
                }

                if !task.notes.isEmpty {
                    Button {
                        model.beginEditDescription(task)
                    } label: {
                        Text(task.notes)
                            .font(.system(size: 11))
                            .foregroundStyle(task.isDone ? .tertiary : .secondary)
                            .lineLimit(compact ? 1 : 2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("点击编辑描述")
                }

                if !task.isDone {
                    TaskProgressBar(
                        percent: model.progress(of: task),
                        tint: model.settings.progressMode == .external ? Theme.accent : Theme.success
                    ) { value in
                        model.setTaskProgress(value, for: task)
                    }
                    .padding(.top, 1)

                    metaRow

                    if (status == .blocked || status == .waiting),
                       let note = task.statusNote, !note.isEmpty {
                        statusNoteLine(note)
                    }
                } else if hasMetadata {
                    metaRow
                }

                if let subtasks = task.subtasks, !subtasks.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(subtasks) { sub in
                            Button {
                                model.toggleSubtask(sub.id, in: task)
                            } label: {
                                HStack(spacing: 6) {
                                    ZStack {
                                        Circle()
                                            .strokeBorder(
                                                sub.isDone ? Theme.success : Color.primary.opacity(0.28),
                                                lineWidth: 1.2
                                            )
                                            .frame(width: 12, height: 12)
                                        if sub.isDone {
                                            Circle().fill(Theme.success).frame(width: 12, height: 12)
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 6, weight: .bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    Text(sub.title)
                                        .font(.system(size: 11))
                                        .foregroundStyle(sub.isDone ? .tertiary : .secondary)
                                        .strikethrough(sub.isDone, color: .secondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    if let minutes = sub.estimateMinutes {
                                        chip("\(minutes)m")
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(sub.isDone ? "取消完成\(sub.title)" : "完成\(sub.title)")
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.primary.opacity(hovering ? 0.085 : 0.052),
                            Color.primary.opacity(hovering ? 0.060 : 0.034)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .strokeBorder(
                    isFocusing ? Theme.accent.opacity(0.45) : Color.primary.opacity(0.055),
                    lineWidth: 1
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: 1.5)
                .opacity(dropTargeted ? 1 : 0)
                .allowsHitTesting(false)
        )
        .overlay(alignment: .leading) {
            if !task.isDone, status != .todo {
                Capsule()
                    .fill(status.tint.opacity(0.9))
                    .frame(width: 2.5)
                    .padding(.vertical, 10)
                    .padding(.leading, 1)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        .onHover { hovering = $0 }
        .help(task.isDone ? "" : "拖动卡片调整顺序")
        .contextMenu {
            Button("重命名…") {
                model.beginEditTitle(task)
            }
            Button(task.notes.isEmpty ? "添加描述…" : "编辑描述…") {
                model.beginEditDescription(task)
            }
            if !task.isDone {
                Button("AI 细化…") { model.beginRefine(task) }
                Button("开始专注") { model.startFocus(task) }
                Picker(
                    "状态",
                    selection: Binding(
                        get: { task.status },
                        set: { model.setTaskStatus($0, for: task) }
                    )
                ) {
                    ForEach(TaskStatus.allCases, id: \.rawValue) { option in
                        Label(option.title, systemImage: option.symbol).tag(option.rawValue)
                    }
                }
                if status == .blocked || status == .waiting {
                    Button(task.statusNote == nil ? "说明原因…" : "编辑状态说明…") {
                        model.beginStatusNote(task)
                    }
                }
                Picker(
                    "专注时长",
                    selection: Binding(
                        get: { task.focusMinutes ?? 0 },
                        set: { model.setFocusMinutes($0 == 0 ? nil : $0, for: task) }
                    )
                ) {
                    Text("跟随番茄钟（\(model.settings.workMinutes) 分钟）").tag(0)
                    ForEach([15, 25, 45, 60], id: \.self) { minutes in
                        Text("\(minutes) 分钟").tag(minutes)
                    }
                }
                Picker(
                    "轻重缓急",
                    selection: Binding(
                        get: { task.priority },
                        set: { model.setTaskPriority($0, for: task) }
                    )
                ) {
                    Text(TaskPriority.high.title).tag(TaskPriority.high.rawValue)
                    Text(TaskPriority.normal.title).tag(TaskPriority.normal.rawValue)
                    Text(TaskPriority.low.title).tag(TaskPriority.low.rawValue)
                }
            }
            Button("复制任务") { model.copyTask(task) }
            if task.subtasks?.isEmpty == false {
                Button("清除二级任务") { model.clearSubtasks(for: task) }
            }
            Button("删除") { model.delete(task) }
        }
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        if task.isDone {
            EmptyView()
        } else if hovering {
            Button {
                model.startFocus(task)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Theme.accentSoft))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("开始专注")
        } else {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.quaternary)
                .frame(width: 20, height: 20)
                .help("拖动卡片调整顺序")
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var metaRow: some View {
        if compact {
            HStack(spacing: 5) {
                if !task.isDone { statusMenu(showsText: false) }
                if let minutes = task.focusMinutes {
                    metaIcon("timer", text: "\(minutes)", help: "专注 \(minutes) 分钟")
                } else if let minutes = task.estimateMinutes {
                    metaIcon("clock", text: "\(minutes)", help: "预估 \(minutes) 分钟")
                }
                if task.originDay != nil {
                    metaIcon("arrow.uturn.backward", help: "来自昨天")
                }
                if let priority, priority != .normal {
                    metaIcon(
                        priority == .high ? "exclamationmark.triangle.fill" : "arrow.down.circle",
                        tint: priority == .high ? .orange : .secondary,
                        help: priority.title
                    )
                }
                if isFocusing {
                    metaIcon("timer", tint: Theme.accent, help: "专注中")
                }
            }
            .lineLimit(1)
        } else {
            HStack(spacing: 6) {
                if !task.isDone { statusMenu(showsText: true) }
                if let minutes = task.focusMinutes {
                    metaIcon("timer", text: "\(minutes)m", help: "专注 \(minutes) 分钟")
                } else if let minutes = task.estimateMinutes {
                    metaIcon("clock", text: "\(minutes)m", help: "预估 \(minutes) 分钟")
                }
                if task.originDay != nil {
                    metaIcon("arrow.uturn.backward", text: "昨天", help: "来自昨天")
                }
                if let priority, priority != .normal {
                    priorityChip(priority)
                }
                if isFocusing {
                    chip("专注中", accent: true)
                }
            }
        }
    }

    private func statusNoteLine(_ note: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Capsule()
                .fill(status.tint.opacity(0.4))
                .frame(width: 2)
            Text(note)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 1)
        .help(note)
    }

    private func statusMenu(showsText: Bool) -> some View {
        Menu {
            ForEach(TaskStatus.allCases, id: \.rawValue) { option in
                Toggle(
                    option.title,
                    isOn: Binding(
                        get: { task.status == option.rawValue },
                        set: { isOn in
                            if isOn { model.setTaskStatus(option.rawValue, for: task) }
                        }
                    )
                )
            }
        } label: {
            if showsText {
                HStack(spacing: 4) {
                    statusDot
                    Text(status.title)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(status.tint)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(status.tint.opacity(status == .todo ? 0.08 : 0.14)))
                .contentShape(Capsule())
            } else {
                Image(systemName: compactStatusSymbol)
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("状态：\(status.title) · 点击修改")
    }

    private var compactStatusSymbol: String {
        switch status {
        case .todo: "circle.dashed"
        case .inProgress: "play.fill"
        case .blocked: "exclamationmark.octagon"
        case .waiting: "hourglass"
        }
    }

    private var statusDot: some View {
        ZStack {
            if status == .todo {
                Circle().strokeBorder(status.tint.opacity(0.6), lineWidth: 1)
            } else {
                Circle().fill(status.tint)
            }
        }
        .frame(width: 5, height: 5)
    }

    private func metaIcon(
        _ symbol: String,
        text: String? = nil,
        tint: Color = .secondary,
        help: String
    ) -> some View {
        HStack(spacing: 2.5) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .medium))
            if let text {
                Text(text)
                    .font(.system(size: 9, weight: .medium, design: .rounded).monospacedDigit())
            }
        }
        .foregroundStyle(tint)
        .fixedSize()
        .help(help)
    }

    private func priorityChip(_ priority: TaskPriority) -> some View {
        Text(priority.title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(priority == .high ? Color.orange : Color.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(priority == .high ? Color.orange.opacity(0.14) : Color.primary.opacity(0.06))
            )
    }

    private func chip(_ text: String, accent: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(accent ? Theme.accent : Color.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(accent ? Theme.accentSoft : Color.primary.opacity(0.06))
            )
    }
}

struct TaskProgressBar: View {
    let percent: Int
    let tint: Color
    let onChange: (Int) -> Void
    @State private var hovering = false

    private var fraction: Double { Double(percent) / 100 }

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 3)
                    Capsule()
                        .fill(tint.opacity(0.8))
                        .frame(width: max(0, geo.size.width * fraction), height: 3)
                        .animation(.easeOut(duration: 0.15), value: fraction)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(dragGesture(width: geo.size.width))
            }
            .frame(height: 11)

            if hovering || percent > 0 {
                Text("\(percent)%")
                    .font(.system(size: 8.5, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 24, alignment: .trailing)
            }
        }
        .onHover { hovering = $0 }
        .help("拖动调整进度")
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard width > 0 else { return }
                let fraction = min(1, max(0, value.location.x / width))
                let snapped = Int((fraction * 100 / 5).rounded()) * 5
                if snapped != percent {
                    onChange(snapped)
                }
            }
    }
}
