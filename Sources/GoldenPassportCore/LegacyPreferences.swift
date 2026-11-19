import Foundation

/// Preferences kept under the bundle id that 0.1.x and 0.2.0 used (site.stanzhai.GoldenPassport;
/// 0.2.1 moved to com.thatscode.GoldenPassport, see Info.plist GPLegacyBundleIdentifier).
public enum LegacyPreferences {
    /// Set in the new domain once the carry-over ran, so that a setting the user removes later
    /// (say, the language back to System Default) is not copied over again.
    static let doneKey = "GPLegacyPreferencesCarriedOver"

    /// The new domain with `keys` copied from the legacy one, once: keys the new domain already
    /// has are kept. nil when the carry-over already ran and nothing needs writing.
    public static func carriedOver(_ keys: [String], legacy: [String: Any]?,
                                   current: [String: Any]?) -> [String: Any]? {
        var domain = current ?? [:]
        guard domain[doneKey] == nil else { return nil }
        for key in keys where domain[key] == nil {
            if let value = legacy?[key] { domain[key] = value }
        }
        domain[doneKey] = true
        return domain
    }

    /// Carries `keys` over from the persistent domain `legacyDomain` into `domain`.
    public static func carryOver(_ keys: [String], from legacyDomain: String, to domain: String,
                                 defaults: UserDefaults = .standard) {
        guard legacyDomain != domain,
              let updated = carriedOver(keys, legacy: defaults.persistentDomain(forName: legacyDomain),
                                        current: defaults.persistentDomain(forName: domain))
        else { return }
        defaults.setPersistentDomain(updated, forName: domain)
    }
}
