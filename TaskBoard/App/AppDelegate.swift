import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var panelController: PanelController!
    private var statusItemController: StatusItemController!
    private var focusHUD: FocusHUDController?
    private var hotKeyManager: HotKeyManager?
    private var settingsWindow: SettingsWindowController?
    private var archiveWindow: ArchiveWindowController?
    private var outsideMonitor: Any?
    private var dayTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-updates") {
            checkUpdatesAndExit()
            return
        }
        if runSetupCheckIfRequested() {
            return
        }
        installMainMenu()
        let inMemory = ProcessInfo.processInfo.arguments.contains("--in-memory")
        let demo = inMemory && ProcessInfo.processInfo.arguments.contains("--demo")
        let defaults: UserDefaults
        if demo {
            // 演示/截图用独立 defaults，避免读写真实偏好与番茄钟快照
            let suite = "com.sakurasep.taskboard.demo"
            defaults = UserDefaults(suiteName: suite) ?? .standard
            defaults.removePersistentDomain(forName: suite)
        } else {
            defaults = .standard
        }
        model = AppModel(
            settings: SettingsStore(defaults: defaults),
            store: inMemory ? TaskStore(inMemory: true) : TaskStore(),
            pomodoroDefaults: defaults
        )
        if demo {
            seedDemoTasks()
        }
        if model.settings.autoArchiveCompleted {
            model.store.archiveCompleted(olderThanDays: model.settings.autoArchiveDays)
        }
        if ProcessInfo.processInfo.arguments.contains("--fast-timer") {
            model.pomodoro.debugPhaseSeconds = 3
        }
        panelController = PanelController(model: model, rootView: RootView(model: model))

        model.expandHandler = { [weak self] in self?.panelController.expandWindow() }
        model.collapseHandler = { [weak self] in self?.panelController.collapseWindow() }
        model.openSettingsHandler = { [weak self] in self?.showSettings() }
        model.openArchiveHandler = { [weak self] in self?.showArchive() }
        model.pebbleVisibilityHandler = { [weak self] hidden in self?.panelController.setHidden(hidden) }
        model.resetPebbleHandler = { [weak self] in self?.panelController.resetPosition() }
        model.isPointerNearPebble = { [weak self] margin in
            self?.panelController.isPointerNearPebble(margin: margin) ?? false
        }
        model.pebblePressHandler = { [weak self] pressed in
            self?.panelController.setPebblePressed(pressed)
        }
        model.isPointInsidePanel = { [weak self] point in
            guard let self else { return false }
            return self.panelController.containsGlobalPoint(point)
                || (self.focusHUD?.containsGlobalPoint(point) ?? false)
        }
        model.beginMoveHandler = { [weak self] in self?.panelController.beginDrag() }
        model.moveToMouseHandler = { [weak self] in self?.panelController.moveToMouse() }
        model.endMoveHandler = { [weak self] in self?.panelController.endDrag() }

        panelController.show()

        if ProcessInfo.processInfo.arguments.contains("--expanded") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                model.expand()
            }
        }

        statusItemController = StatusItemController(model: model)
        statusItemController.onOpenSettings = { [weak self] in self?.showSettings() }
        statusItemController.onOpenArchive = { [weak self] in self?.showArchive() }
        statusItemController.onCheckUpdates = { [weak self] in self?.checkForUpdates() }

        model.checkUpdatesHandler = { [weak self] in self?.checkForUpdates() }

        focusHUD = FocusHUDController(model: model)
        model.captureHandler = { [weak self] allowed in
            self?.panelController.setCaptureAllowed(allowed)
            self?.focusHUD?.setCaptureAllowed(allowed)
        }

        hotKeyManager = HotKeyManager { [weak self] in
            self?.model.toggleExpanded()
        }

        NotificationService.shared.requestAuthorization()

        model.pomodoro.onPhaseFinished = { [weak self] phase, taskID, plannedSeconds in
            self?.handlePhaseFinished(phase: phase, taskID: taskID, plannedSeconds: plannedSeconds)
        }
        model.pomodoro.onTick = { [weak self] in
            self?.statusItemController.refresh()
            self?.focusHUD?.updateVisibility()
        }

        model.performStartupRollover()
        statusItemController.refresh()
        focusHUD?.updateVisibility()

        outsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.collapseExternal()
            }
        }

        dayTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.checkDayChange()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let outsideMonitor {
            NSEvent.removeMonitor(outsideMonitor)
        }
        dayTimer?.invalidate()
    }

    private func installMainMenu() {
        // 无主菜单时 ⌘V/⌘C/⌘A 等编辑快捷键没有菜单项可路由，输入框无法粘贴
        let mainMenu = NSMenu()
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    private func seedDemoTasks() {
        let day = Calendar.current.startOfDay(for: Date())
        let seeds: [(title: String, status: TaskStatus, progress: Int)] = [
            ("整理本周工作周报", .todo, 0),
            ("写 Q4 复盘初稿", .inProgress, 45),
            ("接入支付回调", .blocked, 30),
            ("等设计确认首页改版", .waiting, 70),
        ]
        for seed in seeds {
            model.store.add(title: seed.title, day: day)
            guard let task = model.store.tasks(for: day).last else { continue }
            model.store.setStatus(seed.status.rawValue, for: task)
            model.store.setProgress(seed.progress, for: task)
            model.store.setExternalProgress(seed.progress, for: task)
        }
    }

    private func checkUpdatesAndExit() {
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
        Task { @MainActor in
            let status = await UpdateChecker.check(currentVersion: current)
            let text: String
            switch status {
            case .upToDate(let version):
                text = "status=up-to-date\ncurrent=\(version)\n"
            case .updateAvailable(let release):
                text = """
                status=update-available
                current=\(current)
                latest=\(release.version)
                url=\(release.pageURL.absoluteString)
                """
            case .failed(let message):
                text = "status=failed\ncurrent=\(current)\nerror=\(message)\n"
            }
            try? text.write(
                to: URL(fileURLWithPath: "/tmp/taskboard-update.log"),
                atomically: true,
                encoding: .utf8
            )
            NSApp.terminate(nil)
        }
    }

    private func runSetupCheckIfRequested() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        let wantsEnable = arguments.contains("--enable-login-item")
        let wantsStatus = arguments.contains("--print-status")
        guard wantsEnable || wantsStatus else { return false }

        var lines: [String] = []
        if wantsEnable {
            let error = LaunchAtLogin.setEnabled(true)
            lines.append("enable_error=\(error ?? "none")")
        }
        lines.append("login_item=\(LaunchAtLogin.statusText)")
        let base = lines.joined(separator: "\n") + "\n"

        let logURL = URL(fileURLWithPath: "/tmp/taskboard-setup.log")
        try? base.write(to: logURL, atomically: true, encoding: .utf8)

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let text = base + "notifications=\(settings.authorizationStatus.rawValue)\n"
            try? text.write(to: logURL, atomically: true, encoding: .utf8)
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
        return true
    }

    private func showSettings() {
        if model.isExpanded {
            model.collapse()
        }
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(model: model)
        }
        settingsWindow?.present()
    }

    private func checkForUpdates() {
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
        NSApp.activate(ignoringOtherApps: true)

        Task { @MainActor in
            let status = await UpdateChecker.check(currentVersion: current)
            let alert = NSAlert()
            switch status {
            case .upToDate(let version):
                alert.messageText = "已是最新版本"
                alert.informativeText = "当前版本 \(version)。"
                alert.addButton(withTitle: "好")
                alert.runModal()

            case .updateAvailable(let release):
                alert.messageText = "发现新版本 \(release.version)"
                var notes = release.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if notes.count > 600 {
                    notes = String(notes.prefix(600)) + "…"
                }
                alert.informativeText = notes.isEmpty
                    ? "当前版本 \(current)，可前往 GitHub 下载更新。"
                    : notes + "\n\n当前版本 \(current)。"
                alert.addButton(withTitle: "前往下载")
                alert.addButton(withTitle: "稍后")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(release.pageURL)
                }

            case .failed(let message):
                alert.messageText = "检查更新失败"
                alert.informativeText = message
                alert.addButton(withTitle: "好")
                alert.addButton(withTitle: "打开 Releases")
                if alert.runModal() == .alertSecondButtonReturn {
                    NSWorkspace.shared.open(UpdateChecker.releasesPageURL)
                }
            }
        }
    }

    private func showArchive() {
        if model.isExpanded {
            model.collapse()
        }
        if archiveWindow == nil {
            archiveWindow = ArchiveWindowController(model: model)
        }
        archiveWindow?.present()
    }

    private func handlePhaseFinished(
        phase: PomodoroPhase,
        taskID: UUID?,
        plannedSeconds: TimeInterval
    ) {
        switch phase {
        case .work:
            let title = taskID.flatMap { id in
                model.todayTasks.first { $0.id == id }?.title
            }
            NotificationService.shared.notify(
                title: "专注完成",
                body: title.map { "「\($0)」完成一轮专注，休息一下。" } ?? "完成一轮专注，休息一下。"
            )
            model.store.recordSession(
                taskID: taskID,
                phase: .work,
                plannedSeconds: plannedSeconds,
                startedAt: Date().addingTimeInterval(-plannedSeconds)
            )
        case .shortBreak, .longBreak:
            NotificationService.shared.notify(
                title: "休息结束",
                body: "回来继续今天的计划吧。"
            )
        }
    }
}
