import CryptoKit
import Foundation

/// Checks on a downloaded update before anything is replaced (docs/design/in-app-update.md, 5.2 and 5.3).
public enum UpdatePackageCheck {
    /// The size and SHA-256 GitHub reported for the asset, each only when it was reported.
    public static func verifyDownload(at file: URL, package: UpdatePackage) throws {
        if let expected = package.size {
            let actual = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? -1
            guard actual == expected else { throw UpdateError.sizeMismatch(expected: expected, actual: actual) }
        }
        if let expected = package.sha256 {
            guard try sha256(of: file) == expected else { throw UpdateError.digestMismatch }
        }
    }

    private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The release zip holds `GoldenPassport-<version>/GoldenPassport.app` and nothing else by that name.
    public static func findApp(inUnpacked directory: URL, version: AppVersion) throws -> URL {
        let fm = FileManager.default
        let appName = "GoldenPassport.app"
        var found: [URL] = []
        for entry in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            if entry.lastPathComponent == appName { found.append(entry) }
            for inner in (try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? []
            where inner.lastPathComponent == appName {
                found.append(inner)
            }
        }
        let expected = directory.appendingPathComponent("GoldenPassport-\(version)", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
        // Directory listings report /private/var for /var: compare resolved paths, return the caller's form.
        guard found.count == 1, found[0].resolvingSymlinksInPath().path == expected.resolvingSymlinksInPath().path else {
            throw UpdateError.appNotFound
        }
        return expected
    }

    /// What the new bundle's Info.plist has to say for it to replace this copy.
    public struct Expectations {
        public var bundleIdentifier: String
        /// Exactly the version the update check offered.
        public var version: AppVersion
        /// The version running now; the package must be newer.
        public var current: AppVersion
        public var dataDirectoryName: String?
        public var keychainService: String?
        public var systemVersion: AppVersion
        public var architecture: String

        public init(bundleIdentifier: String, version: AppVersion, current: AppVersion, dataDirectoryName: String?,
                    keychainService: String?, systemVersion: AppVersion, architecture: String) {
            self.bundleIdentifier = bundleIdentifier
            self.version = version
            self.current = current
            self.dataDirectoryName = dataDirectoryName
            self.keychainService = keychainService
            self.systemVersion = systemVersion
            self.architecture = architecture
        }
    }

    /// Guards against publishing the wrong bundle (a Dev build, another storage, another version).
    /// The signature check, not this, is what makes the bundle trustworthy.
    public static func checkInfo(_ info: [String: Any], architectures: [String], expectations: Expectations) throws {
        func text(_ key: String) -> String? { (info[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func normalized(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }

        guard text("CFBundleIdentifier") == expectations.bundleIdentifier else {
            throw UpdateError.wrongPackage("CFBundleIdentifier")
        }
        guard let version = AppVersion(bundleInfo: info), version == expectations.version else {
            throw UpdateError.wrongPackage("version")
        }
        guard text("GPDataDirectoryName") == normalized(expectations.dataDirectoryName) else {
            throw UpdateError.wrongPackage("GPDataDirectoryName")
        }
        guard text("GPKeychainService") == normalized(expectations.keychainService) else {
            throw UpdateError.wrongPackage("GPKeychainService")
        }
        if let minimum = text("LSMinimumSystemVersion") {
            guard let required = AppVersion(minimum) else { throw UpdateError.wrongPackage("LSMinimumSystemVersion") }
            guard !(expectations.systemVersion < required) else { throw UpdateError.needsNewerSystem(minimum) }
        }
        guard architectures.contains(expectations.architecture) else {
            throw UpdateError.missingArchitecture(expectations.architecture)
        }
        guard expectations.current < version else { throw UpdateError.notNewer }
    }

    /// The architectures in a Mach-O executable, read from its header. `lipo` would do, but on a Mac
    /// without the command line tools it only offers to install them.
    public static func architectures(ofExecutableAt url: URL) throws -> [String] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = [UInt8](try handle.read(upToCount: 4096) ?? Data())
        func bigEndian(_ offset: Int) -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            return bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        func littleEndian(_ offset: Int) -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            return bytes[offset..<offset + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
        }
        func name(_ cpuType: UInt32) -> String? {
            switch cpuType {
            case 0x0100_000c: return "arm64"
            case 0x0100_0007: return "x86_64"
            default: return nil
            }
        }

        switch bigEndian(0) {
        case 0xcafe_babe, 0xcafe_babf:
            // fat_arch is 20 bytes, fat_arch_64 32; both start with cputype.
            let stride = bigEndian(0) == 0xcafe_babe ? 20 : 32
            guard let count = bigEndian(4), count > 0, count < 32 else { break }
            return (0..<Int(count)).compactMap { bigEndian(8 + $0 * stride).flatMap(name) }
        default:
            if littleEndian(0) == 0xfeed_facf, let cpuType = littleEndian(4) {
                return name(cpuType).map { [$0] } ?? []
            }
        }
        throw UpdateError.wrongPackage("executable")
    }

    public static let currentArchitecture: String = {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }()

    /// The code requirement from design 5.3: a notarized Developer ID build of this bundle id by this team.
    public static func requirement(bundleIdentifier: String, teamIdentifier: String) -> String {
        func quoted(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return "anchor apple generic and identifier \(quoted(bundleIdentifier))"
            + " and certificate leaf[subject.OU] = \(quoted(teamIdentifier))"
            + " and certificate 1[field.1.2.840.113635.100.6.2.6]"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13]"
            + " and notarized"
    }
}
