import Foundation
import Testing
@testable import TaskBoard

@MainActor
private func makeStore() -> TaskStore {
    TaskStore(inMemory: true)
}

@Suite("AI 编排校验")
struct AIPlannerTests {
    private func snapshot(_ title: String, index: Int) -> TodoTaskSnapshot {
        TodoTaskSnapshot(id: UUID(), title: title, estimateMinutes: nil, sortIndex: index)
    }

    @Test("正常编排：阶段顺序与并行分组")
    func parsesStages() throws {
        let a = snapshot("回邮件", index: 0)
        let b = snapshot("写方案", index: 1)
        let raw = """
        {"summary":"先轻后重","stages":[
          {"title":"热身","rationale":"先清掉碎片","tasks":[{"id":"\(a.id.uuidString)","estimateMinutes":15}]},
          {"title":"深度工作","tasks":[{"id":"\(b.id.uuidString)"}]}
        ]}
        """
        let result = try AIPlanner.parse(raw: raw, snapshots: [a, b])
        #expect(result.stages.count == 2)
        #expect(result.stages[0].title == "热身")
        #expect(result.stages[1].taskIDs == [b.id])
        #expect(result.estimates[a.id] == 15)
    }

    @Test("未知 id 丢弃、重复 id 去重")
    func dropsUnknownAndDuplicates() throws {
        let a = snapshot("A", index: 0)
        let raw = """
        {"stages":[{"title":"一","tasks":[
          "\(UUID().uuidString)",
          "\(a.id.uuidString)",
          "\(a.id.uuidString)"
        ]}]}
        """
        let result = try AIPlanner.parse(raw: raw, snapshots: [a])
        #expect(result.stages.count == 1)
        #expect(result.stages[0].taskIDs == [a.id])
    }

    @Test("同一阶段超过 2 项自动拆分为续阶段")
    func splitsParallelOverflow() throws {
        let theTasks = (0..<3).map { snapshot("T\($0)", index: $0) }
        let idList = theTasks.map { "\"\($0.id.uuidString)\"" }.joined(separator: ",")
        let raw = "{\"stages\":[{\"title\":\"批量\",\"tasks\":[".appending(idList).appending("]}]}")
        let result = try AIPlanner.parse(raw: raw, snapshots: theTasks)
        #expect(result.stages.count == 2)
        #expect(result.stages[0].taskIDs.count == 2)
        #expect(result.stages[1].title == "批量 · 续")
        #expect(result.stages[1].taskIDs.count == 1)
    }

    @Test("缺失任务追加到待安排阶段")
    func appendsMissingTasks() throws {
        let a = snapshot("A", index: 0)
        let b = snapshot("B", index: 1)
        let raw = """
        {"stages":[{"title":"一","tasks":["\(a.id.uuidString)"]}]}
        """
        let result = try AIPlanner.parse(raw: raw, snapshots: [a, b])
        #expect(result.stages.count == 2)
        #expect(result.stages[1].title == "待安排")
        #expect(result.stages[1].taskIDs == [b.id])
    }

    @Test("非法时长夹紧到 1...480")
    func clampsEstimates() throws {
        let a = snapshot("A", index: 0)
        let b = snapshot("B", index: 1)
        let raw = """
        {"stages":[{"title":"一","tasks":[
          {"id":"\(a.id.uuidString)","estimateMinutes":900},
          {"id":"\(b.id.uuidString)","estimateMinutes":-5}
        ]}]}
        """
        let result = try AIPlanner.parse(raw: raw, snapshots: [a, b])
        #expect(result.estimates[a.id] == 480)
        #expect(result.estimates[b.id] == 1)
    }

    @Test("非 JSON 与全部未知 id 均报错")
    func rejectsInvalid() {
        let a = snapshot("A", index: 0)
        #expect(throws: (any Error).self) {
            try AIPlanner.parse(raw: "抱歉，我不能这么做", snapshots: [a])
        }
        #expect(throws: (any Error).self) {
            try AIPlanner.parse(
                raw: "{\"stages\":[{\"title\":\"x\",\"tasks\":[\"\(UUID().uuidString)\"]}]}",
                snapshots: [a]
            )
        }
    }

    @Test("编排会参考用户指导意见")
    func promptIncludesGuidance() {
        let snapshot = TodoTaskSnapshot(
            id: UUID(),
            title: "写方案",
            estimateMinutes: nil,
            sortIndex: 0
        )
        let prompt = AIPlanner.userPrompt(
            snapshots: [snapshot],
            weekdayText: "周日",
            guidance: "上午先做需要专注的，下午留时间沟通"
        )
        #expect(prompt.contains("用户指导意见"))
        #expect(prompt.contains("上午先做需要专注的，下午留时间沟通"))
    }

    @Test("编排会参考任务描述")
    func promptIncludesDescription() {
        let snapshot = TodoTaskSnapshot(
            id: UUID(),
            title: "写方案",
            estimateMinutes: nil,
            sortIndex: 0,
            description: "先给老板过目"
        )
        let prompt = AIPlanner.userPrompt(snapshots: [snapshot], weekdayText: "周日")
        #expect(prompt.contains("先给老板过目"))
        #expect(prompt.contains("\"description\""))
    }

    @Test("编排提示词会带上阻塞状态与原因")
    func promptIncludesStatusNotes() {
        let snapshot = TodoTaskSnapshot(
            id: UUID(),
            title: "等素材",
            estimateMinutes: nil,
            sortIndex: 0,
            status: .blocked,
            statusNote: "等设计确认"
        )
        let prompt = AIPlanner.userPrompt(snapshots: [snapshot], weekdayText: "周日")
        #expect(prompt.contains("等设计确认"))
        #expect(prompt.contains("\"status\""))
        #expect(prompt.contains("\"statusNote\""))
    }

    @Test("Markdown 包裹的 JSON 也能提取")
    func extractsFencedJSON() throws {
        let a = snapshot("A", index: 0)
        let raw = "```json\n{\"stages\":[{\"title\":\"一\",\"tasks\":[\"\(a.id.uuidString)\"]}]}\n```"
        let result = try AIPlanner.parse(raw: raw, snapshots: [a])
        #expect(result.stages.first?.taskIDs == [a.id])
    }
}

@Suite("番茄钟状态机")
@MainActor
struct PomodoroEngineTests {
    private func makeEngine(workMinutes: Int = 1) -> (PomodoroEngine, () -> Date, (Date) -> Void) {
        let suite = "test.pomodoro.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(defaults: defaults, agentConfigURL: nil)
        settings.workMinutes = workMinutes
        settings.shortBreakMinutes = 1
        settings.longBreakMinutes = 1
        settings.autoStartBreak = false
        let engine = PomodoroEngine(settings: settings, defaults: defaults)
        var now = Date(timeIntervalSince1970: 1_000)
        engine.now = { now }
        return (engine, { now }, { now = $0 })
    }

