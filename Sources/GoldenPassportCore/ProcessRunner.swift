import Foundation

public struct ProcessResult: Equatable, Sendable {
    public var status: Int32
    /// Standard output and standard error together.
    public var output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}

public enum ProcessRunnerError: Error, Equatable {
    case timedOut
    case launchFailed(String)
}

/// Runs a program with an argument list, never through a shell, so paths with spaces or
/// Chinese characters pass through as they are.
public enum ProcessRunner {
    public static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }

        // Read while the program runs: a full pipe would otherwise block it forever.
        let output = OutputBuffer()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            output.data = pipe.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            _ = drained.wait(timeout: .now() + 1)
            throw ProcessRunnerError.timedOut
        }
        _ = drained.wait(timeout: .now() + 5)
        return ProcessResult(status: process.terminationStatus, output: String(decoding: output.data, as: UTF8.self))
    }
}

/// Written once by the reading thread, read after it has finished.
private final class OutputBuffer: @unchecked Sendable {
    var data = Data()
}

/// `/usr/bin/ditto`, which keeps bundles, extended attributes and code signatures intact.
public enum Ditto {
    static let timeout: TimeInterval = 120
    private static let executable = URL(fileURLWithPath: "/usr/bin/ditto")

    public static func copy(_ source: URL, to destination: URL) throws {
        try run([source.path, destination.path])
    }

    public static func unzip(_ zip: URL, into directory: URL) throws {
        try run(["-x", "-k", zip.path, directory.path])
    }

    private static func run(_ arguments: [String]) throws {
        let result: ProcessResult
        do {
            result = try ProcessRunner.run(executable, arguments, timeout: timeout)
        } catch {
            throw UpdateError.fileOperation("ditto: \(error)")
        }
        guard result.status == 0 else {
            let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.fileOperation("ditto (\(result.status)): \(message.prefix(300))")
        }
    }
}
