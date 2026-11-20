import Foundation

/// A version such as "0.2.0" or "0.3.0-beta.1". A leading "v", as in tag names, is ignored.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    /// Major, minor and patch; missing parts count as 0.
    public let numbers: [Int]
    public let prerelease: String?

    public init?(_ string: String) {
        var text = Substring(string.trimmingCharacters(in: .whitespacesAndNewlines))
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(numbers.count), numbers.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        self.numbers = numbers.compactMap { $0 } + Array(repeating: 0, count: 3 - numbers.count)
        prerelease = parts.count > 1 ? String(parts[1]) : nil
        if prerelease?.isEmpty == true { return nil }
    }

    /// The version a bundle reports: CFBundleShortVersionString plus, for beta packages, the
    /// GPPrerelease label (scripts/package.sh <label>), as in "0.2.0-beta.3". A beta then counts
    /// as older than the release it leads up to, so the update check offers that release.
    public init?(bundleInfo info: [String: Any]) {
        guard let version = info["CFBundleShortVersionString"] as? String else { return nil }
        if let label = info["GPPrerelease"] as? String, !label.isEmpty {
            self.init("\(version)-\(label)")
        } else {
            self.init(version)
        }
    }

    public var description: String {
        numbers.map(String.init).joined(separator: ".") + (prerelease.map { "-\($0)" } ?? "")
    }

    /// As in Semantic Versioning, a pre-release comes before the release itself.
    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        switch (lhs.prerelease, rhs.prerelease) {
        case let (l?, r?): return l.compare(r, options: .numeric) == .orderedAscending
        case (_?, nil): return true
        default: return false
        }
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

/// The `compat.json` asset attached to every release (docs/compatibility.md, section 5).
public struct ReleaseCompatibility: Decodable, Equatable, Sendable {
    public var dataFormat: Int?
    public var minUpgradeFrom: String?
}

/// The release zip, as attached to the release (`GoldenPassport-<version>.zip`).
public struct UpdatePackage: Equatable, Sendable {
    public var url: URL
    /// From GitHub's asset metadata; nil when it was not reported.
    public var size: Int?
    /// Lowercase hex SHA-256 from GitHub's asset `digest` ("sha256:…"); nil when absent or in another form.
    public var sha256: String?

    public init(url: URL, size: Int?, sha256: String?) {
        self.url = url
        self.size = size
        self.sha256 = sha256
    }
}

public struct AvailableUpdate: Equatable, Sendable {
    public enum Notice: Equatable, Sendable {
        /// The release converts the accounts to a newer data format.
        case dataFormatChange
        /// This version cannot upgrade to the release directly; `version` must be installed first.
        case upgradeFirst(version: String, releasePage: URL)
        /// The release has no readable compat.json, so its compatibility is unknown.
        case compatibilityUnknown
    }

    public var version: String
    public var releasePage: URL
    public var notices: [Notice]
    /// The zip to install from the app; nil when the release has none under the expected name.
    public var package: UpdatePackage? = nil
}

public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate
    case available(AvailableUpdate)
}

public enum UpdateCheckError: Error, Equatable, LocalizedError {
    case httpStatus(Int)
    case unreadableResponse
    case unrecognizedVersion(String)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let status): return String(localized: "GitHub 返回了错误（HTTP \(status)），请稍后再试。")
        case .unreadableResponse: return String(localized: "无法识别 GitHub 返回的内容。")
        case .unrecognizedVersion(let tag): return String(localized: "无法识别最新版本的版本号：\(tag)")
        }
    }
}

/// Asks GitHub for the latest release. All network access goes through `fetch`.
public struct UpdateChecker: Sendable {
    public typealias Fetch = @Sendable (URL) async throws -> (Data, HTTPURLResponse)

    /// Drafts and pre-releases are never returned as "latest".
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/thatscode/GoldenPassport/releases/latest")!

    /// The release asset the app installs (docs/compatibility.md, section 6).
    public static func packageAssetName(for version: AppVersion) -> String {
        "GoldenPassport-\(version).zip"
    }