    @Test("启动、暂停、恢复、完成")
    func lifecycle() {
        let (engine, readNow, setNow) = makeEngine()
        engine.start(taskID: nil)
        #expect(engine.state == .running)
        #expect(engine.remainingSeconds == 60)

        setNow(readNow().addingTimeInterval(10))
        engine.pause()
        #expect(engine.state == .paused)
        #expect(engine.remainingSeconds <= 50.1)

        engine.resume()
        #expect(engine.state == .running)

        setNow(readNow().addingTimeInterval(120))
        engine.tick()
        #expect(engine.state == .idle)
        #expect(engine.completedWorkCount == 1)
    }

    @Test("停止后回到空闲")
    func stopResets() {
        let (engine, _, _) = makeEngine()
        engine.start(taskID: UUID())
        engine.stop()
        #expect(engine.state == .idle)
        #expect(engine.taskID == nil)
        #expect(engine.remainingSeconds == 0)
    }

    @Test("任务自定义专注时长覆盖番茄钟设置")
    func customFocusMinutes() {
        let (engine, _, _) = makeEngine(workMinutes: 25)
        engine.start(taskID: UUID(), minutes: 10)
        #expect(engine.plannedSeconds == 600)
        #expect(engine.remainingSeconds == 600)
    }
}

@Suite("跨天顺延")
@MainActor
struct DayRolloverTests {
    @Test("昨日未完成顺延到今天并可撤销")
    func rolloverAndUndo() {
        let store = makeStore()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        store.add(title: "昨天的活", day: yesterday)
        store.add(title: "今天新任务", day: today)

        let moved = store.rollover(to: today)
        #expect(moved == 1)

        let carried = store.tasks(for: today).first { $0.title == "昨天的活" }
        #expect(carried != nil)
        #expect(carried?.originDay != nil)
        #expect(carried?.stageIndex == nil)

        store.undoRollover(ids: store.lastRolloverIDs)
        let back = store.tasks.first { $0.title == "昨天的活" }
        #expect(calendar.isDate(back!.scheduledDay, inSameDayAs: yesterday))
    }

    @Test("已完成任务不被顺延")
    func doneTasksStay() {
        let store = makeStore()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        store.add(title: "已完成", day: yesterday)
        if let task = store.tasks.first { $0.title == "已完成" } {
            store.toggle(task)
        }
        let moved = store.rollover(to: today)
        #expect(moved == 0)
    }
}

@Suite("自动归档")
@MainActor
struct ArchiveTests {
    private func makeStore() -> TaskStore {
        TaskStore(inMemory: true)
    }

    @Test("完成后归档：移出已完成列表，可还原")
    func archivesAndRestores() {
        let store = makeStore()
        let day = Date()
        store.add(title: "归档候选", day: day)
        let task = store.tasks(for: day).first!

        store.toggle(task)
        #expect(store.doneTasks(for: day).count == 1)

        store.archive(task)
        #expect(store.doneTasks(for: day).isEmpty)
        #expect(store.archivedTasks(for: day).map(\.id) == [task.id])

        store.unarchive(task)
        #expect(store.archivedTasks(for: day).isEmpty)
        #expect(store.doneTasks(for: day).count == 1)
    }

    @Test("归档按天分组，最新在前")
    func groupsArchivesByDay() {
        let suite = "test.archiveGroups.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, agentConfigURL: nil)
        let model = AppModel(
            settings: settings,
            store: TaskStore(inMemory: true),
            pomodoroDefaults: defaults
        )
        model.addTask("今天归档")
        model.addTask("昨天归档")
        let tasks = model.todayTasks
        let today = tasks.first { $0.title == "今天归档" }!
        let older = tasks.first { $0.title == "昨天归档" }!

        model.toggle(today)
        model.store.archive(today)
        model.toggle(older)
        model.store.archive(older)
        older.archivedAt = Calendar.current.date(byAdding: .day, value: -1, to: Date())

        let groups = model.archivedGroups
        #expect(groups.count == 2)
        #expect(groups[0].title == "今天")
        #expect(groups[1].title == "昨天")
        #expect(groups[0].tasks.first?.id == today.id)
        #expect(model.archivedCount == 2)
    }

    @Test("还原旧日归档会回到今天")
    func restoreOldArchiveMovesToToday() {
        let store = makeStore()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        store.add(title: "旧归档", day: yesterday)
        let task = store.tasks(for: yesterday).first!
        store.toggle(task)
        store.archive(task)
        #expect(store.archivedTasks(for: yesterday).count == 1)

        store.unarchive(task)
        #expect(task.archivedAt == nil)
        #expect(calendar.isDate(task.scheduledDay, inSameDayAs: today))
    }

    @Test("取消完成会清除归档标记")
    func uncheckClearsArchive() {
        let store = makeStore()
        let day = Date()
        store.add(title: "取消勾选", day: day)
        let task = store.tasks(for: day).first!

        store.toggle(task)
        store.archive(task)
        #expect(task.archivedAt != nil)

        store.toggle(task)
        #expect(task.isDone == false)
        #expect(task.archivedAt == nil)
        #expect(store.archivedTasks(for: day).isEmpty)
    }
}

