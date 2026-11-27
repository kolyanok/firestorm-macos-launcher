import Foundation

struct FirestormRealmStatus {
    let name: String
    let isOnline: Bool
    let playersOnline: Int?
    let updatedAt: Date?
    let isLocked: Bool

    init(name: String, isOnline: Bool, playersOnline: Int?, updatedAt: Date?, isLocked: Bool = false) {
        self.name = name
        self.isOnline = isOnline
        self.playersOnline = playersOnline
        self.updatedAt = updatedAt
        self.isLocked = isLocked
    }
}

/// Silvermoon is realm 14. The API's Online field is its player count, not a
/// boolean. Realm availability follows the original launcher's heartbeat rule.
final class FirestormRealmService {
    enum Failure: Error {
        case invalidResponse
        case missingRealm
        case http(Int)
        case oversizedResponse
    }

    private let session: URLSession
    private let cacheLock = NSLock()
    private var cachedResponse: (data: Data, date: Date)?
    private static let maximumBytes = 512 * 1024
    private static let freshness: TimeInterval = 30

    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 25
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
    func load(completion: @escaping (Result<FirestormRealmStatus, Error>) -> Void) -> URLSessionDataTask? {
        cacheLock.lock()
        let cached = cachedResponse
        cacheLock.unlock()
        if let cached, Date().timeIntervalSince(cached.date) < Self.freshness {
            DispatchQueue.global(qos: .utility).async {
                completion(Result { try Self.decodeAPI(cached.data) })
            }
            return nil
        }
        let task = session.dataTask(with: Self.makeRequest()) { [weak self] data, response, error in
            do {
                if let error { throw error }
                guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
                guard (200..<300).contains(response.statusCode) else { throw Failure.http(response.statusCode) }
                guard let data else { throw Failure.invalidResponse }
                guard data.count <= Self.maximumBytes else { throw Failure.oversizedResponse }
                let realm = try Self.decodeAPI(data)
                if let self {
                    self.cacheLock.lock()
                    self.cachedResponse = (data, Date())
                    self.cacheLock.unlock()
                }
                completion(.success(realm))
            } catch { completion(.failure(error)) }
        }
        task.resume()
        return task
    }

    static func makeRequest() -> URLRequest {
        FirestormAPI.makeRequest(method: "GetAllRealmsInfo", parameters: [])
    }

    static func decodeAPI(_ data: Data, now: Date = Date()) throws -> FirestormRealmStatus {
        let result = try FirestormAPI.decodeResult(data)
        guard let rows = result["Realms"] as? [Any] else { throw Failure.invalidResponse }
        guard let row = rows.compactMap({ $0 as? [String: Any] }).first(where: { FirestormAPI.integer($0["ID"]) == 14 }) else {
            throw Failure.missingRealm
        }
        guard let lastUpdate = FirestormAPI.integer(row["Lastupdate"]), lastUpdate >= 0 else {
            throw Failure.invalidResponse
        }
        let name = (row["Name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = FirestormAPI.integer(row["Online"]).flatMap { $0 >= 0 ? $0 : nil }
        let heartbeat = TimeInterval(lastUpdate)
        return FirestormRealmStatus(
            name: name.flatMap { $0.isEmpty ? nil : $0 } ?? "Silvermoon",
            isOnline: heartbeat + 150 >= now.timeIntervalSince1970,
            playersOnline: count,
            updatedAt: lastUpdate > 0 ? Date(timeIntervalSince1970: heartbeat) : nil,
            isLocked: (FirestormAPI.integer(row["AllowedSecurityLevel"]) ?? 0) != 0
        )
    }
}
