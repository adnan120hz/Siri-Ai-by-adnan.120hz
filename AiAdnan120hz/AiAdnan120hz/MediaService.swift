import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Media: foto → base64 image_url; video → ekstraksi frame.

enum MediaService {
    static let maxImageDimension: CGFloat = 1536
    static let maxVideoFrames = 4

    /// Kecilkan UIImage-data ke batas dimensi, kembalikan JPEG.
    static func downscaleJPEG(_ data: Data, maxDimension: CGFloat = maxImageDimension) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1.0, maxDimension / max(w, h))
        let nw = max(1, Int(w * scale)), nh = max(1, Int(h * scale))
        guard let ctx = CGContext(data: nil, width: nw, height: nh,
                                 bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let scaled = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality as String: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    static func dataURL(jpeg: Data) -> String {
        "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
    }

    /// Ekstrak hingga `maxVideoFrames` frame dari video, sebagai JPEG data.
    static func extractFrames(from videoURL: URL, count: Int = maxVideoFrames) async -> [Data] {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1024, height: 1024)
        let duration: CMTime
        do { duration = try await asset.load(.duration) } catch { return [] }
        guard duration.seconds > 0 else { return [] }
        var result: [Data] = []
        for i in 0..<count {
            let fraction = Double(i + 1) / Double(count + 1)
            let time = CMTime(seconds: duration.seconds * fraction, preferredTimescale: 600)
            do {
                let cg = try await generator.image(for: time)
                let out = NSMutableData()
                if let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality as String: 0.7] as CFDictionary)
                    if CGImageDestinationFinalize(dest) { result.append(out as Data) }
                }
            } catch { continue }
        }
        return result
    }
}
