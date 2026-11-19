import Foundation
import Testing
@testable import GoldenPassportCore

/// The settings 0.1.x and 0.2.0 kept under the old bundle id (0.2.1 moved to a new one).
/// Works on dictionaries, so no test writes to ~/Library/Preferences.
struct LegacyPreferencesTests {
    private let done = LegacyPreferences.doneKey
    private let position = "NSStatusItem Preferred Position Item-0"
    private let visible = "NSStatusItem Visible Item-0"

    private func carry(_ legacy: [String: Any]?, _ current: [String: Any]?) -> [String: Any]? {
        LegacyPreferences.carriedOver(LegacyPreferences.keys(in: legacy), legacy: legacy, current: current)
    }

    @Test func copiesTheLanguageChosenUnderTheOldID() throws {
        let domain = try #require(carry(["AppleLanguages": ["en"], "Other": 1], nil))
        #expect(domain["AppleLanguages"] as? [String] == ["en"])
        #expect(domain["Other"] == nil, "only the language and the status item settings")
        #expect(domain[done] as? [String] == ["AppleLanguages"])
    }

    /// Without its old position the icon counts as new and may get no room in the menu bar.
    @Test func copiesWhereTheMenuBarIconWasAndWhetherItWasShown() throws {
        let legacy: [String: Any] = [position: 455.0, visible: true, "NSNavPanelExpandedSizeForOpenMode": "{880, 448}"]
        let domain = try #require(carry(legacy, nil))
        #expect(domain[position] as? Double == 455)
        #expect(domain[visible] as? Bool == true)
        #expect(domain["NSNavPanelExpandedSizeForOpenMode"] == nil)
        #expect(Set(domain[done] as? [String] ?? []) == ["AppleLanguages", position, visible])
    }

    @Test func keepsWhatTheNewIDAlreadyHas() throws {
        let domain = try #require(carry(["AppleLanguages": ["en"], position: 455.0],
                                        ["AppleLanguages": ["zh-Hans"], position: 100.0, "Kept": "yes"]))
        #expect(domain["AppleLanguages"] as? [String] == ["zh-Hans"])
        #expect(domain[position] as? Double == 100)
        #expect(domain["Kept"] as? String == "yes")
    }

    @Test func copiesEachKeyOnlyOnceSoARemovedSettingStaysRemoved() throws {
        let legacy: [String: Any] = ["AppleLanguages": ["en"], position: 455.0]
        var domain = try #require(carry(legacy, nil))
        domain["AppleLanguages"] = nil // the user picks System Default in the menu
        #expect(carry(legacy, domain) == nil)
    }

    /// 0.2.1 marked the carry-over done after copying only the language; the icon's position
    /// still comes over.
    @Test func catchesUpAfterTheFirstCarryOverOf021() throws {
        let legacy: [String: Any] = ["AppleLanguages": ["en"], position: 455.0]
        let domain = try #require(carry(legacy, ["AppleLanguages": ["zh-Hans"], done: true]))
        #expect(domain[position] as? Double == 455)
        #expect(domain["AppleLanguages"] as? [String] == ["zh-Hans"])
        #expect(Set(domain[done] as? [String] ?? []) == ["AppleLanguages", position])
    }

    @Test func marksTheCarryOverDoneEvenWithoutOldSettings() throws {
        let domain = try #require(carry(nil, nil))
        #expect(domain["AppleLanguages"] == nil)
        #expect(domain[done] as? [String] == ["AppleLanguages"])
        #expect(carry(nil, domain) == nil)
    }
}
