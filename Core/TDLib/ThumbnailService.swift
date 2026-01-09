//  ThumbnailService.swift
//  Aurora
//

import Foundation

final class ThumbnailService {
    private let thumbsDirURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Aurora/thumbs", isDirectory: true)
        thumbsDirURL = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func ensureThumbnail(
        sourcePath: String,
        fileId: Int32,
        kind: String,
        maxPixel: Int,
        jpegQuality: CGFloat
    ) -> String? {
        AuroraImageThumb.ensureThumbnail(
            sourcePath: sourcePath,
            cacheDirURL: thumbsDirURL,
            fileId: fileId,
            kind: kind,
            maxPixel: maxPixel,
            jpegQuality: jpegQuality
        )
    }
}
