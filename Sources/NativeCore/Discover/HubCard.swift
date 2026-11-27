import Foundation

public struct HubCard: Sendable, Equatable {
    public let repo: String
    public let downloads: Int?
    public let likes: Int?
    public let lastModified: Date?
    public let pipeline: String?
    public let readme: String?
    public let fetched: Date

    public init(repo: String, downloads: Int?, likes: Int?, lastModified: Date?, pipeline: String?, readme: String?, fetched: Date) {
        self.repo = repo
        self.downloads = downloads
        self.likes = likes
        self.lastModified = lastModified
        self.pipeline = pipeline
        self.readme = readme
        self.fetched = fetched
    }
}

public enum HubCards {
    public static let host = URL(string: "https://huggingface.co")!

    public static func repo(of model: String) -> String {
        String(model.split(separator: ":", maxSplits: 1).first ?? Substring(model))
    }

    static func infoURL(_ repo: String) -> URL { host.appending(path: "api/models/" + repo) }

    static func readmeURL(_ repo: String) -> URL { host.appending(path: repo + "/raw/main/README.md") }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.httpAdditionalHeaders = ["User-Agent": "SplashNative", "Accept": "application/json"]
        return URLSession(configuration: configuration)
    }

    public static func fetch(_ repo: String) async throws -> HubCard {
        let session = session()
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: infoURL(repo))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw HubCardError.status((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let readme = (try? await readmeText(repo, session: session)).flatMap { $0 }
        return try card(repo: repo, info: data, readme: readme, fetched: .now)
    }

    static func readmeText(_ repo: String, session: URLSession, limit: Int = 256 * 1024) async throws -> String? {
        let (bytes, answer) = try await session.bytes(from: readmeURL(repo))
        guard (answer as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        if answer.expectedContentLength > limit { return nil }
        var text = Data()
        for try await byte in bytes {
            text.append(byte)
            if text.count > limit { return nil }
        }
        return String(data: text, encoding: .utf8).map(stripFrontMatter)
    }

    static func card(repo: String, info: Data, readme: String?, fetched: Date) throws -> HubCard {
        struct Raw: Decodable {
            let downloads: Int?
            let likes: Int?
            let lastModified: String?
            let pipeline_tag: String?
        }
        let raw = try JSONDecoder().decode(Raw.self, from: info)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = raw.lastModified.flatMap { formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
        return HubCard(repo: repo, downloads: raw.downloads, likes: raw.likes, lastModified: date, pipeline: raw.pipeline_tag,
                       readme: readme, fetched: fetched)
    }

    static func stripFrontMatter(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return text }
        return lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum HubCardError: Error, LocalizedError, Equatable {
    case status(Int)

    public var errorDescription: String? {
        switch self {
        case let .status(code): NativeText.hubStatus(code)
        }
    }
}
