import Foundation

struct AIPlanner: Sendable {
    let client: AIClient

    func plan(
        snapshots: [TodoTaskSnapshot],
        weekdayText: String,
        guidance: String? = nil,
        settings: AIPlanSettings,
        apiKey: String
    ) async throws -> AIPlanResult {
        guard !snapshots.isEmpty else { throw PlanValidationError.noStages }

        let basePrompt = Self.userPrompt(
            snapshots: snapshots,
            weekdayText: weekdayText,
            guidance: guidance
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
            return try Self.parse(raw: first, snapshots: snapshots)
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
            return try Self.parse(raw: second, snapshots: snapshots)
        }
    }

    static let systemPrompt = """
    你是一个日程编排助手。你只输出严格 JSON，不输出 Markdown、代码块标记或任何解释文字。
    """

    static func userPrompt(
        snapshots: [TodoTaskSnapshot],
        weekdayText: String,
        guidance: String? = nil
    ) -> String {
        let rows = snapshots.map { snapshot -> [String: Any] in
            var row: [String: Any] = ["id": snapshot.id.uuidString, "title": snapshot.title]
            if let minutes = snapshot.estimateMinutes { row["estimateMinutes"] = minutes }
            row["order"] = snapshot.sortIndex
            if snapshot.status != .todo {
                row["status"] = snapshot.status.title
                if let note = snapshot.statusNote, !note.isEmpty {
                    row["statusNote"] = note
                }
            }
            if let description = snapshot.description, !description.isEmpty {
                row["description"] = String(description.prefix(300))
            }
            return row
        }
        let json = (try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        let trimmedGuide = (guidance ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let guideLine = trimmedGuide.isEmpty
            ? ""
            : "\n用户指导意见（优先遵守，最多 500 字）：\(String(trimmedGuide.prefix(500)))\n"

        return """
        今天是\(weekdayText)。请把下面的今日任务编排成有先后顺序的阶段。
        任务列表（JSON）：\(json)
        \(guideLine)
        规则：
        1. 只输出一个 JSON 对象，结构为：
        {"summary":"一句话的今日策略","stages":[{"title":"不超过8个字的中文阶段名","rationale":"一句话说明为什么这样排","tasks":[{"id":"任务id","estimateMinutes":25}]}]}
        2. 阶段之间表示先后依赖；同一阶段内最多放 2 个任务，表示可以并行。超过 2 个任务必须拆到后续阶段。
        3. 任务 id 必须来自上面的列表，每个恰好出现一次，不新增、不重复、不遗漏。
        4. estimateMinutes 是可选的正整数（分钟），不要超过 480。
        5. 需要深度专注的任务尽量排在靠前、精力更好的时段；碎片沟通类任务可并行。
        6. status 是用户标注的当前状态，statusNote 是阻塞或等待的原因。状态为「阻塞」的任务不要排在最前面，原因表明暂时推不动时可放到靠后阶段，并在 rationale 里提示先解除阻塞；「等待」类任务可与可并行任务放在同一阶段，或排在靠后。
        7. description 是任务的补充说明（背景、验收标准等），编排先后顺序时参考它，不要改写或输出这些字段。
        8. 任务列表为空时输出 {"summary":"","stages":[]}。
        """
    }

    static func parse(raw: String, snapshots: [TodoTaskSnapshot]) throws -> AIPlanResult {
        guard let jsonText = extractJSON(from: raw),
              let data = jsonText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw PlanValidationError.noJSONObject
        }

        let stageDicts: [[String: Any]] = {
            for key in ["stages", "plan", "schedule"] {
                if let value = root[key] as? [[String: Any]] { return value }
            }
            if let nested = root["result"] as? [String: Any],
               let value = nested["stages"] as? [[String: Any]] {
                return value
            }
            return []
        }()
        guard !stageDicts.isEmpty else { throw PlanValidationError.noStages }

        let summary = (root["summary"] as? String) ?? (root["strategy"] as? String) ?? ""
        let validIDs = Set(snapshots.map(\.id))
        var estimates: [UUID: Int] = [:]
        var seen = Set<UUID>()
        var stages: [PlannedStage] = []
        var matchedAny = false

        func normalize(_ rawID: String) -> UUID? {
            UUID(uuidString: rawID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
        }

        func looseItems(_ stage: [String: Any]) -> [Any] {
            if let items = stage["tasks"] as? [Any] { return items }
            if let items = stage["parallel"] as? [Any] { return items }
            if let items = stage["items"] as? [Any] { return items }
            if let ids = stage["taskIDs"] as? [String] { return ids }
            if let ids = stage["task_ids"] as? [String] { return ids }
            return []
        }

        for dict in stageDicts {
            var stageTasks: [(UUID, Int?)] = []

            for item in looseItems(dict) {
                var rawID: String?
                var estimate: Int?

                if let string = item as? String {
                    rawID = string
                } else if let object = item as? [String: Any] {
                    rawID = object["id"] as? String
                        ?? object["taskID"] as? String
                        ?? object["task_id"] as? String
                    estimate = (object["estimateMinutes"] as? Int)
                        ?? (object["estimate_minutes"] as? Int)
                        ?? (object["minutes"] as? Int)
                }

                guard let rawID, let id = normalize(rawID), validIDs.contains(id), !seen.contains(id) else {
                    continue
                }
                matchedAny = true
                seen.insert(id)
                if let estimate {
                    estimates[id] = min(max(estimate, 1), 480)
                }
                stageTasks.append((id, estimate))
            }

            guard !stageTasks.isEmpty else { continue }
            let title = (dict["title"] as? String)
                ?? (dict["name"] as? String)
                ?? "阶段 \(stages.count + 1)"
            let rationale = (dict["rationale"] as? String) ?? (dict["reason"] as? String)

            var chunk: [UUID] = []
            var chunkIndex = 0
            for (taskID, _) in stageTasks {
                chunk.append(taskID)
                if chunk.count == 2 {
                    let suffix = chunkIndex == 0 ? "" : " · 续"
                    stages.append(PlannedStage(title: title + suffix, rationale: chunkIndex == 0 ? rationale : nil, taskIDs: chunk))
                    chunk.removeAll()
                    chunkIndex += 1
                }
            }
            if !chunk.isEmpty {
                let suffix = chunkIndex == 0 ? "" : " · 续"
                stages.append(PlannedStage(title: title + suffix, rationale: chunkIndex == 0 ? rationale : nil, taskIDs: chunk))
            }
        }

        if !matchedAny || stages.isEmpty {
            throw PlanValidationError.allIDsUnknown
        }

        let leftover = snapshots
            .filter { !seen.contains($0.id) }
            .sorted { $0.sortIndex < $1.sortIndex }
        if !leftover.isEmpty {
            stages.append(PlannedStage(title: "待安排", rationale: "AI 未编排的任务", taskIDs: leftover.map(\.id)))
        }

        return AIPlanResult(summary: summary, stages: stages, estimates: estimates)
    }

    static func extractJSON(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else { return nil }
        return String(text[start...end])
    }
}

struct AIPlanSettings: Sendable {
    let baseURL: String
    let model: String
    let timeout: Double
}
