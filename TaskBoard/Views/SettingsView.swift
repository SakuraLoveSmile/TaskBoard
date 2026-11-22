import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @Bindable var settings: SettingsStore

    @State private var models: [AIModel] = []
    @State private var search = ""
    @State private var isLoadingModels = false
    @State private var connectionMessage: String?
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    @State private var cleanupMessage: String?

    init(model: AppModel) {
        _model = Bindable(wrappedValue: model)
        _settings = Bindable(wrappedValue: model.settings)
    }

    var body: some View {
        Form {
            Section("通用") {
                Toggle("登录时启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        launchError = LaunchAtLogin.setEnabled(enabled)
                    }
                Toggle("隐藏浮钮（仅保留菜单栏图标）", isOn: Binding(
                    get: { model.settings.hidePebble },
                    set: { model.setPebbleHidden($0) }
                ))
                HStack {
                    Button("重置浮钮位置") { model.resetPebblePosition() }
                    Spacer()
                    Text("⌥Space 随时呼出")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("番茄钟") {
                Stepper("专注 \(settings.workMinutes) 分钟", value: $settings.workMinutes, in: 1...120)
                Stepper("短休息 \(settings.shortBreakMinutes) 分钟", value: $settings.shortBreakMinutes, in: 1...60)
                Stepper("长休息 \(settings.longBreakMinutes) 分钟", value: $settings.longBreakMinutes, in: 1...90)
                Stepper("每 \(settings.longBreakInterval) 轮进入长休息", value: $settings.longBreakInterval, in: 2...10)
                Toggle("自动开始休息", isOn: $settings.autoStartBreak)
            }

            Section("任务") {
                Toggle("完成后自动归档", isOn: $settings.autoArchiveCompleted)
                if settings.autoArchiveCompleted {
                    HStack {
                        Text("归档延迟")
                        Spacer()
                        TextField("天", value: $settings.autoArchiveDays, format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Text("天")
                            .foregroundStyle(.secondary)
                    }
                    Text(archiveDelayHint)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                HStack {
                    Text("归档保留")
                    Spacer()
                    TextField("天", value: $settings.archiveRetentionDays, format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("天")
                        .foregroundStyle(.secondary)
                }
                Text("0 表示永不清理；启动和跨天时会自动清理超过天数的归档，清理前自动备份（保留最近 20 份）")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("备份位置：\(model.backupDirectory.path)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("在访达中显示") { revealLatestBackup() }
                        .controlSize(.small)
                        .help("在访达中选中最近一次自动备份文件")
                }
                HStack {
                    Text(cleanupMessage ?? "清理前会先导出备份")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("备份文件夹") { openBackupFolder() }
                        .help(model.backupDirectory.path)
                    Button("立即清理") { runArchiveCleanup() }
                        .disabled(settings.archiveRetentionDays == 0)
                }
                HStack {
                    Text("归档任务 \(model.archivedCount) 件")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("打开归档…") { model.openArchive() }
                }
            }

            Section("AI") {
                Picker("配置来源", selection: Binding(
                    get: { settings.aiSource },
                    set: { settings.selectAISource($0) }
                )) {
                    ForEach(AIConfigSource.allCases, id: \.self) { source in
                        Text(source.title).tag(source)
                    }
                }
                .pickerStyle(.segmented)

                if settings.aiSource == .magpie {
                    HStack(spacing: 5) {
                        Image(systemName: settings.hasMagpieConfig ? "link" : "exclamationmark.triangle")
                            .font(.system(size: 8.5, weight: .semibold))
                        Text(
                            settings.hasMagpieConfig
                                ? "使用 Magpie Agents 页的配置；换模型后点「重新读取」或重启 TaskBoard"
                                : "未检测到 Magpie 配置（agent.json），当前回退到手动配置"
                        )
                        .font(.caption)
                    }
                    .foregroundStyle(settings.hasMagpieConfig ? Theme.accent : Color.orange)

                    configRow("Base URL", value: settings.activeBaseURL)
                    configRow(
                        "模型",
                        value: settings.activeModelID.isEmpty ? "尚未选择" : settings.activeModelID
                    )

                    HStack {
                        Button(settings.hasMagpieConfig ? "重新读取 Magpie 配置" : "检查 Magpie 配置") {
                            settings.reloadMagpieConfig()
                            connectionMessage = nil
                        }
                        Spacer()
                    }
                } else {
                    TextField("Base URL", text: $settings.baseURL)
                        .textFieldStyle(.roundedBorder)
                    SecureField("网关 Key（本机回环可留空）", text: $settings.apiKey)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 8) {
                        Text(selectedModelSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button(isLoadingModels ? "刷新中…" : "刷新模型") {
                            Task { await loadModels() }
                        }
                        .disabled(isLoadingModels)
                    }

                    if let connectionMessage {
                        Text(connectionMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ModelListView(models: models, search: $search, selection: $settings.modelID)
                }
            }

            Section("关于") {
                HStack {
                    Text("版本")
                    Spacer()
                    Text(appVersion)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("检查更新…") { model.checkForUpdates() }
                    Spacer()
                    Button("GitHub 项目主页") {
                        NSWorkspace.shared.open(
                            URL(string: "https://github.com/\(UpdateChecker.repository)")!
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 560)
        .task {
            if settings.aiSource == .manual {
                await loadModels()
            }
        }
        .onChange(of: settings.aiSource) { _, source in
            models = []
            connectionMessage = nil
            if source == .manual {
                Task { await loadModels() }
            }
        }
    }

    private func configRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "0.0.0"
    }

    private func openBackupFolder() {
        try? FileManager.default.createDirectory(
            at: model.backupDirectory,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(model.backupDirectory)
    }

    private func revealLatestBackup() {
        if let latest = ArchiveMaintenance.latestBackup(in: model.backupDirectory) {
            NSWorkspace.shared.activateFileViewerSelecting([latest])
            cleanupMessage = "已在访达中定位 \(latest.lastPathComponent)"
        } else {
            openBackupFolder()
            cleanupMessage = "还没有自动备份，已打开备份文件夹"
        }
    }

    private func runArchiveCleanup() {
        let days = settings.archiveRetentionDays
        guard days > 0 else {
            cleanupMessage = "保留天数为 0，不会清理归档"
            return
        }
        let result = model.purgeExpiredArchive()
        if let error = result.error {
            cleanupMessage = "清理失败，归档已保留：\(error)"
        } else if result.removed > 0 {
            let backupName = result.backupURL?.lastPathComponent ?? "已备份"
            cleanupMessage = "已清理 \(result.removed) 件，备份：\(backupName)"
        } else {
            cleanupMessage = "没有超过 \(days) 天的归档"
        }
    }

    private var archiveDelayHint: String {
        let days = settings.autoArchiveDays
        if days == 0 { return "勾选后立即收进归档" }
        return "勾选后停留 \(days) 天再收进归档"
    }

    private var selectedModelSummary: String {
        guard !settings.modelID.isEmpty else { return "尚未选择模型" }
        if let match = models.first(where: { $0.id == settings.modelID }) {
            return "当前：\(match.displayName)"
        }
        return "当前：\(settings.modelID)"
    }

    private func loadModels() async {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            let list = try await model.aiClient.fetchModels(
                baseURL: settings.baseURL,
                apiKey: settings.apiKey
            )
            guard settings.aiSource == .manual else { return }
            models = list
            connectionMessage = "已连接 · \(list.count) 个模型"
            if settings.modelID.isEmpty, let first = list.first {
                settings.modelID = first.id
            }
        } catch {
            guard settings.aiSource == .manual else { return }
            models = []
            connectionMessage = "未连接：\(error.localizedDescription)"
        }
    }
}

struct ModelListView: View {
    let models: [AIModel]
    @Binding var search: String
    @Binding var selection: String

    private var filtered: [AIModel] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return models }
        return models.filter {
            $0.id.localizedCaseInsensitiveContains(query)
                || $0.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    private var grouped: [(String, [AIModel])] {
        Dictionary(grouping: filtered, by: \.providerName)
            .map { ($0.key, $0.value.sorted { $0.displayName < $1.displayName }) }
            .sorted { $0.0 < $1.0 }
    }

    var body: some View {
        VStack(spacing: 6) {
            TextField("搜索模型", text: $search)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if filtered.isEmpty {
                        Text(models.isEmpty ? "还没有加载到模型" : "没有匹配的模型")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(grouped, id: \.0) { provider, entries in
                        Text(provider)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 6)
                            .padding(.bottom, 2)
                        ForEach(entries) { entry in
                            modelRow(entry)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(maxHeight: 220)
        }
    }

    private func modelRow(_ entry: AIModel) -> some View {
        Button {
            selection = entry.id
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(entry.id)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if let window = entry.contextWindow {
                    Text("\(window / 1000)k")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                if selection == entry.id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selection == entry.id ? Theme.accentSoft : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
