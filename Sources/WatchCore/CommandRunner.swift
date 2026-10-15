import Foundation
#if os(macOS)
import Darwin
#else
import Glibc
#endif

public struct CommandResult {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32?
    public let timedOut: Bool
    public let truncated: Bool
    public let error: String?

    public init(
        stdout: String, stderr: String = "", exitCode: Int32? = 0,
        timedOut: Bool = false, truncated: Bool = false, error: String? = nil
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.truncated = truncated
        self.error = error
    }
}

public protocol CommandRunning {
    func run(executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult
}

/// Uses files rather than Pipe to avoid deadlocking when the child writes more than a pipe buffer.
/// Bounded execution time and output size protect the menu bar app from runaway `log show`.
public struct BoundedCommandRunner: CommandRunning {
    public let maximumOutputBytes: Int

    public init(maximumOutputBytes: Int = 1_048_576) {
        self.maximumOutputBytes = maximumOutputBytes
    }

    public func run(executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        let directory = FileManager.default.temporaryDirectory
        let stdoutURL = directory.appendingPathComponent("macos-watchkit-\(UUID().uuidString).out")
        let stderrURL = directory.appendingPathComponent("macos-watchkit-\(UUID().uuidString).err")
        let fm = FileManager.default
        guard fm.createFile(atPath: stdoutURL.path, contents: nil),
              fm.createFile(atPath: stderrURL.path, contents: nil),
              let stdoutFile = FileHandle(forWritingAtPath: stdoutURL.path),
              let stderrFile = FileHandle(forWritingAtPath: stderrURL.path)
        else {
            try? fm.removeItem(at: stdoutURL)
            try? fm.removeItem(at: stderrURL)
            return CommandResult(stdout: "", exitCode: nil, error: "Unable to create temporary output files")
        }
        defer {
            stdoutFile.closeFile()
            stderrFile.closeFile()
            try? fm.removeItem(at: stdoutURL)
            try? fm.removeItem(at: stderrURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutFile
        process.standardError = stderrFile
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return CommandResult(stdout: "", exitCode: nil, error: "Unable to launch \(executable): \(error.localizedDescription)")
        }

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            finished.signal()
        }
        let timedOut = finished.wait(timeout: .now() + timeout) == .timedOut
        if timedOut && process.isRunning {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut && process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
        }

        stdoutFile.synchronizeFile()
        stderrFile.synchronizeFile()
        let (stdout, outTruncated) = readBounded(stdoutURL)
        let (stderr, errTruncated) = readBounded(stderrURL)
        return CommandResult(
            stdout: stdout, stderr: stderr,
            exitCode: process.isRunning ? nil : process.terminationStatus,
            timedOut: timedOut, truncated: outTruncated || errTruncated
        )
    }

    private func readBounded(_ url: URL) -> (String, Bool) {
        guard let file = FileHandle(forReadingAtPath: url.path) else { return ("", false) }
        defer { file.closeFile() }
        let bytes = file.readData(ofLength: maximumOutputBytes + 1)
        return (String(decoding: bytes.prefix(maximumOutputBytes), as: UTF8.self), bytes.count > maximumOutputBytes)
    }
}