    /// `GP_UPDATE_FEED_URL` points the check at another latest-release document, for testing the
    /// update flow end to end. Whatever it serves still has to pass the signature check.
    public static func feedURL(environment: [String: String]) -> URL {
        guard let text = environment["GP_UPDATE_FEED_URL"], !text.isEmpty, let url = URL(string: text) else {
            return latestReleaseURL
        }
        return url
    }

    private let currentVersion: AppVersion
    /// The data format this build stores accounts in (`AppEnvironment.dataFormat`).
    private let dataFormat: Int
    private let latestReleaseURL: URL
    private let fetch: Fetch

    public init(currentVersion: AppVersion, dataFormat: Int = AccountStore.dataFormat,
                latestReleaseURL: URL = UpdateChecker.latestReleaseURL, fetch: @escaping Fetch) {
        self.currentVersion = currentVersion
        self.dataFormat = dataFormat
        self.latestReleaseURL = latestReleaseURL
        self.fetch = fetch
    }

    public func check() async throws -> UpdateCheckResult {
        let (data, response) = try await fetch(latestReleaseURL)
        // GitHub answers 404 until the first release is published.
        if response.statusCode == 404 { return .upToDate }
        guard response.statusCode == 200 else { throw UpdateCheckError.httpStatus(response.statusCode) }
        guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
            throw UpdateCheckError.unreadableResponse
        }
        guard let latest = AppVersion(release.tagName) else {
            throw UpdateCheckError.unrecognizedVersion(release.tagName)
        }
        guard currentVersion < latest else { return .upToDate }
        let compatibility = await self.compatibility(of: release)
        return .available(AvailableUpdate(version: latest.description, releasePage: release.htmlURL,
                                          notices: notices(for: compatibility, of: release),
                                          package: package(of: release, version: latest)))
    }

    private func package(of release: GitHubRelease, version: AppVersion) -> UpdatePackage? {
        let name = Self.packageAssetName(for: version)
        guard let asset = release.assets.first(where: { $0.name == name }) else { return nil }
        return UpdatePackage(url: asset.browserDownloadURL, size: asset.size, sha256: asset.digest.flatMap { Self.sha256(fromDigest: $0) })
    }

    /// "sha256:<64 hex digits>" → the digits in lowercase; anything else → nil.
    private static func sha256(fromDigest digest: String) -> String? {
        let prefix = "sha256:"
        guard digest.lowercased().hasPrefix(prefix) else { return nil }
        let hex = digest.dropFirst(prefix.count).lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex
    }

    private func compatibility(of release: GitHubRelease) async -> ReleaseCompatibility? {
        guard let asset = release.assets.first(where: { $0.name == "compat.json" }),
              let download = try? await fetch(asset.browserDownloadURL),
              download.1.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(ReleaseCompatibility.self, from: download.0)
    }

    private func notices(for compatibility: ReleaseCompatibility?, of release: GitHubRelease) -> [AvailableUpdate.Notice] {
        guard let compatibility, let dataFormat = compatibility.dataFormat else { return [.compatibilityUnknown] }
        var notices: [AvailableUpdate.Notice] = []
        if dataFormat > self.dataFormat {
            notices.append(.dataFormatChange)
        }
        if let text = compatibility.minUpgradeFrom {
            guard let minimum = AppVersion(text) else { return notices + [.compatibilityUnknown] }
            if currentVersion < minimum {
                // Tags are "v<version>" (docs/compatibility.md, 5.1), so the page sits next to the latest one.
                let page = release.htmlURL.deletingLastPathComponent().appendingPathComponent("v\(minimum)")
                notices.append(.upgradeFirst(version: minimum.description, releasePage: page))
            }
        }
        return notices
    }
}

extension UpdateChecker {
    /// Requests identify themselves only as "GoldenPassport/<version>": an ephemeral session keeps
    /// no cookies, cache or credentials, and Accept-Language is fixed because URLSession would
    /// otherwise send the user's preferred languages.
    public static func networkFetch(appVersion: String) -> Fetch {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["User-Agent": "GoldenPassport/\(appVersion)", "Accept-Language": "en"]
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        return { url in
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { throw UpdateCheckError.unreadableResponse }
            return (data, http)
        }
    }
}

/// The fields of GitHub's latest-release response that the check uses.
struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        let size: Int?
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size, digest
        }
    }

    let tagName: String
    let htmlURL: URL
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}
