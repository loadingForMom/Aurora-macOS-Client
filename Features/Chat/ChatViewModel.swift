//
//  ChatViewModel.swift
//  Aurora
//

import Foundation
import Combine

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var isLoading: Bool = false
    @Published var suggestions: [String] = []
    @Published var errorMessage: String?

    private let aiService: AIService

    init() {
        self.aiService = AIService()
    }

    init(aiService: AIService) {
        self.aiService = aiService
    }

    func onTapGenerate(last3: [ChatMsg]) {
        guard !isLoading else { return }
        guard !last3.isEmpty else {
            suggestions = []
            errorMessage = "Недостаточно данных: нет сообщений для генерации."
            return
        }

        errorMessage = nil
        suggestions = []
        isLoading = true

        Task {
            defer { isLoading = false }
            do {
                suggestions = try await aiService.generateSuggestions(last3: last3)
                errorMessage = nil
            } catch {
                suggestions = []
                if let localized = error as? LocalizedError,
                   let message = localized.errorDescription,
                   !message.isEmpty {
                    errorMessage = message
                } else {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func onTapSuggestion(_ suggestion: String, text: inout String) {
        text = suggestion
        suggestions = []
    }

    func clearState() {
        isLoading = false
        suggestions = []
        errorMessage = nil
    }
}
