//  TelegramStore+Avatars.swift
//  Aurora
//

import Foundation
import AppKit
import Combine

extension TelegramStore {

    func screenScale() -> CGFloat {
        avatarService.screenScale()
    }

    func maxPixel(forPointSize pt: CGFloat, clampTo maxClamp: Int) -> Int {
        avatarService.maxPixel(forPointSize: pt, clampTo: maxClamp)
    }

    func _myProfileNSImage_impl(pointSize: CGFloat) -> NSImage? {
        avatarService.myProfileNSImage(
            pointSize: pointSize,
            profilePhotoPath: myProfilePhotoPath,
            myPhotoFileId: myPhotoFileId
        )
    }

    func _chatAvatarNSImage_impl(
        chatId: Int64,
        pointSize: CGFloat,
        preferHiRes: Bool,
        maxClamp: Int?,
        kindOverride: String?
    ) -> NSImage? {
        let image = avatarService.chatAvatarNSImage(
            chatId: chatId,
            pointSize: pointSize,
            preferHiRes: preferHiRes,
            maxClamp: maxClamp,
            kindOverride: kindOverride,
            chatAvatarMetaByChatId: chatAvatarMetaByChatId,
            chatAvatarPathByChatId: chatAvatarPathByChatId
        )
        if image == nil, let meta = chatAvatarMetaByChatId[chatId] {
            if preferHiRes, let bigId = meta.bigFileId {
                scheduleDownloadFile(fileId: bigId, priority: 10, reason: "visible-avatar-hires:\(chatId)")
            } else if let smallId = meta.smallFileId ?? meta.bigFileId {
                scheduleDownloadFile(fileId: smallId, priority: 16, reason: "visible-avatar:\(chatId)")
            }
        }
        return image
    }

    func _prefetchChatAvatarHiResIfNeeded_impl(chatId: Int64) {
        avatarService.prefetchChatAvatarHiResIfNeeded(
            chatId: chatId,
            chatAvatarMetaByChatId: chatAvatarMetaByChatId,
            downloadFileIfNeeded: downloadFileIfNeeded
        )
    }

    // MARK: - Avatar apply / download

    @MainActor
    func registerChatAvatar(chatId: Int64, smallFileId: Int32?, bigFileId: Int32?, initialBestPath: String?) {
        avatarService.registerChatAvatar(
            chatId: chatId,
            smallFileId: smallFileId,
            bigFileId: bigFileId,
            initialBestPath: initialBestPath,
            chatAvatarMetaByChatId: &chatAvatarMetaByChatId,
            chatIdByAvatarFileId: &chatIdByAvatarFileId
        )
        bumpChatAvatarVersion(chatId: chatId)
        queueChatAvatarPathUpdate(chatId: chatId, path: initialBestPath)
    }

    @MainActor
    func applyChatAvatarFileUpdate(chatId: Int64, fileId: Int32, path: String) {
        let bestPath = avatarService.applyChatAvatarFileUpdate(
            chatId: chatId,
            fileId: fileId,
            path: path,
            chatAvatarMetaByChatId: &chatAvatarMetaByChatId
        )
        bumpChatAvatarVersion(chatId: chatId)
        queueChatAvatarPathUpdate(chatId: chatId, path: bestPath)
    }

    @MainActor
    func clearChatAvatar(chatId: Int64) {
        if let meta = chatAvatarMetaByChatId.removeValue(forKey: chatId) {
            if let smallId = meta.smallFileId, chatIdByAvatarFileId[smallId] == chatId {
                chatIdByAvatarFileId.removeValue(forKey: smallId)
            }
            if let bigId = meta.bigFileId, chatIdByAvatarFileId[bigId] == chatId {
                chatIdByAvatarFileId.removeValue(forKey: bigId)
            }
        }
        bumpChatAvatarVersion(chatId: chatId)
        queueChatAvatarPathUpdate(chatId: chatId, path: nil)
    }

    @MainActor
    func downloadFileIfNeeded(fileId: Int32, priority: Int) {
        scheduleDownloadFile(fileId: fileId, priority: priority, reason: "avatar-manual:\(fileId)")
    }

    // MARK: - Thumbnail load/make

    func loadOrMakeThumbNSImage(
        sourcePath: String,
        fileId: Int32?,
        kind: String,
        maxPixel: Int,
        jpegQuality: CGFloat
    ) -> NSImage? {
        avatarService.loadOrMakeThumbNSImage(
            sourcePath: sourcePath,
            fileId: fileId,
            kind: kind,
            maxPixel: maxPixel,
            jpegQuality: jpegQuality
        )
    }
}
