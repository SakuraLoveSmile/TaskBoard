import Foundation
import Observation

enum PomodoroPhase: String, Codable, Sendable {
    case work
    case shortBreak
    case longBreak

    var title: String {
        switch self {
        case .work: "专注"
        case .shortBreak: "短休息"
        case .longBreak: "长休息"
        }
    }
}

enum PomodoroRunState: String, Codable, Sendable {
    case idle
    case running
    case paused
}

@MainActor
@Observable
final class PomodoroEngine {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var endDate: Date?

    private(set) var phase: PomodoroPhase = .work
    private(set) var state: PomodoroRunState = .idle
    private(set) var remainingSeconds: TimeInterval = 0
    private(set) var plannedSeconds: TimeInterval = 0
    private(set) var taskID: UUID?
    private(set) var completedWorkCount: Int = 0

    @ObservationIgnored var now: () -> Date = { Date() }
    @ObservationIgnored var debugPhaseSeconds: TimeInterval?
    @ObservationIgnored var onPhaseFinished: ((PomodoroPhase, UUID?, TimeInterval) -> Void)?
    @ObservationIgnored var onTick: (() -> Void)?

    init(settings: SettingsStore, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.defaults = defaults
        restore()
    }

    var progress: Double {
        guard plannedSeconds > 0 else { return 0 }
        return max(0, min(1, 1 - remainingSeconds / plannedSeconds))
    }

    var isActive: Bool { state != .idle }

    var timeText: String {
        let total = max(0, Int(remainingSeconds.rounded(.up)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    func start(taskID: UUID?, minutes: Int? = nil) {
        self.taskID = taskID
        let workSeconds = TimeInterval((minutes ?? settings.workMinutes) * 60)
        begin(phase: .work, seconds: debugPhaseSeconds ?? workSeconds)
    }

    func pause() {
        guard state == .running else { return }
        refreshRemaining()
        state = .paused
        endDate = nil
        stopTimer()
        persist()
        onTick?()
    }

    func resume() {
        guard state == .paused else { return }
        endDate = now().addingTimeInterval(remainingSeconds)
        state = .running
        startTimer()
        persist()
        onTick?()
    }

    func stop() {
        stopTimer()
        state = .idle
        phase = .work
        taskID = nil
        remainingSeconds = 0
        plannedSeconds = 0
        endDate = nil
        persist()
        onTick?()
    }

    func skip() {
        stop()
    }

    private func begin(phase: PomodoroPhase, seconds: TimeInterval) {
        self.phase = phase
        if phase != .work {
            taskID = nil
        }
        plannedSeconds = seconds
        remainingSeconds = seconds
        endDate = now().addingTimeInterval(seconds)
        state = .running
        startTimer()
        persist()
        onTick?()
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func tick() {
        guard state == .running else { return }
        guard let endDate else { return }
        let remaining = endDate.timeIntervalSince(now())
        if remaining <= 0 {
            remainingSeconds = 0
            finishPhase()
        } else {
            remainingSeconds = remaining
            persist()
            onTick?()
        }
    }

    private func refreshRemaining() {
        guard let endDate else { return }
        remainingSeconds = max(0, endDate.timeIntervalSince(now()))
    }

    private func finishPhase() {
        stopTimer()
        let finished = phase
        let finishedTask = taskID
        let finishedPlanned = plannedSeconds
        if finished == .work {
            completedWorkCount += 1
        }
        state = .idle
        endDate = nil
        onPhaseFinished?(finished, finishedTask, finishedPlanned)

        if finished == .work && settings.autoStartBreak {
            let interval = max(settings.longBreakInterval, 1)
            let next: PomodoroPhase = completedWorkCount % interval == 0 ? .longBreak : .shortBreak
            let minutes = next == .longBreak ? settings.longBreakMinutes : settings.shortBreakMinutes
            begin(phase: next, seconds: debugPhaseSeconds ?? TimeInterval(minutes * 60))
        } else {
            phase = .work
            taskID = nil
            remainingSeconds = 0
            plannedSeconds = 0
            persist()
            onTick?()
        }
    }

    private func persist() {
        let payload: [String: Any] = [
            "phase": phase.rawValue,
            "state": state.rawValue,
            "remaining": remainingSeconds,
            "planned": plannedSeconds,
            "endDate": endDate?.timeIntervalSince1970 ?? 0,
            "taskID": taskID?.uuidString ?? "",
            "completedWorkCount": completedWorkCount
        ]
        defaults.set(payload, forKey: "pomo.snapshot")
    }

    private func restore() {
        guard let payload = defaults.dictionary(forKey: "pomo.snapshot") else { return }
        completedWorkCount = payload["completedWorkCount"] as? Int ?? 0
        guard let rawState = payload["state"] as? String,
              let restoredState = PomodoroRunState(rawValue: rawState),
              restoredState != .idle,
              let rawPhase = payload["phase"] as? String,
              let restoredPhase = PomodoroPhase(rawValue: rawPhase)
        else { return }

        let planned = payload["planned"] as? Double ?? 0
        let endStamp = payload["endDate"] as? Double ?? 0
        let taskString = payload["taskID"] as? String ?? ""

        guard planned > 0 else { return }

        if restoredState == .running {
            let end = Date(timeIntervalSince1970: endStamp)
            if end <= now() {
                // 已过期：静默收尾，不补发通知
                return
            }
            phase = restoredPhase
            plannedSeconds = planned
            taskID = UUID(uuidString: taskString)
            endDate = end
            remainingSeconds = end.timeIntervalSince(now())
            state = .running
            startTimer()
        } else if restoredState == .paused {
            let remaining = payload["remaining"] as? Double ?? 0
            guard remaining > 0 else { return }
            phase = restoredPhase
            plannedSeconds = planned
            remainingSeconds = remaining
            taskID = UUID(uuidString: taskString)
            state = .paused
        }
    }
}
