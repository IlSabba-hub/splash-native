import Foundation

public enum Probe {
    public static var script: URL {
        Bundle.module.url(forResource: "splash_probe", withExtension: "py")!
    }

    static func run(_ installation: SplashInstallation, _ command: String, _ arguments: [String] = [],
                    environment: [String: String] = [:]) async throws -> Data {
        let argv = [installation.python.path, "-I", "-B", script.path, command, installation.root.path] + arguments
        let result = try await Command.run(argv, environment: environment, timeout: .seconds(60))
        guard result.status == 0 else {
            throw NativeError.commandFailed(program: "splash_probe.py \(command)", status: result.status, detail: String(result.errorText.suffix(2000)))
        }
        return result.output
    }

    public static func schemaJSON(_ installation: SplashInstallation) async throws -> Data {
        try await run(installation, "schema")
    }

    public static func familiesJSON(_ installation: SplashInstallation) async throws -> Data {
        try await run(installation, "families")
    }
}