@Suite("归档设置与按天归档")
@MainActor
struct AutoArchiveDelayTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "test.archiveDelay.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test("默认 1 天、可自定义并持久化、越界夹紧到 0...30")
    func settingsRoundTrip() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults, agentConfigURL: nil)
        #expect(settings.autoArchiveDays == 1)

        settings.autoArchiveDays = 3
        #expect(SettingsStore(defaults: defaults, agentConfigURL: nil).autoArchiveDays == 3)

        settings.autoArchiveDays = 999
        #expect(settings.autoArchiveDays == 30)
        #expect(SettingsStore(defaults: defaults, agentConfigURL: nil).autoArchiveDays == 30)

        settings.autoArchiveDays = -2
        #expect(settings.autoArchiveDays == 0)
        #expect(defaults.object(forKey: "task.autoArchiveDays") as? Int == 0)

        defaults.set(5, forKey: "task.autoArchiveDays")
        #expect(SettingsStore(defaults: defaults, agentConfigURL: nil).autoArchiveDays == 5)
    }

    @Test("旧的秒级设置会换算成天")
    func migratesLegacySeconds() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(90_000, forKey: "task.autoArchiveDelay")
        #expect(SettingsStore(defaults: defaults, agentConfigURL: nil).autoArchiveDays == 2)

        defaults.set(60, forKey: "task.autoArchiveDelay")
        #expect(SettingsStore(defaults: defaults, agentConfigURL: nil).autoArchiveDays == 1)

        defaults.set(0, forKey: "task.autoArchiveDelay")
        #expect(SettingsStore(defaults: defaults, agentConfigURL: nil).autoArchiveDays == 0)
    }

    @Test("延迟 0 天勾选后立即归档")
    func zeroDelayArchivesRightAway() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults, agentConfigURL: nil)
        settings.autoArchiveDays = 0
        let store = TaskStore(inMemory: true)
        let model = AppModel(settings: settings, store: store, pomodoroDefaults: defaults)

        model.addTask("立即归档")
        let task = try #require(model.todayTasks.first)
        model.toggle(task)
        #expect(task.isDone)

        try await Task.sleep(for: .milliseconds(100))
        #expect(store.archivedTasks(for: Date()).map(\.id) == [task.id])
    }

    @Test("延迟 1 天时勾选后留在已完成列表")
    func oneDayDelayKeepsTaskVisible() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults, agentConfigURL: nil)
        settings.autoArchiveDays = 1
        let store = TaskStore(inMemory: true)
        let model = AppModel(settings: settings, store: store, pomodoroDefaults: defaults)

        model.addTask("明天再归档")
        let task = try #require(model.todayTasks.first)
        model.toggle(task)

        try await Task.sleep(for: .milliseconds(200))
        #expect(store.archivedTasks(for: Date()).isEmpty)
        #expect(store.doneTasks(for: Date()).map(\.id) == [task.id])
    }

    @Test("启动清理只归档超过 N 天的完成任务")
    func archivesOnlyOverdueTasks() throws {
        let store = TaskStore(inMemory: true)
        let day = Date()
        store.add(title: "三天前完成", day: day)
        store.add(title: "刚完成", day: day)
        let tasks = store.tasks(for: day)
        #expect(tasks.count == 2)
        let older = try #require(tasks.first { $0.title == "三天前完成" })
        let recent = try #require(tasks.first { $0.title == "刚完成" })

        store.toggle(older)
        store.toggle(recent)
        older.completedAt = Date().addingTimeInterval(-3 * 86_400)

        let archived = store.archiveCompleted(olderThanDays: 1)
        #expect(archived == 1)
        #expect(older.archivedAt != nil)
        #expect(recent.archivedAt == nil)
    }

    @Test("0 天清理会归档所有已完成任务")
    func zeroDaysArchivesEverything() throws {
        let store = TaskStore(inMemory: true)
        let day = Date()
        store.add(title: "刚完成", day: day)
        let task = try #require(store.tasks(for: day).first)
        store.toggle(task)

        let archived = store.archiveCompleted(olderThanDays: 0)
        #expect(archived == 1)
        #expect(task.archivedAt != nil)
    }
}

@Suite("归档窗口")
@MainActor
struct ArchiveWindowTests {
    @Test("归档窗口显示按天分组，还原后回到今天")
    func windowShowsArchivedGroups() throws {
        let suite = "test.archiveWindow.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults, agentConfigURL: nil)
        let store = TaskStore(inMemory: true)
        let model = AppModel(settings: settings, store: store, pomodoroDefaults: defaults)

        model.addTask("归档展示")
        let task = try #require(model.todayTasks.first)
        model.toggle(task)
        store.archive(task)

        #expect(model.archivedGroups.count == 1)
        #expect(model.archivedGroups.first?.tasks.map(\.id) == [task.id])
        #expect(model.archivedCount == 1)

        let controller = ArchiveWindowController(model: model)
        let window = try #require(controller.window)
        #expect(window.title == "任务归档")
        let hosting = try #require(window.contentView)
        hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 560)
        hosting.layoutSubtreeIfNeeded()

        model.unarchive(task)
        #expect(task.archivedAt == nil)
        #expect(model.archivedGroups.isEmpty)
        #expect(Calendar.current.isDateInToday(task.scheduledDay))
    }
}

