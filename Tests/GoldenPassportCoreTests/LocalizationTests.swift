import Foundation
import Testing

/// Guards Resources/*.lproj/Localizable.strings, which build-app.sh copies into the app.
struct LocalizationTests {
    private static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources")

    private func table(_ language: String) throws -> [String: String] {
        let url = Self.resources.appendingPathComponent("\(language).lproj/Localizable.strings")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try #require(plist as? [String: String])
    }

    private func specifiers(_ s: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "%(@|lld|d|%)")
        return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { (s as NSString).substring(with: $0.range) }
    }

    @Test func tablesShareKeysAndChineseIsIdentity() throws {
        let en = try table("en"), zh = try table("zh-Hans")
        #expect(Set(en.keys) == Set(zh.keys))
        for (key, value) in zh { #expect(key == value, "zh-Hans must map \(key) to itself") }
    }

    @Test func englishKeepsFormatSpecifiers() throws {
        for (key, value) in try table("en") {
            #expect(specifiers(key) == specifiers(value), "specifiers differ for \(key)")
            #expect(!value.isEmpty)
        }
    }
}
