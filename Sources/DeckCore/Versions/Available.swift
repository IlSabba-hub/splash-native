import Foundation

public enum AvailableVersions {
    public struct Offer: Codable, Sendable, Equatable {
        public enum Channel: String, Codable, Sendable { case formula, cask, github }
        public let channel: Channel
        public let version: String
        public let url: String?
        public let sha256: String?
        public let published: Date?
        public let prerelease: Bool
    }

    public static func formula(_ text: String) -> Offer? {
        guard let url = text.firstMatch(of: /(?m)^\s*url\s+"([^"]+)"/)?.1,
              let version = url.firstMatch(of: /\/releases\/download\/([^\/]+)\//)?.1
        else { return nil }
        let sha = text.firstMatch(of: /(?m)^\s*sha256\s+"([0-9a-f]{64})"/)?.1
        return Offer(channel: .formula, version: String(version), url: String(url), sha256: sha.map(String.init),
                     published: nil, prerelease: false)
    }

    public static func cask(_ text: String) -> Offer? {
        guard let version = text.firstMatch(of: /(?m)^\s*version\s+"([^"]+)"/)?.1 else { return nil }
        let url = text.firstMatch(of: /(?m)^\s*url\s+"([^"]+)"/).map { String($0.1).replacing("#{version}", with: String(version)) }
        let sha = text.firstMatch(of: /(?m)^\s*sha256\s+"([0-9a-f]{64})"/)?.1
        return Offer(channel: .cask, version: String(version), url: url, sha256: sha.map(String.init), published: nil, prerelease: false)
    }

    public static let tap = URL(filePath: "/opt/homebrew/Library/Taps/incoai/homebrew-tap")

    public static func fromTap(_ tap: URL = tap) -> [Offer] {
        let formula = (try? String(contentsOf: tap.appending(path: "Formula/splash.rb"), encoding: .utf8)).flatMap(Self.formula)
        let cask = (try? String(contentsOf: tap.appending(path: "Casks/splash-app.rb"), encoding: .utf8)).flatMap(Self.cask)
        return [formula, cask].compactMap { $0 }
    }

    public struct Release: Decodable, Sendable, Equatable {
        public struct Asset: Decodable, Sendable, Equatable {
            public let name: String
            public let size: Int64
            public let browserDownloadURL: String

            enum CodingKeys: String, CodingKey { case name, size, browserDownloadURL = "browser_download_url" }
        }

        public let tagName: String
        public let name: String?
        public let draft: Bool
        public let prerelease: Bool
        public let publishedAt: Date?
        public let htmlURL: String
        public let body: String?
        public let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", name, draft, prerelease, publishedAt = "published_at", htmlURL = "html_url", body, assets
        }
    }

    public static func releases(from data: Data) throws -> [Release] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Release].self, from: data)
    }

    public static func offers(_ releases: [Release]) -> [Offer] {
        releases.filter { !$0.draft }.map {
            Offer(channel: .github, version: $0.tagName, url: $0.htmlURL, sha256: nil, published: $0.publishedAt, prerelease: $0.prerelease)
        }
    }

    public static func fetchReleases(repository: String = "incoai/splash", session: URLSession = .shared) async throws -> [Release] {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=100")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SplashDeck", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw DeckError.httpStatus(path: request.url?.path ?? "", status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try releases(from: data)
    }
}

public struct VersionRow: Sendable, Equatable {
    public let version: SplashVersion
    public let installed: [SplashInstallation]
    public let offers: [AvailableVersions.Offer]

    public static func merge(installed: [SplashInstallation], offers: [AvailableVersions.Offer]) -> [VersionRow] {
        var versions: [SplashVersion] = []
        for text in installed.compactMap(\.version) + offers.map(\.version) where !versions.contains(SplashVersion(text)) {
            versions.append(SplashVersion(text))
        }
        return versions.sorted(by: >).map { version in
            VersionRow(version: version,
                       installed: installed.filter { $0.version.map(SplashVersion.init) == version },
                       offers: offers.filter { SplashVersion($0.version) == version })
        }
    }
}
