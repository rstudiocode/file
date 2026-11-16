import CryptoKit
import Foundation
import Security

struct NASItem: Codable, Equatable {
    let name: String
    let path: String
    let dir: Bool
    let size: Int64?
    let date: String?

    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }

    var modified: Date? {
        guard let date else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = iso.date(from: date) { return value }
        iso.formatOptions = [.withInternetDateTime]
        if let value = iso.date(from: date) { return value }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = TimeZone(secondsFromGMT: 0)
        local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return local.date(from: date)
    }
}

struct RelayStatus: Decodable {
    let connected: Bool
    let remembered: Bool?
    let profile: String?
    let account: String?
}

struct RelayError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }

    static let authentication = RelayError(status: 401, message: "Reconnectez le NAS dans ASUSTOR Explorateur.")
    static let invalidResponse = RelayError(status: 502, message: "Le relais EZ‑Connect a renvoyé une réponse inattendue.")
}

struct RelayCookie: Codable, Equatable {
    static let name = "__Host-adm-session"
    let value: String
    let expiry: Date?
    var profile: String? = nil
    var rememberAcrossLaunch: Bool? = nil

    init?(_ cookie: HTTPCookie) {
        guard cookie.name == Self.name, cookie.domain == Relay.origin.host,
              cookie.path == "/", cookie.isSecure, !cookie.value.isEmpty else { return nil }
        value = cookie.value
        expiry = cookie.expiresDate
    }

    var httpCookie: HTTPCookie? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        var header = Self.name + "=" + value + "; Path=/; Secure; HttpOnly; SameSite=Strict"
        if let expiry { header += "; Expires=" + formatter.string(from: expiry) }
        return HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: Relay.origin).first
    }

    fileprivate var fingerprint: Data { Data(SHA256.hash(data: Data(value.utf8))) }

}

struct SessionStore {
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ASUSTOR EZ-Connect",
            kSecAttrAccount as String: Relay.origin.absoluteString,
            kSecAttrAccessGroup as String: Bundle.main.object(forInfoDictionaryKey: "ASUSTORKeychainGroup") as? String ?? ""
        ]
    }

    static func read() throws -> RelayCookie? {
        var query = query
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw RelayError.invalidResponse }
        let cookie = try JSONDecoder().decode(RelayCookie.self, from: data)
        if let expiry = cookie.expiry, expiry <= Date() { return nil }
        return cookie
    }

    static func write(_ cookie: RelayCookie) throws {
        let data = try JSONEncoder().encode(cookie)
        let values = [kSecValueData as String: data, kSecAttrGeneric as String: cookie.fingerprint]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status != errSecItemNotFound {
            try check(status)
            return
        }
        var attributes = query
        attributes.merge(values) { _, new in new }
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(attributes as CFDictionary, nil)
        if added == errSecDuplicateItem {
            try check(SecItemUpdate(query as CFDictionary, values as CFDictionary))
        } else {
            try check(added)
        }
    }

    static func replace(_ previous: RelayCookie, with next: RelayCookie) throws -> Bool {
        var condition = query
        condition[kSecAttrGeneric as String] = previous.fingerprint
        let values = [kSecValueData as String: try JSONEncoder().encode(next),
                      kSecAttrGeneric as String: next.fingerprint]
        let status = SecItemUpdate(condition as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound { return false }
        try check(status)
        return true
    }

    static func remove() throws {
        let result = SecItemDelete(query as CFDictionary)
        if result != errSecItemNotFound { try check(result) }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw RelayError(status: 500, message: "Le trousseau iOS est inaccessible. Vérifiez la signature et le groupe de trousseau de l’app.")
        }
    }
}

final class Relay: NSObject, URLSessionTaskDelegate {
    static let origin = URL(string: "https://asustor-explorateur.greg75.chatgpt.site")!
    static let shared = Relay()

