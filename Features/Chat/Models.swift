//
//  Models.swift
//  Aurora
//

import Foundation

enum ChatRole: String, Codable, Sendable {
    case user
    case assistant
}

struct ChatMsg: Codable, Sendable {
    let role: ChatRole
    let text: String
    let date: String?

    init(role: ChatRole, text: String, date: String? = nil) {
        self.role = role
        self.text = text
        self.date = date
    }
}

struct AISuggestion: Codable, Sendable {
    let text: String
}

struct AISuggestionsResponse: Codable, Sendable {
    let suggestions: [AISuggestion]
}

struct OpenAIChatCompletionRequest: Codable, Sendable {
    let model: String
    let temperature: Double
    let messages: [OpenAIChatCompletionMessage]
}

struct OpenAIChatCompletionMessage: Codable, Sendable {
    let role: String
    let content: String
}

struct OpenAIChatCompletionResponse: Codable, Sendable {
    let choices: [Choice]

    struct Choice: Codable, Sendable {
        let message: Message
    }

    struct Message: Codable, Sendable {
        let content: OpenAIMessageContent?
    }
}

enum OpenAIMessageContent: Codable, Sendable {
    case string(String)
    case parts([Part])

    struct Part: Codable, Sendable {
        let type: String?
        let text: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let rawText = try? container.decode(String.self) {
            self = .string(rawText)
            return
        }
        let parts = try container.decode([Part].self)
        self = .parts(parts)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .parts(let parts):
            try container.encode(parts)
        }
    }

    var textValue: String {
        switch self {
        case .string(let value):
            return value
        case .parts(let parts):
            return parts
                .compactMap(\.text)
                .joined(separator: "\n")
        }
    }
}

struct OpenAIErrorEnvelope: Codable, Sendable {
    let error: OpenAIErrorPayload?
}

struct OpenAIErrorPayload: Codable, Sendable {
    let message: String?
}
