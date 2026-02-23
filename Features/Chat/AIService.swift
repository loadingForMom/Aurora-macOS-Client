//
//  AIService.swift
//  Aurora
//

import Foundation

enum AIServiceError: LocalizedError {
    case invalidBaseURL
    case invalidHTTPResponse
    case serverError(message: String)
    case emptyChoices
    case emptyContent
    case invalidSuggestionsFormat
    case invalidSuggestionCount(Int)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Некорректный Base URL для LM Studio."
        case .invalidHTTPResponse:
            return "Некорректный ответ сервера LM Studio."
        case .serverError(let message):
            return message.isEmpty ? "LM Studio вернул ошибку." : message
        case .emptyChoices:
            return "LM Studio не вернул вариантов в choices."
        case .emptyContent:
            return "LM Studio вернул пустой content."
        case .invalidSuggestionsFormat:
            return "Не удалось распарсить JSON с вариантами ответа."
        case .invalidSuggestionCount:
            return "Модель вернула не 3 варианта ответа."
        }
    }
}

@MainActor
final class AIService {
    private let session: URLSession
    private let settingsStore: SettingsStore

    init(
        session: URLSession = .shared,
        settingsStore: SettingsStore? = nil
    ) {
        self.session = session
        self.settingsStore = settingsStore ?? .shared
    }

    func generateSuggestions(last3: [ChatMsg]) async throws -> [String] {
        let settings = await settingsStore.aiSnapshot()
        guard let url = completionURL(from: settings.baseURLString) else {
            throw AIServiceError.invalidBaseURL
        }

        let recentMessagesJSON = try encodeRecentMessagesJSON(last3)
        let modelName = settings.modelName.isEmpty ? "local-model" : settings.modelName

        let requestBody = OpenAIChatCompletionRequest(
            model: modelName,
            temperature: 0.7,
            messages: [
                OpenAIChatCompletionMessage(role: "system", content: systemPrompt),
                OpenAIChatCompletionMessage(
                    role: "user",
                    content: userPrompt(with: recentMessagesJSON)
                )
            ]
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !settings.apiKey.isEmpty {
            request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.invalidHTTPResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let decoder = JSONDecoder()
            if let envelope = try? decoder.decode(OpenAIErrorEnvelope.self, from: data),
               let message = envelope.error?.message,
               !message.isEmpty {
                throw AIServiceError.serverError(message: message)
            }

            let rawBody = String(data: data, encoding: .utf8) ?? ""
            throw AIServiceError.serverError(message: "HTTP \(httpResponse.statusCode): \(rawBody)")
        }

        let completion = try JSONDecoder().decode(OpenAIChatCompletionResponse.self, from: data)
        guard let firstChoice = completion.choices.first else {
            throw AIServiceError.emptyChoices
        }

        let modelContent = firstChoice.message.content?.textValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !modelContent.isEmpty else {
            throw AIServiceError.emptyContent
        }

        let parsed = try decodeSuggestions(from: modelContent)
        let suggestions = parsed.suggestions
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard suggestions.count == 3 else {
            throw AIServiceError.invalidSuggestionCount(suggestions.count)
        }

        return suggestions
    }

    private let systemPrompt = """
    Ты помогаешь пользователю Telegram сформулировать ответ.
    Верни строго JSON без markdown и лишнего текста в формате:
    {
      \"suggestions\": [
        {\"text\":\"вариант 1\"},
        {\"text\":\"вариант 2\"},
        {\"text\":\"вариант 3\"}
      ]
    }
    Требования:
    - Ровно 3 элемента в suggestions.
    - Только ключ text внутри каждого элемента.
    - Никаких комментариев, пояснений и обрамляющего текста.
    """

    private func userPrompt(with recentMessagesJSON: String) -> String {
        """
        Последние сообщения диалога (JSON):
        \(recentMessagesJSON)

        Задача: предложи ровно 3 уместных варианта ответа следующим сообщением от роли assistant.
        Ответ верни строго JSON по формату из system-инструкции.
        """
    }

    private func encodeRecentMessagesJSON(_ messages: [ChatMsg]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(messages)
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeSuggestions(from rawModelContent: String) throws -> AISuggestionsResponse {
        let decoder = JSONDecoder()

        if let directData = rawModelContent.data(using: .utf8),
           let directParsed = try? decoder.decode(AISuggestionsResponse.self, from: directData) {
            return directParsed
        }

        guard let start = rawModelContent.firstIndex(of: "{"),
              let end = rawModelContent.lastIndex(of: "}"),
              start <= end else {
            throw AIServiceError.invalidSuggestionsFormat
        }

        let jsonSlice = rawModelContent[start...end]
        guard let data = String(jsonSlice).data(using: .utf8) else {
            throw AIServiceError.invalidSuggestionsFormat
        }

        do {
            return try decoder.decode(AISuggestionsResponse.self, from: data)
        } catch {
            throw AIServiceError.invalidSuggestionsFormat
        }
    }

    private func completionURL(from baseURLString: String) -> URL? {
        guard let baseURL = URL(string: baseURLString),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        guard let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else {
            return nil
        }

        var pathSegments = components.path
            .split(separator: "/")
            .map(String.init)
        let lowercasedPath = pathSegments.map { $0.lowercased() }

        if Array(lowercasedPath.suffix(3)) == ["v1", "chat", "completions"] {
            return components.url
        }

        if pathSegments.last?.lowercased() != "v1" {
            pathSegments.append("v1")
        }

        pathSegments.append(contentsOf: ["chat", "completions"])
        components.path = "/" + pathSegments.joined(separator: "/")

        return components.url
    }

}
