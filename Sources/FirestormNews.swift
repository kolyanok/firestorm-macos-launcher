import Foundation
import CoreFoundation

struct FirestormNewsItem: Identifiable {
    let id: String
    let title: String
    let summary: String?
    let imageURL: URL?
    let articleURL: URL
    let publishedAt: Date?
}

/// Same public news RPC as the official launcher. The application identifier is
/// distributed in its installer; this feature never uses a player's credentials.
final class FirestormNewsService {
    enum Failure: Error {
        case invalidResponse
        case http(Int)
        case api(Int)
        case oversizedResponse
    }

    private let session: URLSession
    private let cacheLock = NSLock()
    private var cachedResponse: (data: Data, date: Date)?
    private static let maximumBytes = 8 * 1024 * 1024
    private static let freshness: TimeInterval = 30 * 60

    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    func invalidateCache() {
        cacheLock.lock()
        cachedResponse = nil
        cacheLock.unlock()
    }

    @discardableResult
    func load(language: String, completion: @escaping (Result<[FirestormNewsItem], Error>) -> Void) -> URLSessionDataTask? {
        let language = language == "ru" ? "ru" : "en"
        cacheLock.lock()
        let cached = cachedResponse
        cacheLock.unlock()
        if let cached, Date().timeIntervalSince(cached.date) < Self.freshness {
            DispatchQueue.global(qos: .utility).async {
                completion(Result { try Self.decodeAPI(cached.data, language: language) })
            }
            return nil
        }
        let task = session.dataTask(with: Self.makeRequest(language: language)) { [weak self] data, response, error in
            do {
                if let error { throw error }
                guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
                guard (200..<300).contains(response.statusCode) else { throw Failure.http(response.statusCode) }
                guard let data else { throw Failure.invalidResponse }
                guard data.count <= Self.maximumBytes else { throw Failure.oversizedResponse }
                let articles = try Self.decodeAPI(data, language: language)
                if let self {
                    self.cacheLock.lock()
                    self.cachedResponse = (data, Date())
                    self.cacheLock.unlock()
                }
                completion(.success(articles))
            } catch { completion(.failure(error)) }
        }
        task.resume()
        return task
    }

    static func makeRequest(language: String) -> URLRequest {
        FirestormAPI.makeRequest(method: "GetLauncherLastNews", parameters: [30, language == "ru" ? 4 : 0, ""])
    }

    /// All translations arrive together, so switching interface language can
    /// reuse the cached feed. This matches the official 30-minute freshness.
    static func decodeAPI(_ data: Data, language: String) throws -> [FirestormNewsItem] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.invalidResponse
        }
        if let error = root["error"], !(error is NSNull) {
            throw Failure.api(integer((error as? [String: Any])?["ErrorID"]) ?? -1)
        }
        guard let result = root["result"] as? [String: Any],
              let status = integer(result["ErrorID"]) else { throw Failure.invalidResponse }
        guard status == 0 else { throw Failure.api(status) }
        guard let rows = result["News"] as? [Any] else { throw Failure.invalidResponse }
        let localeID = language == "ru" ? 4 : 0
        var seen = Set<String>()
        var articles: [FirestormNewsItem] = []
        for candidate in rows {
            guard let row = candidate as? [String: Any] else { continue }
            guard integer(row["CategoryID"]) == 1,
                  !flag(row["HideFromHomepage"], default: false),
                  flag(row["Visible"], default: true),
                  let number = integer(row["ID"] ?? row["Id"]), number > 0 else { continue }
            let id = String(number)
            guard !seen.contains(id), let rawTitle = localized(row["Title"], localeID: localeID) else { continue }
            let title = plainHTML(rawTitle)
            guard !title.isEmpty else { continue }
            seen.insert(id)
            let picture = imageFilenameURL(row["Picture"] as? String)
                ?? imageFilenameURL(row["PictureAlt"] as? String)
            let date = double(row["Date"]).flatMap { $0 > 0 && $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
            let summary = localized(row["Content"], localeID: localeID).map { String(plainHTML($0).prefix(200)) }
            let locale = language == "ru" ? "ru" : "en"
            articles.append(FirestormNewsItem(
                id: id, title: title, summary: summary, imageURL: picture,
                articleURL: URL(string: "https://firestorm-servers.com/\(locale)/news/\(id)")!,
                publishedAt: date
            ))
            if articles.count == 30 { break }
        }
        return articles
    }

    private static func localized(_ value: Any?, localeID: Int) -> String? {
        let entries: [[String: Any]]
        if let values = value as? [[String: Any]] { entries = values }
        else if let values = value as? [String: Any] {
            entries = values.keys.sorted().compactMap { values[$0] as? [String: Any] }
        } else { return nil }
        func text(_ entry: [String: Any]) -> String? {
            guard let value = entry["Value"] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
        return entries.first(where: { integer($0["Locale"]) == localeID && text($0) != nil }).flatMap(text)
            ?? entries.first(where: { integer($0["Locale"]) == 0 && text($0) != nil }).flatMap(text)
            ?? entries.compactMap(text).first
    }

    private static func imageFilenameURL(_ filename: String?) -> URL? {
        guard let filename, !filename.isEmpty,
              filename.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil,
              !filename.contains("..") else { return nil }
        return safeImageURL("https://firestorm-servers.com/assets/img/news/\(filename)")
    }

    static func safeImageURL(_ value: String?) -> URL? {
        guard let value, !value.isEmpty,
              var components = URLComponents(string: value),
              components.user == nil, components.password == nil else { return nil }
        if components.host == nil {
            guard value.hasPrefix("/assets/img/") else { return nil }
            components = URLComponents(string: "https://firestorm-servers.com" + value)!
        }
        guard let host = components.host?.lowercased(),
              host == "firestorm-servers.com" || host == "www.firestorm-servers.com",
              components.scheme?.lowercased() == "https" || components.scheme?.lowercased() == "http",
              components.port == nil || components.port == 443 else { return nil }
        guard !components.path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        components.scheme = "https"
        return components.url
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? String { return Int(value) }
        if let value = value as? NSNumber {
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            let number = value.doubleValue
            guard number.isFinite, number.rounded() == number,
                  number >= Double(Int.min), number < Double(Int.max) else { return nil }
            return value.intValue
        }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? String { return Double(value) }
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { return value.doubleValue }
        return nil
    }

    private static func flag(_ value: Any?, default fallback: Bool) -> Bool {
        if let value = value as? Bool { return value }
        if let value = integer(value) { return value != 0 }
        return fallback
    }

    private static func plainHTML(_ value: String) -> String {
        // Parses text only. Scripts and external entities never execute or load.
        let html = "<html><body><div>\(value)</div></body></html>"
        if let document = try? XMLDocument(xmlString: html, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
           let nodes = try? document.nodes(forXPath: "//body//text()[not(ancestor::script) and not(ancestor::style)]") {
            return nodes.compactMap(\.stringValue).joined(separator: " ")
                .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        }
        return value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
