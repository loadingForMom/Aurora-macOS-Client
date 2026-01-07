//
//  MessageTextPipeline.swift
//  Aurora
//

import SwiftUI
import Foundation

enum MessageTextStyle: Hashable {
    case bubbleBody
}

struct MessageTextCacheKey: Hashable {
    let chatId: Int64
    let messageId: Int64
    let style: MessageTextStyle
}

final class MessageTextCache {
    static let shared = MessageTextCache()

    private let limit = 512
    private var values: [MessageTextCacheKey: AttributedString] = [:]
    private var order: [MessageTextCacheKey] = []
    private let lock = NSLock()

    func value(for key: MessageTextCacheKey) -> AttributedString? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    func set(_ value: AttributedString, for key: MessageTextCacheKey) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
        touch(key)
        trimIfNeeded()
    }

    private func touch(_ key: MessageTextCacheKey) {
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
        }
        order.append(key)
    }

    private func trimIfNeeded() {
        while order.count > limit {
            let removed = order.removeFirst()
            values.removeValue(forKey: removed)
        }
    }
}

enum MessageTextPipeline {
    // Supported now vs later:
    // | Supported now | Later |
    // | --- | --- |
    // | bold, italic, underline, strikethrough, code, pre, preCode, textUrl | spoiler, custom emoji, block quotes, mentions, hashtags |

    static func render(
        chatId: Int64,
        messageId: Int64,
        rawText: String?,
        entities: [TGTextEntity]?,
        style: MessageTextStyle
    ) -> AttributedString {
        let cacheKey = MessageTextCacheKey(chatId: chatId, messageId: messageId, style: style)
        if let cached = MessageTextCache.shared.value(for: cacheKey) {
            return cached
        }

        let text: String
        if let rawText {
            if rawText.isEmpty {
#if DEBUG
                print("[MessageTextPipeline] (chatId=\(chatId), messageId=\(messageId)) no text content")
#endif
                text = "[unsupported message]"
            } else {
                text = rawText
            }
        } else {
#if DEBUG
            print("[MessageTextPipeline] (chatId=\(chatId), messageId=\(messageId)) unsupported content type")
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

        MessageTextCache.shared.set(attributed, for: cacheKey)
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
                print("[MessageTextPipeline] (chatId=\(chatId), messageId=\(messageId)) invalid entity range offset=\(entity.offset) length=\(entity.length)")
#endif
                continue
            }
            guard let attrRange = Range<AttributedString.Index>(stringRange, in: attributed) else {
#if DEBUG
                print("[MessageTextPipeline] (chatId=\(chatId), messageId=\(messageId)) entity apply error range mapping failed")
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
                    print("[MessageTextPipeline] (chatId=\(chatId), messageId=\(messageId)) invalid URL entity")
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
