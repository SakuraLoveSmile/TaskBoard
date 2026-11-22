import Foundation

struct ReleaseInfo: Sendable, Equatable {
    let version: String
    let name: String?
    let pageURL: URL
    let notes: String?
}

enum UpdateStatus: Sendable, Equatable {
    case upToDate(current: String)
    case updateAvailable(ReleaseInfo)
    case failed(String)
}

enum UpdateError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "无法解析更新信息"
        case .httpStatus(let code):
            code == 404 ? "还没有发布过版本" : "服务器返回 \(code)"
        }
    }
}

enum UpdateChecker {
    static let repository = "SakuraLoveSmile/TaskBoard"

    static var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    static var releasesPageURL: URL {
        URL(string: "https://github.com/\(repository)/releases")!
    }

    static func check(currentVersion: String, session: URLSession = .shared) async -> UpdateStatus {
        do {
            let release = try await latestRelease(session: session)
            if isNewer(release.version, than: currentVersion) {
                return .updateAvailable(release)
            }
            return .upToDate(current: currentVersion)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func latestRelease(session: URLSession = .shared) async throws -> ReleaseInfo {
        var request = URLRequest(url: latestReleaseURL)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("TaskBoard", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw UpdateError.httpStatus(http.statusCode)
        }
        return try parseRelease(data)
    }

    static func parseRelease(_ data: Data) throws -> ReleaseInfo {
        struct GitHubRelease: Decodable {
            let tagName: String
            let name: String?
            let htmlURL: URL
            let body: String?

            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case name
                case htmlURL = "html_url"
                case body
            }
        }

        let payload = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let version = normalize(payload.tagName)
        guard !version.isEmpty else { throw UpdateError.invalidResponse }
        return ReleaseInfo(
            version: version,
            name: payload.name,
            pageURL: payload.htmlURL,
            notes: payload.body
        )
    }

    static func normalize(_ tag: String) -> String {
        var value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") {
            value.removeFirst()
        }
        return value
    }

    static func isNewer(_ remote: String, than current: String) -> Bool {
        let remoteValue = normalize(remote)
        let currentValue = normalize(current)
        if remoteValue == currentValue { return false }

        let remoteParts = remoteValue.split(separator: "-", maxSplits: 1).first.map(String.init) ?? remoteValue
        let currentParts = currentValue.split(separator: "-", maxSplits: 1).first.map(String.init) ?? currentValue
        let remoteNumbers = remoteParts.split(separator: ".").map { Int($0) ?? 0 }
        let currentNumbers = currentParts.split(separator: ".").map { Int($0) ?? 0 }

        for index in 0..<max(remoteNumbers.count, currentNumbers.count) {
            let remoteNumber = index < remoteNumbers.count ? remoteNumbers[index] : 0
            let currentNumber = index < currentNumbers.count ? currentNumbers[index] : 0
            if remoteNumber != currentNumber {
                return remoteNumber > currentNumber
            }
        }
        // 数字相同：远端是预发布版时不算更新
        return !remoteValue.contains("-")
    }
}
