//
//  CoreImage.swift
//  Aurora
//
//  Created by Sasha on 1/4/26.
//

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

extension NSImage {

    /// Average color of the bottom strip (e.g. 18% of height).
    /// Used for subtle UI tinting; NOT for avatar decode/caching.
    func averageColorOfBottomStrip(stripFraction: CGFloat = 0.18) -> NSColor? {
        guard isValid else { return nil }

        var imageRect = CGRect(origin: .zero, size: size)
        guard let cg = self.cgImage(forProposedRect: &imageRect, context: nil, hints: nil) else {
            return nil
        }

        let ci = CIImage(cgImage: cg)

        let h = ci.extent.height
        let stripH = max(1, h * stripFraction)
        let stripRect = CGRect(
            x: ci.extent.minX,
            y: ci.extent.minY,
            width: ci.extent.width,
            height: stripH
        )

        let cropped = ci.cropped(to: stripRect)

        let filter = CIFilter.areaAverage()
        filter.inputImage = cropped
        filter.extent = cropped.extent

        guard let out = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = CIContext(options: [.workingColorSpace: kCFNull!])
        ctx.render(
            out,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )

        return NSColor(
            red: CGFloat(pixel[0]) / 255.0,
            green: CGFloat(pixel[1]) / 255.0,
            blue: CGFloat(pixel[2]) / 255.0,
            alpha: CGFloat(pixel[3]) / 255.0
        )
    }
}

/// Disk thumbnail helper.
///
/// Important goals:
/// - Avoid decoding full source images via NSImage(contentsOfFile:)
/// - Create thumbnails only when source changes (mtime in filename)
/// - Reuse thumbnails across app launches (no "compress every startup")
nonisolated enum AuroraImageThumb {

    static func decodeThumbnailNSImage(sourcePath: String, maxPixel: Int) -> NSImage? {
        guard maxPixel > 0 else { return nil }
        let url = URL(fileURLWithPath: sourcePath)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    static func ensureThumbnail(sourcePath: String,
                               cacheDirURL: URL,
                               fileId: Int32,
                               kind: String,
                               maxPixel: Int,
                               jpegQuality: CGFloat) -> String? {
        guard maxPixel > 0 else { return nil }

        let srcURL = URL(fileURLWithPath: sourcePath)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: sourcePath),
              let mdate = attrs[.modificationDate] as? Date else {
            return nil
        }

        let mtime = Int(mdate.timeIntervalSince1970)
        let safeKind = kind.replacingOccurrences(of: "/", with: "_")
        let baseName = "fid\(fileId)_\(safeKind)_px\(maxPixel)_mt\(mtime)"
        let destURL = cacheDirURL.appendingPathComponent(baseName).appendingPathExtension("jpg")

        // If already exists, done.
        if FileManager.default.fileExists(atPath: destURL.path) {
            return destURL.path
        }

        // Cleanup older thumbs for same fid/kind/maxPixel (different mt)
        cleanupOldVersions(cacheDirURL: cacheDirURL,
                           prefix: "fid\(fileId)_\(safeKind)_px\(maxPixel)_mt",
                           keep: destURL.lastPathComponent)

        // Make thumb via ImageIO (fast, avoids full decode)
        guard let src = CGImageSourceCreateWithURL(srcURL as CFURL, nil) else { return nil }

        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else { return nil }

        // Write JPEG (small, fast)
        guard let dest = CGImageDestinationCreateWithURL(destURL as CFURL,
                                                        UTType.jpeg.identifier as CFString,
                                                        1,
                                                        nil) else { return nil }

        let q = max(0.65, min(Double(jpegQuality), 0.98))
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: q
        ]

        CGImageDestinationAddImage(dest, cgThumb, props as CFDictionary)

        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: destURL)
            return nil
        }

        return destURL.path
    }

    private static func cleanupOldVersions(cacheDirURL: URL, prefix: String, keep: String) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDirURL,
                                                                       includingPropertiesForKeys: nil,
                                                                       options: [.skipsHiddenFiles]) else { return }
        for f in files {
            let name = f.lastPathComponent
            guard name != keep else { continue }
            guard name.hasPrefix(prefix) else { continue }
            try? FileManager.default.removeItem(at: f)
        }
    }
}
