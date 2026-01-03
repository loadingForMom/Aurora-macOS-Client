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

    init(id: Int64,
         title: String,
         kind: TGChatKind = .unknown,
         order: Int64 = 0,
         lastMessagePreview: String = "",
         lastMessageDate: Int = 0) {
        self.id = id
        self.title = title
        self.kind = kind
        self.order = order
        self.lastMessagePreview = lastMessagePreview
        self.lastMessageDate = lastMessageDate
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

struct TGMessage: Identifiable, Hashable {
    let id: Int64
    let chatId: Int64
    let date: Int
    let isOutgoing: Bool
    let senderUserId: Int64?
    let text: String

    var previewText: String { text }
}