@Suite("归档清理与备份")
@MainActor
struct ArchiveMaintenanceTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "test.archiveMaintenance.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test("保留天数默认 0 表示永不清理，可持久化并夹紧到 0...365")
    func retentionSettings() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults, agentConfigURL: nil)
        #expect(settings.archiveRetentionDays == 0)

        settings.archiveRetentionDays = 45
        #expect(SettingsStore(defaults: defaults, agentConfigURL: nil).archiveRetentionDays == 45)

        settings.archiveRetentionDays = 9_999
        #expect(settings.archiveRetentionDays == 365)
        #expect(SettingsStore(defaults: defaults, agentConfigURL: nil).archiveRetentionDays == 365)

        settings.archiveRetentionDays = -3
        #expect(settings.archiveRetentionDays == 0)
        #expect(defaults.object(forKey: "task.archiveRetentionDays") as? Int == 0)
    }

    private func makeTempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskBoardBackupTests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("只挑选超过保留天数的归档，未归档任务不受影响")
    func selectsExpiredArchive() throws {
        let store = TaskStore(inMemory: true)
        let day = Date()
        store.add(title: "旧归档", day: day)
        store.add(title: "新归档", day: day)
        store.add(title: "未归档", day: day)
        let tasks = store.tasks(for: day)
        let old = try #require(tasks.first { $0.title == "旧归档" })
        let fresh = try #require(tasks.first { $0.title == "新归档" })
        let open = try #require(tasks.first { $0.title == "未归档" })
        store.toggle(old)
        store.toggle(fresh)
        store.archive(old)
        store.archive(fresh)
        old.archivedAt = Date().addingTimeInterval(-10 * 86_400)
        fresh.archivedAt = Date().addingTimeInterval(-86_400)

        #expect(store.expiredArchived(olderThanDays: 0).isEmpty)
        #expect(store.expiredArchived(olderThanDays: 5).map(\.id) == [old.id])

        #expect(store.remove(store.expiredArchived(olderThanDays: 5)) == 1)
        #expect(store.tasks.count == 2)
        #expect(store.tasks.contains { $0.id == old.id } == false)
        #expect(store.tasks.contains { $0.id == fresh.id })
        #expect(store.tasks.contains { $0.id == open.id })

        #expect(store.expiredArchived(olderThanDays: 1).map(\.id) == [fresh.id])
    }

    @Test("启动维护清理前会写出备份文件")
    func startupPurgesWithBackup() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let backups = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: backups) }

        let settings = SettingsStore(defaults: defaults, agentConfigURL: nil)
        settings.archiveRetentionDays = 1
        let store = TaskStore(inMemory: true)
        let model = AppModel(
            settings: settings,
            store: store,
            pomodoroDefaults: defaults,
            backupDirectory: backups
        )

        model.addTask("过期归档")
        let task = try #require(model.todayTasks.first)
        model.toggle(task)
        store.archive(task)
        task.archivedAt = Date().addingTimeInterval(-3 * 86_400)

        model.performStartupRollover()
        #expect(store.tasks.isEmpty)

        let files = try FileManager.default.contentsOfDirectory(
            at: backups,
            includingPropertiesForKeys: nil
        )
        #expect(files.count == 1)
        let url = try #require(files.first)
        let backup = try ArchiveBackup.decode(Data(contentsOf: url))
        #expect(backup.tasks.map(\.title) == ["过期归档"])
        #expect(backup.tasks.first?.archivedAt != nil)
    }

    @Test("备份写入失败时不删除归档")
    func failedBackupKeepsArchive() throws {
        let base = makeTempDirectory()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // 用同名普通文件占住备份目录位置，让建目录失败
        let blocker = base.appendingPathComponent("Backups")
        try Data("x".utf8).write(to: blocker)

        let store = TaskStore(inMemory: true)
        let day = Date()
        store.add(title: "保留我", day: day)
        let task = try #require(store.tasks(for: day).first)
        store.toggle(task)
        store.archive(task)
        task.archivedAt = Date().addingTimeInterval(-30 * 86_400)

        let result = ArchiveMaintenance.purge(
            store: store,
            olderThanDays: 1,
            backupDirectory: blocker
        )
        #expect(result.removed == 0)
        #expect(result.error != nil)
        #expect(store.tasks.count == 1)
        #expect(task.archivedAt != nil)
    }

    @Test("自动备份只保留最近 20 份")
    func keepsRecentBackups() throws {
        let directory = makeTempDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for day in 1...25 {
            let name = "TaskBoard-归档备份-202601\(String(format: "%02d", day))-000000.json"
            try Data("{}".utf8).write(to: directory.appendingPathComponent(name))
        }
        ArchiveMaintenance.pruneBackups(in: directory)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(remaining.count == 20)
        #expect(remaining.contains("TaskBoard-归档备份-20260125-000000.json"))
        #expect(remaining.contains("TaskBoard-归档备份-20260106-000000.json"))
        #expect(remaining.contains("TaskBoard-归档备份-20260105-000000.json") == false)
    }

    @Test("能找到最近一份自动备份，没有备份时返回 nil")
    func latestBackupSelection() throws {
        let directory = makeTempDirectory()
        #expect(ArchiveMaintenance.latestBackup(in: directory) == nil)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for day in [1, 3, 2] {
            let name = "TaskBoard-归档备份-202601\(String(format: "%02d", day))-000000.json"
            try Data("{}".utf8).write(to: directory.appendingPathComponent(name))
        }
        #expect(
            ArchiveMaintenance.latestBackup(in: directory)?.lastPathComponent
                == "TaskBoard-归档备份-20260103-000000.json"
        )
    }

    @Test("导入备份恢复到归档，重复导入会跳过")
    func importRestoresArchivedTasks() throws {
        let source = TaskStore(inMemory: true)
        let day = Date()
        source.add(title: "找回我", day: day, estimateMinutes: 45)
        let original = try #require(source.tasks.first)
        source.toggle(original)
        source.archive(original)
        original.notes = "导入后应保留"
        original.status = TaskStatus.waiting.rawValue
        original.statusNote = "等回复"
        original.priority = TaskPriority.high.rawValue
        original.subtasks = [SubtaskItem(title: "跟进", isDone: false, estimateMinutes: 5)]
        original.archivedAt = Date().addingTimeInterval(-2 * 86_400)

        let data = try ArchiveBackup.encode(ArchiveBackup.make(from: [original]))
        let backup = try ArchiveBackup.decodeForImport(data)

        let target = TaskStore(inMemory: true)
        let first = target.importArchived(backup.tasks)
        #expect(first.added == 1)
        #expect(first.overwritten == 0)
        #expect(first.skipped == 0)

        let restored = try #require(target.tasks.first)
        #expect(restored.id == original.id)
        #expect(restored.title == "找回我")
        #expect(restored.notes == "导入后应保留")
        #expect(restored.isDone)
        #expect(restored.status == TaskStatus.waiting.rawValue)
        #expect(restored.statusNote == "等回复")
        #expect(restored.priority == TaskPriority.high.rawValue)
        #expect(restored.estimateMinutes == 45)
        #expect(restored.subtasks?.first?.title == "跟进")
        let restoredArchivedAt = try #require(restored.archivedAt)
        let originalArchivedAt = try #require(original.archivedAt)
        #expect(abs(restoredArchivedAt.timeIntervalSince(originalArchivedAt)) < 2)
        #expect(Calendar.current.isDate(restored.scheduledDay, inSameDayAs: day))

        let second = target.importArchived(backup.tasks)
        #expect(second.added == 0)
        #expect(second.skipped == 1)
        #expect(target.tasks.count == 1)
    }

    @Test("导入冲突选择覆盖会更新现有任务，选择跳过则保留原内容")
    func importConflictPolicies() throws {
        let store = TaskStore(inMemory: true)
        let day = Date()
        store.add(title: "旧标题", day: day)
        let original = try #require(store.tasks.first)
        store.toggle(original)
        store.archive(original)
        original.notes = "旧描述"

        let firstExport = try ArchiveBackup.decodeForImport(
            ArchiveBackup.encode(ArchiveBackup.make(from: [original]))
        )
        let target = TaskStore(inMemory: true)
        #expect(target.importArchived(firstExport.tasks).added == 1)

        original.title = "新标题"
        original.notes = "新描述"
        original.status = TaskStatus.blocked.rawValue
        original.statusNote = "卡住了"
        let secondExport = try ArchiveBackup.decodeForImport(
            ArchiveBackup.encode(ArchiveBackup.make(from: [original]))
        )
        #expect(target.conflictingTaskIDs(secondExport.tasks) == [original.id])

        let skipped = target.importArchived(secondExport.tasks, policy: .skip)
        #expect(skipped.added == 0)
        #expect(skipped.overwritten == 0)
        #expect(skipped.skipped == 1)
        #expect(target.tasks.first?.title == "旧标题")

        let overwritten = target.importArchived(secondExport.tasks, policy: .overwrite)
        #expect(overwritten.added == 0)
        #expect(overwritten.overwritten == 1)
        #expect(overwritten.skipped == 0)
        #expect(target.tasks.count == 1)
        let updated = try #require(target.tasks.first)
        #expect(updated.id == original.id)
        #expect(updated.title == "新标题")
        #expect(updated.notes == "新描述")
        #expect(updated.status == TaskStatus.blocked.rawValue)
        #expect(updated.statusNote == "卡住了")
        #expect(updated.archivedAt != nil)
    }

    @Test("不支持的备份版本会拒绝导入")
    func rejectsUnsupportedVersion() throws {
        let store = TaskStore(inMemory: true)
        store.add(title: "版本检查", day: Date())
        let task = try #require(store.tasks.first)
        store.toggle(task)
        store.archive(task)

        let data = try ArchiveBackup.encode(ArchiveBackup.make(from: [task]))
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\"formatVersion\" : 1", with: "\"formatVersion\" : 99")
        let tampered = Data(text.utf8)

        #expect(throws: ArchiveBackupError.self) {
            try ArchiveBackup.decodeForImport(tampered)
        }
    }

    @Test("导出备份可编码解码且保留任务详情")
    func backupRoundTrip() throws {
        let store = TaskStore(inMemory: true)
        let day = Date()
        store.add(title: "写周报", day: day, estimateMinutes: 30)
        let task = try #require(store.tasks.first)
        store.toggle(task)
        store.archive(task)
        task.notes = "包含本周进度"
        task.status = TaskStatus.blocked.rawValue
        task.statusNote = "等数据"
        task.subtasks = [SubtaskItem(title: "汇总数据", isDone: true, estimateMinutes: 10)]

        let backup = ArchiveBackup.make(from: [task])
        let data = try ArchiveBackup.encode(backup)
        let decoded = try ArchiveBackup.decode(data)

        #expect(decoded.formatVersion == 1)
        #expect(decoded.taskCount == 1)
        let record = try #require(decoded.tasks.first)
        #expect(record.id == task.id)
        #expect(record.title == "写周报")
        #expect(record.notes == "包含本周进度")
        #expect(record.status == "阻塞")
        #expect(record.statusNote == "等数据")
        #expect(record.estimateMinutes == 30)
        #expect(record.subtasks?.first?.title == "汇总数据")
        #expect(record.archivedAt != nil)
    }

    @Test("备份文件名带时间戳")
    func backupFilename() {
        let name = ArchiveBackup.defaultFilename(now: Date())
        #expect(name.hasPrefix("TaskBoard-归档备份-"))
        #expect(name.hasSuffix(".json"))
    }
}

