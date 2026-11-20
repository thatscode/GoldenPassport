import Foundation
import Testing
@testable import GoldenPassportCore

/// Records each operation as a short line ("copy src→S") and fails the ones `fails` picks.
final class FakeInstallOperations: UpdateInstallOperations {
    static let target = URL(fileURLWithPath: "/x/Apps/GoldenPassport.app")
    static let staging = URL(fileURLWithPath: "/x/Apps/.GoldenPassport.app.updating")
    static let source = URL(fileURLWithPath: "/x/unpacked/GoldenPassport-0.2.4/GoldenPassport.app")
    static let trashed = URL(fileURLWithPath: "/x/.Trash/GoldenPassport.app")
    static let trashedNew = URL(fileURLWithPath: "/x/.Trash/GoldenPassport 2.app")

    var calls: [String] = []
    var fails: (String) -> Bool
    private var trashCount = 0

    init(fails: @escaping (String) -> Bool = { _ in false }) {
        self.fails = fails
    }

    /// By path: a URL made with `isDirectory: true` compares unequal to the same path without it.
    private func label(_ url: URL) -> String {
        let labels = [Self.target: "T", Self.staging: "S", Self.source: "src", Self.trashed: "R", Self.trashedNew: "R2"]
        return labels.first { $0.key.path == url.path }?.value ?? url.path
    }

    private func record(_ call: String) throws {
        calls.append(call)
        if fails(call) { throw UpdateError.fileOperation(call) }
    }

    func removeIfPresent(_ url: URL) throws { try record("remove \(label(url))") }
    func copy(_ source: URL, to destination: URL) throws { try record("copy \(label(source))→\(label(destination))") }
    func verify(_ app: URL) throws { try record("verify \(label(app))") }
    func checkData(_ app: URL) throws { try record("checkData \(label(app))") }
    func readyToQuit() throws {
        calls.append("readyToQuit")
        if fails("readyToQuit") { throw UpdateError.windowsOpen }
    }
    func trash(_ url: URL) throws -> URL {
        try record("trash \(label(url))")
        trashCount += 1
        return trashCount == 1 ? Self.trashed : Self.trashedNew
    }
    func move(_ source: URL, to destination: URL) throws { try record("move \(label(source))→\(label(destination))") }
    func launch(_ app: URL, arguments: [String]) throws { try record((["launch", label(app)] + arguments).joined(separator: " ")) }
}

struct UpdateInstallerTests {
    static let arguments = UpdateLaunchArguments(oldProcessID: 42, updatedFrom: "0.2.3")

    /// Runs an install with `fake`; returns the steps reported to `progress` and the failure, if any.
    static func install(_ fake: FakeInstallOperations) -> (steps: [InstallStep], failure: InstallFailure?) {
        var steps: [InstallStep] = []
        let installer = UpdateInstaller(target: FakeInstallOperations.target, launchArguments: arguments,
                                        operations: fake, progress: { steps.append($0) })
        do {
            try installer.install(from: FakeInstallOperations.source)
            return (steps, nil)
        } catch let failure as InstallFailure {
            return (steps, failure)
        } catch {
            Issue.record("unexpected error \(error)")
            return (steps, nil)
        }
    }

