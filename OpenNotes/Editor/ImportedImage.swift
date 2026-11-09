import UIKit
import ImageIO

enum ImportedImage {
    static func decode(_ data: Data) throws -> UIImage {
        guard !data.isEmpty, data.count <= 150_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 3200] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        // shortcut: inserted photos are limited to 3200 pixels, retain originals when full-resolution image export is added.
        return UIImage(cgImage: image)
    }
    static func encode(_ source: UIImage, crop: CGRect?) throws -> (Data, CGSize) {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        if let alpha = source.cgImage?.alphaInfo, [.none, .noneSkipFirst, .noneSkipLast].contains(alpha) { format.opaque = true }
        let pixels = CGSize(width: source.size.width * source.scale, height: source.size.height * source.scale)
        let scale = min(1, 3200 / max(1, pixels.width, pixels.height))
        let size = CGSize(width: pixels.width * scale, height: pixels.height * scale)
        var image = UIGraphicsImageRenderer(size: size, format: format).image { _ in source.draw(in: CGRect(origin: .zero, size: size)) }
        if let crop {
            guard crop.width > 0, crop.height > 0, CGRect(x: 0, y: 0, width: 1, height: 1).contains(crop), let cgImage = image.cgImage,
                  let cropped = cgImage.cropping(to: CGRect(x: Double(cgImage.width) * crop.minX, y: Double(cgImage.height) * crop.minY, width: Double(cgImage.width) * crop.width, height: Double(cgImage.height) * crop.height).integral) else { throw CocoaError(.fileReadCorruptFile) }
            image = UIImage(cgImage: cropped)
        }
        // Opaque photos go to JPEG: PNG of a 3200 px photo took seconds on older iPads.
        let alpha = image.cgImage?.alphaInfo ?? .none
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(alpha) || !hasTransparency(image)
        guard let data = opaque ? image.jpegData(compressionQuality: 0.88) : image.pngData() else { throw CocoaError(.fileReadCorruptFile) }
        prepared(image, data: data)
        return (data, image.size)
    }
    /// File name extension matching the bytes `encode` produced.
    static func fileExtension(_ data: Data) -> String { data.starts(with: [0xFF, 0xD8, 0xFF]) ? "jpg" : "png" }

    // Decoded, display-sized images by content: every edit rebuilds PageArtwork, which used to re-decode each image.
    private static let cache: NSCache<NSData, UIImage> = { let cache = NSCache<NSData, UIImage>(); cache.countLimit = 48; return cache }()
    /// A decoded image of at most 2048 px for screen rendering, shared across edits.
    static func display(_ data: Data) -> UIImage? {
        if let hit = cache.object(forKey: data as NSData) { return hit }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary) else { return UIImage(data: data) }
        let result = UIImage(cgImage: image)
        cache.setObject(result, forKey: data as NSData)
        return result
    }
    private static func prepared(_ image: UIImage, data: Data) {
        let pixels = max(image.size.width * image.scale, image.size.height * image.scale)
        if pixels <= 2048, let ready = image.preparingForDisplay() { cache.setObject(ready, forKey: data as NSData) }
        else { _ = display(data) }
    }
    private static func hasTransparency(_ image: UIImage) -> Bool {
        // Renderer output always carries alpha; sample a small copy to see whether any pixel uses it.
        guard let cgImage = image.cgImage else { return true }
        let side = 64
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return true }
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        return stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] < 250 }
    }
}