@Suite("检查更新", .serialized)
@MainActor
struct UpdateCheckerTests {
    @Test("版本号比较：补丁、前缀、预发布与补位")
    func versionComparison() {
        #expect(UpdateChecker.isNewer("1.0.1", than: "1.0.0"))
        #expect(UpdateChecker.isNewer("v0.2", than: "0.1.9"))
        #expect(UpdateChecker.isNewer("1.0", than: "0.9.9"))
        #expect(UpdateChecker.isNewer("1.0.0", than: "1.0.0-beta"))
        #expect(UpdateChecker.isNewer("1.0.0-beta", than: "1.0.0") == false)
        #expect(UpdateChecker.isNewer("0.1.0", than: "0.1.0") == false)
        #expect(UpdateChecker.isNewer("v1.2.3", than: "1.2.3") == false)
    }

    @Test("解析 Releases 返回并生成更新状态")
    func checksViaStub() async throws {
        let json = """
        {
          "tag_name": "v0.2.0",
          "name": "TaskBoard 0.2.0",
          "html_url": "https://github.com/SakuraLoveSmile/TaskBoard/releases/tag/v0.2.0",
          "body": "- 新功能"
        }
        """
        let payload = Data(json.utf8)

        let available = await UpdateChecker.check(
            currentVersion: "0.1.0",
            session: StubURLProtocol.session(status: 200, body: payload)
        )
        guard case .updateAvailable(let release) = available else {
            Issue.record("应识别到新版本，实际为 \(available)")
            return
        }
        #expect(release.version == "0.2.0")
        #expect(release.name == "TaskBoard 0.2.0")
        #expect(release.notes == "- 新功能")
        #expect(release.pageURL.absoluteString.hasSuffix("/releases/tag/v0.2.0"))

        let current = await UpdateChecker.check(
            currentVersion: "0.2.0",
            session: StubURLProtocol.session(status: 200, body: payload)
        )
        #expect(current == .upToDate(current: "0.2.0"))

        let missing = await UpdateChecker.check(
            currentVersion: "0.1.0",
            session: StubURLProtocol.session(status: 404, body: Data())
        )
        #expect(missing == .failed("还没有发布过版本"))
    }
}

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var payload = Data()

    static func session(status: Int, body: Data) -> URLSession {
        statusCode = status
        payload = body
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("任务进度与显示模式")
@MainActor
struct TaskProgressTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "test.progress.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test("任务进度夹紧到 0...100")
    func taskProgressClamps() {
        let store = TaskStore(inMemory: true)
        store.add(title: "A", day: Date())
        let task = store.tasks(for: Date()).first!

        store.setProgress(140, for: task)
        #expect(task.progress == 100)
        store.setProgress(-10, for: task)
        #expect(task.progress == 0)
        store.setProgress(45, for: task)
        #expect(task.progress == 45)
    }

    @Test("总进度只算未完成任务，按轻重缓急加权")
    func priorityWeightsTotal() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, agentConfigURL: nil)
        settings.autoArchiveCompleted = false
        let model = AppModel(settings: settings, store: TaskStore(inMemory: true), pomodoroDefaults: defaults)

        model.addTask("A")
        model.addTask("B")
        let tasks = model.todayTasks
        let a = tasks[0]
        let b = tasks[1]
        #expect(a.priority == TaskPriority.normal.rawValue)

        model.setTaskProgress(50, for: a)
        #expect(abs(model.averageProgress - 0.25) < 0.001)

        model.setTaskPriority(TaskPriority.high.rawValue, for: a)
        #expect(abs(model.averageProgress - 1.0 / 3) < 0.001)

        model.setTaskPriority(TaskPriority.low.rawValue, for: b)
        #expect(abs(model.averageProgress - 0.4) < 0.001)

        // 完成后离开分母：只剩 B 的 0%
        model.toggle(a)
        #expect(abs(model.averageProgress - 0) < 0.001)

        // 全部完成记 100%
        model.toggle(b)
        #expect(abs(model.averageProgress - 1) < 0.001)

        model.setTaskPriority(99, for: b)
        #expect(b.priority == TaskPriority.high.rawValue)
        model.setTaskPriority(-99, for: b)
        #expect(b.priority == TaskPriority.low.rawValue)
    }

    @Test("对外视图同样按轻重缓急加权")
    func priorityWeightsExternalTotal() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, agentConfigURL: nil)
        settings.autoArchiveCompleted = false
        settings.progressMode = .external
        let model = AppModel(settings: settings, store: TaskStore(inMemory: true), pomodoroDefaults: defaults)

        model.addTask("A")
        model.addTask("B")
        let tasks = model.todayTasks
        model.setTaskPriority(TaskPriority.high.rawValue, for: tasks[0])
        model.setTaskProgress(50, for: tasks[0])
        #expect(abs(model.displayProgress - 1.0 / 3) < 0.001)

        model.setTaskProgress(50, for: tasks[1])
        #expect(abs(model.displayProgress - 0.5) < 0.001)
    }

    @Test("真实/对外两份进度各自只算未完成任务，互不影响")
    func displayProgressModes() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, agentConfigURL: nil)
        settings.autoArchiveCompleted = false
        let model = AppModel(settings: settings, store: TaskStore(inMemory: true), pomodoroDefaults: defaults)

        #expect(model.displayProgress == 0)

        model.addTask("A")
        model.addTask("B")
        let tasks = model.todayTasks
        #expect(tasks.count == 2)

        model.setTaskProgress(40, for: tasks[0])
        #expect(tasks[0].progress == 40)
        #expect(abs(model.averageProgress - 0.2) < 0.001)
        #expect(model.displayPercent == 20)

        // 对外视图下拖任务进度条，只写 externalProgress
        model.toggleProgressMode()
        model.setTaskProgress(90, for: tasks[1])
        #expect(tasks[1].externalProgress == 90)
        #expect(tasks[1].progress == 0)
        #expect(abs(model.averageExternalProgress - 0.45) < 0.001)
        #expect(model.displayPercent == 45)
        #expect(model.progress(of: tasks[1]) == 90)

        // 切回真实视图：聚合回到真实进度
        model.toggleProgressMode()
        #expect(abs(model.displayProgress - 0.2) < 0.001)
        #expect(model.progress(of: tasks[1]) == 0)
        #expect(tasks[1].externalProgress == 90)

        // 完成的 A 退出分母，各视图只看剩下的 B
        model.toggle(tasks[0])
        #expect(model.displayProgress == 0)
        model.toggleProgressMode()
        #expect(model.displayPercent == 90)

        model.toggle(tasks[1])
        #expect(model.displayPercent == 100)
    }

    @Test("展示模式持久化，对外进度按任务夹紧")
    func settingsPersistence() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults, agentConfigURL: nil)
        #expect(settings.progressMode == .real)

        settings.progressMode = .external
        let reloaded = SettingsStore(defaults: defaults, agentConfigURL: nil)
        #expect(reloaded.progressMode == .external)
        #expect(defaults.string(forKey: "ui.progressMode") == "external")

        let store = TaskStore(inMemory: true)
        store.add(title: "A", day: Date())
        let task = store.tasks(for: Date()).first!
        store.setExternalProgress(120, for: task)
        #expect(task.externalProgress == 100)
        store.setExternalProgress(-5, for: task)
        #expect(task.externalProgress == 0)
        #expect(task.progress == 0)
    }

    @Test("专注时长不参与任务进度")
    func focusDoesNotAffectProgress() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, agentConfigURL: nil)
        settings.autoArchiveCompleted = false
        let model = AppModel(settings: settings, store: TaskStore(inMemory: true), pomodoroDefaults: defaults)

        model.addTask("A")
        let task = model.todayTasks.first!
        model.setTaskProgress(50, for: task)
        let before = model.displayProgress

        model.startFocus(task)
        #expect(model.pomodoro.isActive)
        #expect(abs(model.displayProgress - before) < 0.001)
        model.pomodoro.stop()
    }
}

