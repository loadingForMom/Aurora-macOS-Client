//
//  MessageCellProps.swift
//  Aurora
//

import Foundation
import CoreGraphics

struct MediaEnsureRequest {
    let chatId: Int64
    let messageId: Int64
    let descriptor: TGMessageMediaDescriptor
    let targetPointSize: CGSize
    let screenScale: CGFloat
    let preferThumbnail: Bool
}
