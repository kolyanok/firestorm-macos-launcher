import Foundation
import CryptoKit

/// Stable launcher releases use three numeric components. Comparing components
/// avoids offering 1.1.9 as an upgrade from 1.1.13 or accepting prerelease tags.
struct LauncherVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(rawString: String) {
        let value = rawString.hasPrefix("v") ? String(rawString.dropFirst()) : rawString
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3 else { return nil }
        var numbers: [Int] = []
        for component in components {
            guard !component.isEmpty,
                  component.utf8.allSatisfy({ (48...57).contains($0) }),
                  component.count == 1 || component.first != "0",
                  let number = Int(component) else { return nil }
            numbers.append(number)
        }
        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

struct LauncherUpdateRelease: Equatable {
    let version: LauncherVersion
    let tagName: String
    let releaseURL: URL
    let assetURL: URL
    let assetName: String
    let assetSize: Int64
    /// Lowercase SHA256 hex, without GitHub's "sha256:" prefix. Older releases
    /// can be shown with a manual download link, but cannot be installed here.
    let digestSHA256: String?
}

enum LauncherUpdateError: Error, LocalizedError {
    case invalidVersion
    case invalidRelease
    case missingAsset
    case invalidAsset
    case missingDigest
    case invalidDigest
    case http(Int)
    case oversizedResponse
    case unsafeRedirect
    case invalidDownload
    case sizeMismatch
    case checksumMismatch
    case destinationExists

    var errorDescription: String? {
        switch self {
        case .invalidVersion: return L("The launcher version could not be read.")
        case .invalidRelease: return L("GitHub returned invalid release information.")
        case .missingAsset: return L("This release does not include the macOS Universal launcher.")
        case .invalidAsset: return L("The update download address could not be verified.")
        case .missingDigest: return L("This release has no SHA256 checksum. Download it from GitHub manually.")
        case .invalidDigest: return L("The update checksum could not be verified.")
        case .http(let status): return LF("GitHub returned HTTP %d. Please try again later.", status)
        case .oversizedResponse: return L("GitHub returned too much release information.")
        case .unsafeRedirect: return L("GitHub redirected the update to an untrusted address.")
        case .invalidDownload: return L("The downloaded update is not a valid file.")
        case .sizeMismatch: return L("The downloaded update has an unexpected size. Please try again.")
        case .checksumMismatch: return L("The downloaded update failed its SHA256 check. Please try again.")
        case .destinationExists: return L("The update download destination is already in use.")
        }
    }
}

/// Public GitHub metadata only: no account, token, or player credentials. The UI
/// owns the six-hour checking schedule and asks before replacing the application.
final class LauncherUpdateService {
    static let releasesURL = URL(string: "https://github.com/kolyanok/firestorm-macos-launcher/releases")!
    private static let repositoryPath = "/kolyanok/firestorm-macos-launcher"
    private static let maximumMetadataBytes = 2 * 1024 * 1024
    fileprivate static let maximumArchiveBytes: Int64 = 512 * 1024 * 1024
    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? URLSession(configuration: Self.configuration())
    }