@Suite("拖动任务排序")
@MainActor
struct TaskReorderTests {
    private func makePlannedStore() -> (store: TaskStore, a: TodoTask, b: TodoTask, c: TodoTask) {
        let store = TaskStore(inMemory: true)
        let day = Date()
        for title in ["A", "B", "C"] {
            store.add(title: title, day: day)
        }
        let tasks = store.tasks(for: day)
        let a = tasks.first { $0.title == "A" }!
        let b = tasks.first { $0.title == "B" }!
        let c = tasks.first { $0.title == "C" }!
        store.apply(plan: AIPlanResult(
            summary: "",
            stages: [
                PlannedStage(title: "热身", rationale: nil, taskIDs: [a.id, b.id]),
                PlannedStage(title: "深度工作", rationale: nil, taskIDs: [c.id])
            ],
            estimates: [:]
        ))
        return (store, a, b, c)
    }

    @Test("同阶段内拖到目标之后会重排 lane 与 sortIndex")
    func reorderWithinStage() {
        let (store, a, b, _) = makePlannedStore()

        #expect(store.moveTask(id: a.id, relativeTo: b.id, placeAfter: true))
        #expect(a.lane == 1)
        #expect(b.lane == 0)
        #expect(store.openTasks(for: Date()).map(\.title) == ["B", "A", "C"])
        #expect(a.stageIndex == 0)
        #expect(a.stageTitle == "热身")
    }

    @Test("拖到其他阶段的任务旁会跟随目标阶段")
    func movesAcrossStages() {
        let (store, a, b, c) = makePlannedStore()

        #expect(store.moveTask(id: a.id, relativeTo: c.id, placeAfter: false))
        #expect(a.stageIndex == 1)
        #expect(a.stageTitle == "深度工作")
        #expect(a.lane == 0)
        #expect(c.lane == 1)
        #expect(b.lane == 0)
        #expect(b.stageIndex == 0)
    }

    @Test("拖到阶段空白处会排到该阶段末尾")
    func appendsToStageEnd() {
        let (store, a, b, c) = makePlannedStore()

        #expect(store.moveTask(id: a.id, toStage: 1, stageTitle: "深度工作"))
        #expect(a.stageIndex == 1)
        #expect(c.lane == 0)
        #expect(a.lane == 1)
        #expect(b.lane == 0)
    }

    @Test("拖回待安排会清除阶段标记")
    func movesBackToUnplanned() {
        let (store, a, b, _) = makePlannedStore()
        let day = Date()
        store.add(title: "D", day: day)
        let d = store.tasks(for: day).first { $0.title == "D" }!

        #expect(store.moveTask(id: a.id, toStage: nil, stageTitle: nil))
        #expect(a.stageIndex == nil)
        #expect(a.stageTitle == nil)
        #expect(d.stageIndex == nil)
        #expect(b.stageIndex == 0)
    }

    @Test("拖到已完成任务或自己身上不生效")
    func rejectsInvalidTargets() {
        let (store, a, b, _) = makePlannedStore()

        #expect(!store.moveTask(id: a.id, relativeTo: a.id, placeAfter: true))

        store.toggle(b)
        #expect(!store.moveTask(id: a.id, relativeTo: b.id, placeAfter: true))
        #expect(a.lane == 0)
    }

    @Test("面板分组顺序随拖动更新")
    func stageGroupsReflectMove() {
        let suite = "test.reorder.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TaskStore(inMemory: true)
        let settings = SettingsStore(defaults: defaults, agentConfigURL: nil)
        let model = AppModel(settings: settings, store: store, pomodoroDefaults: defaults)

        model.addTask("A")
        model.addTask("B")
        let tasks = model.todayTasks
        let a = tasks.first { $0.title == "A" }!
        let b = tasks.first { $0.title == "B" }!
        store.apply(plan: AIPlanResult(
            summary: "",
            stages: [PlannedStage(title: "串联", rationale: nil, taskIDs: [a.id, b.id])],
            estimates: [:]
        ))

        #expect(model.stageGroups.first?.tasks.map(\.title) == ["A", "B"])
        model.moveTask(id: b.id, relativeTo: a.id, placeAfter: false)
        #expect(model.stageGroups.first?.tasks.map(\.title) == ["B", "A"])
    }
}

