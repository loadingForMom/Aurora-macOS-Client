//  ImageMemCache.swift
//  Aurora
//

import Foundation
import AppKit

final class ImageMemCache {
    private let cache = NSCache<NSString, NSImage>()

    init(countLimit: Int = 256) {
        cache.countLimit = countLimit
    }

    func image(forKey key: NSString) -> NSImage? {
        cache.object(forKey: key)
    }

    func setImage(_ image: NSImage, forKey key: NSString) {
        cache.setObject(image, forKey: key)
    }

    func removeImage(forKey key: NSString) {
        cache.removeObject(forKey: key)
    }

    func clear() {
        cache.removeAllObjects()
    }
}
