import Foundation
import Security

/// Code signature checks for updates (docs/design/in-app-update.md, 5.3): the new bundle must be a
/// notarized Developer ID build of the same team as the running app.
public enum CodeSignature {
    /// The Developer ID team of the running app; nil for ad-hoc builds.
    public static func teamIdentifierOfRunningApp() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return teamIdentifier(of: staticCode)
    }

    public static func teamIdentifier(ofBundleAt url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return teamIdentifier(of: staticCode)
    }

    private static func teamIdentifier(of code: SecStaticCode) -> String? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    public static func compile(requirement: String) throws {
        _ = try makeRequirement(requirement)
    }

    /// Validates every file the signature seals, in every architecture and nested bundle, against `requirement`.
    public static func verify(bundleAt url: URL, requirement text: String) throws {
        let requirement = try makeRequirement(text)
        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard status == errSecSuccess, let staticCode else { throw UpdateError.signature(message(status)) }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        status = SecStaticCodeCheckValidity(staticCode, flags, requirement)
        guard status == errSecSuccess else { throw UpdateError.signature(message(status)) }
    }

    private static func makeRequirement(_ text: String) throws -> SecRequirement {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(text as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else { throw UpdateError.signature(message(status)) }
        return requirement
    }

    private static func message(_ status: OSStatus) -> String {
        let text = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus"
        return "\(text) (\(status))"
    }
}
