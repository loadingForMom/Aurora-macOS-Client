//
//  MessageTextRenderer.swift
//  Aurora
//
//  Background text parsing + attributed string cache.
//

import AppKit
import os

struct MessageTextStyle: Hashable {
    let fontSize: CGFloat
    let isOutgoing: Bool

    static let defaultStyle = MessageTextStyle(fontSize: 14, isOutgoing: false)
}

final class MessageTextRenderer {
    private final class CacheKey: NSObject {
        let messageId: Int64
        let style: MessageTextStyle

        init(messageId: Int64, style: MessageTextStyle) {
            self.messageId = messageId
            self.style = style
        }

        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(messageId)
            hasher.combine(style)
            return hasher.finalize()
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? CacheKey else { return false }
            return messageId == other.messageId && style == other.style
        }
    }

    private let cache = NSCache<CacheKey, NSAttributedString>()
    private let lock = DispatchQueue(label: "Aurora.MessageTextRenderer.lock")
    private var inFlight: [CacheKey: [((NSAttributedString) -> Void)]] = [:]

    private let log = Logger(subsystem: "Aurora.Chat", category: "TextRender")
    private let signposter = OSSignposter(subsystem: "Aurora.Chat", category: "TextRender")

    func render(message: TGMessage, style: MessageTextStyle, completion: @escaping (NSAttributedString) -> Void) {
        let key = CacheKey(messageId: message.id, style: style)
        if let cached = cache.object(forKey: key) {
            log.debug("Text cache hit for message \\(message.id)")
            completion(cached)
            return
        }

        let shouldRender = lock.sync { () -> Bool in
            if var callbacks = inFlight[key] {
                callbacks.append(completion)
                inFlight[key] = callbacks
                return false
            } else {
                inFlight[key] = [completion]
                return true
            }
        }

        guard shouldRender else { return }

        let signpostId = signposter.makeSignpostID()
        signposter.beginInterval("RenderMessage", id: signpostId)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let attributed = Self.buildAttributedString(message: message, style: style)
            self?.cache.setObject(attributed, forKey: key)
            self?.signposter.endInterval("RenderMessage", id: signpostId)

            let callbacks = self?.lock.sync { () -> [((NSAttributedString) -> Void)] in
                let list = self?.inFlight[key] ?? []
                self?.inFlight[key] = nil
                return list
            } ?? []

            DispatchQueue.main.async {
                callbacks.forEach { $0(attributed) }
            }
        }
    }

    func prefetch(message: TGMessage, style: MessageTextStyle) {
        render(message: message, style: style) { _ in }
    }

    private static func buildAttributedString(message: TGMessage, style: MessageTextStyle) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .left

        let font = NSFont.systemFont(ofSize: style.fontSize, weight: .regular)
        let color = style.isOutgoing ? NSColor.white : NSColor.labelColor

        return NSAttributedString(
            string: message.text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
    }
}
