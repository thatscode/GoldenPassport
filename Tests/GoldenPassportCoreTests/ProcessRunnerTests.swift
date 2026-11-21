import Foundation
import Testing
@testable import GoldenPassportCore

struct ProcessRunnerTests {
    static let sh = URL(fileURLWithPath: "/bin/sh")

    @Test func capturesOutputAndStatus() throws {
        let result = try ProcessRunner.run(Self.sh, ["-c", "echo out; echo err >&2; exit 3"], timeout: 10)
        #expect(result.status == 3)
        #expect(result.output.contains("out"))
        #expect(result.output.contains("err"))
    }

    @Test func timesOutAndStopsTheProcess() throws {
        let start = Date()
        #expect(throws: ProcessRunnerError.timedOut) {
            try ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), ["30"], timeout: 0.3)
        }
        #expect(Date().timeIntervalSince(start) < 1.5)
    }

    @Test func stopsAProcessThatIgnoresTerminate() throws {
        let start = Date()
        #expect(throws: ProcessRunnerError.timedOut) {
            try ProcessRunner.run(Self.sh, ["-c", "trap '' TERM; sleep 30"], timeout: 0.3)
        }
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func handlesLargeOutput() throws {
        let result = try ProcessRunner.run(Self.sh, ["-c", "head -c 1048576 /dev/zero | tr '\\000' a"], timeout: 10)
        #expect(result.status == 0)
        #expect(result.output.utf8.count == 1_048_576)
    }

    @Test func reportsExecutablesThatCannotStart() {
        #expect(throws: ProcessRunnerError.self) {
            try ProcessRunner.run(URL(fileURLWithPath: "/nonexistent/tool"), [], timeout: 1)
        }
    }

    @Test func dittoCopiesAndUnzipsPathsWithSpacesAndChinese() throws {
        let root = try makeTempDirectory()
        let source = root.appendingPathComponent("源 目录", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: source.appendingPathComponent("a b.txt"))

        let copy = root.appendingPathComponent("副本 目录", isDirectory: true)
        try Ditto.copy(source, to: copy)
        #expect(try String(contentsOf: copy.appendingPathComponent("a b.txt"), encoding: .utf8) == "hello")

        let zip = root.appendingPathComponent("包 1.zip")
        _ = try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-c", "-k", "--keepParent", source.path, zip.path], timeout: 30)
        let unpacked = root.appendingPathComponent("解 压", isDirectory: true)
        try Ditto.unzip(zip, into: unpacked)
        #expect(try String(contentsOf: unpacked.appendingPathComponent("源 目录/a b.txt"), encoding: .utf8) == "hello")
    }

    @Test func dittoFailuresAreFileOperationErrors() async throws {
        let root = try makeTempDirectory()
        let notAZip = root.appendingPathComponent("broken.zip")
        try Data("<html>login</html>".utf8).write(to: notAZip)
        await expectUpdateError("fileOperation") {
            try Ditto.unzip(notAZip, into: root.appendingPathComponent("out"))
        }
    }

    // MARK: Data check

    @Test(arguments: ["status=already-migrated", "status=no-data"])
    func acceptsUnchangedData(line: String) throws {
        try DataCheck.evaluate(ProcessResult(status: 0, output: "data_dir=/x\n\(line)\nstorage=keychain\n"), expectedStorage: "keychain")
    }

    @Test func rejectsMigrationsFailuresAndMissingStatus() async {
        let failures = [ProcessResult(status: 0, output: "status=migrated\nstorage=keychain"),
                        ProcessResult(status: 3, output: "status=already-migrated\nstorage=keychain"),
                        ProcessResult(status: 0, output: "")]
        for result in failures {
            await expectUpdateError("dataCheck") {
                try DataCheck.evaluate(result, expectedStorage: "keychain")
            }
        }
    }

    @Test func rejectsTheWrongStorage() {
        #expect(throws: UpdateError.dataCheck("exit=0 status=no-data storage=file")) {
            try DataCheck.evaluate(ProcessResult(status: 0, output: "status=no-data\nstorage=file"), expectedStorage: "keychain")
        }
    }

    /// A bundle whose executable is a shell script, as `DataCheck.run` finds it through Info.plist.
    static func fakeApp(script: String) throws -> URL {
        let app = try makeTempDirectory().appendingPathComponent("Fake.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleExecutable": "Fake"]
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let executable = macOS.appendingPathComponent("Fake")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return app
    }

    @Test func runsTheBundledExecutableWithMigrateData() throws {
        let app = try Self.fakeApp(script: """
            #!/bin/sh
            [ "$1" = "--migrate-data" ] || exit 9
            echo status=already-migrated
            echo storage=keychain
            """)
        try DataCheck.run(app: app, expectedStorage: "keychain")
        #expect(throws: UpdateError.dataCheck("exit=0 status=already-migrated storage=keychain")) {
            try DataCheck.run(app: app, expectedStorage: "file")
        }
    }

    @Test func slowDataChecksTimeOut() throws {
        let app = try Self.fakeApp(script: "#!/bin/sh\nsleep 5\n")
        #expect(throws: UpdateError.dataCheckTimedOut) {
            try DataCheck.run(app: app, expectedStorage: "keychain", timeout: 0.3)
        }
    }
}
