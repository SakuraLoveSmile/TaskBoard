import AppKit

@MainActor
final class StatusItemController: NSObject {
    private static let autosaveName = "com.sakurasep.taskboard.status"
    private let statusItem: NSStatusItem
    private let model: AppModel
    var onOpenSettings: (() -> Void)?
    var onOpenArchive: (() -> Void)?
    var onCheckUpdates: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        // 首次创建给一个靠右的偏好位置，避免默认落在最左格被顶部灵动岛浮层压住
        let positionKey = "NSStatusItem Preferred Position \(Self.autosaveName)"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(230, forKey: positionKey)
        }
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem.autosaveName = Self.autosaveName
        super.init()

        if let button = statusItem.button {
            let image: NSImage?
            if let assetImage = NSImage(named: "MenuBarIcon") {
                image = assetImage
            } else if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "pdf"),
                      let pdfImage = NSImage(contentsOf: url) {
                image = pdfImage
            } else {
                image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "TaskBoard")
            }
            image?.size = NSSize(width: 18, height: 18)
            image?.isTemplate = true
            image?.accessibilityDescription = "TaskBoard"
            button.image = image
            button.imageScaling = .scaleProportionallyDown
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "TaskBoard 今日看板"
        }

        if ProcessInfo.processInfo.arguments.contains("--status-debug") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(1200))
                guard let self, let button = self.statusItem.button else { return }
                let text = """
                length=\(self.statusItem.length)
                frame=\(button.frame)
                window=\(String(describing: button.window?.frame))
                imageSize=\(String(describing: button.image?.size))
                reps=\(button.image?.representations.count ?? -1)
                isTemplate=\(button.image?.isTemplate ?? false)
                isHidden=\(button.isHidden)
                screen=\(NSScreen.main?.frame ?? .zero)
                """
                try? text.write(to: URL(fileURLWithPath: "/tmp/taskboard-status.log"), atomically: true, encoding: .utf8)
            }
        }
    }

    func refresh() {
        guard let button = statusItem.button else { return }
        if model.pomodoro.isActive {
            button.title = " " + model.pomodoro.timeText
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        } else {
            button.title = ""
        }
    }

    @objc private func handleClick() {
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
        if isRightClick {
            let menu = buildMenu()
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            model.toggleExpanded()
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let open = NSMenuItem(title: "打开看板", action: #selector(openPanel), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let toggleTitle: String = switch model.pomodoro.state {
        case .running: "暂停专注"
        case .paused: "继续专注"
        case .idle: "开始专注"
        }
        let toggle = NSMenuItem(title: toggleTitle, action: #selector(togglePomodoro), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(.separator())

        let archive = NSMenuItem(
            title: model.archivedCount > 0 ? "任务归档（\(model.archivedCount)）…" : "任务归档…",
            action: #selector(openArchive),
            keyEquivalent: ""
        )
        archive.target = self
        menu.addItem(archive)

        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let updates = NSMenuItem(
            title: "检查更新…",
            action: #selector(checkUpdates),
            keyEquivalent: ""
        )
        updates.target = self
        menu.addItem(updates)

        let hide = NSMenuItem(
            title: model.settings.hidePebble ? "显示浮钮" : "隐藏浮钮",
            action: #selector(togglePebble),
            keyEquivalent: ""
        )
        hide.target = self
        menu.addItem(hide)

        let capture = NSMenuItem(
            title: "允许截图/录屏",
            action: #selector(toggleCapture),
            keyEquivalent: ""
        )
        capture.target = self
        capture.state = model.captureAllowed ? .on : .off
        menu.addItem(capture)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 TaskBoard", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func openPanel() {
        model.expand()
    }

    @objc private func togglePomodoro() {
        model.togglePomodoro()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func openArchive() {
        onOpenArchive?()
    }

    @objc private func checkUpdates() {
        onCheckUpdates?()
    }

    @objc private func togglePebble() {
        model.setPebbleHidden(!model.settings.hidePebble)
    }

    @objc private func toggleCapture() {
        model.setCaptureAllowed(!model.captureAllowed)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
