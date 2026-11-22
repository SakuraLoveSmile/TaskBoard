import AppKit
import SwiftUI

struct PanelView: View {
    @Bindable var model: AppModel
    @State private var draft = ""
    @State private var showDone = false
    @State private var refineDraft = ""
    @State private var statusNoteDraft = ""
    @State private var descriptionDraft = ""
    @State private var titleDraft = ""
    @State private var planGuideDraft = ""
    @FocusState private var inputFocused: Bool
    @FocusState private var refineFocused: Bool
    @FocusState private var statusNoteFocused: Bool
    @FocusState private var descriptionFocused: Bool
    @FocusState private var titleFocused: Bool
    @FocusState private var planGuideFocused: Bool

    var body: some View {
        ZStack {
            panelContent
            overlays
        }
        .onExitCommand(perform: handleEscape)
        .onKeyPress(KeyEquivalent("n"), phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            inputFocused = true
            return .handled
        }
        .onChange(of: overlayKey) { _, _ in
            syncOverlayDrafts()
        }
        .animation(.easeInOut(duration: 0.16), value: overlayKey)
    }

    private var overlayKey: String {
        if model.isPlanGuideVisible { return "plan" }
        if let task = model.titleEditTask { return "title-\(task.id.uuidString)" }
        if let task = model.descriptionTask { return "description-\(task.id.uuidString)" }
        if let task = model.statusNoteTask { return "status-\(task.id.uuidString)" }
        if let task = model.refineTask { return "refine-\(task.id.uuidString)" }
        return ""
    }

    private func syncOverlayDrafts() {
        if model.isPlanGuideVisible {
            planGuideDraft = model.lastPlanGuidance ?? ""
            planGuideFocused = true
        }
        if model.titleEditTask != nil {
            titleDraft = model.titleEditTask?.title ?? ""
            titleFocused = true
        }
        if model.descriptionTask != nil {
            descriptionDraft = model.descriptionTask?.notes ?? ""
            descriptionFocused = true
        }
        if model.statusNoteTask != nil {
            statusNoteDraft = model.statusNoteTask?.statusNote ?? ""
            statusNoteFocused = true
        }
        if model.refineTask != nil {
            refineDraft = ""
            refineFocused = true
        }
    }

