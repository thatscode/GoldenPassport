import Foundation

/// Modifier combinations offered for the "fill in code N" global hotkeys (N = 0–9).
public enum HotkeyModifiers: String, CaseIterable, Codable, Sendable {
    case controlOptionCommand
    case shiftCommand
    case controlOption

    public var symbols: String {
        switch self {
        case .controlOptionCommand: return "⌃⌥⌘"
        case .shiftCommand: return "⇧⌘"
        case .controlOption: return "⌃⌥"
        }
    }

    /// Hotkey digit for the account at `index` (first account is 0, as in 0.1.x), or nil past the tenth.
    public static func digit(forAccountAt index: Int) -> Int? {
        (0..<10).contains(index) ? index : nil
    }
}

public struct Settings: Codable, Equatable, Sendable {
    public var httpServerAutoStart: Bool?
    public var httpServerPort: Int?
    public var hotkeysEnabled: Bool?
    public var hotkeyModifiers: HotkeyModifiers?

    public init(httpServerAutoStart: Bool? = nil, httpServerPort: Int? = nil,
                hotkeysEnabled: Bool? = nil, hotkeyModifiers: HotkeyModifiers? = nil) {
        self.httpServerAutoStart = httpServerAutoStart
        self.httpServerPort = httpServerPort
        self.hotkeysEnabled = hotkeysEnabled
        self.hotkeyModifiers = hotkeyModifiers
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

    public var hotkeyModifiers: HotkeyModifiers {
        get { settings.hotkeyModifiers ?? .controlOptionCommand }
        set { update { $0.hotkeyModifiers = newValue } }
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
