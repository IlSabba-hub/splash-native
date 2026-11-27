import Foundation
import Synchronization

public enum Command {
    public struct Result: Sendable {
        public let status: Int32
        public let output: Data
        public let errors: Data

        public var text: String { String(decoding: output, as: UTF8.self) }
        public var errorText: String { String(decoding: errors, as: UTF8.self) }
    }

    public static func run(_ argv: [String], environment: [String: String] = [:], directory: URL? = nil,
                           input: Data? = nil, timeout: Duration = .seconds(60)) async throws -> Result {
        guard let program = argv.first else { throw NativeError.emptyCommand }
        let process = Process()
        process.executableURL = URL(filePath: program)
        process.arguments = Array(argv.dropFirst())
        process.environment = environment
        if let directory { process.currentDirectoryURL = directory }
        let output = Pipe(), errors = Pipe(), stdin = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        let ended = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { ended.continuation.yield($0.terminationStatus); ended.continuation.finish() }
        try process.run()
        async let read = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
        async let readErrors = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }.value
        if let input {
            let writer = stdin.fileHandleForWriting
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            Task.detached {
                try? writer.write(contentsOf: input)
                try? writer.close()
            }
        }
        let expired = Atomic<Bool>(false)
        let deadline = Task {
            try await Task.sleep(for: timeout)
            expired.store(true, ordering: .relaxed)
            process.terminate()
        }
        let status = await withTaskCancellationHandler {
            var status: Int32 = -1
            for await code in ended.stream { status = code }
            return status
        } onCancel: {
            process.terminate()
        }
        deadline.cancel()
        let result = Result(status: status, output: await read, errors: await readErrors)
        try Task.checkCancellation()
        if expired.load(ordering: .relaxed) {
            throw NativeError.timedOut(program: program, seconds: Int(timeout.components.seconds))
        }
        return result
    }
}