    private let config: URLSessionConfiguration = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 3600
        return config
    }()

    private static let session = URLSession(configuration: shared.config, delegate: shared, delegateQueue: nil)

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    private func request(_ endpoint: String, _ parameters: [URLQueryItem], _ cookie: RelayCookie) -> URLRequest {
        var components = URLComponents(url: Self.origin.appendingPathComponent("api").appendingPathComponent(endpoint),
                                       resolvingAgainstBaseURL: false)!
        if !parameters.isEmpty { components.queryItems = parameters }
        var request = URLRequest(url: components.url!)
        request.setValue(RelayCookie.name + "=" + cookie.value, forHTTPHeaderField: "Cookie")
        return request
    }

    private func response(_ response: URLResponse, data: Data? = nil) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw RelayError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            struct ErrorBody: Decodable { let error: String }
            let body = data.flatMap { try? JSONDecoder().decode(ErrorBody.self, from: $0) }
            throw RelayError(status: http.statusCode, message: body?.error ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        return http
    }

    func status(_ cookie: RelayCookie, renew: Bool = false) async throws -> (RelayStatus, RelayCookie?) {
        let query = renew ? [URLQueryItem(name: "renew", value: "1")] : []
        let (body, raw) = try await Self.session.data(for: request("status", query, cookie))
        let http = try response(raw, data: body)
        let status = try JSONDecoder().decode(RelayStatus.self, from: body)
        let fields = http.allHeaderFields.reduce(into: [String: String]()) { fields, header in
            if let name = header.key as? String, let value = header.value as? String { fields[name] = value }
        }
        let updated = HTTPCookie.cookies(withResponseHeaderFields: fields, for: http.url ?? Self.origin)
            .compactMap(RelayCookie.init).first
        return (status, updated)
    }

    private func sessionForOperation<T>(profile: String, _ operation: (RelayCookie) async throws -> T) async throws -> T {
        guard let cookie = try SessionStore.read(), cookie.profile == profile else { throw RelayError.authentication }
        do {
            return try await operation(cookie)
        } catch let error as RelayError where error.status == 401 {
            if let current = try SessionStore.read(), current.profile == profile, current.value != cookie.value {
                return try await operation(current)
            }
            let (identity, updated) = try await status(cookie, renew: true)
            guard identity.connected, identity.profile == profile, var updated else { throw RelayError.authentication }
            updated.profile = profile
            updated.rememberAcrossLaunch = identity.remembered
            if try SessionStore.replace(cookie, with: updated) { return try await operation(updated) }
            guard let current = try SessionStore.read(), current.profile == profile, current.value != cookie.value else {
                throw RelayError.authentication
            }
            return try await operation(current)
        }
    }

    func list(_ folder: String, profile: String) async throws -> [NASItem] {
        try await sessionForOperation(profile: profile) { cookie in
            try await listing(folder, cookie)
        }
    }

    private func listing(_ folder: String, _ cookie: RelayCookie) async throws -> [NASItem] {
        let (body, raw) = try await Self.session.data(for: request("list", [.init(name: "path", value: folder)], cookie))
        _ = try response(raw, data: body)
        return try JSONDecoder().decode([NASItem].self, from: body).filter { item in
            !item.name.isEmpty && item.path.hasPrefix("/") && item.path != folder &&
                (folder == "/" || NASItem.parent(of: item.path) == folder)
        }
    }


    func recordOpening(_ path: String, profile: String) async {
        guard let cookie = try? SessionStore.read(), cookie.profile == profile else { return }
        var request = request("recent", [], cookie)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["path": path])
        _ = try? await Self.session.data(for: request)
    }

    func download(_ item: NASItem, profile: String, to directory: URL) async throws -> URL {
        guard !item.dir else { throw RelayError.invalidResponse }
        return try await sessionForOperation(profile: profile) { cookie in
            let params = [URLQueryItem(name: "path", value: item.path), .init(name: "download", value: "1")]
            let (temporaryURL, raw) = try await Self.session.download(for: request("content", params, cookie))
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            let http = try response(raw)
            guard http.statusCode == 200,
                  http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") == true else {
                throw RelayError.invalidResponse
            }
            try Task.checkCancellation()
            guard try SessionStore.read()?.profile == profile else { throw RelayError.authentication }
            let fileURL = directory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
            return fileURL
        }
    }
}
