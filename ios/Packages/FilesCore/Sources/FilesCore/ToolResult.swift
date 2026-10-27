import Foundation

/// An MCP `tools/call` result: a list of content blocks plus an error flag.
public struct ToolResult: Equatable, Sendable {
    public var content: [JSONValue]
    public var isError: Bool

    public init(content: [JSONValue], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func text(_ text: String) -> ToolResult {
        ToolResult(content: [["type": "text", "text": .string(text)]])
    }

    public static func json(_ value: JSONValue) -> ToolResult {
        .text(value.prettyString())
    }

    public static func error(_ message: String) -> ToolResult {
        ToolResult(content: [["type": "text", "text": .string(message)]], isError: true)
    }

    public static func image(_ data: Data, mimeType: String, caption: String) -> ToolResult {
        ToolResult(content: [
            ["type": "image", "data": .string(data.base64EncodedString()), "mimeType": .string(mimeType)],
            ["type": "text", "text": .string(caption)],
        ])
    }

    /// The first text block, for logging and tests.
    public var text: String {
        for block in content {
            if block["type"]?.stringValue == "text", let text = block["text"]?.stringValue { return text }
        }
        return ""
    }

    public var jsonValue: JSONValue {
        ["content": .array(content), "isError": .bool(isError)]
    }
}

/// An error whose message is shown to Claude as a tool error.
public struct ToolError: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Typed access to tool arguments.
public struct ToolArguments: Sendable {
    public let values: [String: JSONValue]

    public init(_ values: [String: JSONValue]) { self.values = values }

    public func string(_ key: String) -> String? {
        guard let value = values[key] else { return nil }
        switch value {
        case .string(let s): return s
        case .number(let n): return n.rounded() == n ? String(Int64(n)) : String(n)
        default: return nil
        }
    }

    public func requiredString(_ key: String) throws -> String {
        guard let value = string(key) else { throw ToolError("Missing required argument '\(key)'.") }
        return value
    }

    public func int(_ key: String, default defaultValue: Int, min: Int? = nil, max: Int? = nil) -> Int {
        var result = values[key]?.numberValue.map { Int($0) } ?? defaultValue
        if let min { result = Swift.max(result, min) }
        if let max { result = Swift.min(result, max) }
        return result
    }

    public func optionalInt(_ key: String) -> Int? {
        values[key]?.numberValue.map { Int($0) }
    }

    public func bool(_ key: String, default defaultValue: Bool = false) -> Bool {
        values[key]?.boolValue ?? defaultValue
    }
}