@Suite("任务状态")
@MainActor
struct TaskStatusTests {
    @Test("默认待办，状态夹紧到 0...3")
    func statusClamps() {
        let store = TaskStore(inMemory: true)
        store.add(title: "A", day: Date())
        let task = store.tasks.first!
        #expect(task.status == TaskStatus.todo.rawValue)

        store.setStatus(TaskStatus.blocked.rawValue, for: task)
        #expect(task.status == TaskStatus.blocked.rawValue)

        store.setStatus(99, for: task)
        #expect(task.status == TaskStatus.waiting.rawValue)
        store.setStatus(-3, for: task)
        #expect(task.status == TaskStatus.todo.rawValue)
    }

    @Test("阻塞/等待原因可保存，离开状态自动清除")
    func statusNoteLifecycle() {
        let store = TaskStore(inMemory: true)
        store.add(title: "A", day: Date())
        let task = store.tasks.first!

        store.setStatus(TaskStatus.blocked.rawValue, for: task)
        store.setStatusNote("等设计稿", for: task)
        #expect(task.statusNote == "等设计稿")

        store.setStatus(TaskStatus.waiting.rawValue, for: task)
        #expect(task.statusNote == "等设计稿")

        store.setStatus(TaskStatus.inProgress.rawValue, for: task)
        #expect(task.statusNote == nil)

        store.setStatus(TaskStatus.blocked.rawValue, for: task)
        store.setStatusNote("   ", for: task)
        #expect(task.statusNote == nil)
    }

    @Test("切到阻塞会自动打开原因输入并可保存")
    func blockedOpensNoteEditor() {
        let suite = "test.statusnote.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, agentConfigURL: nil)
        let model = AppModel(
            settings: settings,
            store: TaskStore(inMemory: true),
            pomodoroDefaults: defaults
        )
        model.addTask("A")
        let task = model.todayTasks.first!

        model.setTaskStatus(TaskStatus.blocked.rawValue, for: task)
        #expect(model.statusNoteTask?.id == task.id)

        model.submitStatusNote("等权限审批")
        #expect(model.statusNoteTask == nil)
        #expect(task.statusNote == "等权限审批")
    }

    @Test("阻塞任务不会被选为下一项专注")
    func blockedSkippedForFocus() {
        let suite = "test.status.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, agentConfigURL: nil)
        let model = AppModel(
            settings: settings,
            store: TaskStore(inMemory: true),
            pomodoroDefaults: defaults
        )

        model.addTask("A")
        model.addTask("B")
        let tasks = model.todayTasks
        model.setTaskStatus(TaskStatus.blocked.rawValue, for: tasks[0])
        #expect(model.nextFocusTask?.id == tasks[1].id)
        #expect(model.headerHint.contains("先做「B」"))

        model.setTaskStatus(TaskStatus.blocked.rawValue, for: tasks[1])
        #expect(model.nextFocusTask == nil)
        #expect(model.headerHint.contains("先解除阻塞"))
    }
}

@Suite("AI 编排指导")
@MainActor
struct PlanGuidanceTests {
    private func makeModel() -> (AppModel, UserDefaults, String) {
        let suite = "test.planguide.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(defaults: defaults, agentConfigURL: nil)
        let model = AppModel(
            settings: settings,
            store: TaskStore(inMemory: true),
            pomodoroDefaults: defaults
        )
        return (model, defaults, suite)
    }

    @Test("有任务时先弹出指导意见，关闭后不编排")
    func opensAndCancels() {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }

        model.beginPlan()
        #expect(!model.isPlanGuideVisible)

        model.addTask("A")
        model.beginPlan()
        #expect(model.isPlanGuideVisible)

        model.cancelPlan()
        #expect(!model.isPlanGuideVisible)
    }

    @Test("提交指导意见后关闭弹层")
    func submitClosesOverlay() {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }

        model.addTask("A")
        model.beginPlan()
        model.submitPlan(guidance: "先做难的")
        #expect(!model.isPlanGuideVisible)
        #expect(model.lastPlanGuidance == "先做难的")
    }
}

@Suite("任务标题编辑")
@MainActor
struct TaskTitleTests {
    @Test("重命名去空白、限制 200 字，空标题不生效")
    func renameSanitizes() {
        let store = TaskStore(inMemory: true)
        store.add(title: "旧标题", day: Date())
        let task = store.tasks.first!

        store.rename(task, to: "  新标题 \n")
        #expect(task.title == "新标题")

        store.rename(task, to: "   ")
        #expect(task.title == "新标题")

        store.rename(task, to: String(repeating: "字", count: 300))
        #expect(task.title.count == 200)
    }

    @Test("编辑标题弹层保存后写回，空标题保持弹层")
    func titleEditorFlow() {
        let suite = "test.title.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, agentConfigURL: nil)
        let model = AppModel(
            settings: settings,
            store: TaskStore(inMemory: true),
            pomodoroDefaults: defaults
        )
        model.addTask("A")
        let task = model.todayTasks.first!

        model.beginEditTitle(task)
        #expect(model.titleEditTask?.id == task.id)

        model.submitTitle("   ")
        #expect(model.titleEditTask?.id == task.id)
        #expect(task.title == "A")

        model.submitTitle("  新任务  ")
        #expect(model.titleEditTask == nil)
        #expect(task.title == "新任务")
    }
}

@Suite("任务描述")
@MainActor
struct TaskDescriptionTests {
    @Test("描述可保存、去空白，空内容清除")
    func descriptionRoundTrip() {
        let store = TaskStore(inMemory: true)
        store.add(title: "A", day: Date())
        let task = store.tasks.first!
        #expect(task.notes.isEmpty)

        store.setNotes("  背景说明  \n", for: task)
        #expect(task.notes == "背景说明")

        store.setNotes("   ", for: task)
        #expect(task.notes.isEmpty)
    }

    @Test("编辑描述弹层保存后写回任务")
    func descriptionEditorFlow() {
        let suite = "test.description.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, agentConfigURL: nil)
        let model = AppModel(
            settings: settings,
            store: TaskStore(inMemory: true),
            pomodoroDefaults: defaults
        )
        model.addTask("A")
        let task = model.todayTasks.first!

        model.beginEditDescription(task)
        #expect(model.descriptionTask?.id == task.id)

        model.submitDescription("验收标准：覆盖三种状态")
        #expect(model.descriptionTask == nil)
        #expect(task.notes == "验收标准：覆盖三种状态")
    }
}

