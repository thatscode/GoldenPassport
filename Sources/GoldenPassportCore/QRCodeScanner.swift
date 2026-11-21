import Foundation
import ImageIO
import Vision

/// Reads every QR code in an image with Vision, which copes with photos of a phone screen and with
/// the dense codes of a Google Authenticator export better than Core Image's detector.
public enum QRCodeScanner {
    /// The text of each code, in the order found, without repeats.
    public static func payloads(in image: CGImage) -> [String] {
        payloads(in: image, orientation: .up)
    }

    /// Through ImageIO, so HEIC photos from an iPhone work too. Empty if the file isn't an image.
    public static func payloads(inImageAt url: URL) -> [String] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        return payloads(in: source)
    }

    public static func payloads(inImageData data: Data) -> [String] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [] }
        return payloads(in: source)
    }

    private static func payloads(in source: CGImageSource) -> [String] {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
        // Photos are often stored sideways with an orientation tag.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32)
            .flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        return payloads(in: image, orientation: orientation)
    }

    private static func payloads(in image: CGImage, orientation: CGImagePropertyOrientation) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        var seen: Set<String> = []
        return (request.results ?? []).compactMap { observation in
            guard let payload = observation.payloadStringValue, seen.insert(payload).inserted else { return nil }
            return payload
        }
    }
}
