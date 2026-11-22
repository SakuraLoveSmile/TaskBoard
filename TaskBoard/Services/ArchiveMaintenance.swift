import Foundation

struct ArchivePurgeResult {
    let removed: Int
    let backupURL: URL?
    let error: String?

    static let empty = ArchivePurgeResult(removed: 0, backupURL: nil, error: nil)
}

@MainActor
enum ArchiveMaintenance {
    static let maxBackups = 20

    // 先落盘备份，写成功后才删除；备份失败则保留归档
    static func purge(
        store: TaskStore,
        olderThanDays days: Int,
        backupDirectory: URL,
        now: Date = Date()
    ) -> ArchivePurgeResult {
        guard days > 0 else { return .empty }
        let expired = store.expiredArchived(olderThanDays: days, now: now)
        guard !expired.isEmpty else { return .empty }

        do {
            let backupURL = try writeBackup(tasks: expired, to: backupDirectory, now: now)
            let removed = store.remove(expired)
            pruneBackups(in: backupDirectory)
            return ArchivePurgeResult(removed: removed, backupURL: backupURL, error: nil)
        } catch {
            return ArchivePurgeResult(
                removed: 0,
                backupURL: nil,
                error: error.localizedDescription
            )
        }
    }

    static func writeBackup(tasks: [TodoTask], to directory: URL, now: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent(ArchiveBackup.defaultFilename(now: now))
        let data = try ArchiveBackup.encode(ArchiveBackup.make(from: tasks, now: now))
        try data.write(to: url, options: .atomic)
        return url
    }

    static func backupFiles(in directory: URL) -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return files
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func latestBackup(in directory: URL) -> URL? {
        backupFiles(in: directory).last
    }

    static func pruneBackups(in directory: URL, keep: Int = maxBackups) {
        guard keep > 0 else { return }
        let backups = backupFiles(in: directory)
        guard backups.count > keep else { return }
        for url in backups.prefix(backups.count - keep) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
