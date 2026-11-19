import Foundation
import Testing
@testable import GoldenPassportCore

/// The settings 0.1.x and 0.2.0 kept under the old bundle id (0.2.1 moved to a new one).
/// Works on dictionaries, so no test writes to ~/Library/Preferences.
struct LegacyPreferencesTests {
    private let done = LegacyPreferences.doneKey

    @Test func copiesTheLanguageChosenUnderTheOldID() throws {
        let legacy: [String: Any] = ["AppleLanguages": ["en"], "Other": 1]
        let domain = try #require(LegacyPreferences.carriedOver(["AppleLanguages"], legacy: legacy, current: nil))
        #expect(domain["AppleLanguages"] as? [String] == ["en"])
        #expect(domain["Other"] == nil, "only the keys asked for")
        #expect(domain[done] as? Bool == true)
    }

    @Test func keepsWhatTheNewIDAlreadyHas() throws {
        let domain = try #require(LegacyPreferences.carriedOver(
            ["AppleLanguages"], legacy: ["AppleLanguages": ["en"]], current: ["AppleLanguages": ["zh-Hans"], "Kept": "yes"]))
        #expect(domain["AppleLanguages"] as? [String] == ["zh-Hans"])
        #expect(domain["Kept"] as? String == "yes")
    }

    @Test func runsOnlyOnceSoARemovedSettingStaysRemoved() throws {
        let legacy: [String: Any] = ["AppleLanguages": ["en"]]
        var domain = try #require(LegacyPreferences.carriedOver(["AppleLanguages"], legacy: legacy, current: nil))
        domain["AppleLanguages"] = nil // the user picks System Default in the menu
        #expect(LegacyPreferences.carriedOver(["AppleLanguages"], legacy: legacy, current: domain) == nil)
    }

    @Test func marksTheCarryOverDoneEvenWithoutOldSettings() throws {
        let domain = try #require(LegacyPreferences.carriedOver(["AppleLanguages"], legacy: nil, current: nil))
        #expect(domain["AppleLanguages"] == nil)
        #expect(domain[done] as? Bool == true)
    }
}
