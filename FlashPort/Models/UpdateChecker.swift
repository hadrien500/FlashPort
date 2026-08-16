import AppKit
import Foundation
import Observation

/// Version comparable extraite d'un tag de release GitHub (ex. v1.0.0-beta.2).
struct ReleaseVersion: Comparable, Equatable {
    var numbers: [Int]
    var betaNumber: Int

    init?(tag: String) {
        var normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("v") {
            normalized.removeFirst()
        }

        let parts = normalized.split(separator: "-", maxSplits: 1)
        guard let versionPart = parts.first else { return nil }

        let parsedNumbers = versionPart.split(separator: ".").compactMap { Int($0) }
        guard !parsedNumbers.isEmpty else { return nil }
        numbers = parsedNumbers

        if parts.count == 2 {
            // "beta.3" ou "rc.1" : seul le numéro final sert à comparer.
            let suffixDigits = parts[1].split(whereSeparator: { !$0.isNumber }).last
            betaNumber = suffixDigits.flatMap { Int($0) } ?? 0
        } else {
            // Une version finale prime sur toutes ses pré-versions.
            betaNumber = Int.max
        }
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let count = max(lhs.numbers.count, rhs.numbers.count)
        for index in 0..<count {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right {
                return left < right
            }
        }
        return lhs.betaNumber < rhs.betaNumber
    }
}

/// Vérifie au lancement si une release plus récente est publiée sur GitHub.
@MainActor
@Observable
final class UpdateChecker {
    /// Tag de la version distribuée : à incrémenter à chaque release GitHub.
    static let currentReleaseTag = "v1.0.0-beta.2"

    private static let releasesURL = URL(
        string: "https://api.github.com/repos/hadrien500/FlashPort/releases?per_page=10"
    )!

    private(set) var availableUpdateTag: String?

    @ObservationIgnored
    private var availableUpdateURL: URL?

    private struct GitHubRelease: Decodable {
        var tagName: String
        var htmlUrl: URL
        var draft: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlUrl = "html_url"
            case draft
        }
    }

    func checkForUpdate() async {
        guard let currentVersion = ReleaseVersion(tag: Self.currentReleaseTag) else { return }

        var request = URLRequest(url: Self.releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let releases = try? JSONDecoder().decode([GitHubRelease].self, from: data) else {
            return
        }

        let newestRelease = releases
            .filter { !$0.draft }
            .compactMap { release -> (release: GitHubRelease, version: ReleaseVersion)? in
                guard let version = ReleaseVersion(tag: release.tagName) else { return nil }
                return (release, version)
            }
            .max { $0.version < $1.version }

        guard let newestRelease, newestRelease.version > currentVersion else { return }
        availableUpdateTag = newestRelease.release.tagName
        availableUpdateURL = newestRelease.release.htmlUrl
    }

    func openUpdatePage() {
        guard let availableUpdateURL else { return }
        NSWorkspace.shared.open(availableUpdateURL)
    }
}
