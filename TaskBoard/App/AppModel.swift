import AppKit
import Foundation
import Observation
import SwiftUI

enum PanelAnchor {
    case topLeading
    case topTrailing
}

struct ArchivedDayGroup: Identifiable {
    let day: Date
    let tasks: [TodoTask]

    var id: Date { day }

    var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "今天" }
        if calendar.isDateInYesterday(day) { return "昨天" }
        return day.formatted(
            .dateTime.month().day().weekday(.abbreviated)
                .locale(Locale(identifier: "zh_CN"))
        )
    }
}

struct StageGroup: Identifiable {
    let id: Int
    let title: String
    let rationale: String?
    let tasks: [TodoTask]

    var isDone: Bool { tasks.allSatisfy(\.isDone) }
    var isCurrent: Bool { tasks.contains { !$0.isDone } }
}

@MainActor
@Observable
final class AppModel {
    let settings: SettingsStore
    let store: TaskStore
    let pomodoro: PomodoroEngine
    let aiClient: AIClient
    private let planner: AIPlanner
    private let refiner: AIRefiner

    var isExpanded = false
    var panelAnchor: PanelAnchor = .topTrailing
    var panelTargetSize = CGSize(width: Theme.panelWidth, height: Theme.panelHeight)
    // 随窗口生长/收缩联动，避免面板内容被窗口边缘硬裁
    var panelContentOpacity: Double = 1
    var ballOpacity: Double = 1
    var isPlanning = false
    var isPlanGuideVisible = false
    private(set) var lastPlanGuidance: String?
    var aiError: String?
    var aiToast: String?
    var refineTask: TodoTask?
    var isRefining = false
    var refineError: String?
    var statusNoteTask: TodoTask?
    var descriptionTask: TodoTask?
    var titleEditTask: TodoTask?
    var lastPlanAt: Date?
    var planSummary: String?
    var rolloverCount = 0
    private(set) var captureAllowed = false
    private(set) var currentDay: Date
    @ObservationIgnored let backupDirectory: URL

