import Foundation

/// Runs long operations (downloads, extractions) in the background so a tool call can
/// return a job id instead of timing out.
final class JobManager: @unchecked Sendable {
    private final class Job {
        let id: String
        let kind: String
        let description: String
        let started = Date()
        var result: ToolResult?

        init(id: String, kind: String, description: String) {
            self.id = id
            self.kind = kind
            self.description = description
        }
    }

    private var jobs: [String: Job] = [:]
    private let lock = NSLock()

    func start(kind: String, description: String, work: @escaping @Sendable () async -> ToolResult) -> String {
        let id = "job-" + UUID().uuidString.prefix(8).lowercased()
        let job = Job(id: id, kind: kind, description: description)
        lock.lock()
        jobs[id] = job
        lock.unlock()
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = await work()
            guard let self else { return }
            self.lock.withLock { job.result = result }
        }
        return id
    }

    /// Waits up to `timeout` seconds for the job, then reports its status.
    func wait(_ id: String, timeout: TimeInterval) async -> ToolResult {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let result = finishedResult(id) { return result }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return status(id)
    }

    private func finishedResult(_ id: String) -> ToolResult? {
        lock.withLock { jobs[id]?.result }
    }

    func status(_ id: String) -> ToolResult {
        lock.lock()
        defer { lock.unlock() }
        guard let job = jobs[id] else {
            return .error("No job with id '\(id)'. Jobs are forgotten when the app restarts.")
        }
        if let result = job.result { return result }
        return .json([
            "job_id": .string(job.id),
            "status": "running",
            "kind": .string(job.kind),
            "description": .string(job.description),
            "elapsed_seconds": JSONValue(Int(Date().timeIntervalSince(job.started))),
            "hint": "Still running. Call job_status with this job_id again in a little while.",
        ])
    }
}
