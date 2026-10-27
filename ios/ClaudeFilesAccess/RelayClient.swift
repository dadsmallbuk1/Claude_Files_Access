import FilesCore
import Foundation

/// Keeps a WebSocket open to the relay and answers tool calls arriving on it.
@MainActor
final class RelayClient {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    /// Largest result we send. Cloudflare accepts up to 32 MiB, but results this big would
    /// swamp Claude's context, so tools are asked to page instead.
    static let maxMessageBytes = 950_000

    var onStateChange: ((State) -> Void)?
    var handleCall: ((_ tool: String, _ arguments: [String: JSONValue]) async -> ToolResult)?

    private(set) var state: State = .disconnected {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    private let session = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    private var url: URL?
    private var shouldRun = false
    private var generation = 0
    private var retryDelay: TimeInterval = 1
    private var pingTimer: Timer?
    private var lastPong = Date()

    func start(url: URL) {
        if shouldRun, self.url == url, state == .connected || state == .connecting { return }
        self.url = url
        shouldRun = true
        retryDelay = 1
        open()
    }

    func stop() {
        shouldRun = false
        generation += 1
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .disconnected
    }

    private func open() {
        guard shouldRun, let url else { return }
        generation += 1
        let current = generation
        task?.cancel(with: .goingAway, reason: nil)

        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 16 * 1024 * 1024
        self.task = task
        state = .connecting
        task.resume()
        receive(task, generation: current)

        // The relay answers "ping" with "pong"; the first pong confirms the connection.
        lastPong = Date()
        send("ping", on: task, generation: current)
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.keepAlive(generation: current) }
        }
    }

    private func keepAlive(generation current: Int) {
        guard current == generation, let task else { return }
        if Date().timeIntervalSince(lastPong) > 65 {
            reconnect(after: "No response from the relay.", generation: current)
            return
        }
        send("ping", on: task, generation: current)
    }

    private func receive(_ task: URLSessionWebSocketTask, generation current: Int) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, current == self.generation else { return }
                switch result {
                case .failure(let error):
                    self.reconnect(after: Self.describe(error), generation: current)
                case .success(let message):
                    self.handle(message, task: task, generation: current)
                    self.receive(task, generation: current)
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message, task: URLSessionWebSocketTask, generation current: Int) {
        let text: String
        switch message {
        case .string(let string): text = string
        case .data(let data): text = String(decoding: data, as: UTF8.self)
        @unknown default: return
        }

        if text == "pong" {
            lastPong = Date()
            retryDelay = 1
            state = .connected
            return
        }

        guard let data = text.data(using: .utf8),
            let message = try? JSONDecoder().decode(JSONValue.self, from: data),
            message["type"]?.stringValue == "call",
            let id = message["id"]?.stringValue,
            let tool = message["tool"]?.stringValue
        else { return }
        let arguments = message["arguments"]?.objectValue ?? [:]

        Task {
            let result = await self.handleCall?(tool, arguments) ?? .error("The app is not ready.")
            self.sendResult(id: id, result: result, on: task, generation: current)
        }
    }

    private func sendResult(id: String, result: ToolResult, on task: URLSessionWebSocketTask, generation current: Int) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        func encode(_ result: ToolResult) -> String? {
            let envelope: JSONValue = ["type": "result", "id": .string(id), "result": result.jsonValue]
            return (try? encoder.encode(envelope)).map { String(decoding: $0, as: UTF8.self) }
        }
        guard var payload = encode(result) else { return }
        if payload.utf8.count > Self.maxMessageBytes {
            let size = String(format: "%.1f", Double(payload.utf8.count) / 1_048_576)
            payload =
                encode(
                    .error(
                        "The result was too large to send (\(size) MB). Ask for less at once, e.g. a smaller length, fewer lines or max_entries, or a subfolder."
                    )) ?? payload
        }
        send(payload, on: task, generation: current)
    }

    private func send(_ text: String, on task: URLSessionWebSocketTask, generation current: Int) {
        task.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.reconnect(after: Self.describe(error), generation: current) }
        }
    }

    private func reconnect(after reason: String, generation current: Int) {
        guard current == generation, shouldRun else { return }
        generation += 1
        pingTimer?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .failed(reason)
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        let next = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.shouldRun, next == self.generation else { return }
            self.open()
        }
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorBadServerResponse {
            return "The relay rejected the connection. Check the relay URL."
        }
        return error.localizedDescription
    }
}
