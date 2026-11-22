import Foundation
import Observation

enum ProgressDisplayMode: String, CaseIterable {
    case real
    case external
}

enum AIConfigSource: String, CaseIterable, Sendable {
    case magpie
    case manual

    var title: String {
        switch self {
        case .magpie: "Magpie 插件"
        case .manual: "手动配置"
        }
    }
}

@MainActor
@Observable
final class SettingsStore {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let agentConfigURL: URL?

    // Magpie 的 Agents 页选中 TaskBoard 后会写这份文件
    private(set) var hasMagpieConfig = false
    private(set) var magpieBaseURL = ""
    private(set) var magpieAPIKey = ""
    private(set) var magpieModelID = ""

    static var defaultAgentConfigURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TaskBoard/agent.json")
    }

    var aiSource: AIConfigSource = .manual {
        didSet { defaults.set(aiSource.rawValue, forKey: "ai.source") }
    }

    var baseURL: String { didSet { defaults.set(baseURL, forKey: "ai.baseURL") } }
    var apiKey: String { didSet { defaults.set(apiKey, forKey: "ai.apiKey") } }
    var modelID: String { didSet { defaults.set(modelID, forKey: "ai.modelID") } }
    var planTimeout: Double { didSet { defaults.set(planTimeout, forKey: "ai.timeout") } }

    var workMinutes: Int { didSet { defaults.set(workMinutes, forKey: "pomo.work") } }
    var shortBreakMinutes: Int { didSet { defaults.set(shortBreakMinutes, forKey: "pomo.short") } }
    var longBreakMinutes: Int { didSet { defaults.set(longBreakMinutes, forKey: "pomo.long") } }
    var longBreakInterval: Int { didSet { defaults.set(longBreakInterval, forKey: "pomo.interval") } }
    var autoStartBreak: Bool { didSet { defaults.set(autoStartBreak, forKey: "pomo.autoBreak") } }

    var autoArchiveCompleted: Bool { didSet { defaults.set(autoArchiveCompleted, forKey: "task.autoArchive") } }
    var autoArchiveDays: Int {
        didSet {
            let clamped = min(Self.maxAutoArchiveDays, max(0, autoArchiveDays))
            if clamped != autoArchiveDays {
                autoArchiveDays = clamped
            }
            defaults.set(clamped, forKey: "task.autoArchiveDays")
        }
    }
    static let maxAutoArchiveDays = 30

    // 0 = 永不清理
    var archiveRetentionDays: Int {
        didSet {
            let clamped = min(Self.maxArchiveRetentionDays, max(0, archiveRetentionDays))
            if clamped != archiveRetentionDays {
                archiveRetentionDays = clamped
            }
            defaults.set(clamped, forKey: "task.archiveRetentionDays")
        }
    }
    static let maxArchiveRetentionDays = 365

    var progressMode: ProgressDisplayMode {
        didSet { defaults.set(progressMode.rawValue, forKey: "ui.progressMode") }
    }

    var hidePebble: Bool { didSet { defaults.set(hidePebble, forKey: "ui.hidePebble") } }
    var hasPebblePosition: Bool { didSet { defaults.set(hasPebblePosition, forKey: "ui.hasPebblePosition") } }
    var pebbleX: Double { didSet { defaults.set(pebbleX, forKey: "ui.pebbleX") } }
    var pebbleY: Double { didSet { defaults.set(pebbleY, forKey: "ui.pebbleY") } }

    var managedByMagpie: Bool { aiSource == .magpie && hasMagpieConfig }

    // 实际请求 AI 用的配置：Magpie 模式优先用 agent.json，缺项回退手动值
    var activeBaseURL: String {
        guard aiSource == .magpie else { return baseURL }
        return magpieBaseURL.isEmpty ? baseURL : magpieBaseURL
    }

    var activeAPIKey: String {
        guard aiSource == .magpie, !magpieAPIKey.isEmpty else { return apiKey }
        return magpieAPIKey
    }

    var activeModelID: String {
        guard aiSource == .magpie else { return modelID }
        return magpieModelID.isEmpty ? modelID : magpieModelID
    }

    init(defaults: UserDefaults = .standard, agentConfigURL: URL? = SettingsStore.defaultAgentConfigURL) {
        self.defaults = defaults
        self.agentConfigURL = agentConfigURL

        func string(_ key: String, _ fallback: String) -> String {
            defaults.string(forKey: key) ?? fallback
        }
        func positiveInt(_ key: String, _ fallback: Int) -> Int {
            let value = defaults.integer(forKey: key)
            return value > 0 ? value : fallback
        }

        baseURL = string("ai.baseURL", "http://127.0.0.1:3425/v1")
        apiKey = string("ai.apiKey", "")
        modelID = string("ai.modelID", "")
        let timeout = defaults.double(forKey: "ai.timeout")
        planTimeout = timeout > 0 ? timeout : 25

        workMinutes = positiveInt("pomo.work", 25)
        shortBreakMinutes = positiveInt("pomo.short", 5)
        longBreakMinutes = positiveInt("pomo.long", 15)
        longBreakInterval = positiveInt("pomo.interval", 4)
        autoStartBreak = defaults.object(forKey: "pomo.autoBreak") as? Bool ?? false
        autoArchiveCompleted = defaults.object(forKey: "task.autoArchive") as? Bool ?? true
        if let savedDays = defaults.object(forKey: "task.autoArchiveDays") as? Int {
            autoArchiveDays = min(Self.maxAutoArchiveDays, max(0, savedDays))
        } else if let oldSeconds = defaults.object(forKey: "task.autoArchiveDelay") as? Int {
            // 旧版本以秒保存，迁移为向上取整的天数
            autoArchiveDays = Self.days(fromSeconds: oldSeconds)
        } else {
            autoArchiveDays = 1
        }
        let retention = defaults.object(forKey: "task.archiveRetentionDays") as? Int ?? 0
        archiveRetentionDays = min(Self.maxArchiveRetentionDays, max(0, retention))

        progressMode = ProgressDisplayMode(
            rawValue: defaults.string(forKey: "ui.progressMode") ?? ""
        ) ?? .real

        hidePebble = defaults.bool(forKey: "ui.hidePebble")
        hasPebblePosition = defaults.bool(forKey: "ui.hasPebblePosition")
        pebbleX = defaults.double(forKey: "ui.pebbleX")
        pebbleY = defaults.double(forKey: "ui.pebbleY")

        reloadMagpieConfig()

        if let raw = defaults.string(forKey: "ai.source"),
           let saved = AIConfigSource(rawValue: raw) {
            aiSource = saved
        } else {
            // 兼容旧行为：存在 agent.json 时默认使用 Magpie
            aiSource = hasMagpieConfig ? .magpie : .manual
        }
    }

    private static func days(fromSeconds seconds: Int) -> Int {
        guard seconds > 0 else { return 0 }
        let days = Int(ceil(Double(seconds) / 86_400))
        return min(maxAutoArchiveDays, max(1, days))
    }

    func selectAISource(_ source: AIConfigSource) {
        if source == .magpie {
            reloadMagpieConfig()
        }
        aiSource = source
    }

    func reloadMagpieConfig() {
        let config = Self.readAgentConfig(agentConfigURL)
        magpieBaseURL = config.baseURL ?? ""
        magpieAPIKey = config.apiKey ?? ""
        magpieModelID = config.modelID ?? ""
        hasMagpieConfig = config.hasAny
    }

    private struct AgentConfig {
        var baseURL: String?
        var apiKey: String?
        var modelID: String?

        var hasAny: Bool {
            baseURL != nil || apiKey != nil || modelID != nil
        }
    }

    private static func readAgentConfig(_ url: URL?) -> AgentConfig {
        guard let url,
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return AgentConfig() }

        let ai = root["ai"] as? [String: Any]
        func value(_ key: String) -> String? {
            let raw = (ai?[key] ?? root["ai.\(key)"]) as? String
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty
            else { return nil }
            return trimmed
        }

        return AgentConfig(
            baseURL: value("baseURL"),
            apiKey: value("apiKey"),
            modelID: value("modelID")
        )
    }
}
