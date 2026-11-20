import Foundation

/// Where and how this copy of the app runs, as far as installing an update over it goes
/// (docs/design/in-app-update.md, section 3).
public struct RunningApp: Equatable, Sendable {
    /// The bundle, with symbolic links resolved: the update replaces what is really there.
    public var bundleURL: URL
    /// The Developer ID team the app is signed by; nil for ad-hoc builds.
    public var teamIdentifier: String?
    /// Opened straight from a download, macOS runs a read-only copy under a random path.
    public var isTranslocated: Bool
    /// The bundle can be moved away and replaced: its folder and the bundle itself are writable.
    public var canReplace: Bool

    public static func inspect(bundleURL: URL, teamIdentifier: String?, fileManager: FileManager = .default) -> RunningApp {
        let bundle = bundleURL.resolvingSymlinksInPath()
        let folder = bundle.deletingLastPathComponent()
        return RunningApp(bundleURL: bundle,
                          teamIdentifier: teamIdentifier,
                          isTranslocated: bundle.path.contains("/AppTranslocation/"),
                          canReplace: fileManager.isWritableFile(atPath: folder.path)
                              && fileManager.isWritableFile(atPath: bundle.path))
    }
}

/// Why an update can only be offered as a link to its release page.
public enum InstallBlocker: Equatable, Sendable {
    /// The release changes the data format, needs a step upgrade, or its compatibility is unknown:
    /// install.sh, which backs up first, has to do it.
    case releaseNeedsInstaller
    /// The release has no `GoldenPassport-<version>.zip`.
    case noPackage
    /// This copy has no Developer ID team (ad-hoc and Dev builds), so nothing can be verified against it.
    case notReleaseBuild
    case translocated
    case notWritable(path: String)
}

public enum UpdateAction: Equatable, Sendable {
    case install(UpdatePackage)
    case releasePageOnly(InstallBlocker)
}

extension AvailableUpdate {
    /// The first condition of section 3 that fails, in the order the dialog explains them.
    public func action(for app: RunningApp) -> UpdateAction {
        guard notices.isEmpty else { return .releasePageOnly(.releaseNeedsInstaller) }
        guard let package else { return .releasePageOnly(.noPackage) }
        guard app.teamIdentifier != nil else { return .releasePageOnly(.notReleaseBuild) }
        guard !app.isTranslocated else { return .releasePageOnly(.translocated) }
        guard app.canReplace else { return .releasePageOnly(.notWritable(path: app.bundleURL.path)) }
        return .install(package)
    }
}