    private static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return configuration
    }

    static func makeRequest() -> URLRequest {
        let url = URL(string: "https://api.github.com/repos/kolyanok/firestorm-macos-launcher/releases/latest")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Firestorm-macOS-Launcher", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Completion and progress callbacks are always delivered on the main queue.
    @discardableResult
    func check(currentVersion: String, completion: @escaping (Result<LauncherUpdateRelease?, Error>) -> Void) -> URLSessionDataTask? {
        guard LauncherVersion(rawString: currentVersion) != nil else {
            DispatchQueue.main.async { completion(.failure(LauncherUpdateError.invalidVersion)) }
            return nil
        }
        let task = session.dataTask(with: Self.makeRequest()) { data, response, error in
            let result: Result<LauncherUpdateRelease?, Error> = Result {
                if let error { throw error }
                guard let response = response as? HTTPURLResponse else { throw LauncherUpdateError.invalidRelease }
                // A repository without published releases has no update yet.
                if response.statusCode == 404 { return nil }
                guard response.statusCode == 200 else { throw LauncherUpdateError.http(response.statusCode) }
                guard let data else { throw LauncherUpdateError.invalidRelease }
                return try Self.decodeRelease(data, currentVersion: currentVersion)
            }
            DispatchQueue.main.async { completion(result) }
        }
        task.resume()
        return task
    }

    static func decodeRelease(_ data: Data, currentVersion: String) throws -> LauncherUpdateRelease? {
        guard let current = LauncherVersion(rawString: currentVersion) else { throw LauncherUpdateError.invalidVersion }
        guard data.count <= maximumMetadataBytes else { throw LauncherUpdateError.oversizedResponse }
        let metadata: GitHubRelease
        do { metadata = try JSONDecoder().decode(GitHubRelease.self, from: data) }
        catch { throw LauncherUpdateError.invalidRelease }
        guard !metadata.draft, !metadata.prerelease else { return nil }
        guard let version = LauncherVersion(rawString: metadata.tag_name) else { throw LauncherUpdateError.invalidRelease }
        guard version > current else { return nil }
        let name = "Firestorm-Launcher-\(version)-macOS-Universal.zip"
        let matches = metadata.assets.filter { $0.name == name && ($0.state == nil || $0.state == "uploaded") }
        guard !matches.isEmpty else { throw LauncherUpdateError.missingAsset }
        guard matches.count == 1, let asset = matches.first,
              let releaseURL = githubURL(metadata.html_url, path: repositoryPath + "/releases/tag/" + metadata.tag_name),
              let assetURL = githubURL(asset.browser_download_url, path: repositoryPath + "/releases/download/" + metadata.tag_name + "/" + name),
              asset.size > 0, asset.size <= maximumArchiveBytes else { throw LauncherUpdateError.invalidAsset }
        var digest: String?
        if let raw = asset.digest {
            guard raw.hasPrefix("sha256:"), validDigest(String(raw.dropFirst(7))) else { throw LauncherUpdateError.invalidDigest }
            digest = String(raw.dropFirst(7)).lowercased()
        }
        return LauncherUpdateRelease(version: version, tagName: metadata.tag_name, releaseURL: releaseURL,
                                     assetURL: assetURL, assetName: name, assetSize: asset.size, digestSHA256: digest)
    }

    @discardableResult
    func download(release: LauncherUpdateRelease, to destinationURL: URL, progress: ((Double) -> Void)? = nil,
                  completion: @escaping (Result<URL, Error>) -> Void) -> URLSessionDownloadTask? {
        do {
            try Self.validateAsset(release)
            guard let digest = release.digestSHA256 else { throw LauncherUpdateError.missingDigest }
            guard Self.validDigest(digest) else { throw LauncherUpdateError.invalidDigest }
            guard destinationURL.isFileURL else { throw LauncherUpdateError.invalidDownload }
            guard !FileManager.default.fileExists(atPath: destinationURL.path) else { throw LauncherUpdateError.destinationExists }
        } catch {
            DispatchQueue.main.async { completion(.failure(error)) }
            return nil
        }
        // Copying the injected configuration preserves URLProtocol fixtures while
        // a dedicated delegate can reject redirects and report streamed progress.
        let configuration = session.configuration
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30 * 60
        let download = LauncherUpdateDownload(release: release, destinationURL: destinationURL,
                                              progress: progress, completion: completion)
        return download.start(configuration: configuration)
    }

    static func validateDownloadedFile(_ file: URL, release: LauncherUpdateRelease) throws {
        try validateAsset(release)
        guard let expectedDigest = release.digestSHA256 else { throw LauncherUpdateError.missingDigest }
        guard validDigest(expectedDigest) else { throw LauncherUpdateError.invalidDigest }
        guard file.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else { throw LauncherUpdateError.invalidDownload }
        guard size.int64Value == release.assetSize else { throw LauncherUpdateError.sizeMismatch }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expectedDigest.lowercased() else { throw LauncherUpdateError.checksumMismatch }
    }

    private static func validDigest(_ digest: String) -> Bool {
        digest.utf8.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    private static func validateAsset(_ release: LauncherUpdateRelease) throws {
        let name = "Firestorm-Launcher-\(release.version)-macOS-Universal.zip"
        guard LauncherVersion(rawString: release.tagName) == release.version,
              release.assetName == name, release.assetSize > 0, release.assetSize <= maximumArchiveBytes,
              githubURL(release.releaseURL.absoluteString, path: repositoryPath + "/releases/tag/" + release.tagName) != nil,
              githubURL(release.assetURL.absoluteString, path: repositoryPath + "/releases/download/" + release.tagName + "/" + name) != nil else {
            throw LauncherUpdateError.invalidAsset
        }
    }

    private static func githubURL(_ value: String, path: String) -> URL? {
        guard let parts = URLComponents(string: value), parts.scheme?.lowercased() == "https",
              parts.host?.lowercased() == "github.com", parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443, parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath == path else { return nil }
        return parts.url
    }

    fileprivate static func isDownloadURL(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443, parts.fragment == nil,
              let host = parts.host?.lowercased() else { return false }
        // GitHub signs asset-delivery URLs with query parameters. The initial
        // request is still restricted to this repository's exact release asset.
        return host == "github.com" || host == "release-assets.githubusercontent.com" || host == "objects.githubusercontent.com"
    }

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let html_url: String
        let draft: Bool
        let prerelease: Bool
        let assets: [GitHubAsset]
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let state: String?
        let size: Int64
        let digest: String?
        let browser_download_url: String
    }
}

