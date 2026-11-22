import Foundation

enum ArchiveImportPolicy {
    case skip
    case overwrite
}

struct ArchiveImportResult: Equatable {
    var added = 0
    var overwritten = 0
    var skipped = 0
}

enum ArchiveBackupError: LocalizedError {
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "不支持的备份版本（\(version)），请用当前版本导出的备份"
        }
    }
}

struct ArchiveBackup: Codable, Sendable {
    struct TaskRecord: Codable, Sendable {
        let id: UUID
        let title: String
        let notes: String
        let status: String
        let statusNote: String?
        let priority: String
        let estimateMinutes: Int?
        let focusMinutes: Int?
        let stageTitle: String?
        let scheduledDay: Date
        let createdAt: Date
        let completedAt: Date?
        let archivedAt: Date?
        let progress: Int
        let externalProgress: Int
        let subtasks: [SubtaskItem]?

        var taskStatus: TaskStatus {
            TaskStatus.allCases.first { $0.title == status } ?? .todo
        }

        var taskPriority: TaskPriority {
            TaskPriority.allCases.first { $0.title == priority } ?? .normal
        }

        init(task: TodoTask) {
            id = task.id
            title = task.title
            notes = task.notes
            status = TaskStatus(rawValue: task.status)?.title ?? TaskStatus.todo.title
            statusNote = task.statusNote
            priority = TaskPriority(rawValue: task.priority)?.title ?? TaskPriority.normal.title
            estimateMinutes = task.estimateMinutes
            focusMinutes = task.focusMinutes
            stageTitle = task.stageTitle
            scheduledDay = task.scheduledDay
            createdAt = task.createdAt
            completedAt = task.completedAt
            archivedAt = task.archivedAt
            progress = task.progress
            externalProgress = task.externalProgress
            subtasks = task.subtasks
        }
    }

    let formatVersion: Int
    let exportedAt: Date
    let appVersion: String?
    let taskCount: Int
    let tasks: [TaskRecord]

    static func make(
        from tasks: [TodoTask],
        now: Date = Date(),
        bundle: Bundle = .main
    ) -> ArchiveBackup {
        ArchiveBackup(
            formatVersion: 1,
            exportedAt: now,
            appVersion: bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
            taskCount: tasks.count,
            tasks: tasks.map(TaskRecord.init)
        )
    }

    static func encode(_ backup: ArchiveBackup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(backup)
    }

    static func decode(_ data: Data) throws -> ArchiveBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ArchiveBackup.self, from: data)
    }

    static func decodeForImport(_ data: Data) throws -> ArchiveBackup {
        let backup = try decode(data)
        guard backup.formatVersion == 1 else {
            throw ArchiveBackupError.unsupportedVersion(backup.formatVersion)
        }
        return backup
    }

    static func defaultFilename(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "TaskBoard-归档备份-\(formatter.string(from: now)).json"
    }
}
