//
//  CoreImage.swift
//  Aurora
//
//  Created by Sasha on 1/4/26.
//

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

extension NSImage {

    /// Average color of the bottom strip (e.g. 18% of height).
    func averageColorOfBottomStrip(stripFraction: CGFloat = 0.18) -> NSColor? {
        guard isValid else { return nil }

        var imageRect = CGRect(origin: .zero, size: size)
        guard let cg = self.cgImage(forProposedRect: &imageRect, context: nil, hints: nil) else {
            return nil
        }

        let ci = CIImage(cgImage: cg)

        // bottom strip
        let h = ci.extent.height
        let stripH = max(1, h * stripFraction)
        let stripRect = CGRect(x: ci.extent.minX,
                               y: ci.extent.minY,
                               width: ci.extent.width,
                               height: stripH)

        let cropped = ci.cropped(to: stripRect)

        let filter = CIFilter.areaAverage()
        filter.inputImage = cropped
        filter.extent = cropped.extent

        guard let out = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = CIContext(options: [.workingColorSpace: kCFNull!])
        ctx.render(out,
                   toBitmap: &pixel,
                   rowBytes: 4,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBA8,
                   colorSpace: nil)

        return NSColor(red: CGFloat(pixel[0]) / 255.0,
                       green: CGFloat(pixel[1]) / 255.0,
                       blue: CGFloat(pixel[2]) / 255.0,
                       alpha: CGFloat(pixel[3]) / 255.0)
    }
}


