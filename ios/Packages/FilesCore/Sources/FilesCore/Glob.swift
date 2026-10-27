import Foundation

/// Case-insensitive shell-style glob for file names: `*`, `?` and `[abc]`.
public struct Glob: Sendable {
    private let regex: NSRegularExpression

    public init(_ pattern: String) throws {
        var expression = "^"
        var inBracket = false
        for char in pattern {
            if inBracket {
                if char == "]" { inBracket = false }
                if char == "!" && expression.hasSuffix("[") {
                    expression += "^"
                } else {
                    expression += char == "\\" ? "\\\\" : String(char)
                }
                continue
            }
            switch char {
            case "*": expression += ".*"
            case "?": expression += "."
            case "[":
                inBracket = true
                expression += "["
            default: expression += NSRegularExpression.escapedPattern(for: String(char))
            }
        }
        if inBracket { throw ToolError("Invalid name pattern '\(pattern)': unclosed '['.") }
        expression += "$"
        do {
            regex = try NSRegularExpression(pattern: expression, options: [.caseInsensitive])
        } catch {
            throw ToolError("Invalid name pattern '\(pattern)'.")
        }
    }

    public func matches(_ name: String) -> Bool {
        regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }
}
