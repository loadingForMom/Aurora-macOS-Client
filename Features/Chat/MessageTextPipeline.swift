//
//  MessageTextPipeline.swift
//  Aurora
//

import SwiftUI
import Foundation
import OSLog

nonisolated enum MessageTextStyle: Hashable {
    case bubbleBody
}

nonisolated struct MessageTextRenderInput: Hashable, Sendable {
    let chatId: Int64
    let messageId: Int64
    let rawText: String?
    let entities: [TGTextEntity]?
    let style: MessageTextStyle
}

nonisolated struct MessageTextCacheKey: Hashable {
    let chatId: Int64
    let messageId: Int64
    let style: MessageTextStyle
}

nonisolated final class MessageTextCache {
    static let shared = MessageTextCache()

    private struct CachedEntry {
        let rawText: String?
        let entities: [TGTextEntity]?
        let attributed: AttributedString
    }

    private let limit = 512
    private var entries: [MessageTextCacheKey: CachedEntry] = [:]
    private var previousByKey: [MessageTextCacheKey: MessageTextCacheKey] = [:]
    private var nextByKey: [MessageTextCacheKey: MessageTextCacheKey] = [:]
    private var oldestKey: MessageTextCacheKey?
    private var newestKey: MessageTextCacheKey?
    private let lock = NSLock()

    func value(for key: MessageTextCacheKey, rawText: String?, entities: [TGTextEntity]?) -> AttributedString? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        guard entry.rawText == rawText, entry.entities == entities else { return nil }
        touch(key)
        return entry.attributed
    }

    func set(_ value: AttributedString, for key: MessageTextCacheKey, rawText: String?, entities: [TGTextEntity]?) {
        lock.lock()
        defer { lock.unlock() }
        entries[key] = CachedEntry(rawText: rawText, entities: entities, attributed: value)
        touch(key)
        trimIfNeeded()
    }

    private func touch(_ key: MessageTextCacheKey) {
        if newestKey == key { return }
        detach(key)
        appendNewest(key)
    }

    private func trimIfNeeded() {
        while entries.count > limit {
            guard let oldest = oldestKey else { return }
            remove(oldest)
        }
    }

    private func appendNewest(_ key: MessageTextCacheKey) {
        if let newest = newestKey {
            nextByKey[newest] = key
            previousByKey[key] = newest
        } else {
            oldestKey = key
        }
        newestKey = key
    }

    private func detach(_ key: MessageTextCacheKey) {
        let previous = previousByKey[key]
        let next = nextByKey[key]

        if let previous {
            nextByKey[previous] = next
        } else if oldestKey == key {
            oldestKey = next
        }

        if let next {
            previousByKey[next] = previous
        } else if newestKey == key {
            newestKey = previous
        }

        previousByKey.removeValue(forKey: key)
        nextByKey.removeValue(forKey: key)
    }

    private func remove(_ key: MessageTextCacheKey) {
        detach(key)
        entries.removeValue(forKey: key)
    }
}

