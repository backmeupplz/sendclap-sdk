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
    static let checkout = #"{"id":"0xabc","status":"pending","type":"product","amount":29,"currency":"usd","method":"card","email":"b@example.com""#
    static let html = "<!doctype html><h1>Not found</h1>"

    static func route(_ req: URLRequest, _ body: Data?) -> (Int, String) {
        let url = req.url!, path = url.path, query = url.query.map { "?" + $0 } ?? ""
        if path.hasPrefix("/api/v1/licenses/") {
            let b = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: String] ?? [:]
            let key = b["license_key"], instance = b["instance_id"], action = url.lastPathComponent
            if key != "GOOD" && key != "FULL" { return (404, #"{"valid":false,"error":"license key not found"}"#) }
            if action == "validate" { return (200, "{\"valid\":\(instance == nil || instance == "dev-1"),\(meta)}") }
            guard let instance = instance else { return (400, #"{"error":"instance_id is required"}"#) }
            if action == "activate" && key == "FULL" {
                return (409, #"{"activated":false,"error":"activation limit reached","license":{"key":"FULL","activations":3,"max_activations":3},"product":{"id":1,"name":"Pro"}}"#)
            }
            if action == "activate" { return (200, "{\"activated\":true,\"instance_id\":\"\(instance)\",\(meta)}") }
            return (200, "{\"deactivated\":true,\(meta.replacingOccurrences(of: "\"activations\":1", with: "\"activations\":0"))}")
        }
        if path == "/api/v1/creators/demo" {
            return (200, #"{"handle":"demo","name":"Ada Builds","bio":"","url":"https://sendclap.com/demo","avatar":null,"links":[{"label":"GitHub","url":"https://github.com/ada"}],"payment_methods":{"card":true,"crypto":false,"x402":false},"tip":{"suggested":5,"currency":"usd","page":"https://sendclap.com/demo","x402":null},"memberships":[{"id":1,"name":"Supporter","description":"","price":5,"currency":"usd","interval":"month","x402":null}],"products":[]}"#)
        }
        if !path.hasPrefix("/api/v1/") { return (404, html) }
        if req.value(forHTTPHeaderField: "Authorization") != "Bearer sc_test" { return (401, #"{"error":"invalid API key"}"#) }
        switch (req.httpMethod ?? "GET", path) {
        case ("POST", "/api/v1/checkouts"): return (201, checkout + #","url":"https://sendclap.com/checkout/0xabc"}"#)
        case ("GET", "/api/v1/checkouts/0xabc"): return (200, checkout + "}")
        case ("GET", "/api/v1/me"):
            return (200, #"{"handle":"demo","name":"Ada","url":"u","currency":"usd","last_30_days":{"payments":2,"gross":58,"fees":0.58,"net":57.42},"all_time":{"payments":3,"gross":87,"fees":0.87,"net":86.13},"members":{"active":1,"monthly_recurring":5},"open_disputes":0}"#)
        case ("GET", "/api/v1/payments"):
            return (200, "[{\"id\":42,\"type\":\"product\",\"method\":\"card\",\"status\":\"paid\",\"amount\":29,\"fee\":0.29,\"currency\":\"usd\",\"email\":null,\"message\":null,\"reference\":\"\(query)\",\"test\":false,\"created_at\":\"2026-11-13T18:04:11.000Z\"}]")
        case ("GET", "/api/v1/payments/42"):
            return (200, #"{"id":42,"type":"product","method":"card","status":"paid","amount":29,"fee":0.29,"currency":"usd","email":null,"message":null,"reference":null,"test":true,"created_at":"2026-11-13T18:04:11.000Z","item":"Pro","purchase_ip":null,"purchase_device":null,"dispute":{"id":"dp_1","status":"open","reason":null,"respond_by":null},"activity":[{"at":"2026-11-13T18:04:11.000Z","event":"license_activate","detail":"Pro","ip":null}],"evidence_pdf":"https://sendclap.com/dashboard/evidence/42/pdf"}"#)
        case ("GET", "/api/v1/payments/7"): return (404, #"{"error":"payment not found"}"#)
        case ("GET", "/api/v1/licenses"):
            return (200, "[{\"key\":\"GOOD\",\"product\":\"Pro\",\"email\":\"\(query)\",\"activations\":1,\"max_activations\":3,\"disabled\":false,\"issued_at\":\"2026-11-13T18:04:11.000Z\"}]")
        case ("GET", "/api/v1/members"), ("GET", "/api/v1/disputes"), ("GET", "/api/v1/products"), ("GET", "/api/v1/memberships"): return (200, "[]")
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
        XCTAssertEqual(r.license, LicenseInfo(key: "GOOD", activations: 1, maxActivations: 3))
        XCTAssertEqual(r.product, ProductRef(id: 1, name: "Pro"))
        XCTAssertEqual(MockServer.last?.url?.absoluteString, "http://mock.test/api/v1/licenses/activate")
        XCTAssertEqual(MockServer.lastBody, #"{"instance_id":"dev-1","license_key":"GOOD"}"#)
        XCTAssertEqual(MockServer.last?.value(forHTTPHeaderField: "User-Agent"), "sendclap-swift/0.1.0")
        XCTAssertEqual(MockServer.last?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(MockServer.last?.value(forHTTPHeaderField: "Authorization"))
    }

    func testActivationLimit() async {
        let full = LicenseInfo(key: "FULL", activations: 3, maxActivations: 3)
        await assertThrows(.activationLimit("activation limit reached", license: full, product: ProductRef(id: 1, name: "Pro"))) {
            _ = try await self.client.activate(licenseKey: "FULL", instanceName: "dev-9")
        }
        XCTAssertEqual(SendclapError.activationLimit("", license: full, product: ProductRef(id: nil, name: nil)).status, 409)
    }

    func testInvalidKeyAndMissingInstance() async {
        await assertThrows(.invalidLicense("license key not found")) { _ = try await self.client.activate(licenseKey: "BAD", instanceName: "dev-1") }
        await assertThrows(.invalidLicense("license key not found")) { _ = try await self.client.deactivate(licenseKey: "BAD", instanceId: "dev-1") }
        await assertThrows(.api(status: 400, message: "instance_id is required")) { _ = try await self.client.activate(licenseKey: "GOOD", instanceName: "") }
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
        XCTAssertEqual(bad, ValidateResult(valid: false, status: .invalid, license: nil, product: nil))
    }

    func testDeactivate() async throws {
        let r = try await client.deactivate(licenseKey: "GOOD", instanceId: "dev-1")
        XCTAssertEqual(r.license.activations, 0)
    }

    func testHtmlNotFoundIsNotAnInvalidLicense() async {
        let wrong = LicenseClient(baseURL: "http://mock.test/wrong", session: MockServer.session)
        await assertThrows(.api(status: 404, message: "HTTP 404")) { _ = try await wrong.validate(licenseKey: "GOOD") }
    }

    func testConnectionRefusedIsNetworkError() async {
        do {
            _ = try await LicenseClient(baseURL: "http://127.0.0.1:1", timeout: 5).validate(licenseKey: "GOOD")
            XCTFail("expected a network error")
        } catch let e as SendclapError {
            guard case .network = e else { return XCTFail("got \(e)") }
            XCTAssertEqual(e.status, 0)
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
        XCTAssertEqual(MockServer.last?.value(forHTTPHeaderField: "User-Agent"), "sendclap-swift/0.1.0")
    }

    func testGetCheckoutHasNoURL() async throws {
        let c = try await client.getCheckout(id: "0xabc")
        XCTAssertEqual(c.status, "pending")
        XCTAssertNil(c.url)
        XCTAssertEqual(MockServer.last?.httpMethod, "GET")
    }

    func testMe() async throws {
        let s = try await client.me()
        XCTAssertEqual(s.last30Days.payments, 2)
        XCTAssertEqual(s.allTime.net, 86.13)
        XCTAssertEqual(s.members.monthlyRecurring, 5)
    }

    func testListPaymentsEncodesQuery() async throws {
        let p = try await client.listPayments(status: "paid", email: "a+b@example.com", limit: 2)
        XCTAssertEqual(p[0].reference, "?status=paid&email=a%2Bb%40example.com&limit=2")
        XCTAssertEqual(p[0].fee, 0.29)
        XCTAssertEqual(p[0].createdAt, "2026-11-13T18:04:11.000Z")
    }

    func testGetPayment() async throws {
        let p = try await client.getPayment(id: 42)
        XCTAssertEqual(p.item, "Pro")
        XCTAssertEqual(p.dispute?.id, "dp_1")
        XCTAssertEqual(p.activity.first?.event, "license_activate")
        await assertThrows(.api(status: 404, message: "payment not found")) { _ = try await self.client.getPayment(id: 7) }
    }

    func testListEndpoints() async throws {
        let licenses = try await client.listLicenses(email: "a@b.c")
        XCTAssertEqual(licenses[0].email, "?email=a%40b.c")
        let members = try await client.listMembers(), disputes = try await client.listDisputes()
        let products = try await client.listProducts(), memberships = try await client.listMemberships()
        XCTAssertTrue(members.isEmpty && disputes.isEmpty && products.isEmpty && memberships.isEmpty)
    }

    func testWrongKey() async {
        let wrong = APIClient(apiKey: "sc_wrong", baseURL: "http://mock.test", session: MockServer.session)
        await assertThrows(.api(status: 401, message: "invalid API key")) { _ = try await wrong.me() }
    }

    func testGetCreatorWithoutKey() async throws {
        let c = try await APIClient(apiKey: nil, baseURL: "http://mock.test", session: MockServer.session).getCreator(handle: "demo")
        XCTAssertNil(MockServer.last?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(c.name, "Ada Builds")
        XCTAssertTrue(c.paymentMethods.card)
        XCTAssertEqual(c.memberships.first?.interval, "month")
        XCTAssertEqual(c.tip.suggested, 5)
    }
}