    @Test func stagingSitsNextToTheTarget() {
        #expect(UpdateInstaller.stagingURL(for: URL(fileURLWithPath: "/Applications/GoldenPassport 2.app")).path
            == "/Applications/.GoldenPassport.app.updating")
    }

    @Test func happyPathRunsStepsInOrder() {
        let fake = FakeInstallOperations()
        let result = Self.install(fake)
        #expect(result.failure == nil)
        #expect(fake.calls == ["remove S", "copy src→S", "verify S", "checkData S", "readyToQuit", "trash T",
                               "move S→T", "launch T --after-update 42 --updated-from 0.2.3"])
        #expect(result.steps == InstallStep.allCases)
    }

    @Test(arguments: [("copy src→S", InstallStep.stage), ("verify S", .verify), ("checkData S", .checkData),
                      ("readyToQuit", .trashOld), ("trash T", .trashOld)])
    func failuresBeforeTheMoveLeaveTheOldAppInPlace(failing: String, step: InstallStep) throws {
        let fake = FakeInstallOperations(fails: { $0 == failing })
        let failure = try #require(Self.install(fake).failure)
        #expect(failure.step == step)
        #expect(failure.restored)
        #expect(failure.previousAppInTrash == nil)
        #expect(fake.calls.last == "remove S")
        #expect(!fake.calls.contains { $0.hasPrefix("move") || $0.hasPrefix("launch") })
    }

    @Test func windowOpenedDuringDownloadStopsBeforeTrash() throws {
        let fake = FakeInstallOperations(fails: { $0 == "readyToQuit" })
        let failure = try #require(Self.install(fake).failure)
        #expect(failure.step == .trashOld)
        #expect(failure.underlying as? UpdateError == .windowsOpen)
        #expect(!fake.calls.contains("trash T"))
    }

    @Test func failedMovePutsTheOldAppBack() throws {
        let fake = FakeInstallOperations(fails: { $0 == "move S→T" })
        let failure = try #require(Self.install(fake).failure)
        #expect(failure.step == .moveNew)
        #expect(failure.restored)
        #expect(Array(fake.calls.suffix(3)) == ["move S→T", "move R→T", "remove S"])
    }

    @Test func failedLaunchRestoresTheOldApp() throws {
        let fake = FakeInstallOperations(fails: { $0.hasPrefix("launch") })
        let failure = try #require(Self.install(fake).failure)
        #expect(failure.step == .launch)
        #expect(failure.restored)
        #expect(Array(fake.calls.suffix(2)) == ["trash T", "move R→T"])
    }

    @Test func failedRestoreIsReported() throws {
        let fake = FakeInstallOperations(fails: { $0 == "move S→T" || $0 == "move R→T" })
        let failure = try #require(Self.install(fake).failure)
        #expect(failure.step == .moveNew)
        #expect(!failure.restored)
        #expect(failure.previousAppInTrash == FakeInstallOperations.trashed)
    }

    @Test func replacesTheAppInPlaceOnDisk() throws {
        let root = try makeTempDirectory()
        let apps = root.appendingPathComponent("Apps 应用", isDirectory: true)
        let target = apps.appendingPathComponent("GoldenPassport 2.app", isDirectory: true)
        let staleStaging = apps.appendingPathComponent(".GoldenPassport.app.updating", isDirectory: true)
        let source = root.appendingPathComponent("unpacked/GoldenPassport-0.2.4/GoldenPassport.app", isDirectory: true)
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        for (dir, marker) in [(target, "old"), (staleStaging, "stale"), (source, "new")] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try Data(marker.utf8).write(to: dir.appendingPathComponent("Contents/marker"))
        }
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)

        var launched: [String] = []
        let operations = FileSystemInstallOperations(
            verify: { _ in }, checkData: { _ in }, readyToQuit: {},
            launch: { app, arguments in launched = [app.lastPathComponent] + arguments },
            trash: { url in
                let destination = trash.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            })
        try UpdateInstaller(target: target, launchArguments: Self.arguments, operations: operations).install(from: source)

        func marker(_ app: URL) throws -> String {
            try String(contentsOf: app.appendingPathComponent("Contents/marker"), encoding: .utf8)
        }
        #expect(try marker(target) == "new")
        #expect(try marker(trash.appendingPathComponent("GoldenPassport 2.app")) == "old")
        #expect(!FileManager.default.fileExists(atPath: staleStaging.path))
        #expect(launched == ["GoldenPassport 2.app", "--after-update", "42", "--updated-from", "0.2.3"])
    }

    @Test func launchArgumentsRoundTrip() {
        let args = UpdateLaunchArguments(oldProcessID: 42, updatedFrom: "0.2.3")
        #expect(args.arguments == ["--after-update", "42", "--updated-from", "0.2.3"])
        #expect(UpdateLaunchArguments(arguments: ["/x/GoldenPassport"] + args.arguments) == args)
        #expect(UpdateLaunchArguments(arguments: ["/x", "--after-update", "abc"]).oldProcessID == nil)
        #expect(UpdateLaunchArguments(arguments: ["/x", "--after-update", "-5"]).oldProcessID == nil)
        #expect(UpdateLaunchArguments(arguments: ["/x", "--updated-from", "garbage"]).updatedFrom == nil)
        #expect(UpdateLaunchArguments(arguments: ["/x", "--after-update"]) == UpdateLaunchArguments(arguments: []))
        #expect(UpdateLaunchArguments(arguments: []).arguments.isEmpty)
    }

    @Test func waitsUntilTheOldProcessExits() {
        var checks = 0
        let exited = UpdateLaunchArguments.waitForExit(of: 42, timeout: 5) { pid in
            #expect(pid == 42)
            checks += 1
            return checks <= 3
        }
        #expect(exited)
        #expect(checks == 4)
    }

    @Test func processExistsCountsProcessesOfOtherUsers() throws {
        #expect(UpdateLaunchArguments.processExists(getpid()))
        // launchd runs as root: kill(1, 0) fails with EPERM, yet the process is there.
        #expect(UpdateLaunchArguments.processExists(1))
        let finished = try ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo $$"], timeout: 10)
        let pid = try #require(Int32(finished.output.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(!UpdateLaunchArguments.processExists(pid))
    }

    @Test func givesUpAfterTheTimeout() {
        let start = Date()
        #expect(!UpdateLaunchArguments.waitForExit(of: 42, timeout: 0.3) { _ in true })
        #expect(Date().timeIntervalSince(start) < 1)
    }
}
