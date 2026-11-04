import Foundation
import Observation
import TeslaCamKit
#if os(iOS)
import UIKit
#endif

/// 一次导出任务（单个选区或批量风险片段），关闭导出界面后继续运行。
@MainActor @Observable
final class ExportJob: Identifiable {
    enum Phase {
        case exporting(Double)
        case done([ExportResult])
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let eventID: DashcamEvent.ID
    let title: String
    let createdAt = Date()
    var phase: Phase = .exporting(0)
    @ObservationIgnored fileprivate var task: Task<Void, Never>?

    init(eventID: DashcamEvent.ID, title: String) {
        self.eventID = eventID
        self.title = title
    }

    var isRunning: Bool {
        if case .exporting = phase { return true }
        return false
    }

    var progress: Double {
        if case .exporting(let fraction) = phase { return fraction }
        return 1
    }

    func cancel() { task?.cancel() }
}

/// 管理全部导出任务，生命周期与 App 相同。
@MainActor @Observable
final class ExportCenter {
    private(set) var jobs: [ExportJob] = []

    /// 某个事件的任务，最新的在前
    func jobs(for eventID: DashcamEvent.ID) -> [ExportJob] {
        jobs.filter { $0.eventID == eventID }.reversed()
    }

    func runningJobs(for eventID: DashcamEvent.ID) -> [ExportJob] {
        jobs(for: eventID).filter(\.isRunning)
    }

    /// 启动导出。取消或失败时删除 partialOutput（未完成的单个视频文件）。
    @discardableResult
    func start(eventID: DashcamEvent.ID, title: String, partialOutput: URL? = nil,
               work: @escaping @Sendable (_ progress: @escaping @Sendable (Double) -> Void) async throws -> [ExportResult]) -> ExportJob {
        let job = ExportJob(eventID: eventID, title: title)
        jobs.append(job)
        #if os(iOS)
        // 切到后台时向系统申请额外运行时间，尽量让导出跑完
        let background = BackgroundActivity(name: "TesCam 导出")
        #endif
        job.task = Task { [weak job] in
            #if os(iOS)
            defer { background.end() }
            #endif
            do {
                let results = try await work { fraction in
                    Task { @MainActor in
                        if job?.isRunning == true { job?.phase = .exporting(fraction) }
                    }
                }
                job?.phase = .done(results)
            } catch {
                if let partialOutput { try? FileManager.default.removeItem(at: partialOutput) }
                job?.phase = Task.isCancelled || error is CancellationError ? .cancelled : .failed(error.localizedDescription)
            }
        }
        return job
    }
}

#if os(iOS)
@MainActor
private final class BackgroundActivity {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#endif
