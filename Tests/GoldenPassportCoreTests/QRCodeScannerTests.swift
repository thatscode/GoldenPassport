import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GoldenPassportCore

/// QR code images made with Core Image, with the quiet zone readers expect.
enum QRImage {
    static func make(_ message: String, scale: CGFloat = 8) throws -> CGImage {
        let filter = try #require(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(message.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let code = try #require(filter.outputImage).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let margin = scale * 4
        let canvas = CGRect(x: 0, y: 0, width: code.extent.width + 2 * margin, height: code.extent.height + 2 * margin)
        let image = code.transformed(by: CGAffineTransform(translationX: margin, y: margin))
            .composited(over: CIImage(color: CIColor.white).cropped(to: canvas))
        return try #require(CIContext().createCGImage(image, from: canvas))
    }

    static func blank(width: Int = 200, height: Int = 200) throws -> CGImage {
        try draw(width: width, height: height) { _ in }
    }

    static func sideBySide(_ left: CGImage, _ right: CGImage) throws -> CGImage {
        try draw(width: left.width + right.width + 40, height: max(left.height, right.height)) { context in
            context.draw(left, in: CGRect(x: 0, y: 0, width: left.width, height: left.height))
            context.draw(right, in: CGRect(x: left.width + 40, y: 0, width: right.width, height: right.height))
        }
    }

    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func draw(width: Int, height: Int, _ body: (CGContext) -> Void) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        body(context)
        return try #require(context.makeImage())
    }
}

struct QRCodeScannerTests {
    static let link = "otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP&issuer=GitHub"

    /// Ten accounts, the most Google Authenticator puts in one code.
    static var denseMigration: String {
        let otps = (0..<10).map { index in
            Protobuf.otp(secret: Data((0..<20).map { UInt8(($0 * 7 + index * 13) % 256) }),
                         name: "user\(index)@example.com", issuer: "Service \(index)")
        }
        return Protobuf.url(Protobuf.payload(otps))
    }

    @Test func readsAnOtpauthCode() throws {
        #expect(QRCodeScanner.payloads(in: try QRImage.make(Self.link)) == [Self.link])
    }

    @Test func readsADenseMigrationCode() throws {
        let message = Self.denseMigration
        #expect(QRCodeScanner.payloads(in: try QRImage.make(message, scale: 4)) == [message])
    }

    @Test func readsTwoCodesInOneImage() throws {
        let other = "otpauth://totp/AWS:bob?secret=MZXW6YTBOI"
        let image = try QRImage.sideBySide(try QRImage.make(Self.link), try QRImage.make(other))
        #expect(Set(QRCodeScanner.payloads(in: image)) == [Self.link, other])
    }

    @Test func imageWithoutACodeGivesNothing() throws {
        #expect(QRCodeScanner.payloads(in: try QRImage.blank()).isEmpty)
    }

    @Test func notAnImageGivesNothing() throws {
        #expect(QRCodeScanner.payloads(inImageData: Data("hello".utf8)).isEmpty)
        let file = try makeTempDirectory().appendingPathComponent("notes.png")
        try Data("hello".utf8).write(to: file)
        #expect(QRCodeScanner.payloads(inImageAt: file).isEmpty)
    }

    @Test func readsPNGFilesAndData() throws {
        let png = try QRImage.png(try QRImage.make(Self.link))
        #expect(QRCodeScanner.payloads(inImageData: png) == [Self.link])
        let file = try makeTempDirectory().appendingPathComponent("code.png")
        try png.write(to: file)
        #expect(QRCodeScanner.payloads(inImageAt: file) == [Self.link])
    }
}