    static var defaultBackupDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("TaskBoard/Backups", isDirectory: true)
    }

    @ObservationIgnored var expandHandler: (@MainActor @Sendable () -> Void)?
    @ObservationIgnored var collapseHandler: (@MainActor @Sendable () -> Void)?
    @ObservationIgnored var openSettingsHandler: (@MainActor @Sendable () -> Void)?
    @ObservationIgnored var openArchiveHandler: (@MainActor @Sendable () -> Void)?
    @ObservationIgnored var checkUpdatesHandler: (@MainActor @Sendable () -> Void)?
    @ObservationIgnored var beginMoveHandler: (@MainActor @Sendable () -> Void)?
    @ObservationIgnored var moveToMouseHandler: (@MainActor @Sendable () -> Void)?
    @ObservationIgnored var endMoveHandler: (@MainActor @Sendable () -> Void)?
    @ObservationIgnored var pebbleVisibilityHandler: (@MainActor @Sendable (Bool) -> Void)?
    @ObservationIgnored var resetPebbleHandler: (@MainActor @Sendable () -> Void)?
    @ObservationIgnored var captureHandler: (@MainActor @Sendable (Bool) -> Void)?
    @ObservationIgnored var isPointerNearPebble: (@MainActor @Sendable (CGFloat) -> Bool)?
    @ObservationIgnored var pebblePressHandler: (@MainActor @Sendable (Bool) -> Void)?
    @ObservationIgnored var isPointInsidePanel: (@MainActor @Sendable (CGPoint) -> Bool)?

    init(
        settings: SettingsStore = SettingsStore(),
        store: TaskStore = TaskStore(),
        pomodoroDefaults: UserDefaults = .standard,
        backupDirectory: URL? = nil
    ) {
        self.settings = settings
        self.store = store
        self.backupDirectory = backupDirectory ?? Self.defaultBackupDirectory
        let client = AIClient()
        self.aiClient = client
        self.planner = AIPlanner(client: client)
        self.refiner = AIRefiner(client: client)
        self.pomodoro = PomodoroEngine(settings: settings, defaults: pomodoroDefaults)
        self.currentDay = Calendar.current.startOfDay(for: Date())
        self.captureAllowed = ProcessInfo.processInfo.arguments.contains("--capture")
    }

    var today: Date {
        Calendar.current.startOfDay(for: Date())
    }

    var todayTasks: [TodoTask] {
        store.tasks(for: today)
    }

    var openTasks: [TodoTask] {
        todayTasks.filter { !$0.isDone }.sorted { lhs, rhs in
            let leftStage = lhs.stageIndex ?? Int.max
            let rightStage = rhs.stageIndex ?? Int.max
            if leftStage != rightStage { return leftStage < rightStage }
            if leftStage != Int.max, lhs.lane != rhs.lane { return lhs.lane < rhs.lane }
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.createdAt < rhs.createdAt
        }
    }

    var doneTasks: [TodoTask] {
        store.doneTasks(for: today)
    }

    var archivedGroups: [ArchivedDayGroup] {
        let calendar = Calendar.current
        let archived = store.tasks.filter { $0.archivedAt != nil }
        let grouped = Dictionary(grouping: archived) { task in
            calendar.startOfDay(for: task.archivedAt ?? Date())
        }
        return grouped
            .map { day, tasks in
                ArchivedDayGroup(
                    day: day,
                    tasks: tasks.sorted {
                        ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast)
                    }
                )
            }
            .sorted { $0.day > $1.day }
    }

    var archivedCount: Int {
        archivedGroups.reduce(0) { $0 + $1.tasks.count }
    }

    // 归档任务仍然计入当天进度
    var doneCount: Int { todayTasks.filter(\.isDone).count }
    var totalCount: Int { todayTasks.count }

    // 只统计未完成任务，按轻重缓急加权；全部完成记 100%，没有任务记 0%
    var averageProgress: Double { average(of: \.progress) }
    var averageExternalProgress: Double { average(of: \.externalProgress) }

    private func average(of keyPath: KeyPath<TodoTask, Int>) -> Double {
        let open = todayTasks.filter { !$0.isDone }
        if open.isEmpty { return todayTasks.isEmpty ? 0 : 1 }
        var weighted = 0.0
        var totalWeight = 0.0
        for task in open {
            let weight = TaskPriority(rawValue: task.priority)?.weight ?? TaskPriority.normal.weight
            weighted += weight * Double(task[keyPath: keyPath]) / 100
            totalWeight += weight
        }
        guard totalWeight > 0 else { return 0 }
        return weighted / totalWeight
    }

    private var isExternalMode: Bool { settings.progressMode == .external }

    var displayProgress: Double {
        guard totalCount > 0 else { return 0 }
        return isExternalMode ? averageExternalProgress : averageProgress
    }

    var displayPercent: Int {
        Int((displayProgress * 100).rounded())
    }

    var nextFocusTask: TodoTask? {
        openTasks.first { TaskStatus(rawValue: $0.status) != .blocked }
    }

    var nextFocusMinutes: Int {
        nextFocusTask?.focusMinutes ?? settings.workMinutes
    }

    var focusTask: TodoTask? {
        guard let id = pomodoro.taskID else { return nil }
        return todayTasks.first { $0.id == id }
    }

    var headerHint: String {
        if totalCount == 0 { return "今天还没有任务，先写下一件小事" }
        if openTasks.isEmpty { return "今天的任务都完成了，收工" }
        if let next = nextFocusTask {
            return "还有 \(openTasks.count) 件 · 先做「\(next.title)」"
        }
        return "还有 \(openTasks.count) 件 · 先解除阻塞"
    }

    var dateText: String {
        today.formatted(
            .dateTime.month(.wide).day().weekday(.wide)
                .locale(Locale(identifier: "zh_CN"))
        )
    }

    var stageGroups: [StageGroup] {
        let open = openTasks.sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.createdAt < rhs.createdAt
        }
        let planned = open.filter { $0.stageIndex != nil }

        guard !planned.isEmpty else {
            guard !open.isEmpty else { return [] }
            return [StageGroup(id: 0, title: "今天", rationale: nil, tasks: open)]
        }

        let grouped = Dictionary(grouping: planned) { $0.stageIndex ?? 0 }
        var groups: [StageGroup] = []
        for key in grouped.keys.sorted() {
            let tasks = (grouped[key] ?? []).sorted { $0.lane < $1.lane }
            groups.append(
                StageGroup(
                    id: key,
                    title: tasks.first?.stageTitle ?? "阶段 \(key + 1)",
                    rationale: key == 0 ? planSummary : nil,
                    tasks: tasks
                )
            )
        }

        let unplanned = open.filter { $0.stageIndex == nil }
        if !unplanned.isEmpty {
            groups.append(StageGroup(id: 99_999, title: "待安排", rationale: nil, tasks: unplanned))
        }
        return groups
    }

    func addTask(_ title: String) {
        store.add(title: title, day: today)
    }

    func toggle(_ task: TodoTask) {
        store.toggle(task)
        guard task.isDone, settings.autoArchiveCompleted else { return }
        scheduleAutoArchive(taskID: task.id)
    }

    func unarchive(_ task: TodoTask) {
        withAnimation(.easeOut(duration: 0.22)) {
            store.unarchive(task)
        }
    }

    private func scheduleAutoArchive(taskID: UUID) {
        Task { @MainActor in
            // 延迟让任务在已完成区停留一段时间，时长按天设置
            let days = settings.autoArchiveDays
            if days > 0 {
                try? await Task.sleep(for: .seconds(Double(days) * 86_400))
            }
            guard let task = store.tasks.first(where: { $0.id == taskID }),
                  task.isDone, task.archivedAt == nil
            else { return }
            withAnimation(.easeOut(duration: 0.22)) {
                store.archive(task)
            }
        }
    }

    func delete(_ task: TodoTask) {
        store.delete(task)
    }

    func copyTask(_ task: TodoTask) {
        let text = task.notes.isEmpty ? task.title : "\(task.title)\n\(task.notes)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func setFocusMinutes(_ minutes: Int?, for task: TodoTask) {
        store.setFocusMinutes(minutes, for: task)
    }

    func setTaskPriority(_ priority: Int, for task: TodoTask) {
        store.setPriority(priority, for: task)
    }

    func setTaskStatus(_ status: Int, for task: TodoTask) {
        store.setStatus(status, for: task)
        guard let option = TaskStatus(rawValue: task.status),
              option == .blocked || option == .waiting,
              task.statusNote == nil
        else { return }
        beginStatusNote(task)
    }

    func beginStatusNote(_ task: TodoTask) {
        statusNoteTask = task
    }

    func cancelStatusNote() {
        statusNoteTask = nil
    }

    func submitStatusNote(_ text: String) {
        guard let task = statusNoteTask else { return }
        store.setStatusNote(text, for: task)
        statusNoteTask = nil
    }

    func beginEditTitle(_ task: TodoTask) {
        titleEditTask = task
    }

    func cancelEditTitle() {
        titleEditTask = nil
    }

    func submitTitle(_ title: String) {
        guard let task = titleEditTask else { return }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.rename(task, to: title)
        titleEditTask = nil
    }

    func beginEditDescription(_ task: TodoTask) {
        descriptionTask = task
    }

    func cancelEditDescription() {
        descriptionTask = nil
    }

    func submitDescription(_ text: String) {
        guard let task = descriptionTask else { return }
        store.setNotes(text, for: task)
        descriptionTask = nil
    }

    @discardableResult
    func moveTask(id: UUID, relativeTo targetID: UUID, placeAfter: Bool) -> Bool {
        store.moveTask(id: id, relativeTo: targetID, placeAfter: placeAfter)
    }

    @discardableResult
    func moveTask(id: UUID, toStage stageIndex: Int?, stageTitle: String?) -> Bool {
        store.moveTask(id: id, toStage: stageIndex, stageTitle: stageTitle)
    }

    // 当前视图下任务自身的进度值
    func progress(of task: TodoTask) -> Int {
        guard !task.isDone else { return 100 }
        return isExternalMode ? task.externalProgress : task.progress
    }

    // 拖动任务进度条时写入当前视图对应的那一份
    func setTaskProgress(_ percent: Int, for task: TodoTask) {
        if isExternalMode {
            store.setExternalProgress(percent, for: task)
        } else {
            store.setProgress(percent, for: task)
        }
    }

    func toggleProgressMode() {
        settings.progressMode = settings.progressMode == .real ? .external : .real
    }

    func beginRefine(_ task: TodoTask) {
        refineTask = task
        refineError = nil
    }

    func cancelRefine() {
        guard !isRefining else { return }
        refineTask = nil
        refineError = nil
    }

    func submitRefine(description: String) async {
        guard let task = refineTask, !isRefining else { return }
        guard !settings.activeModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            refineError = "先在设置里选择 Magpie 模型"
            return
        }

        isRefining = true
        refineError = nil
        defer { isRefining = false }

        let planSettings = AIPlanSettings(
            baseURL: settings.activeBaseURL,
            model: settings.activeModelID,
            timeout: settings.planTimeout
        )
        do {
            let result = try await refiner.refine(
                taskTitle: task.title,
                currentEstimate: task.estimateMinutes,
                description: description,
                settings: planSettings,
                apiKey: settings.activeAPIKey
            )
            store.applyRefinement(
                to: task,
                estimateMinutes: result.estimateMinutes,
                subtasks: result.subtasks
            )
            refineTask = nil
            refineError = nil
            aiToast = result.subtasks.isEmpty
                ? "已更新预估时长"
                : "已拆成 \(result.subtasks.count) 个二级任务"
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.6))
                self?.aiToast = nil
            }
        } catch {
            refineError = error.localizedDescription
        }
    }

    func toggleSubtask(_ subtaskID: UUID, in task: TodoTask) {
        store.toggleSubtask(subtaskID, in: task)
    }

    func clearSubtasks(for task: TodoTask) {
        store.clearSubtasks(for: task)
    }

    func startFocus(_ task: TodoTask?) {
        pomodoro.start(taskID: task?.id, minutes: task?.focusMinutes)
    }

    func togglePomodoro() {
        switch pomodoro.state {
        case .running: pomodoro.pause()
        case .paused: pomodoro.resume()
        case .idle: startFocus(nextFocusTask)
        }
    }

    func expand() {
        guard !isExpanded else { return }
        // 先让窗口控制器算好目标几何与锚点，SwiftUI 同一帧里按最终尺寸插入面板
        expandHandler?()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
            isExpanded = true
        }
    }

    func collapse() {
        guard isExpanded else { return }
        collapseHandler?()
        // 窗口先缩，缩到接近球大小时再换成球，视觉上是卡片收进球里
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            withAnimation(.easeOut(duration: 0.16)) {
                isExpanded = false
            }
        }
    }

    func toggleExpanded() {
        if isExpanded { collapse() } else { expand() }
    }

    func collapseExternal() {
        guard isExpanded else { return }
        if let isPointInsidePanel, isPointInsidePanel(NSEvent.mouseLocation) {
            return
        }
        collapse()
    }

    func openSettings() {
        openSettingsHandler?()
    }

    func openArchive() {
        openArchiveHandler?()
    }

    func checkForUpdates() {
        checkUpdatesHandler?()
    }

    func importConflictCount(in backup: ArchiveBackup) -> Int {
        store.conflictingTaskIDs(backup.tasks).count
    }

    func importArchiveBackup(
        _ backup: ArchiveBackup,
        policy: ArchiveImportPolicy = .skip
    ) -> ArchiveImportResult {
        store.importArchived(backup.tasks, policy: policy)
    }

    @discardableResult
    func purgeExpiredArchive() -> ArchivePurgeResult {
        ArchiveMaintenance.purge(
            store: store,
            olderThanDays: settings.archiveRetentionDays,
            backupDirectory: backupDirectory
        )
    }

    func setPebbleHidden(_ hidden: Bool) {
        if hidden && isExpanded { collapse() }
        settings.hidePebble = hidden
        pebbleVisibilityHandler?(hidden)
    }

    func setCaptureAllowed(_ allowed: Bool) {
        guard captureAllowed != allowed else { return }
        captureAllowed = allowed
        captureHandler?(allowed)
    }

    func resetPebblePosition() {
        resetPebbleHandler?()
    }

    func beginPlan() {
        guard !isPlanning, !openTasks.isEmpty else { return }
        isPlanGuideVisible = true
    }

    func cancelPlan() {
        isPlanGuideVisible = false
    }

    func submitPlan(guidance: String) {
        isPlanGuideVisible = false
        let trimmed = guidance.trimmingCharacters(in: .whitespacesAndNewlines)
        lastPlanGuidance = trimmed.isEmpty ? nil : trimmed
        Task { await planToday(guidance: guidance) }
    }

    func retryPlan() {
        Task { await planToday(guidance: lastPlanGuidance) }
    }

    func planToday(guidance: String? = nil) async {
        guard !isPlanning else { return }
        let trimmedGuidance = (guidance ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        lastPlanGuidance = trimmedGuidance.isEmpty ? nil : trimmedGuidance
        guard !settings.activeModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            aiError = "先在设置里选择 Magpie 模型"
            return
        }
        let tasks = openTasks
        guard !tasks.isEmpty else { return }

        isPlanning = true
        aiError = nil
        defer { isPlanning = false }

        let snapshots = tasks.enumerated().map { index, task in
            TodoTaskSnapshot(
                id: task.id,
                title: task.title,
                estimateMinutes: task.estimateMinutes,
                sortIndex: index,
                status: TaskStatus(rawValue: task.status) ?? .todo,
                statusNote: task.statusNote,
                description: task.notes.isEmpty ? nil : task.notes
            )
        }

        let weekday = Date.now.formatted(
            .dateTime.year().month().day().weekday(.wide)
                .locale(Locale(identifier: "zh_CN"))
        )
        let planSettings = AIPlanSettings(
            baseURL: settings.activeBaseURL,
            model: settings.activeModelID,
            timeout: settings.planTimeout
        )

        do {
            let result = try await planner.plan(
                snapshots: snapshots,
                weekdayText: weekday,
                guidance: trimmedGuidance,
                settings: planSettings,
                apiKey: settings.activeAPIKey
            )
            store.apply(plan: result)
            lastPlanAt = Date()
            planSummary = result.summary
            aiToast = "已编排为 \(result.stageCount) 个阶段"
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.6))
                self?.aiToast = nil
            }
        } catch {
            aiError = error.localizedDescription
        }
    }

    func performStartupRollover() {
        let moved = store.rollover(to: today)
        rolloverCount = moved
        if moved > 0 {
            planSummary = nil
            lastPlanAt = nil
        }
        purgeExpiredArchive()
    }

    func undoRollover() {
        store.undoRollover(ids: store.lastRolloverIDs)
        rolloverCount = 0
    }

    func checkDayChange() {
        let day = Calendar.current.startOfDay(for: Date())
        guard day != currentDay else { return }
        currentDay = day
        store.reload()
        performStartupRollover()
        // 应用跨天不重启时，也要按天把过期的完成任务收进归档
        if settings.autoArchiveCompleted {
            store.archiveCompleted(olderThanDays: settings.autoArchiveDays)
        }
    }
}
