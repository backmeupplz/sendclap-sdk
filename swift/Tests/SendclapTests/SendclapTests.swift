import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import Sendclap

/// Answers like the real server for the fixtures in SPEC.md, and records the last request.
final class MockServer: URLProtocol {
    static var last: URLRequest?
    static var lastBody: String?

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockServer.self]
        return URLSession(configuration: config)
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            body = data
        }
        MockServer.last = request
        MockServer.lastBody = body.map { String(decoding: $0, as: UTF8.self) }
        let (status, text) = MockServer.route(request, body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": text.hasPrefix("<") ? "text/html" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    static let meta = #""license":{"key":"GOOD","activations":1,"max_activations":3},"product":{"id":1,"name":"Pro"}"#
    static let lapsed = #""license":{"key":"LAPSED","activations":1,"max_activations":3,"expires_at":"2026-01-01T00:00:00.000Z"},"product":{"id":1,"name":"Pro"}"#
    static let checkout = #"{"id":"0xabc","status":"pending","type":"product","amount":29,"currency":"usd","method":"card","email":"b@example.com","url":"https://sendclap.com/checkout/0xabc","paid_at":null"#
    static func payment(_ id: Int, _ reference: String) -> String {
        "{\"id\":\(id),\"type\":\"product\",\"method\":\"card\",\"status\":\"paid\",\"amount\":29,\"fee\":0.29,\"currency\":\"usd\",\"email\":null,\"message\":null,\"reference\":\"\(reference)\",\"test\":false,\"created_at\":\"2026-11-13T18:04:11.000Z\"}"
    }
    static let html = "<!doctype html><h1>Not found</h1>"

    static func route(_ req: URLRequest, _ body: Data?) -> (Int, String) {
        let url = req.url!, path = url.path, query = url.query.map { "?" + $0 } ?? ""
        if path.hasPrefix("/api/v1/licenses/") {
            let b = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: String] ?? [:]
            let key = b["license_key"], instance = b["instance_id"], action = url.lastPathComponent
            if action == "validate" {
                if key == "LAPSED" { return (200, "{\"valid\":false,\"status\":\"expired\",\(lapsed)}") }
                if key == "REFUNDED" { return (200, #"{"valid":false,"status":"disabled"}"#) }
                if key != "GOOD" && key != "FULL" { return (200, #"{"valid":false,"status":"not_found"}"#) }
                let ok = instance == nil || instance == "dev-1"
                return (200, "{\"valid\":\(ok),\"status\":\"\(ok ? "active" : "not_activated")\",\(meta)}")
            }
            if key == "LAPSED" { return (403, "{\"error\":\"this license key has expired\",\"code\":\"license_expired\",\(lapsed)}") }
            if key == "REFUNDED" { return (403, #"{"error":"this license key is disabled","code":"license_disabled"}"#) }
            if key != "GOOD" && key != "FULL" { return (404, #"{"error":"license key not found","code":"license_not_found"}"#) }
            guard let instance = instance else { return (400, #"{"error":"instance_id is required","code":"bad_request"}"#) }
            if action == "deactivate" && instance != "dev-1" {
                return (404, #"{"error":"that instance is not activated","code":"instance_not_found"}"#)
            }
            if action == "activate" && key == "FULL" {
                return (409, #"{"error":"activation limit reached","code":"activation_limit","license":{"key":"FULL","activations":3,"max_activations":3},"product":{"id":1,"name":"Pro"}}"#)
            }
            if action == "activate" { return (200, "{\"activated\":true,\"instance_id\":\"\(instance)\",\(meta)}") }
            return (200, "{\"deactivated\":true,\(meta.replacingOccurrences(of: "\"activations\":1", with: "\"activations\":0"))}")
        }
        if path == "/api/v1/creators/demo" {
            return (200, #"{"handle":"demo","name":"Ada Builds","bio":"","url":"https://sendclap.com/demo","avatar":null,"links":[{"label":"GitHub","url":"https://github.com/ada"}],"payment_methods":{"card":true,"crypto":false,"x402":false},"tip":{"suggested":5,"currency":"usd","page":"https://sendclap.com/demo","x402":null},"memberships":[{"id":1,"name":"Supporter","description":"","price":5,"currency":"usd","interval":"month","x402":null}],"products":[{"id":1,"name":"Weekly","description":"","price":3,"currency":"usd","delivers_file":false,"issues_license_key":true,"page":"p","x402":null,"interval":"week"},{"id":2,"name":"Once","description":"","price":9,"currency":"usd","delivers_file":true,"issues_license_key":false,"page":"p","x402":null,"interval":null}]}"#)
        }
        if !path.hasPrefix("/api/v1/") { return (404, html) }
        if req.value(forHTTPHeaderField: "Authorization") != "Bearer sc_test" { return (401, #"{"error":"invalid API key","code":"invalid_api_key"}"#) }
        switch (req.httpMethod ?? "GET", path) {
        case ("POST", "/api/v1/checkouts"): return (201, checkout + "}")
        case ("GET", "/api/v1/checkouts/0xabc"): return (200, checkout + "}")
        case ("GET", "/api/v1/checkouts/0xpaid"): return (200, checkout.replacingOccurrences(of: "\"paid_at\":null", with: "\"paid_at\":\"2026-11-14T10:00:00.000Z\"") + "}")
        case ("GET", "/api/v1/me"):
            return (200, #"{"handle":"demo","name":"Ada","url":"u","currency":"usd","last_30_days":{"payments":2,"gross":58,"fees":0.58,"net":57.42},"all_time":{"payments":3,"gross":87,"fees":0.87,"net":86.13},"members":{"active":1,"monthly_recurring":5},"open_disputes":0}"#)
        case ("GET", "/api/v1/payments"):
            // two pages; the reference echoes the query so tests can check it
            if query.contains("after=41") { return (200, "{\"data\":[\(payment(40, query))],\"has_more\":false,\"next\":null}") }
            return (200, "{\"data\":[\(payment(42, query)),\(payment(41, query))],\"has_more\":true,\"next\":41}")
        case ("GET", "/api/v1/payments/42"):
            return (200, #"{"id":42,"type":"product","method":"card","status":"paid","amount":29,"fee":0.29,"currency":"usd","email":null,"message":null,"reference":null,"test":true,"created_at":"2026-11-13T18:04:11.000Z","item":"Pro","purchase_ip":null,"purchase_device":null,"dispute":{"id":"dp_1","status":"open","reason":null,"respond_by":null},"activity":[{"at":"2026-11-13T18:04:11.000Z","event":"license_activate","detail":"Pro","ip":null}],"evidence_pdf":"https://sendclap.com/dashboard/evidence/42/pdf"}"#)
        case ("GET", "/api/v1/payments/7"): return (404, #"{"error":"payment not found","code":"not_found"}"#)
        case ("GET", "/api/v1/licenses"):
            return (200, "{\"data\":[{\"key\":\"GOOD\",\"product\":\"Pro\",\"email\":\"\(query)\",\"activations\":1,\"max_activations\":3,\"disabled\":false,\"issued_at\":\"2026-11-13T18:04:11.000Z\"}],\"has_more\":false,\"next\":null}")
        case ("GET", "/api/v1/members"), ("GET", "/api/v1/disputes"): return (200, #"{"data":[],"has_more":false,"next":null}"#)
        case ("GET", "/api/v1/products"), ("GET", "/api/v1/memberships"): return (200, "[]")
        default: return (404, html)
        }
    }
}

func assertThrows(_ expected: SendclapError, _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        try await body()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? SendclapError, expected, file: file, line: line)
    }
}

final class LicenseClientTests: XCTestCase {
    let client = LicenseClient(baseURL: "http://mock.test/", session: MockServer.session)

    func testActivate() async throws {
        let r = try await client.activate(licenseKey: "GOOD", instanceName: "dev-1")
        XCTAssertEqual(r.instanceId, "dev-1")
        XCTAssertEqual(r.license, LicenseInfo(key: "GOOD", activations: 1, maxActivations: 3, expiresAt: nil))
        XCTAssertEqual(r.product, ProductRef(id: 1, name: "Pro"))
        XCTAssertEqual(MockServer.last?.url?.absoluteString, "http://mock.test/api/v1/licenses/activate")
        XCTAssertEqual(MockServer.lastBody, #"{"instance_id":"dev-1","license_key":"GOOD"}"#)
        XCTAssertEqual(MockServer.last?.value(forHTTPHeaderField: "User-Agent"), "sendclap-swift/0.5.0")
        XCTAssertEqual(MockServer.last?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(MockServer.last?.value(forHTTPHeaderField: "Authorization"))
    }

    func testActivationLimit() async {
        let full = LicenseInfo(key: "FULL", activations: 3, maxActivations: 3, expiresAt: nil)
        await assertThrows(.activationLimit("activation limit reached", license: full, product: ProductRef(id: 1, name: "Pro"))) {
            _ = try await self.client.activate(licenseKey: "FULL", instanceName: "dev-9")
        }
        let limit = SendclapError.activationLimit("", license: full, product: ProductRef(id: nil, name: nil))
        XCTAssertEqual(limit.status, 409)
        XCTAssertEqual(limit.code, "activation_limit")
    }

    func testInvalidKeyAndMissingInstance() async {
        await assertThrows(.invalidLicense("license key not found")) { _ = try await self.client.activate(licenseKey: "BAD", instanceName: "dev-1") }
        await assertThrows(.invalidLicense("license key not found")) { _ = try await self.client.deactivate(licenseKey: "BAD", instanceId: "dev-1") }
        await assertThrows(.api(status: 400, code: "bad_request", message: "instance_id is required")) { _ = try await self.client.activate(licenseKey: "GOOD", instanceName: "") }
        XCTAssertEqual(SendclapError.invalidLicense("x").code, "license_not_found")
    }

    func testDisabledLicense() async throws {
        await assertThrows(.licenseDisabled("this license key is disabled")) { _ = try await self.client.activate(licenseKey: "REFUNDED", instanceName: "dev-1") }
        let e = SendclapError.licenseDisabled("x")
        XCTAssertEqual(e.status, 403)
        XCTAssertEqual(e.code, "license_disabled")
    }

    func testExpiredLicense() async throws {
        let v = try await client.validate(licenseKey: "LAPSED", instanceId: "dev-1")
        XCTAssertFalse(v.valid)
        XCTAssertEqual(v.status, .expired)
        XCTAssertEqual(v.license?.expiresAt, "2026-01-01T00:00:00.000Z")
        XCTAssertEqual(v.product?.name, "Pro")
        let lapsed = LicenseInfo(key: "LAPSED", activations: 1, maxActivations: 3, expiresAt: "2026-01-01T00:00:00.000Z")
        await assertThrows(.licenseExpired("this license key has expired", license: lapsed, product: ProductRef(id: 1, name: "Pro"))) {
            _ = try await self.client.activate(licenseKey: "LAPSED", instanceName: "dev-1")
        }
        let e = SendclapError.licenseExpired("x", license: lapsed, product: ProductRef(id: nil, name: nil))
        XCTAssertEqual(e.status, 403)
        XCTAssertEqual(e.code, "license_expired")
    }

    func testInstanceNotFound() async {
        await assertThrows(.instanceNotFound("that instance is not activated")) { _ = try await self.client.deactivate(licenseKey: "GOOD", instanceId: "nope") }
    }

    func testValidateStatuses() async throws {
        let keyOnly = try await client.validate(licenseKey: "GOOD")
        XCTAssertEqual(keyOnly.status, .active)
        XCTAssertEqual(MockServer.lastBody, #"{"license_key":"GOOD"}"#)
        let active = try await client.validate(licenseKey: "GOOD", instanceId: "dev-1")
        XCTAssertTrue(active.valid)
        let other = try await client.validate(licenseKey: "GOOD", instanceId: "dev-2")
        XCTAssertEqual(other.status, .notActivated)
        XCTAssertFalse(other.valid)
        XCTAssertEqual(other.license?.maxActivations, 3)
        let bad = try await client.validate(licenseKey: "BAD", instanceId: "dev-1")
        XCTAssertEqual(bad, ValidateResult(valid: false, status: .notFound, license: nil, product: nil))
        let refunded = try await client.validate(licenseKey: "REFUNDED", instanceId: "dev-1")
        XCTAssertEqual(refunded, ValidateResult(valid: false, status: .disabled, license: nil, product: nil))
    }

    func testDeactivate() async throws {
        let r = try await client.deactivate(licenseKey: "GOOD", instanceId: "dev-1")
        XCTAssertEqual(r.license.activations, 0)
    }

    func testHtmlNotFoundIsNotAnInvalidLicense() async {
        let wrong = LicenseClient(baseURL: "http://mock.test/wrong", session: MockServer.session)
        await assertThrows(.api(status: 404, code: "", message: "HTTP 404")) { _ = try await wrong.validate(licenseKey: "GOOD") }
    }

    func testConnectionRefusedIsNetworkError() async {
        do {
            _ = try await LicenseClient(baseURL: "http://127.0.0.1:1", timeout: 5).validate(licenseKey: "GOOD")
            XCTFail("expected a network error")
        } catch let e as SendclapError {
            guard case .network = e else { return XCTFail("got \(e)") }
            XCTAssertEqual(e.status, 0)
            XCTAssertEqual(e.code, "network_error")
        } catch {
            XCTFail("got \(error)")
        }
    }

    func testInstanceName() {
        XCTAssertFalse(LicenseClient.instanceName().isEmpty)
    }
}

final class APIClientTests: XCTestCase {
    let client = APIClient(apiKey: "sc_test", baseURL: "http://mock.test", session: MockServer.session)

    func testCreateCheckout() async throws {
        let c = try await client.createCheckout(CheckoutParams(type: "product", productId: 1, email: "b@example.com"))
        XCTAssertEqual(c.id, "0xabc")
        XCTAssertEqual(c.amount, 29)
        XCTAssertEqual(c.url, "https://sendclap.com/checkout/0xabc")
        let sent = try JSONSerialization.jsonObject(with: Data(MockServer.lastBody!.utf8)) as? NSDictionary
        XCTAssertEqual(sent, ["type": "product", "product_id": 1, "email": "b@example.com"] as NSDictionary)
        XCTAssertEqual(MockServer.last?.value(forHTTPHeaderField: "Authorization"), "Bearer sc_test")
        XCTAssertEqual(MockServer.last?.value(forHTTPHeaderField: "User-Agent"), "sendclap-swift/0.5.0")
    }

    func testGetCheckoutHasURL() async throws {
        let c = try await client.getCheckout(id: "0xabc")
        XCTAssertEqual(c.status, "pending")
        XCTAssertEqual(c.url, "https://sendclap.com/checkout/0xabc")
        XCTAssertNil(c.paidAt)
        let paid = try await client.getCheckout(id: "0xpaid")
        XCTAssertEqual(paid.paidAt, "2026-11-14T10:00:00.000Z")
        XCTAssertEqual(MockServer.last?.httpMethod, "GET")
    }

    func testMe() async throws {
        let s = try await client.me()
        XCTAssertEqual(s.last30Days.payments, 2)
        XCTAssertEqual(s.allTime.net, 86.13)
        XCTAssertEqual(s.members.monthlyRecurring, 5)
    }

    func testListPaymentsReturnsAPage() async throws {
        let p = try await client.listPayments(status: "paid", email: "a+b@example.com", limit: 2)
        XCTAssertEqual(p.data[0].reference, "?status=paid&email=a%2Bb%40example.com&limit=2")
        XCTAssertEqual(p.data[0].fee, 0.29)
        XCTAssertEqual(p.data[0].createdAt, "2026-11-13T18:04:11.000Z")
        XCTAssertTrue(p.hasMore)
        XCTAssertEqual(p.next, 41)
        let last = try await client.listPayments(after: p.next)
        XCTAssertEqual(last.data[0].reference, "?after=41")
        XCTAssertFalse(last.hasMore)
        XCTAssertNil(last.next)
    }

    func testAllPaymentsFollowsNext() async throws {
        var ids: [Int] = []
        for try await p in client.allPayments(status: "paid", limit: 2) { ids.append(p.id) }
        XCTAssertEqual(ids, [42, 41, 40])
        XCTAssertEqual(MockServer.last?.url?.query, "status=paid&limit=2&after=41")
    }

    func testGetPayment() async throws {
        let p = try await client.getPayment(id: 42)
        XCTAssertEqual(p.item, "Pro")
        XCTAssertEqual(p.dispute?.id, "dp_1")
        XCTAssertEqual(p.activity.first?.event, "license_activate")
        await assertThrows(.api(status: 404, code: "not_found", message: "payment not found")) { _ = try await self.client.getPayment(id: 7) }
    }

    func testListEndpoints() async throws {
        let licenses = try await client.listLicenses(email: "a@b.c")
        XCTAssertEqual(licenses.data[0].email, "?email=a%40b.c")
        var all = 0
        for try await _ in client.allLicenses() { all += 1 }
        for try await _ in client.allMembers() { all += 10 }
        for try await _ in client.allDisputes() { all += 10 }
        XCTAssertEqual(all, 1)
        let members = try await client.listMembers(), disputes = try await client.listDisputes()
        let products = try await client.listProducts(), memberships = try await client.listMemberships()
        XCTAssertTrue(members.data.isEmpty && disputes.data.isEmpty && products.isEmpty && memberships.isEmpty)
    }

    func testWrongKey() async {
        let wrong = APIClient(apiKey: "sc_wrong", baseURL: "http://mock.test", session: MockServer.session)
        await assertThrows(.api(status: 401, code: "invalid_api_key", message: "invalid API key")) { _ = try await wrong.me() }
    }

    func testGetCreatorWithoutKey() async throws {
        let c = try await APIClient(apiKey: nil, baseURL: "http://mock.test", session: MockServer.session).getCreator(handle: "demo")
        XCTAssertNil(MockServer.last?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(c.name, "Ada Builds")
        XCTAssertTrue(c.paymentMethods.card)
        XCTAssertEqual(c.memberships.first?.interval, "month")
        XCTAssertEqual(c.products.map(\.interval), ["week", nil])
        XCTAssertEqual(c.tip.suggested, 5)
    }
}
