//
//  TelegramModels.swift
//  Aurora
//
//  Created by Sasha on 1/3/26.
//

import Foundation

enum TGChatKind: String, Hashable {
    case privateChat
    case basicGroup
    case supergroup
    case secret
    case unknown

    var label: String {
        switch self {
        case .privateChat: return "Direct"
        case .basicGroup, .supergroup: return "Group"
        case .secret: return "Secret"
        case .unknown: return ""
        }
    }

    var isGroup: Bool {
        self == .basicGroup || self == .supergroup
    }
}

struct TGChat: Identifiable, Hashable {
    let id: Int64
    var title: String
    var kind: TGChatKind
    var order: Int64

    // Для sidebar превью
    var lastMessagePreview: String
    var lastMessageDate: Int

    /// Number of unread messages in this chat.
    var unreadCount: Int32

    /// The last read inbox message id (TDLib: last_read_inbox_message_id).
    var lastReadInboxMessageId: Int64

    /// Last known inbox message id (from TDLib last_message.id when available).
    var lastMessageId: Int64

    init(id: Int64,
         title: String,
         kind: TGChatKind = .unknown,
         order: Int64 = 0,
         lastMessagePreview: String = "",
         lastMessageDate: Int = 0,
         unreadCount: Int32 = 0,
         lastReadInboxMessageId: Int64 = 0,
         lastMessageId: Int64 = 0) {
        self.id = id
        self.title = title
        self.kind = kind
        self.order = order
        self.lastMessagePreview = lastMessagePreview
        self.lastMessageDate = lastMessageDate
        self.unreadCount = unreadCount
        self.lastReadInboxMessageId = lastReadInboxMessageId
        self.lastMessageId = lastMessageId
    }

    var hasUnread: Bool {
        unreadCount > 0
    }
}

struct TGUser: Identifiable, Hashable {
    let id: Int64
    var firstName: String
    var lastName: String
    var username: String

    var displayName: String {
        let full = ([firstName, lastName].filter { !$0.isEmpty }).joined(separator: " ")
        if !full.isEmpty { return full }
        if !username.isEmpty { return username }
        return "User \(id)"
    }
}

enum TGMessageSendState: Hashable {
    case sent
    case pending
    case sending
    case failed(errorText: String)
}

struct TGMessage: Identifiable, Hashable {
    let id: Int64
    let chatId: Int64
    let date: Int
    let isOutgoing: Bool
    let senderUserId: Int64?
    
    
    

    /// Preview / fallback text (what you already used everywhere).
    let text: String

    /// correctness-first rendering payload
    let contentType: String
    var rawText: String?
    var entities: [TGTextEntity]

    // Optimistic / sending state
    var sendState: TGMessageSendState

    /// Reply-to message id (if any).
    var replyToMessageId: Int64?

    /// Local identity for UI bookkeeping (optimistic placeholder ↔ TDLib message).
    var localId: UUID?

    /// TDLib sending_id (goes into messageSendOptions.sending_id, then echoes back in messageSendingStatePending.sending_id).
    var sendingId: Int32?

    /// From TDLib updateMessageEdited.edit_date (Unix time). Content changes come via updateMessageContent.
    var editedAt: Int?

    /// From TDLib messageSendingStateFailed.can_retry (and/or sending_state.failed.can_retry).
    var canRetry: Bool

    /// Local retry bookkeeping.
    var retryCount: Int
    var nextRetryAt: Int?

    init(
        id: Int64,
        chatId: Int64,
        date: Int,
        isOutgoing: Bool,
        senderUserId: Int64?,
        text: String,
        contentType: String = "messageText",
        rawText: String? = nil,
        entities: [TGTextEntity] = [],
        sendState: TGMessageSendState = .sent,
        replyToMessageId: Int64? = nil,
        localId: UUID? = nil,
        sendingId: Int32? = nil,
        editedAt: Int? = nil,
        canRetry: Bool = false,
        retryCount: Int = 0,
        nextRetryAt: Int? = nil
    ) {
        self.id = id
        self.chatId = chatId
        self.date = date
        self.isOutgoing = isOutgoing
        self.senderUserId = senderUserId
        self.text = text
        self.contentType = contentType
        self.rawText = rawText
        self.entities = entities
        self.sendState = sendState
        self.replyToMessageId = replyToMessageId
        self.localId = localId
        self.sendingId = sendingId
        self.editedAt = editedAt
        self.canRetry = canRetry
        self.retryCount = retryCount
        self.nextRetryAt = nextRetryAt
    }

    var isEdited: Bool {
        if let t = editedAt { return t > 0 }
        return false
    }

    var errorText: String? {
        if case let .failed(err) = sendState { return err }
        return nil
    }

    var previewText: String { text }

    var textForRendering: String? {
        guard contentType == "messageText" else { return nil }
        return rawText ?? text
    }

    var messageKey: MessageKey {
        MessageKey(chatId: chatId, stableId: stableId)
    }

    var stableId: MessageStableId {
        if id > 0 { return .server(id) }
        if let localId { return .local(localId) }
        return .server(id)
    }

    func withLocal(localId: UUID?, sendingId: Int32?) -> TGMessage {
        var m = self
        m.localId = localId
        m.sendingId = sendingId
        return m
    }
}

enum MessageStableId: Hashable {
    case server(Int64)
    case local(UUID)
}

struct MessageKey: Hashable {
    let chatId: Int64
    let stableId: MessageStableId
}

struct TGTextEntity: Hashable {
    let type: TGTextEntityType
    let offset: Int
    let length: Int
}

enum TGTextEntityType: Hashable {
    case bold
    case italic
    case underline
    case strikethrough
    case code
    case pre
    case preCode(language: String?)
    case textUrl(url: String)
    case unknown(String)
}