@Suite("截图模式")
@MainActor
struct CaptureModeTests {
    @MainActor
    private final class Recorder {
        var values: [Bool] = []
    }

    @Test("允许截图开关更新状态并通知窗口控制器")
    func togglesCapture() {
        let suite = "test.capture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, agentConfigURL: nil)
        let model = AppModel(
            settings: settings,
            store: TaskStore(inMemory: true),
            pomodoroDefaults: defaults
        )
        let recorder = Recorder()
        model.captureHandler = { recorder.values.append($0) }

        #expect(!model.captureAllowed)
        model.setCaptureAllowed(true)
        #expect(model.captureAllowed)
        model.setCaptureAllowed(true)
        model.setCaptureAllowed(false)
        #expect(!model.captureAllowed)
        #expect(recorder.values == [true, false])
    }
}

@Suite("Magpie 接管配置")
@MainActor
struct MagpieAgentConfigTests {
    private func tempConfig(_ json: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tb-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("agent.json")
        if let json {
            try json.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "test.agentcfg.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test("agent.json 覆盖 AI 设置并标记由 Magpie 接管")
    func overlay() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = try tempConfig("""
        {"ai": {"baseURL": "http://127.0.0.1:9999/v1", "apiKey": "magpie", "modelID": "opencode-go/glm-5.3"}}
        """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let settings = SettingsStore(defaults: defaults, agentConfigURL: url)
        #expect(settings.aiSource == .magpie)
        #expect(settings.activeBaseURL == "http://127.0.0.1:9999/v1")
        #expect(settings.activeAPIKey == "magpie")
        #expect(settings.activeModelID == "opencode-go/glm-5.3")
        #expect(settings.managedByMagpie)
        // 手动配置保持默认，不被 Magpie 覆盖
        #expect(settings.baseURL == "http://127.0.0.1:3425/v1")
        #expect(settings.modelID.isEmpty)
    }

    @Test("切到手动配置后不再使用 Magpie，并保留手动值")
    func manualSourceWins() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = try tempConfig("""
        {"ai": {"baseURL": "http://127.0.0.1:9999/v1", "apiKey": "magpie", "modelID": "magpie/model"}}
        """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let settings = SettingsStore(defaults: defaults, agentConfigURL: url)
        #expect(settings.aiSource == .magpie)

        settings.baseURL = "https://api.example.com/v1"
        settings.apiKey = "sk-manual"
        settings.modelID = "manual-model"
        settings.selectAISource(.manual)

        #expect(!settings.managedByMagpie)
        #expect(settings.activeBaseURL == "https://api.example.com/v1")
        #expect(settings.activeAPIKey == "sk-manual")
        #expect(settings.activeModelID == "manual-model")
        #expect(defaults.string(forKey: "ai.source") == "manual")

        let reloaded = SettingsStore(defaults: defaults, agentConfigURL: url)
        #expect(reloaded.aiSource == .manual)
        #expect(reloaded.activeBaseURL == "https://api.example.com/v1")
    }

    @Test("重新读取 Magpie 配置会刷新活动模型")
    func reloadsMagpieConfig() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = try tempConfig("""
        {"ai": {"baseURL": "http://127.0.0.1:9999/v1", "modelID": "model-1"}}
        """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let settings = SettingsStore(defaults: defaults, agentConfigURL: url)
        #expect(settings.activeModelID == "model-1")

        try """
        {"ai": {"baseURL": "http://127.0.0.1:9999/v1", "modelID": "model-2"}}
        """.write(to: url, atomically: true, encoding: .utf8)

        settings.selectAISource(.magpie)
        #expect(settings.activeModelID == "model-2")
    }

    @Test("文件缺失、损坏或空值回落 defaults")
    func fallback() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("tb-missing-\(UUID().uuidString).json")
        let absent = SettingsStore(defaults: defaults, agentConfigURL: missing)
        #expect(absent.aiSource == .manual)
        #expect(!absent.managedByMagpie)
        #expect(absent.activeBaseURL == "http://127.0.0.1:3425/v1")

        let brokenURL = try tempConfig("{not json")
        defer { try? FileManager.default.removeItem(at: brokenURL.deletingLastPathComponent()) }
        let broken = SettingsStore(defaults: defaults, agentConfigURL: brokenURL)
        #expect(broken.aiSource == .manual)
        #expect(!broken.managedByMagpie)

        let emptyURL = try tempConfig(#"{"ai": {"baseURL": "", "modelID": "  "}}"#)
        defer { try? FileManager.default.removeItem(at: emptyURL.deletingLastPathComponent()) }
        let empty = SettingsStore(defaults: defaults, agentConfigURL: emptyURL)
        #expect(empty.aiSource == .manual)
        #expect(!empty.managedByMagpie)
    }
}

@Suite("AI 任务细化校验")
struct AIRefinerTests {
    @Test("正常拆分二级任务并更新时长")
    func parsesRefinement() throws {
        let raw = """
        {"estimateMinutes": 90, "subtasks": [
            {"title":"收集数据","estimateMinutes":25},
            {"title":"写初稿","estimateMinutes":40},
            {"title":"校对","minutes":20}
        ]}
        """
        let result = try AIRefiner.parse(raw: raw)
        #expect(result.estimateMinutes == 90)
        #expect(result.subtasks.map(\.title) == ["收集数据", "写初稿", "校对"])
        #expect(result.subtasks[2].estimateMinutes == 20)
    }

    @Test("夹紧超限时长、去重并限制最多 8 项")
    func clampsAndDedupes() throws {
        var items: [String] = []
        for index in 0..<12 {
            items.append("{\"title\":\"步骤\(index)\",\"estimateMinutes\":999}")
        }
        items.append("{\"title\":\"步骤0\"}")
        let raw = "{\"estimate_minutes\":9999,\"sub_tasks\":[\(items.joined(separator: ","))]}"
        let result = try AIRefiner.parse(raw: raw)
        #expect(result.estimateMinutes == 480)
        #expect(result.subtasks.count == 8)
        #expect(result.subtasks.allSatisfy { $0.estimateMinutes == 480 })
        #expect(Set(result.subtasks.map(\.title)).count == 8)
    }

    @Test("无 JSON 或空结果报错")
    func rejectsEmpty() {
        #expect(throws: RefineValidationError.self) {
            try AIRefiner.parse(raw: "not json")
        }
        #expect(throws: RefineValidationError.self) {
            try AIRefiner.parse(raw: #"{"subtasks":[]}"#)
        }
    }

    @Test("Markdown 代码块包裹也能解析")
    func parsesFencedJSON() throws {
        let raw = "```json\n{\"estimateMinutes\":30,\"subtasks\":[\"第一步\"]}\n```"
        let result = try AIRefiner.parse(raw: raw)
        #expect(result.estimateMinutes == 30)
        #expect(result.subtasks.first?.title == "第一步")
    }
}
