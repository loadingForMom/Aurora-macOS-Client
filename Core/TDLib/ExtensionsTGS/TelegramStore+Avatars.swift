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
        avatarService.chatAvatarNSImage(
            chatId: chatId,
            pointSize: pointSize,
            preferHiRes: preferHiRes,
            maxClamp: maxClamp,
            kindOverride: kindOverride,
            chatAvatarMetaByChatId: chatAvatarMetaByChatId,
            chatAvatarPathByChatId: chatAvatarPathByChatId
        )
    }

    func _prefetchChatAvatarHiResIfNeeded_impl(chatId: Int64) {
        avatarService.prefetchChatAvatarHiResIfNeeded(
            chatId: chatId,
            chatAvatarMetaByChatId: chatAvatarMetaByChatId,
            downloadFileIfNeeded: downloadFileIfNeeded
        )
    }

    // MARK: - Avatar apply / download

    func registerChatAvatar(chatId: Int64, smallFileId: Int32?, bigFileId: Int32?, initialBestPath: String?) {
        avatarService.registerChatAvatar(
            chatId: chatId,
            smallFileId: smallFileId,
            bigFileId: bigFileId,
            initialBestPath: initialBestPath,
            chatAvatarMetaByChatId: &chatAvatarMetaByChatId,
            chatIdByAvatarFileId: &chatIdByAvatarFileId
        )
        if let sid = smallFileId {
                downloadFileIfNeeded(fileId: sid, priority: 16)
            }
    }

    func applyChatAvatarFileUpdate(chatId: Int64, fileId: Int32, path: String) {
        avatarService.applyChatAvatarFileUpdate(
            chatId: chatId,
            fileId: fileId,
            path: path,
            chatAvatarMetaByChatId: &chatAvatarMetaByChatId,
            chatAvatarPathByChatId: &chatAvatarPathByChatId
        )

        objectWillChange.send()
    }

    func downloadFileIfNeeded(fileId: Int32, priority: Int) {
        avatarService.downloadFileIfNeeded(
            fileId: fileId,
            priority: priority,
            requestedAvatarFileIds: &requestedAvatarFileIds,
            sendJSON: sendJSON
        )
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
