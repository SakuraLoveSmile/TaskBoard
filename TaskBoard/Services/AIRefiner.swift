import Foundation

struct AIRefineResult: Sendable {
    let estimateMinutes: Int?
    let subtasks: [SubtaskItem]
}

enum RefineValidationError: LocalizedError {
    case noJSONObject
    case emptyResult
    case invalidSubtasks

    var errorDescription: String? {
        switch self {
        case .noJSONObject: "AI 返回的内容不是 JSON"
        case .emptyResult: "AI 既没有给出时长，也没有拆出二级任务"
        case .invalidSubtasks: "AI 给出的二级任务为空"
        }
    }
}

struct AIRefiner: Sendable {
    let client: AIClient

    func refine(
        taskTitle: String,
        currentEstimate: Int?,
        description: String,
        settings: AIPlanSettings,
        apiKey: String
    ) async throws -> AIRefineResult {
        let basePrompt = Self.userPrompt(
            taskTitle: taskTitle,
            currentEstimate: currentEstimate,
            description: description
        )
        let first = try await client.chat(
            baseURL: settings.baseURL,
            apiKey: apiKey,
            model: settings.model,
            system: Self.systemPrompt,
            user: basePrompt,
            timeout: settings.timeout
        )

        do {
            return try Self.parse(raw: first)
        } catch {
            let retryPrompt = basePrompt + "\n\n上一次输出无法使用：\(error.localizedDescription)。请只输出修正后的 JSON 对象。"
            let second = try await client.chat(
                baseURL: settings.baseURL,
                apiKey: apiKey,
                model: settings.model,
                system: Self.systemPrompt,
                user: retryPrompt,
                timeout: settings.timeout
            )
            return try Self.parse(raw: second)
        }
    }

    static let systemPrompt = """
    你是任务拆解助手。你只输出严格 JSON，不输出 Markdown、代码块标记或任何解释文字。
    """

    static func userPrompt(taskTitle: String, currentEstimate: Int?, description: String) -> String {
        let estimateText = currentEstimate.map { "\($0) 分钟" } ?? "未设置"
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let descriptionText = trimmed.isEmpty ? "（无）" : trimmed

        return """
        任务：\(taskTitle)
        当前预估计时：\(estimateText)
        我的补充说明：\(descriptionText)

        请根据补充说明，细化这个任务的完成时长，并拆解成二级任务。
        规则：
        1. 只输出一个 JSON 对象，结构为：
        {"estimateMinutes":45,"subtasks":[{"title":"不超过24个字的中文二级任务","estimateMinutes":15}]}
        2. estimateMinutes 是完成整个任务所需的总分钟数，正整数，1-480。
        3. subtasks 是 2-6 项按执行顺序排列的二级任务，标题要具体、可直接执行；每项可给 estimateMinutes。
        4. 各二级任务时长之和尽量接近总时长；确实不需要拆分时 subtasks 输出空数组。
        5. 使用中文，不要输出额外字段或解释。
        """
    }

    static func parse(raw: String) throws -> AIRefineResult {
        guard let jsonText = AIPlanner.extractJSON(from: raw),
              let data = jsonText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw RefineValidationError.noJSONObject
        }

        func intValue(_ value: Any?) -> Int? {
            if let number = value as? Int { return number }
            if let number = value as? Double { return Int(number) }
            if let number = value as? NSNumber { return number.intValue }
            if let text = value as? String, let number = Int(text) { return number }
            return nil
        }

        let rawEstimate = intValue(root["estimateMinutes"])
            ?? intValue(root["estimate_minutes"])
            ?? intValue(root["minutes"])
        let estimate = rawEstimate.map { min(max($0, 1), 480) }

        let rawSubtasks: [Any] = {
            for key in ["subtasks", "subTasks", "sub_tasks", "steps"] {
                if let items = root[key] as? [Any] { return items }
            }
            return []
        }()

        var subtasks: [SubtaskItem] = []
        var seenTitles = Set<String>()
        for item in rawSubtasks {
            var title: String?
            var minutes: Int?
            if let text = item as? String {
                title = text
            } else if let object = item as? [String: Any] {
                title = object["title"] as? String
                    ?? object["name"] as? String
                    ?? object["task"] as? String
                minutes = intValue(object["estimateMinutes"])
                    ?? intValue(object["estimate_minutes"])
                    ?? intValue(object["minutes"])
            }

            guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty,
                  !seenTitles.contains(trimmed)
            else { continue }
            seenTitles.insert(trimmed)
            subtasks.append(
                SubtaskItem(
                    title: String(trimmed.prefix(60)),
                    estimateMinutes: minutes.map { min(max($0, 1), 480) }
                )
            )
            if subtasks.count == 8 { break }
        }

        if estimate == nil, subtasks.isEmpty {
            throw RefineValidationError.emptyResult
        }
        return AIRefineResult(estimateMinutes: estimate, subtasks: subtasks)
    }
}