    private var panelContent: some View {
        VStack(spacing: 0) {
            header
            ProgressModeBar(model: model)
                .padding(.top, 9)
            addBar
                .padding(.top, 12)
            aiBar
                .padding(.top, 8)
            banners
            Divider()
                .overlay(Color.primary.opacity(0.08))
                .padding(.top, 10)
            ScrollView(.vertical) {
                TimelineView(model: model, showDone: $showDone)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
            }
            .scrollIndicators(.hidden)
            FocusBar(model: model)
        }
        .padding(16)
        .frame(width: Theme.panelWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { inputFocused = true }
    }

    private func handleEscape() {
        if model.isPlanGuideVisible {
            model.cancelPlan()
        } else if model.titleEditTask != nil {
            model.cancelEditTitle()
        } else if model.statusNoteTask != nil {
            model.cancelStatusNote()
        } else if model.descriptionTask != nil {
            model.cancelEditDescription()
        } else if model.refineTask != nil {
            model.cancelRefine()
        } else {
            model.collapse()
        }
    }

    @ViewBuilder
    private var overlays: some View {
        if model.isPlanGuideVisible {
            planGuideOverlay
                .transition(.opacity)
        }
        if let task = model.titleEditTask {
            titleOverlay(for: task)
                .transition(.opacity)
        }
        if let task = model.descriptionTask {
            descriptionOverlay(for: task)
                .transition(.opacity)
        }
        if let task = model.statusNoteTask {
            statusNoteOverlay(for: task)
                .transition(.opacity)
        }
        if model.refineTask != nil {
            refineOverlay
                .transition(.opacity)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.dateText)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Text(model.headerHint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            ProgressPill(
                progress: model.displayProgress,
                done: model.doneCount,
                total: model.totalCount
            )

            Button {
                model.openArchive()
            } label: {
                Image(systemName: "archivebox")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.archivedCount > 0 ? "任务归档（\(model.archivedCount)）" : "任务归档")

            Button {
                model.openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("设置")

            Button {
                model.collapse()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("收起")
        }
    }

    private var addBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("添加今天要做的事…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($inputFocused)
                .onSubmit(submitDraft)
            Button(action: submitDraft) {
                Text("↵")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary.opacity(0.45) : Theme.accent)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle().fill(
                            draft.trimmingCharacters(in: .whitespaces).isEmpty
                                ? Color.clear
                                : Theme.accentSoft
                        )
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("添加任务（回车）")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var aiBar: some View {
        HStack(spacing: 8) {
            Button {
                model.beginPlan()
            } label: {
                HStack(spacing: 5) {
                    if model.isPlanning {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10, weight: .medium))
                    }
                    Text(model.isPlanning ? "正在编排…" : (model.lastPlanAt == nil ? "AI 编排" : "重新编排"))
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5.5)
                .background(Capsule().fill(Theme.accentSoft))
                .foregroundStyle(Theme.accent)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.isPlanning || model.openTasks.isEmpty)
            .opacity(model.openTasks.isEmpty && !model.isPlanning ? 0.45 : 1)

            if let toast = model.aiToast {
                Text(toast)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            Spacer()

            if let last = model.lastPlanAt {
                Text(last.formatted(.dateTime.hour().minute().locale(Locale(identifier: "zh_CN"))) + " 已生成")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.aiToast)
    }

    @ViewBuilder
    private var banners: some View {
        if let error = model.aiError {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Spacer(minLength: 4)
                Button("重试") { model.retryPlan() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.orange.opacity(0.10))
            )
            .padding(.top, 8)
        }

        if model.rolloverCount > 0 {
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.right.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent)
                Text("\(model.rolloverCount) 项从昨天顺延")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("撤销") { model.undoRollover() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.accentSoft)
            )
            .padding(.top, 8)
        }
    }

    private var refineOverlay: some View {
        ZStack {
            Color.black.opacity(0.38)
                .contentShape(Rectangle())
                .onTapGesture { model.cancelRefine() }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("AI 细化任务")
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Button {
                        model.cancelRefine()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isRefining)
                }

                if let task = model.refineTask {
                    Text(task.title)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                ZStack(alignment: .topLeading) {
                    if refineDraft.isEmpty {
                        Text("补充说明：想怎么做、有哪些环节、希望多久完成…")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $refineDraft)
                        .font(.system(size: 11.5))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 5)
                        .focused($refineFocused)
                }
                .frame(height: 96)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                )

                if let error = model.refineError {
                    Text(error)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                }

                HStack(spacing: 8) {
                    Text("结果会写回时长和二级清单")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        model.cancelRefine()
                    } label: {
                        Text("取消")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isRefining)

                    Button {
                        Task { await model.submitRefine(description: refineDraft) }
                    } label: {
                        HStack(spacing: 5) {
                            if model.isRefining {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                            Text(model.isRefining ? "细化中…" : "开始细化")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Theme.accent.opacity(model.isRefining ? 0.6 : 1)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isRefining)
                }
            }
            .padding(14)
            .frame(width: 320)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.thinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            )
        }
    }

    private var planGuideOverlay: some View {
        ZStack {
            Color.black.opacity(0.32)
                .contentShape(Rectangle())
                .onTapGesture { model.cancelPlan() }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("AI 编排")
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Button {
                        model.cancelPlan()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Text("\(model.openTasks.count) 件待办 · 可以补充今天希望怎么安排")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)

                ZStack(alignment: .topLeading) {
                    if planGuideDraft.isEmpty {
                        Text("例如：上午先做需要专注的；下午留时间沟通；先解除阻塞…")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $planGuideDraft)
                        .font(.system(size: 11.5))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 5)
                        .focused($planGuideFocused)
                }
                .frame(height: 96)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                )

                HStack(spacing: 8) {
                    Text("留空则按默认策略编排")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("取消") {
                        model.cancelPlan()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())

                    Button("开始编排") {
                        model.submitPlan(guidance: planGuideDraft)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.accent))
                    .contentShape(Capsule())
                }
            }
            .padding(14)
            .frame(width: 320)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.thinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            )
        }
    }

    private func titleOverlay(for task: TodoTask) -> some View {
        let canSave = !titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return ZStack {
            Color.black.opacity(0.32)
                .contentShape(Rectangle())
                .onTapGesture { model.cancelEditTitle() }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("编辑任务标题")
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Button {
                        model.cancelEditTitle()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                TextField("任务标题", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($titleFocused)
                    .onSubmit { model.submitTitle(titleDraft) }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                    )

                HStack(spacing: 8) {
                    Text("最多 200 字")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("取消") {
                        model.cancelEditTitle()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())

                    Button("保存") {
                        model.submitTitle(titleDraft)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.accent.opacity(canSave ? 1 : 0.45)))
                    .contentShape(Capsule())
                    .disabled(!canSave)
                }
            }
            .padding(14)
            .frame(width: 320)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.thinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            )
        }
    }

    private func descriptionOverlay(for task: TodoTask) -> some View {
        ZStack {
            Color.black.opacity(0.32)
                .contentShape(Rectangle())
                .onTapGesture { model.cancelEditDescription() }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("编辑任务描述")
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Button {
                        model.cancelEditDescription()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Text(task.title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                ZStack(alignment: .topLeading) {
                    if descriptionDraft.isEmpty {
                        Text("补充背景、验收标准、相关链接…")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $descriptionDraft)
                        .font(.system(size: 11.5))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 5)
                        .focused($descriptionFocused)
                }
                .frame(height: 96)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                )

                HStack(spacing: 8) {
                    Text("留空保存会清除描述")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("取消") {
                        model.cancelEditDescription()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())

                    Button("保存") {
                        model.submitDescription(descriptionDraft)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.accent))
                    .contentShape(Capsule())
                }
            }
            .padding(14)
            .frame(width: 320)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.thinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            )
        }
    }

    private func statusNoteOverlay(for task: TodoTask) -> some View {
        let status = TaskStatus(rawValue: task.status) ?? .todo
        let isBlocked = status == .blocked
        return ZStack {
            Color.black.opacity(0.32)
                .contentShape(Rectangle())
                .onTapGesture { model.cancelStatusNote() }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: isBlocked ? "exclamationmark.bubble" : "hourglass")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(status.tint)
                    Text(isBlocked ? "说明阻塞原因" : "说明等待原因")
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Button {
                        model.cancelStatusNote()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Text(task.title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                ZStack(alignment: .topLeading) {
                    if statusNoteDraft.isEmpty {
                        Text(isBlocked ? "例如：等设计稿确认、缺少权限…" : "例如：等对方回复、等排期…")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $statusNoteDraft)
                        .font(.system(size: 11.5))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 5)
                        .focused($statusNoteFocused)
                }
                .frame(height: 72)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                )

                HStack(spacing: 8) {
                    Text("原因会一起交给 AI 编排")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("跳过") {
                        model.cancelStatusNote()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())

                    Button("保存") {
                        model.submitStatusNote(statusNoteDraft)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(status.tint))
                    .contentShape(Capsule())
                }
            }
            .padding(14)
            .frame(width: 320)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.thinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            )
        }
    }

    private func submitDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.addTask(trimmed)
        draft = ""
        inputFocused = true
    }
}

