import Foundation

/// The numbered steps of design 5.4, all taken while the old app still runs.
public enum InstallStep: Int, Sendable, CaseIterable {
    case stage = 1, verify, checkData, trashOld, moveNew, launch
}

/// What the installer does to the file system and the outside world; injected so every failure
/// point can be tested.
public protocol UpdateInstallOperations {
    func removeIfPresent(_ url: URL) throws
    func copy(_ source: URL, to destination: URL) throws
    func verify(_ app: URL) throws
    func checkData(_ app: URL) throws
    /// Throws when quitting now would lose something, such as input in an open window.
    func readyToQuit() throws
    /// Moves `url` to the Trash and returns where it ended up.
    func trash(_ url: URL) throws -> URL
    func move(_ source: URL, to destination: URL) throws
    func launch(_ app: URL, arguments: [String]) throws
}

public struct InstallFailure: Error {
    public let step: InstallStep
    public let underlying: Error
    /// Whether the old app is back where it was. If not, `previousAppInTrash` says where it is.
    public let restored: Bool
    public let previousAppInTrash: URL?
}

/// Swaps the running app's bundle for a new one (design 5.4). Only creates a new bundle and renames;
/// it never writes inside an existing one.
public struct UpdateInstaller {
    private let target: URL
    private let launchArguments: UpdateLaunchArguments
    private let operations: UpdateInstallOperations
    private let progress: (InstallStep) -> Void

    public init(target: URL, launchArguments: UpdateLaunchArguments, operations: UpdateInstallOperations,
                progress: @escaping (InstallStep) -> Void = { _ in }) {
        self.target = target
        self.launchArguments = launchArguments
        self.operations = operations
        self.progress = progress
    }

    /// Next to the target, on the same volume, so the final rename is atomic. Not ending in ".app",
    /// Launch Services never takes it for an app.
    public static func stagingURL(for target: URL) -> URL {
        target.deletingLastPathComponent().appendingPathComponent(".GoldenPassport.app.updating", isDirectory: true)
    }

    /// Steps 1–6. On failure, undoes what was done and throws `InstallFailure`; afterwards the caller
    /// quits (step 7) so the new copy can take over.
    public func install(from unpackedApp: URL) throws {
        let staging = Self.stagingURL(for: target)
        let operations = self.operations
        let removeStaging = { try operations.removeIfPresent(staging) }

        try run(.stage, restore: [removeStaging], previous: nil) {
            try operations.removeIfPresent(staging)
            try operations.copy(unpackedApp, to: staging)
        }
        try run(.verify, restore: [removeStaging], previous: nil) { try operations.verify(staging) }
        try run(.checkData, restore: [removeStaging], previous: nil) { try operations.checkData(staging) }

        var previous: URL?
        try run(.trashOld, restore: [removeStaging], previous: nil) {
            try operations.readyToQuit()
            previous = try operations.trash(target)
        }
        guard let previous else { return }

        let target = self.target
        try run(.moveNew, restore: [{ try operations.move(previous, to: target) }, removeStaging], previous: previous) {
            try operations.move(staging, to: target)
        }
        try run(.launch, restore: [{ _ = try operations.trash(target) }, { try operations.move(previous, to: target) }],
                previous: previous) {
            try operations.launch(target, arguments: launchArguments.arguments)
        }
    }

    /// Runs one step; if it throws, tries every restore action in order (even after one fails).
    private func run(_ step: InstallStep, restore: [() throws -> Void], previous: URL?, _ body: () throws -> Void) throws {
        progress(step)
        do {
            try body()
        } catch {
            var restored = true
            for action in restore {
                do { try action() } catch { restored = false }
            }
            throw InstallFailure(step: step, underlying: error, restored: restored, previousAppInTrash: previous)
        }
    }
}

/// The real file operations; checks, readiness and launching come from the app.
public struct FileSystemInstallOperations: UpdateInstallOperations {
    private let verifyApp: (URL) throws -> Void
    private let checkAppData: (URL) throws -> Void
    private let checkReadyToQuit: () throws -> Void
    private let launchApp: (URL, [String]) throws -> Void
    private let trashItem: (URL) throws -> URL

    public init(verify: @escaping (URL) throws -> Void, checkData: @escaping (URL) throws -> Void,
                readyToQuit: @escaping () throws -> Void, launch: @escaping (URL, [String]) throws -> Void,
                trash: @escaping (URL) throws -> URL = FileSystemInstallOperations.moveToTrash) {
        verifyApp = verify
        checkAppData = checkData
        checkReadyToQuit = readyToQuit
        launchApp = launch
        trashItem = trash
    }

    /// The volume's own Trash; volumes without one (some network shares) throw.
    public static func moveToTrash(_ url: URL) throws -> URL {
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        } catch {
            throw UpdateError.fileOperation(error.localizedDescription)
        }
        guard let resulting else { throw UpdateError.fileOperation("trash: \(url.path)") }
        return resulting as URL
    }

    public func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw UpdateError.fileOperation(error.localizedDescription)
        }
    }

    public func copy(_ source: URL, to destination: URL) throws { try Ditto.copy(source, to: destination) }
    public func verify(_ app: URL) throws { try verifyApp(app) }
    public func checkData(_ app: URL) throws { try checkAppData(app) }
    public func readyToQuit() throws { try checkReadyToQuit() }
    public func trash(_ url: URL) throws -> URL { try trashItem(url) }

    public func move(_ source: URL, to destination: URL) throws {
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            throw UpdateError.fileOperation(error.localizedDescription)
        }
    }

    public func launch(_ app: URL, arguments: [String]) throws { try launchApp(app, arguments) }
}

/// `--after-update <pid> --updated-from <version>`, passed to the new copy (design 5.5).
public struct UpdateLaunchArguments: Equatable, Sendable {
    public var oldProcessID: Int32?
    public var updatedFrom: String?

    public init(arguments: [String]) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        oldProcessID = value(after: "--after-update").flatMap { Int32($0) }.flatMap { $0 > 0 ? $0 : nil }
        updatedFrom = value(after: "--updated-from").flatMap { AppVersion($0) == nil ? nil : $0 }
    }

    public init(oldProcessID: Int32, updatedFrom: String) {
        self.oldProcessID = oldProcessID
        self.updatedFrom = updatedFrom
    }

    public var arguments: [String] {
        (oldProcessID.map { ["--after-update", String($0)] } ?? []) + (updatedFrom.map { ["--updated-from", $0] } ?? [])
    }

    /// Whether a process with this id exists. EPERM means it does, only under another user.
    public static func processExists(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Polls on the current run loop until `isRunning` says the process is gone (`completion(true)`)
    /// or `timeout` passes (`completion(false)`). Returns at once: the old copy quits only after
    /// Launch Services reports that the new copy finished launching, so a new copy that blocked
    /// here would hold the old one up for the whole timeout.
    public static func whenExited(of pid: Int32, timeout: TimeInterval = 10,
                                  isRunning: @escaping (Int32) -> Bool = UpdateLaunchArguments.processExists,
                                  completion: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            if !isRunning(pid) {
                timer.invalidate()
                completion(true)
            } else if Date() >= deadline {
                timer.invalidate()
                completion(false)
            }
        }
        RunLoop.current.add(timer, forMode: .common)
    }
}
