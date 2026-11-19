import Foundation

/// Preferences kept under the bundle id that 0.1.x and 0.2.0 used (site.stanzhai.GoldenPassport;
/// 0.2.1 moved to com.thatscode.GoldenPassport, see Info.plist GPLegacyBundleIdentifier).
public enum LegacyPreferences {
    /// The keys already carried over, kept in the new domain, so that each key is copied once and
    /// a setting the user removes later (say, the language back to System Default) stays removed.
    /// 0.2.1 stored `true` here after carrying over AppleLanguages only.
    static let doneKey = "GPLegacyPreferencesCarriedOver"

    /// What to carry over from `legacy`: the menu's language choice, and where the menu bar icon
    /// sits and whether it is shown (AppKit's "NSStatusItem …" keys). Without its old position, a
    /// status item counts as new and goes to the far left of the icons, where a crowded menu bar
    /// next to the notch has no room for it, so the icon doesn't appear at all.
    public static func keys(in legacy: [String: Any]?) -> [String] {
        ["AppleLanguages"] + (legacy?.keys.filter { $0.hasPrefix("NSStatusItem ") }.sorted() ?? [])
    }

    /// The new domain with each of `keys` not carried over yet copied from the legacy one, unless
    /// the new domain already has it. nil when there is nothing to write.
    public static func carriedOver(_ keys: [String], legacy: [String: Any]?,
                                   current: [String: Any]?) -> [String: Any]? {
        var domain = current ?? [:]
        let done: Set<String>
        switch domain[doneKey] {
        case let list as [String]: done = Set(list)
        case .some: done = ["AppleLanguages"] // 0.2.1's marker
        case nil: done = []
        }
        let pending = keys.filter { !done.contains($0) }
        guard !pending.isEmpty else { return nil }
        for key in pending where domain[key] == nil {
            if let value = legacy?[key] { domain[key] = value }
        }
        domain[doneKey] = done.union(pending).sorted()
        return domain
    }

    /// Carries the settings over from the persistent domain `legacyDomain` into `domain`.
    public static func carryOver(from legacyDomain: String, to domain: String,
                                 defaults: UserDefaults = .standard) {
        guard legacyDomain != domain else { return }
        let legacy = defaults.persistentDomain(forName: legacyDomain)
        guard let updated = carriedOver(keys(in: legacy), legacy: legacy,
                                        current: defaults.persistentDomain(forName: domain))
        else { return }
        defaults.setPersistentDomain(updated, forName: domain)
    }
}
