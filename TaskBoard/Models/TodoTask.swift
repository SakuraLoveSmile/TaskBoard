import Foundation
import SwiftData

struct SubtaskItem: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var isDone: Bool
    var estimateMinutes: Int?

    init(id: UUID = UUID(), title: String, isDone: Bool = false, estimateMinutes: Int? = nil) {
        self.id = id
        self.title = title
        self.isDone = isDone
        self.estimateMinutes = estimateMinutes
    }
}

enum TaskStatus: Int, CaseIterable, Sendable {
    case todo = 0
    case inProgress = 1
    case blocked = 2
    case waiting = 3

    var title: String {
        switch self {
        case .todo: "待办"
        case .inProgress: "进行中"
        case .blocked: "阻塞"
        case .waiting: "等待"
        }
    }
}

enum TaskPriority: Int, CaseIterable {
    case low = -1
    case normal = 0
    case high = 1

    var weight: Double {
        switch self {
        case .low: 0.5
        case .normal: 1
        case .high: 2
        }
    }

    var title: String {
        switch self {
        case .low: "次要"
        case .normal: "常规"
        case .high: "关键"
        }
    }
}

@Model
final class TodoTask {
    @Attribute(.unique) var id: UUID
    var title: String
    var notes: String
    var createdAt: Date
    var scheduledDay: Date
    var originDay: Date?
    var isDone: Bool
    var completedAt: Date?
    var archivedAt: Date?
    var sortIndex: Int
    var stageIndex: Int?
    var stageTitle: String?
    var lane: Int
    var estimateMinutes: Int?
    var focusMinutes: Int?
    var progress: Int = 0
    var externalProgress: Int = 0
    var priority: Int = 0
    var status: Int = TaskStatus.todo.rawValue
    var statusNote: String?
    var subtasks: [SubtaskItem]?

    init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        createdAt: Date = Date(),
        scheduledDay: Date,
        originDay: Date? = nil,
        isDone: Bool = false,
        completedAt: Date? = nil,
        archivedAt: Date? = nil,
        sortIndex: Int = 0,
        stageIndex: Int? = nil,
        stageTitle: String? = nil,
        lane: Int = 0,
        estimateMinutes: Int? = nil,
        focusMinutes: Int? = nil,
        progress: Int = 0,
        externalProgress: Int = 0,
        priority: Int = 0,
        status: Int = TaskStatus.todo.rawValue,
        statusNote: String? = nil,
        subtasks: [SubtaskItem]? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.createdAt = createdAt
        self.scheduledDay = scheduledDay
        self.originDay = originDay
        self.isDone = isDone
        self.completedAt = completedAt
        self.archivedAt = archivedAt
        self.sortIndex = sortIndex
        self.stageIndex = stageIndex
        self.stageTitle = stageTitle
        self.lane = lane
        self.estimateMinutes = estimateMinutes
        self.focusMinutes = focusMinutes
        self.progress = progress
        self.externalProgress = externalProgress
        self.priority = priority
        self.status = status
        self.statusNote = statusNote
        self.subtasks = subtasks
    }
}

@Model
final class PomodoroSession {
    @Attribute(.unique) var id: UUID
    var taskID: UUID?
    var phaseRaw: String
    var startedAt: Date
    var plannedSeconds: Double
    var completed: Bool

    init(
        id: UUID = UUID(),
        taskID: UUID?,
        phaseRaw: String,
        startedAt: Date,
        plannedSeconds: Double,
        completed: Bool
    ) {
        self.id = id
        self.taskID = taskID
        self.phaseRaw = phaseRaw
        self.startedAt = startedAt
        self.plannedSeconds = plannedSeconds
        self.completed = completed
    }
}
