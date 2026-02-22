//  ThumbHash.swift
//  Aurora
//

import Foundation

nonisolated func fnv1a32(_ s: String) -> UInt32 {
    var h: UInt32 = 2166136261
    for b in s.utf8 {
        h ^= UInt32(b)
        h &*= 16777619
    }
    return h
}

nonisolated func stableThumbFallbackFileId(sourcePath: String, kind: String, maxPixel: Int) -> Int32 {
    let key = "\(kind)|\(maxPixel)|\(sourcePath)"
    let h = fnv1a32(key)
    let nonZeroPositive = (h & 0x7fffffff) | 1
    return Int32(nonZeroPositive)
}
