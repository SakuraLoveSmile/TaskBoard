import Foundation

struct TodoTaskSnapshot: Sendable, Equatable {
    let id: UUID
    let title: String
    let estimateMinutes: Int?
    let sortIndex: Int
    var status: TaskStatus = .todo
    var statusNote: String? = nil
    var description: String? = nil
}

struct PlannedStage: Sendable, Equatable {
    var title: String
    var rationale: String?
    var taskIDs: [UUID]
}

struct AIPlanResult: Sendable, Equatable {
    var summary: String
    var stages: [PlannedStage]
    var estimates: [UUID: Int]

    var stageCount: Int { stages.count }
}

enum PlanValidationError: LocalizedError, Equatable {
    case noJSONObject
    case noStages
    case allIDsUnknown

    var errorDescription: String? {
        switch self {
        case .noJSONObject: "模型返回的内容不是 JSON"
        case .noStages: "模型返回里没有有效的阶段"
        case .allIDsUnknown: "阶段里的任务 id 全部无法匹配"
        }
    }
}
