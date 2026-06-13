import Foundation

public struct ProcessResult: Sendable {
    public var stdout: Data
    public var stderr: Data
    public var status: Int32
}

public protocol ProcessRunning: Sendable {
    func run(executable: String, arguments: [String], stdin: Data?) throws -> ProcessResult
}

public struct ProcessRunner: ProcessRunning {
    public init() {}

    public func run(executable: String, arguments: [String], stdin: Data? = nil) throws -> ProcessResult {
        try run(executable: executable, arguments: arguments, stdin: stdin, timeoutSeconds: nil)
    }

    public func run(executable: String, arguments: [String], stdin: Data? = nil, timeoutSeconds: TimeInterval?) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let input: Pipe?
        if let stdin {
            let pipe = Pipe()
            process.standardInput = pipe
            input = pipe
            pipe.fileHandleForWriting.writeabilityHandler = { handle in
                handle.write(stdin)
                try? handle.close()
            }
        } else {
            input = nil
        }

        try process.run()
        input?.fileHandleForWriting.writeabilityHandler = nil
        if let timeoutSeconds {
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                process.terminate()
                Thread.sleep(forTimeInterval: 0.2)
                let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
                let timeoutMessage = Data("Timed out after \(timeoutSeconds) seconds.".utf8)
                return ProcessResult(stdout: stdoutData, stderr: stderrData + timeoutMessage, status: 124)
            }
        } else {
            process.waitUntilExit()
        }

        return ProcessResult(
            stdout: stdout.fileHandleForReading.readDataToEndOfFile(),
            stderr: stderr.fileHandleForReading.readDataToEndOfFile(),
            status: process.terminationStatus
        )
    }
}