struct ProgressModeBar: View {
    @Bindable var model: AppModel

    private var isExternal: Bool { model.settings.progressMode == .external }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.toggleProgressMode()
            } label: {
                Image(systemName: isExternal ? "eye.fill" : "chart.bar.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(isExternal ? Theme.accent : Color.secondary)
                    .frame(width: 22, height: 16)
                    .background(Capsule().fill(isExternal ? Theme.accentSoft : Color.primary.opacity(0.05)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("切换进度视图")

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                        .frame(height: 4)
                    Capsule()
                        .fill(isExternal ? Theme.accent : Theme.success)
                        .frame(width: max(0, geo.size.width * model.displayProgress), height: 4)
                        .animation(.easeOut(duration: 0.18), value: model.displayProgress)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 12)
            .allowsHitTesting(false)

            Text("\(model.displayPercent)%")
                .font(.system(size: 9.5, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(isExternal ? Theme.accent : Color.secondary)
                .frame(minWidth: 30, alignment: .trailing)
        }
    }
}

struct ProgressPill: View {
    let progress: Double
    let done: Int
    let total: Int

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.12), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(progress, 0.001))
                    .stroke(Theme.success, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 15, height: 15)

            Text(total == 0 ? "0/0" : "\(done)/\(total)")
                .font(.system(size: 10.5, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
    }
}