private final class LauncherUpdateDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let release: LauncherUpdateRelease
    private let destinationURL: URL
    private let progress: ((Double) -> Void)?
    private let completion: (Result<URL, Error>) -> Void
    private var session: URLSession?
    private var result: Result<URL, Error>?

    init(release: LauncherUpdateRelease, destinationURL: URL, progress: ((Double) -> Void)?,
         completion: @escaping (Result<URL, Error>) -> Void) {
        self.release = release
        self.destinationURL = destinationURL
        self.progress = progress
        self.completion = completion
    }

    func start(configuration: URLSessionConfiguration) -> URLSessionDownloadTask {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        var request = URLRequest(url: release.assetURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Firestorm-macOS-Launcher", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        task.resume()
        return task
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, LauncherUpdateService.isDownloadURL(url) else {
            result = .failure(LauncherUpdateError.unsafeRedirect)
            completionHandler(nil)
            return
        }
        var request = request
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= release.assetSize,
              totalBytesExpectedToWrite <= 0 || totalBytesExpectedToWrite == release.assetSize else {
            result = .failure(LauncherUpdateError.sizeMismatch)
            downloadTask.cancel()
            return
        }
        let fraction = min(1, Double(totalBytesWritten) / Double(release.assetSize))
        if let progress { DispatchQueue.main.async { progress(fraction) } }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard result == nil else { return }
        result = Result {
            guard let response = downloadTask.response as? HTTPURLResponse else { throw LauncherUpdateError.invalidDownload }
            guard response.statusCode == 200 else { throw LauncherUpdateError.http(response.statusCode) }
            guard let url = response.url, LauncherUpdateService.isDownloadURL(url) else { throw LauncherUpdateError.unsafeRedirect }
            try LauncherUpdateService.validateDownloadedFile(location, release: release)
            let fileManager = FileManager.default
            guard !fileManager.fileExists(atPath: destinationURL.path) else { throw LauncherUpdateError.destinationExists }
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: location, to: destinationURL)
            return destinationURL
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let final: Result<URL, Error>
        if let error, case .success(let file)? = result {
            // Cancellation can arrive while the delegate is hashing/moving a
            // finished download. Do not hand that archive to the installer.
            try? FileManager.default.removeItem(at: file)
            final = .failure(error)
        } else if let result { final = result }
        else if let error { final = .failure(error) }
        else { final = .failure(LauncherUpdateError.invalidDownload) }
        session.finishTasksAndInvalidate()
        self.session = nil
        DispatchQueue.main.async { self.completion(final) }
    }
}
