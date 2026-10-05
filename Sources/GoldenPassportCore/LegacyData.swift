import Foundation

/// Reads and writes the NSKeyedArchiver `[String: String]` files used by
/// GoldenPassport <= 0.1.7 (`gp.secrets`, `config.plist`, exported `.secrets`).
public enum LegacyData {
    public static let secretsFileName = "gp.secrets"
    public static let configFileName = "config.plist"

    public static func readDictionary(at url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        let object = try NSKeyedUnarchiver.unarchivedObject(
            ofClasses: [NSDictionary.self, NSMutableDictionary.self, NSString.self, NSMutableString.self],
            from: data)
        guard let dictionary = object as? [String: String] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return dictionary
    }

    /// Writes the format the old app can import, so exports stay usable both ways.
    public static func writeDictionary(_ dictionary: [String: String], to url: URL) throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: dictionary as NSDictionary,
                                                    requiringSecureCoding: false)
        try FileStorage.writeProtected(data, to: url)
    }

    /// Old storage was an unordered dictionary, so start from a stable alphabetical order.
    public static func accounts(from dictionary: [String: String]) -> [Account] {
        dictionary
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { Account(name: $0.key, url: $0.value) }
    }
}
