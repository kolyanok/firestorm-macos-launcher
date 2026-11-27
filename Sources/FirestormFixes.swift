import Foundation

struct FirestormFixesItem: Identifiable {
    let id: String
    let title: String
    let bodyText: String
    let publishedAt: Date?
    let articleURL: URL
    let bodyLinks: [FirestormTextLink]
    let bodyBoldRanges: [NSRange]

    init(id: String, title: String, bodyText: String, publishedAt: Date?, articleURL: URL,
         bodyLinks: [FirestormTextLink] = [], bodyBoldRanges: [NSRange] = []) {
        self.id = id
        self.title = title
        self.bodyText = bodyText
        self.publishedAt = publishedAt
        self.articleURL = articleURL
        self.bodyLinks = bodyLinks
        self.bodyBoldRanges = bodyBoldRanges
    }
}

/// Midnight's development notes use the same public RPC as news, with the
/// official subcategory 34. Their homepage-hidden flag is intentional.
final class FirestormFixesService {
    enum Failure: Error {
        case invalidResponse
        case http(Int)
        case oversizedResponse
    }

    private let session: URLSession
    private let cacheLock = NSLock()
    private var cachedResponse: (data: Data, date: Date)?
    private static let maximumBytes = 8 * 1024 * 1024
    private static let freshness: TimeInterval = 5 * 60

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
    func load(language: String, completion: @escaping (Result<[FirestormFixesItem], Error>) -> Void) -> URLSessionDataTask? {
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
                let items = try Self.decodeAPI(data, language: language)
                if let self {
                    self.cacheLock.lock()
                    self.cachedResponse = (data, Date())
                    self.cacheLock.unlock()
                }
                completion(.success(items))
            } catch { completion(.failure(error)) }
        }
        task.resume()
        return task
    }

    static func makeRequest(language: String) -> URLRequest {
        FirestormAPI.makeRequest(method: "GetLauncherLastNews", parameters: [5, language == "ru" ? 4 : 0, "34"])
    }

    static func decodeAPI(_ data: Data, language: String) throws -> [FirestormFixesItem] {
        let result = try FirestormAPI.decodeResult(data)
        guard let rows = result["News"] as? [Any] else { throw Failure.invalidResponse }
        let localeID = language == "ru" ? 4 : 0
        let locale = language == "ru" ? "ru" : "en"
        var seen = Set<String>()
        var items: [FirestormFixesItem] = []
        for candidate in rows {
            guard let row = candidate as? [String: Any],
                  FirestormAPI.integer(row["CategoryID"]) == 2,
                  FirestormAPI.integer(row["SubCategoryID"]) == 34,
                  FirestormAPI.flag(row["Visible"], default: true),
                  let number = FirestormAPI.integer(row["ID"] ?? row["Id"]), number > 0,
                  let titleHTML = FirestormAPI.localized(row["Title"], localeID: localeID),
                  let contentHTML = FirestormAPI.localized(row["Content"], localeID: localeID) else { continue }
            let id = String(number)
            guard !seen.contains(id) else { continue }
            let title = FirestormAPI.plainText(titleHTML)
            let body = FirestormAPI.richBlockText(contentHTML)
            guard !title.isEmpty, !body.text.isEmpty else { continue }
            seen.insert(id)
            let date = FirestormAPI.double(row["Date"]).flatMap { $0 > 0 && $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
            items.append(FirestormFixesItem(
                id: id, title: title, bodyText: body.text, publishedAt: date,
                articleURL: URL(string: "https://firestorm-servers.com/\(locale)/news/\(id)")!,
                bodyLinks: body.links, bodyBoldRanges: body.boldRanges
            ))
        }
        return items
    }
}
