import Foundation

#if canImport(ImageIO)
    import ImageIO
    import UniformTypeIdentifiers
#endif

/// Returns images (screenshots, textures) to Claude, shrinking large ones so the
/// result fits through the relay.
enum ImageSupport {
    static let maxInlineBytes = 600 * 1024

    static func mimeType(forExtension ext: String) -> String? {
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "bmp", "tga", "tif", "tiff", "heic": return "image/other"
        default: return nil
        }
    }

    /// Returns the image to send, or nil if it cannot be prepared.
    static func prepareForClaude(_ data: Data, mimeType: String) -> (data: Data, mimeType: String, note: String)? {
        if data.count <= maxInlineBytes && mimeType != "image/other" {
            return (data, mimeType, "")
        }
        #if canImport(ImageIO)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            var maxSide = 1568
            while maxSide >= 256 {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxSide,
                ]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                    return nil
                }
                let output = NSMutableData()
                guard
                    let destination = CGImageDestinationCreateWithData(
                        output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
                else { return nil }
                CGImageDestinationAddImage(
                    destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { return nil }
                if output.length <= maxInlineBytes {
                    return (output as Data, "image/jpeg", " - downscaled to \(image.width)x\(image.height) JPEG for viewing")
                }
                maxSide /= 2
            }
            return nil
        #else
            return nil
        #endif
    }
}
