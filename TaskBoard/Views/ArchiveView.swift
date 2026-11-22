import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ArchiveView: View {
    @Bindable var model: AppModel
    @State private var query = ""
    @State private var statusMessage: String?
    @State private var pendingImport: PendingImport?

    private struct PendingImport: Identifiable {
        let id = UUID()
        let backup: ArchiveBackup
        let conflicts: Int
    }

    private var groups: [ArchivedDayGroup] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return model.archivedGroups }
        return model.archivedGroups.compactMap { group in
            let tasks = group.tasks.filter {
                $0.title.localizedCaseInsensitiveContains(trimmed)
                    || $0.notes.localizedCaseInsensitiveContains(trimmed)
            }
            return tasks.isEmpty ? nil : ArchivedDayGroup(day: group.day, tasks: tasks)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if groups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(groups) { group in
                            daySection(group)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 420)
        .alert(
            pendingImport.map { "有 \($0.conflicts) 件任务与现有归档重复" } ?? "导入备份",
            isPresented: Binding(
                get: { pendingImport != nil },
                set: { if !$0 { pendingImport = nil } }
            )
        ) {
            Button("覆盖已有任务") { resolveImport(.overwrite) }
            Button("跳过重复") { resolveImport(.skip) }
            Button("取消", role: .cancel) { pendingImport = nil }
        } message: {
            Text("覆盖会用备份内容替换现有任务；跳过则只导入备份中不存在的任务。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "archivebox")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("任务归档")
                        .font(.system(size: 13, weight: .semibold))
                    Text(model.archivedCount == 0 ? "还没有归档的任务" : "共 \(model.archivedCount) 件 · 按归档日期分组")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    importBackup()
                } label: {
                    Label("导入备份…", systemImage: "square.and.arrow.down")
                        .font(.system(size: 11.5))
                }
                .help("从 JSON 备份恢复归档任务")
                Button {
                    exportBackup()
                } label: {
                    Label("导出备份…", systemImage: "square.and.arrow.up")
                        .font(.system(size: 11.5))
                }
                .disabled(model.archivedCount == 0)
                .help("把全部归档导出为 JSON 备份文件")
            }

            TextField("搜索归档", text: $query)
                .textFieldStyle(.roundedBorder)

            if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func exportBackup() {
        let tasks = model.archivedGroups.flatMap(\.tasks)
        guard !tasks.isEmpty else { return }

        let panel = NSSavePanel()
        panel.title = "导出归档备份"
        panel.message = "将以 JSON 保存 \(tasks.count) 件归档任务"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = ArchiveBackup.defaultFilename()
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try ArchiveBackup.encode(ArchiveBackup.make(from: tasks))
            try data.write(to: url, options: .atomic)
            statusMessage = "已导出 \(tasks.count) 件到 \(url.lastPathComponent)"
        } catch {
            statusMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.title = "导入归档备份"
        panel.message = "选择由 TaskBoard 导出的 JSON 备份，任务会恢复到归档中"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let backup = try ArchiveBackup.decodeForImport(Data(contentsOf: url))
            let conflicts = model.importConflictCount(in: backup)
            if conflicts > 0 {
                pendingImport = PendingImport(backup: backup, conflicts: conflicts)
            } else {
                performImport(backup, policy: .skip)
            }
        } catch {
            statusMessage = "导入失败：\(error.localizedDescription)"
        }
    }

    private func resolveImport(_ policy: ArchiveImportPolicy) {
        guard let pending = pendingImport else { return }
        pendingImport = nil
        performImport(pending.backup, policy: policy)
    }

    private func performImport(_ backup: ArchiveBackup, policy: ArchiveImportPolicy) {
        let result = model.importArchiveBackup(backup, policy: policy)
        if result.added == 0 && result.overwritten == 0 && result.skipped == 0 {
            statusMessage = "备份里没有任务"
            return
        }
        var parts: [String] = []
        if result.added > 0 { parts.append("新增 \(result.added) 件") }
        if result.overwritten > 0 { parts.append("覆盖 \(result.overwritten) 件") }
        if result.skipped > 0 { parts.append("跳过 \(result.skipped) 件") }
        statusMessage = "已恢复到归档：" + parts.joined(separator: "，")
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: query.isEmpty ? "archivebox" : "magnifyingglass")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text(query.isEmpty ? "归档里还没有任务" : "没有匹配的任务")
                .font(.system(size: 12.5, weight: .medium))
            Text(query.isEmpty ? "任务完成后按设置的延迟自动收进这里" : "换个关键词试试")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func daySection(_ group: ArchivedDayGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(group.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(group.tasks.count) 件")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 5) {
                ForEach(group.tasks) { task in
                    row(task)
                }
            }
        }
    }

    private func row(_ task: TodoTask) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent.opacity(0.75))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .strikethrough(color: .secondary)
                    .lineLimit(2)

                Text(detail(for: task))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Button("还原") { model.unarchive(task) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.accent)
                .help("还原到今天")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .contextMenu {
            Button("还原到今天") { model.unarchive(task) }
            Button("复制标题") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(task.title, forType: .string)
            }
        }
    }

    private func detail(for task: TodoTask) -> String {
        var parts: [String] = []
        if let stageTitle = task.stageTitle {
            parts.append(stageTitle)
        }
        if let completedAt = task.completedAt {
            parts.append("完成于 " + completedAt.formatted(
                .dateTime.month().day().hour().minute()
                    .locale(Locale(identifier: "zh_CN"))
            ))
        }
        if let archivedAt = task.archivedAt {
            parts.append("归档于 " + archivedAt.formatted(
                .dateTime.hour().minute()
                    .locale(Locale(identifier: "zh_CN"))
            ))
        }
        return parts.isEmpty ? "已完成" : parts.joined(separator: " · ")
    }
}