nonisolated enum MessageTextPipeline {
    private static let log = Logger(subsystem: "com.aurora.app", category: "message.text")
    private static let prewarmer = MessageTextPrewarmActor()
    private static let prewarmMaxConcurrency = 3
    // Supported now vs later:
    // | Supported now | Later |
    // | --- | --- |
    // | bold, italic, underline, strikethrough, code, pre, preCode, textUrl | spoiler, custom emoji, block quotes, mentions, hashtags |

    static func cachedValue(_ input: MessageTextRenderInput) -> AttributedString? {
        let cacheKey = MessageTextCacheKey(
            chatId: input.chatId,
            messageId: input.messageId,
            style: input.style
        )
        return MessageTextCache.shared.value(
            for: cacheKey,
            rawText: input.rawText,
            entities: input.entities
        )
    }

    static func renderAsync(
        _ input: MessageTextRenderInput,
        priority: TaskPriority = .userInitiated
    ) async -> AttributedString {
        await Task.detached(priority: priority) {
            render(
                chatId: input.chatId,
                messageId: input.messageId,
                rawText: input.rawText,
                entities: input.entities,
                style: input.style
            )
        }.value
    }

    static func enqueuePrewarm(
        chatId: Int64,
        messages: [TGMessage],
        style: MessageTextStyle = .bubbleBody
    ) {
        let inputs = messages.compactMap { message -> MessageTextRenderInput? in
            guard message.chatId == chatId else { return nil }
            return MessageTextRenderInput(
                chatId: chatId,
                messageId: message.id,
                rawText: message.textForRendering,
                entities: message.entities,
                style: style
            )
        }
        Task(priority: .utility) {
            await prewarmer.submit(inputs: inputs, maxConcurrency: prewarmMaxConcurrency)
        }
    }

    static func cancelPrewarm() {
        Task(priority: .utility) {
            await prewarmer.cancel()
        }
    }

    static func render(
        chatId: Int64,
        messageId: Int64,
        rawText: String?,
        entities: [TGTextEntity]?,
        style: MessageTextStyle
    ) -> AttributedString {
        var cacheHit = false
        let traceEnabled = ChatPerfTrace.isEnabled(for: chatId)
        let textRenderStartNs = traceEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        let signpostId = ChatPerfTrace.beginSignpost("MessageTextPipeline.render", chatId: chatId)
        defer {
            if traceEnabled {
                let textRenderDurationMs = ChatPerfTrace.elapsedMs(since: textRenderStartNs)
                ChatPerfTrace.recordTextRender(
                    chatId: chatId,
                    durationMs: textRenderDurationMs,
                    cacheHit: cacheHit
                )
            }
            ChatPerfTrace.endSignpost("MessageTextPipeline.render", signpostId: signpostId, chatId: chatId)
        }

        let cacheKey = MessageTextCacheKey(
            chatId: chatId,
            messageId: messageId,
            style: style
        )
        if let cached = MessageTextCache.shared.value(for: cacheKey, rawText: rawText, entities: entities) {
            cacheHit = true
            return cached
        }

        let text: String
        if let rawText {
            if rawText.isEmpty {
#if DEBUG
                log.debug("no text content chatId=\(chatId, privacy: .public) messageId=\(messageId, privacy: .public)")
#endif
                text = "[unsupported message]"
            } else {
                text = rawText
            }
        } else {
#if DEBUG
            log.debug("unsupported content type chatId=\(chatId, privacy: .public) messageId=\(messageId, privacy: .public)")
#endif
            text = "[unsupported message]"
        }

        var attributed = AttributedString(text)

        if let rawText, !rawText.isEmpty, let entities, !entities.isEmpty {
            applyEntities(
                entities,
                to: &attributed,
                rawText: rawText,
                chatId: chatId,
                messageId: messageId
            )
        }

        MessageTextCache.shared.set(attributed, for: cacheKey, rawText: rawText, entities: entities)
        return attributed
    }

    private static func applyEntities(
        _ entities: [TGTextEntity],
        to attributed: inout AttributedString,
        rawText: String,
        chatId: Int64,
        messageId: Int64
    ) {
        let sorted = entities.sorted { $0.offset < $1.offset }

        for entity in sorted {
            guard let stringRange = utf16Range(in: rawText, offset: entity.offset, length: entity.length) else {
#if DEBUG
                log.debug("invalid entity range chatId=\(chatId, privacy: .public) messageId=\(messageId, privacy: .public) offset=\(entity.offset, privacy: .public) length=\(entity.length, privacy: .public)")
#endif
                continue
            }
            guard let attrRange = Range<AttributedString.Index>(stringRange, in: attributed) else {
#if DEBUG
                log.debug("entity apply error chatId=\(chatId, privacy: .public) messageId=\(messageId, privacy: .public)")
#endif
                continue
            }

            switch entity.type {
            case .bold:
                attributed[attrRange].inlinePresentationIntent = .stronglyEmphasized
            case .italic:
                attributed[attrRange].inlinePresentationIntent = .emphasized
            case .underline:
                attributed[attrRange].underlineStyle = .single
            case .strikethrough:
                attributed[attrRange].strikethroughStyle = .single
            case .code, .pre, .preCode:
                attributed[attrRange].font = .system(.body, design: .monospaced)
            case .textUrl(let urlString):
                guard let url = URL(string: urlString), !urlString.isEmpty else {
#if DEBUG
                    log.debug("invalid URL entity chatId=\(chatId, privacy: .public) messageId=\(messageId, privacy: .public)")
#endif
                    continue
                }
                attributed[attrRange].link = url
            case .unknown(_):
                break
            }
        }
    }

    static func utf16Range(in text: String, offset: Int, length: Int) -> Range<String.Index>? {
        guard offset >= 0, length >= 0 else { return nil }
        let utf16Count = text.utf16.count
        let end = offset + length
        guard offset <= utf16Count, end <= utf16Count else { return nil }
        let startIndex = String.Index(utf16Offset: offset, in: text)
        let endIndex = String.Index(utf16Offset: end, in: text)
        return startIndex..<endIndex
    }
}

private actor MessageTextPrewarmActor {
    private var lastSubmittedInputs: [MessageTextRenderInput] = []
    private var runningTask: Task<Void, Never>? = nil

    func submit(inputs: [MessageTextRenderInput], maxConcurrency: Int) {
        guard inputs != lastSubmittedInputs else { return }
        lastSubmittedInputs = inputs

        runningTask?.cancel()
        guard !inputs.isEmpty else {
            runningTask = nil
            return
        }

        let batch = inputs
        let workerCount = max(1, min(4, maxConcurrency))
        runningTask = Task(priority: .utility) {
            await Self.prewarm(batch, maxConcurrency: workerCount)
        }
    }

    func cancel() {
        lastSubmittedInputs = []
        runningTask?.cancel()
        runningTask = nil
    }

    nonisolated private static func prewarm(
        _ inputs: [MessageTextRenderInput],
        maxConcurrency: Int
    ) async {
        guard !inputs.isEmpty else { return }
        let workerCount = max(1, min(maxConcurrency, inputs.count))
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<workerCount {
                group.addTask {
                    var index = worker
                    while index < inputs.count {
                        if Task.isCancelled { return }
                        let input = inputs[index]
                        _ = MessageTextPipeline.render(
                            chatId: input.chatId,
                            messageId: input.messageId,
                            rawText: input.rawText,
                            entities: input.entities,
                            style: input.style
                        )
                        index += workerCount
                        if index.isMultiple(of: 8) {
                            await Task.yield()
                        }
                    }
                }
            }
            await group.waitForAll()
        }
    }
}
