import Foundation

public struct Settings: Codable, Equatable, Sendable {
    public var httpServerAutoStart: Bool?
    public var httpServerPort: Int?
    public var hotkeysEnabled: Bool?

    public init(httpServerAutoStart: Bool? = nil, httpServerPort: Int? = nil, hotkeysEnabled: Bool? = nil) {
        self.httpServerAutoStart = httpServerAutoStart
        self.httpServerPort = httpServerPort
        self.hotkeysEnabled = hotkeysEnabled
    }
}

public final class SettingsStore {
    public static let fileName = "settings.json"

    private let fileURL: URL
    private let defaults: AppEnvironment.Defaults
    public private(set) var settings: Settings

    public init(directory: URL, defaults: AppEnvironment.Defaults) {
        fileURL = directory.appendingPathComponent(Self.fileName)
        self.defaults = defaults
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = decoded
        } else {
            settings = Settings()
        }
    }

    public var httpServerAutoStart: Bool {
        get { settings.httpServerAutoStart ?? true }
        set { update { $0.httpServerAutoStart = newValue } }
    }

    public var httpServerPort: Int {
        get { settings.httpServerPort ?? defaults.httpPort }
        set { update { $0.httpServerPort = newValue } }
    }

    public var hotkeysEnabled: Bool {
        get { settings.hotkeysEnabled ?? defaults.hotkeysEnabled }
        set { update { $0.hotkeysEnabled = newValue } }
    }

    private func update(_ change: (inout Settings) -> Void) {
        change(&settings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(settings) {
            try? FileStorage.writeProtected(data, to: fileURL)
        }
    }
}
