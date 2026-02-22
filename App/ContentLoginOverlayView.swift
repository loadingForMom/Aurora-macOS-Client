//
//  ContentLoginOverlayView.swift
//  Aurora
//

import SwiftUI

struct ContentLoginOverlayView: View {
    let store: TelegramStore

    var body: some View {
        TelegramLoginView(store: store)
    }
}

struct TelegramLoginView: View {
    @ObservedObject var store: TelegramStore

    @State private var phoneNumber: String = ""
    @State private var authCode: String = ""
    @State private var password: String = ""

    @FocusState private var focusedField: Field?

    private enum Field {
        case phone
        case code
        case password
    }

    private enum AuthStep {
        case phone
        case code
        case password
        case other(title: String, message: String)
        case pending(message: String)
    }

    private var authStep: AuthStep {
        switch store.authState {
        case "authorizationStateWaitPhoneNumber":
            return .phone
        case "authorizationStateWaitCode":
            return .code
        case "authorizationStateWaitPassword":
            return .password
        case "authorizationStateWaitOtherDeviceConfirmation":
            return .other(
                title: "Подтверждение входа",
                message: "Подтвердите вход на другом устройстве в Telegram."
            )
        case "authorizationStateWaitTdlibParameters":
            return .pending(message: "Подготавливаем вход в Telegram…")
        case "authorizationStateLoggingOut":
            return .pending(message: "Выходим из аккаунта…")
        default:
            return .pending(message: "Подключаемся к Telegram…")
        }
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    Text("Telegram")
                        .font(.system(size: 24, weight: .semibold))
                    Text("Вход в аккаунт")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                loginContent
            }
            .padding(32)
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .padding(24)
        }
    }

    @ViewBuilder
    private var loginContent: some View {
        switch authStep {
        case .phone:
            VStack(alignment: .leading, spacing: 12) {
                Text("Введите номер телефона в международном формате.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                TextField("+7 999 123-45-67", text: $phoneNumber)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .phone)
                    .onSubmit {
                        submitPhoneIfPossible()
                    }

                Button("Отправить код") {
                    submitPhoneIfPossible()
                }
                .buttonStyle(.borderedProminent)
                .disabled(phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        case .code:
            VStack(alignment: .leading, spacing: 12) {
                Text("Введите код подтверждения из Telegram.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                TextField("Код подтверждения", text: $authCode)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .code)
                    .onSubmit {
                        submitCodeIfPossible()
                    }

                Button("Подтвердить код") {
                    submitCodeIfPossible()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmitCode)
            }
        case .password:
            VStack(alignment: .leading, spacing: 12) {
                Text("Введите пароль двухэтапной аутентификации.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                SecureField("Пароль", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .password)
                    .onSubmit {
                        submitPasswordIfPossible()
                    }

                Button("Войти") {
                    submitPasswordIfPossible()
                }
                .buttonStyle(.borderedProminent)
                .disabled(password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        case let .other(title, message):
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        case let .pending(message):
            VStack(spacing: 10) {
                ProgressView()
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func submitPhoneIfPossible() {
        let trimmed = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.submitPhoneNumber(trimmed)
    }

    private func submitCodeIfPossible() {
        guard let code = sanitizedAuthCode() else { return }
        store.submitAuthCode(code)
    }

    private func submitPasswordIfPossible() {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.submitAuthPassword(trimmed)
    }

    private var canSubmitCode: Bool {
        sanitizedAuthCode() != nil
    }

    private func sanitizedAuthCode() -> String? {
        let trimmed = authCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let compact = trimmed.filter { !$0.isWhitespace }
        guard compact.allSatisfy({ $0.isNumber }) else { return nil }
        guard (3...8).contains(compact.count) else { return nil }
        return compact
    }
}
