// The engine's answers for the AI Assistant tab: ./revit mcp servers, tokens and log.
import Foundation

public struct McpServerInfo: Decodable, Equatable, Sendable {
    public let id, name, state, missing, note: String
    public let tiers: [String]
    public let claudeName, engine: String
    public let args: [String]
    public var ready: Bool { state == "ready" }
}

public struct McpServers: Decodable, Equatable, Sendable { public let servers: [McpServerInfo] }

public struct McpToken: Decodable, Equatable, Sendable {
    public let name, bottle, server, tier: String
    public let created: String?
}

public struct McpTokens: Decodable, Equatable, Sendable { public let tokens: [McpToken] }

/// outcome: refused, answered, error, no_answer. "answered" is all the log knows: not that Revit did it.
public struct McpCall: Decodable, Equatable, Sendable {
    public let ts: String?
    public let tool: String?
    public let outcome: String
    public let ms: Int?
    public let token, client: String?
}

public struct McpCalls: Decodable, Equatable, Sendable { public let calls: [McpCall] }

public enum McpClient: String, CaseIterable, Sendable {
    case claudeCode = "claude-code", claudeDesktop = "claude-desktop"
    public func tokenName(bottle: String, server: String) -> String { "\(rawValue)-\(bottle)-\(server)" }
}

/// What the sheet shows once. It lives in the sheet and goes with it.
public struct McpIssued: Equatable, Sendable {
    public let token, name: String
    public let client: McpClient
    public let addCommand, removeCommand: String
    public let bundle: String?
}

public enum McpTier {
    public static func text(_ tier: String, server: String) -> String {
        switch (tier, server) {
        case ("read", _): String(localized: "Read the model, show and select elements, take pictures of views.")
        case ("write", "ui"): String(localized: "The whole interface: it can press any button of any dialog, so it can confirm what you would confirm.")
        case ("write", _): String(localized: "Also change the model with the server's ready-made tools.")
        default: String(localized: "Everything the server offers, running code included. Python runs with your rights and can reach your files.")
        }
    }
}

extension String {
    /// As shlex.quote: a command the person pastes into a shell.
    var shellQuoted: String {
        if !isEmpty, allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_@%+=:,./-".contains($0)) }) { return self }
        return "'" + replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
