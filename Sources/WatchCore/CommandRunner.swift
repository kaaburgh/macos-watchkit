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

/// Thread-safe bounded capture of subprocess stdout and stderr.
private final class BoundedCapture {
    private let lock = NSLock()
    private let limit: Int
    private var stdout = Data()
    private var stderr = Data()
    private var exceeded = false

    init(limit: Int) { self.limit = max(0, limit) }

    /// Returns true only once, so the caller terminates the process on first overflow.
    func append(_ data: Data, stderr isError: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, limit - stdout.count - stderr.count)
        if remaining > 0 {
            if isError { stderr.append(data.prefix(remaining)) }
            else { stdout.append(data.prefix(remaining)) }
        }
        if data.count > remaining && !exceeded {
            exceeded = true
            return true
        }
        return false
    }

    func result() -> (String, String, Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (String(decoding: stdout, as: UTF8.self),
                String(decoding: stderr, as: UTF8.self), exceeded)
    }
}

/// Pipes are continuously drained into bounded memory. No unbounded temporary files.
public struct BoundedCommandRunner: CommandRunning {
    public let maximumOutputBytes: Int

    public init(maximumOutputBytes: Int = 1_048_576) {
        self.maximumOutputBytes = max(0, maximumOutputBytes)
    }

    public func run(executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return CommandResult(stdout: "", exitCode: nil,
                                 error: "Unable to launch \(executable): \(error.localizedDescription)")
        }
        // Close parent's writing ends; the child retains its own descriptors.
        outPipe.fileHandleForWriting.closeFile()
        errPipe.fileHandleForWriting.closeFile()

        let captured = BoundedCapture(limit: maximumOutputBytes)
        let readers = DispatchGroup()
        let handles: [(FileHandle, Bool)] = [
            (outPipe.fileHandleForReading, false), (errPipe.fileHandleForReading, true)
        ]
        for (handle, isError) in handles {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { readers.leave() }
                while true {
                    let chunk = handle.readData(ofLength: 16_384)
                    if chunk.isEmpty { break }
                    if captured.append(chunk, stderr: isError), process.isRunning {
                        process.terminate()
                    }
                }
            }
        }

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            finished.signal()
        }
        let timedOut = finished.wait(timeout: .now() + max(0, timeout)) == .timedOut
        if timedOut && process.isRunning { process.terminate() }
        if timedOut {
            if finished.wait(timeout: .now() + 1) == .timedOut && process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
        } else if process.isRunning {
            _ = finished.wait(timeout: .now() + 1)
        }
        let drained = readers.wait(timeout: .now() + 2) == .success
        let (stdout, stderr, truncated) = captured.result()
        return CommandResult(
            stdout: stdout, stderr: stderr,
            exitCode: process.isRunning ? nil : process.terminationStatus,
            timedOut: timedOut, truncated: truncated,
            error: drained ? nil : "Unable to drain command output"
        )
    }
}
