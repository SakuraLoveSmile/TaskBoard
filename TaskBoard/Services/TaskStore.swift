import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class TaskStore {
    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let context: ModelContext

    private(set) var tasks: [TodoTask] = []
    private(set) var lastRolloverIDs: [UUID] = []

    init(inMemory: Bool = false) {
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        if let container = try? ModelContainer(
            for: TodoTask.self, PomodoroSession.self,
            configurations: config
        ) {
            self.container = container
        } else {
            let fallback = ModelConfiguration(isStoredInMemoryOnly: true)
            self.container = try! ModelContainer(
                for: TodoTask.self, PomodoroSession.self,
                configurations: fallback
            )
        }
        self.context = ModelContext(self.container)
        reload()
    }

    func reload() {
        let descriptor = FetchDescriptor<TodoTask>(
            sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.createdAt)]
        )
        tasks = (try? context.fetch(descriptor)) ?? []
    }

    func tasks(for day: Date, calendar: Calendar = .current) -> [TodoTask] {
        tasks
            .filter { calendar.isDate($0.scheduledDay, inSameDayAs: day) }
            .sorted { lhs, rhs in
                if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
                return lhs.createdAt < rhs.createdAt
            }
    }

    func openTasks(for day: Date) -> [TodoTask] {
        tasks(for: day).filter { !$0.isDone }
    }

    func doneTasks(for day: Date) -> [TodoTask] {
        tasks(for: day).filter { $0.isDone && $0.archivedAt == nil }
    }

    func archivedTasks(for day: Date) -> [TodoTask] {
        tasks(for: day).filter { $0.archivedAt != nil }
    }

    func add(title: String, day: Date, estimateMinutes: Int? = nil) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let existing = tasks(for: day)
        let task = TodoTask(
            title: trimmed,
            scheduledDay: Calendar.current.startOfDay(for: day),
            sortIndex: (existing.map(\.sortIndex).max() ?? -1) + 1,
            estimateMinutes: estimateMinutes
        )
        context.insert(task)
        save()
    }

    func toggle(_ task: TodoTask) {
        task.isDone.toggle()
        task.completedAt = task.isDone ? Date() : nil
        if !task.isDone {
            task.archivedAt = nil
        }
        save()
    }

    func archive(_ task: TodoTask) {
        guard task.isDone else { return }
        task.archivedAt = Date()
        save()
    }

    @discardableResult
    func archiveCompleted(olderThanDays days: Int) -> Int {
        let now = Date()
        let cutoff = Calendar.current.date(byAdding: .day, value: -max(0, days), to: now) ?? now
        var count = 0
        for task in tasks where task.isDone && task.archivedAt == nil {
            if days > 0 {
                let stamp = task.completedAt ?? task.createdAt
                guard stamp <= cutoff else { continue }
            }
            task.archivedAt = now
            count += 1
        }
        if count > 0 {
            save()
        }
        return count
    }

    func expiredArchived(olderThanDays days: Int, now: Date = Date()) -> [TodoTask] {
        guard days > 0 else { return [] }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        return tasks.filter { task in
            guard let archivedAt = task.archivedAt else { return false }
            return archivedAt <= cutoff
        }
    }

    func conflictingTaskIDs(_ records: [ArchiveBackup.TaskRecord]) -> Set<UUID> {
        let existing = Set(tasks.map(\.id))
        return Set(records.map(\.id).filter(existing.contains))
    }

    // 导入的备份恢复为归档任务；冲突按策略覆盖或跳过，空标题总是跳过
    @discardableResult
    func importArchived(
        _ records: [ArchiveBackup.TaskRecord],
        policy: ArchiveImportPolicy = .skip,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ArchiveImportResult {
        var byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        var result = ArchiveImportResult()

        for record in records {
            let title = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                result.skipped += 1
                continue
            }

            if let existing = byID[record.id] {
                switch policy {
                case .skip:
                    result.skipped += 1
                case .overwrite:
                    apply(record, to: existing, now: now, calendar: calendar)
                    result.overwritten += 1
                }
                continue
            }

            let task = TodoTask(
                id: record.id,
                title: title,
                scheduledDay: calendar.startOfDay(for: record.scheduledDay),
                isDone: true
            )
            apply(record, to: task, now: now, calendar: calendar)
            context.insert(task)
            byID[task.id] = task
            result.added += 1
        }

        if result.added + result.overwritten > 0 {
            save()
        }
        return result
    }

    private func apply(
        _ record: ArchiveBackup.TaskRecord,
        to task: TodoTask,
        now: Date,
        calendar: Calendar
    ) {
        let title = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
        task.title = String(title.prefix(200))
        task.notes = String(record.notes.prefix(2_000))
        task.createdAt = record.createdAt
        task.scheduledDay = calendar.startOfDay(for: record.scheduledDay)
        task.isDone = true
        task.completedAt = record.completedAt ?? record.archivedAt ?? now
        task.archivedAt = record.archivedAt ?? now
        task.stageTitle = record.stageTitle
        task.estimateMinutes = record.estimateMinutes
        task.focusMinutes = record.focusMinutes
        task.progress = min(100, max(0, record.progress))
        task.externalProgress = min(100, max(0, record.externalProgress))
        task.priority = record.taskPriority.rawValue
        task.status = record.taskStatus.rawValue
        task.statusNote = record.statusNote
        task.subtasks = record.subtasks
    }

    @discardableResult
    func remove(_ targets: [TodoTask]) -> Int {
        guard !targets.isEmpty else { return 0 }
        for task in targets {
            context.delete(task)
        }
        save()
        return targets.count
    }

    func unarchive(_ task: TodoTask) {
        task.archivedAt = nil
        let today = Calendar.current.startOfDay(for: Date())
        if !Calendar.current.isDate(task.scheduledDay, inSameDayAs: today) {
            task.scheduledDay = today
        }
        save()
    }

    func delete(_ task: TodoTask) {
        context.delete(task)
        save()
    }

    func rename(_ task: TodoTask, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let capped = String(trimmed.prefix(200))
        guard task.title != capped else { return }
        task.title = capped
        save()
    }

    func setNotes(_ notes: String, for task: TodoTask) {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = String(trimmed.prefix(2000))
        guard task.notes != capped else { return }
        task.notes = capped
        save()
    }

    func setEstimate(_ minutes: Int?, for task: TodoTask) {
        task.estimateMinutes = minutes
        save()
    }

    func setFocusMinutes(_ minutes: Int?, for task: TodoTask) {
        task.focusMinutes = minutes
        save()
    }

    func setProgress(_ percent: Int, for task: TodoTask) {
        let clamped = min(100, max(0, percent))
        guard task.progress != clamped else { return }
        task.progress = clamped
        save()
    }

    func setExternalProgress(_ percent: Int, for task: TodoTask) {
        let clamped = min(100, max(0, percent))
        guard task.externalProgress != clamped else { return }
        task.externalProgress = clamped
        save()
    }

    func setPriority(_ priority: Int, for task: TodoTask) {
        let clamped = min(TaskPriority.high.rawValue, max(TaskPriority.low.rawValue, priority))
        guard task.priority != clamped else { return }
        task.priority = clamped
        save()
    }

    func setStatus(_ status: Int, for task: TodoTask) {
        let clamped = min(TaskStatus.waiting.rawValue, max(TaskStatus.todo.rawValue, status))
        guard task.status != clamped else { return }
        task.status = clamped
        if clamped != TaskStatus.blocked.rawValue, clamped != TaskStatus.waiting.rawValue {
            task.statusNote = nil
        }
        save()
    }

    func setStatusNote(_ note: String?, for task: TodoTask) {
        let trimmed = (note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = trimmed.isEmpty ? nil : String(trimmed.prefix(200))
        guard task.statusNote != capped else { return }
        task.statusNote = capped
        save()
    }

    // MARK: - 拖动排序

    @discardableResult
    func moveTask(id: UUID, relativeTo targetID: UUID, placeAfter: Bool) -> Bool {
        guard id != targetID,
              let task = tasks.first(where: { $0.id == id }),
              let target = tasks.first(where: { $0.id == targetID }),
              !task.isDone, !target.isDone
        else { return false }

        let siblings = orderedOpenTasks(
            stageIndex: target.stageIndex,
            in: tasks(for: target.scheduledDay),
            excluding: id
        )
        guard let targetIndex = siblings.firstIndex(where: { $0.id == targetID }) else { return false }
        place(
            task,
            into: target.stageIndex,
            title: target.stageTitle,
            among: siblings,
            at: placeAfter ? targetIndex + 1 : targetIndex
        )
        return true
    }

    @discardableResult
    func moveTask(id: UUID, toStage stageIndex: Int?, stageTitle: String?) -> Bool {
        guard let task = tasks.first(where: { $0.id == id }), !task.isDone else { return false }
        let siblings = orderedOpenTasks(
            stageIndex: stageIndex,
            in: tasks(for: task.scheduledDay),
            excluding: id
        )
        place(task, into: stageIndex, title: stageTitle, among: siblings, at: siblings.count)
        return true
    }

    private func orderedOpenTasks(
        stageIndex: Int?,
        in all: [TodoTask],
        excluding id: UUID?
    ) -> [TodoTask] {
        all.filter { !$0.isDone && $0.stageIndex == stageIndex && $0.id != id }
            .sorted { lhs, rhs in
                if lhs.lane != rhs.lane { return lhs.lane < rhs.lane }
                if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
                return lhs.createdAt < rhs.createdAt
            }
    }

    private func place(
        _ task: TodoTask,
        into stageIndex: Int?,
        title: String?,
        among siblings: [TodoTask],
        at index: Int
    ) {
        let previousStage = task.stageIndex
        var ordered = siblings
        ordered.insert(task, at: min(max(index, 0), ordered.count))
        task.stageIndex = stageIndex
        task.stageTitle = title
        renumber(ordered)
        if previousStage != stageIndex {
            renumber(orderedOpenTasks(
                stageIndex: previousStage,
                in: tasks(for: task.scheduledDay),
                excluding: nil
            ))
        }
        save()
    }

    private func renumber(_ ordered: [TodoTask]) {
        for (offset, item) in ordered.enumerated() {
            item.lane = offset
            item.sortIndex = offset
        }
    }

    func applyRefinement(to task: TodoTask, estimateMinutes: Int?, subtasks: [SubtaskItem]) {
        if let estimateMinutes {
            task.estimateMinutes = min(max(estimateMinutes, 1), 480)
        }
        task.subtasks = subtasks.isEmpty ? nil : subtasks
        save()
    }

    func toggleSubtask(_ subtaskID: UUID, in task: TodoTask) {
        guard var items = task.subtasks,
              let index = items.firstIndex(where: { $0.id == subtaskID })
        else { return }
        items[index].isDone.toggle()
        task.subtasks = items
        save()
    }

    func clearSubtasks(for task: TodoTask) {
        task.subtasks = nil
        save()
    }

    func apply(plan: AIPlanResult) {
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        for (index, stage) in plan.stages.enumerated() {
            for (lane, id) in stage.taskIDs.enumerated() {
                guard let task = byID[id] else { continue }
                task.stageIndex = index
                task.stageTitle = stage.title
                task.lane = lane
                if let minutes = plan.estimates[id] {
                    task.estimateMinutes = minutes
                }
            }
        }
        save()
    }

    func clearPlan(for day: Date) {
        for task in tasks(for: day) where !task.isDone {
            task.stageIndex = nil
            task.stageTitle = nil
            task.lane = 0
        }
        save()
    }

    @discardableResult
    func rollover(to day: Date, calendar: Calendar = .current) -> Int {
        let target = calendar.startOfDay(for: day)
        let stale = tasks.filter { task in
            !task.isDone && calendar.startOfDay(for: task.scheduledDay) < target
        }
        guard !stale.isEmpty else {
            lastRolloverIDs = []
            return 0
        }
        lastRolloverIDs = stale.map(\.id)
        for task in stale {
            if task.originDay == nil {
                task.originDay = task.scheduledDay
            }
            task.scheduledDay = target
            task.stageIndex = nil
            task.stageTitle = nil
            task.lane = 0
        }
        save()
        return stale.count
    }

    func undoRollover(ids: [UUID]) {
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        for id in ids {
            guard let task = byID[id], let origin = task.originDay else { continue }
            task.scheduledDay = origin
            task.originDay = nil
        }
        lastRolloverIDs = []
        save()
    }

    func recordSession(taskID: UUID?, phase: PomodoroPhase, plannedSeconds: Double, startedAt: Date) {
        context.insert(
            PomodoroSession(
                taskID: taskID,
                phaseRaw: phase.rawValue,
                startedAt: startedAt,
                plannedSeconds: plannedSeconds,
                completed: true
            )
        )
        save()
    }

    private func save() {
        try? context.save()
        reload()
    }
}
