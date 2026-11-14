import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public let sendclapVersion = "0.1.0"

/// Every error the SDK throws.
public enum SendclapError: Error, LocalizedError, Equatable {
    /// 404: the license key does not exist, or it was disabled after a refund or dispute.
    case invalidLicense(String)
    /// 409: the key is already activated on as many instances as it allows.
    case activationLimit(String, license: LicenseInfo, product: ProductRef)
    /// Any other non-2xx answer (400, 401, 404, 5xx, HTML error pages) or an unreadable response.
    case api(status: Int, message: String)
    /// No HTTP response: DNS, connection, TLS failure or timeout.
    case network(String)

    /// The HTTP status, 0 for network errors.
    public var status: Int {
        switch self {
        case .invalidLicense: return 404
        case .activationLimit: return 409
        case .api(let status, _): return status
        case .network: return 0
        }
    }

    public var message: String {
        switch self {
        case .invalidLicense(let m), .activationLimit(let m, _, _), .api(_, let m), .network(let m): return m
        }
    }

    public var errorDescription: String? { message }
}

struct Transport {
    let baseURL: String
    let timeout: TimeInterval
    let session: URLSession
    let apiKey: String?

    init(baseURL: String, timeout: TimeInterval, session: URLSession, apiKey: String?) {
        var base = baseURL
        while base.hasSuffix("/") { base.removeLast() }
        self.baseURL = base
        self.timeout = timeout
        self.session = session
        self.apiKey = apiKey
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    func send<T: Decodable>(_ method: String, _ path: String, query: [(String, String?)] = [], body: Data? = nil) async throws -> T {
        guard var url = URLComponents(string: baseURL + "/api/v1" + path) else { throw SendclapError.network("invalid base URL") }
        let items = query.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
        if !items.isEmpty {
            url.queryItems = items
            // URLComponents leaves + and @ alone; encode them so emails survive the query string.
            url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").replacingOccurrences(of: "@", with: "%40")
        }
        var req = URLRequest(url: url.url!, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("sendclap-swift/\(sendclapVersion)", forHTTPHeaderField: "User-Agent")
        if let apiKey = apiKey, !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        if let body = body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        // A dataTask wrapper instead of `data(for:)`, which older Linux Foundation lacks.
        // ponytail: Task cancellation is not forwarded to the URLSession task; the request timeout bounds it.
        let (data, response): (Data, URLResponse) = try await withCheckedThrowingContinuation { cont in
            session.dataTask(with: req) { data, response, error in
                if let error = error { return cont.resume(throwing: SendclapError.network(error.localizedDescription)) }
                guard let response = response else { return cont.resume(throwing: SendclapError.network("no response")) }
                cont.resume(returning: (data ?? Data(), response))
            }.resume()
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw SendclapError.network("not an HTTP response") }

        guard (200..<300).contains(status) else {
            // HTML error pages (unknown routes, proxies) fall through to .api with "HTTP <status>".
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = obj?["error"] as? String ?? "HTTP \(status)"
            if status == 404, obj?["valid"] as? Bool == false { throw SendclapError.invalidLicense(message) }
            if status == 409, obj?["activated"] as? Bool == false, let r = try? Transport.decoder.decode(DeactivateResult.self, from: data) {
                throw SendclapError.activationLimit(message, license: r.license, product: r.product)
            }
            throw SendclapError.api(status: status, message: message)
        }
        do {
            return try Transport.decoder.decode(T.self, from: data)
        } catch {
            throw SendclapError.api(status: status, message: "invalid JSON response")
        }
    }
}

private func escapePath(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s
}

/// License keys from the app you ship. Needs no API key: activate an instance, validate on start, deactivate to free a seat.
public final class LicenseClient {
    let t: Transport

    /// - Parameters:
    ///   - baseURL: Defaults to https://sendclap.com.
    ///   - timeout: Per request, in seconds.
    ///   - session: The URLSession to use, `.shared` by default.
    public init(baseURL: String = "https://sendclap.com", timeout: TimeInterval = 15, session: URLSession = .shared) {
        t = Transport(baseURL: baseURL, timeout: timeout, session: session, apiKey: nil)
    }

    /// A per-machine instance name: the host name. It is sent to Sendclap and shown to the creator, and two machines with
    /// the same host name share one activation. On iOS prefer `UIDevice.current.identifierForVendor?.uuidString`.
    public static func instanceName() -> String { ProcessInfo.processInfo.hostName }

    /// Registers this instance against the key. Activating the same instance again counts once.
    /// Throws `.invalidLicense`, `.activationLimit`, `.api` or `.network`.
    public func activate(licenseKey: String, instanceName: String) async throws -> ActivateResult {
        try await t.send("POST", "/licenses/activate", body: body(licenseKey, instanceName))
    }

    /// Checks the key, and with `instanceId` that this instance is activated. An unknown or disabled key returns
    /// status `.invalid` instead of throwing, so a thrown error means "could not check" (offline: use your grace period).
    public func validate(licenseKey: String, instanceId: String? = nil) async throws -> ValidateResult {
        do {
            let r: ValidateResponse = try await t.send("POST", "/licenses/validate", body: body(licenseKey, instanceId))
            return ValidateResult(valid: r.valid, status: r.valid ? .active : .notActivated, license: r.license, product: r.product)
        } catch SendclapError.invalidLicense {
            return ValidateResult(valid: false, status: .invalid, license: nil, product: nil)
        }
    }

    /// Releases an instance, freeing one activation.
    public func deactivate(licenseKey: String, instanceId: String) async throws -> DeactivateResult {
        try await t.send("POST", "/licenses/deactivate", body: body(licenseKey, instanceId))
    }

    private func body(_ key: String, _ instance: String?) throws -> Data {
        var b = ["license_key": key]
        if let instance = instance, !instance.isEmpty { b["instance_id"] = instance }
        return try JSONSerialization.data(withJSONObject: b, options: [.sortedKeys])
    }
}

/// The creator REST API, authenticated with an `sc_…` key. Server side only: never ship the key inside an app.
public final class APIClient {
    let t: Transport

    /// - Parameter apiKey: Your `sc_…` key. May be nil for `getCreator`, which is public.
    public init(apiKey: String?, baseURL: String = "https://sendclap.com", timeout: TimeInterval = 15, session: URLSession = .shared) {
        t = Transport(baseURL: baseURL, timeout: timeout, session: session, apiKey: apiKey)
    }

    public func createCheckout(_ params: CheckoutParams) async throws -> Checkout {
        try await t.send("POST", "/checkouts", body: Transport.encoder.encode(params))
    }

    /// The checkout's `url` is only returned by `createCheckout`.
    public func getCheckout(id: String) async throws -> Checkout { try await t.send("GET", "/checkouts/" + escapePath(id)) }

    public func me() async throws -> Stats { try await t.send("GET", "/me") }

    /// - Parameter limit: 1 to 500, the server defaults to 50.
    public func listPayments(status: String? = nil, type: String? = nil, email: String? = nil, limit: Int? = nil) async throws -> [Payment] {
        try await t.send("GET", "/payments", query: [("status", status), ("type", type), ("email", email), ("limit", limit.map(String.init))])
    }

    public func getPayment(id: Int) async throws -> PaymentDetail { try await t.send("GET", "/payments/\(id)") }

    public func listMembers() async throws -> [Member] { try await t.send("GET", "/members") }

    public func listLicenses(email: String? = nil) async throws -> [IssuedLicense] {
        try await t.send("GET", "/licenses", query: [("email", email)])
    }

    public func listDisputes() async throws -> [Dispute] { try await t.send("GET", "/disputes") }

    public func listProducts() async throws -> [Product] { try await t.send("GET", "/products") }

    public func listMemberships() async throws -> [Membership] { try await t.send("GET", "/memberships") }

    /// Public: works without an API key.
    public func getCreator(handle: String) async throws -> Creator { try await t.send("GET", "/creators/" + escapePath(handle)) }
}
