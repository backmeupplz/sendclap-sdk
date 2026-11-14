// Response shapes of https://sendclap.com/docs. Amounts are US dollars; timestamps are ISO-8601 strings.

// MARK: License API

public struct LicenseInfo: Codable, Equatable, Sendable {
    public let key: String
    public let activations: Int
    public let maxActivations: Int
}

/// Both fields are nil if the product was deleted.
public struct ProductRef: Codable, Equatable, Sendable {
    public let id: Int?
    public let name: String?
}

public struct ActivateResult: Codable, Equatable, Sendable {
    /// The instance name you passed (Sendclap keeps up to 200 characters).
    public let instanceId: String
    public let license: LicenseInfo
    public let product: ProductRef
}

public enum LicenseStatus: String, Codable, Sendable {
    /// The key is valid (and, if an instance was given, that instance is activated).
    case active
    /// The key exists but this instance is not activated on it.
    case notActivated = "not_activated"
    /// The key exists but was disabled after a refund or dispute.
    case disabled
    /// The key does not exist.
    case notFound = "not_found"
}

public struct ValidateResult: Decodable, Equatable, Sendable {
    public let valid: Bool
    public let status: LicenseStatus
    /// nil when `status` is `.notFound` or `.disabled`.
    public let license: LicenseInfo?
    /// nil when `status` is `.notFound` or `.disabled`.
    public let product: ProductRef?
}

public struct DeactivateResult: Codable, Equatable, Sendable {
    public let license: LicenseInfo
    public let product: ProductRef
}

// MARK: Creator API

/// Body of `POST /api/v1/checkouts`. Nil fields are not sent.
public struct CheckoutParams: Encodable, Sendable {
    /// `tip`, `product` or `membership`.
    public var type: String
    /// Tip amount in US dollars (1 to 10000). Required for a tip.
    public var amount: Double?
    public var productId: Int?
    public var tierId: Int?
    /// Required for a membership.
    public var email: String?
    /// `card` (default) or `crypto`.
    public var method: String?
    public var message: String?

    public init(type: String, amount: Double? = nil, productId: Int? = nil, tierId: Int? = nil, email: String? = nil, method: String? = nil, message: String? = nil) {
        self.type = type
        self.amount = amount
        self.productId = productId
        self.tierId = tierId
        self.email = email
        self.method = method
        self.message = message
    }
}

public struct Checkout: Codable, Equatable, Sendable {
    public let id: String
    /// `pending` or `paid`.
    public let status: String
    public let type: String
    public let amount: Double
    public let currency: String
    public let method: String
    public let email: String?
    /// Where to send the customer to pay.
    public let url: String
    /// ISO 8601 time it was paid, nil while unpaid.
    public let paidAt: String?
}

/// One page of a list, newest first. When `hasMore` is true, pass `next` as `after` for the following page.
public struct Page<T: Decodable & Sendable>: Decodable, Sendable {
    public let data: [T]
    public let hasMore: Bool
    public let next: Int?
}

public struct Totals: Codable, Equatable, Sendable {
    public let payments: Int
    public let gross: Double
    public let fees: Double
    public let net: Double
}

public struct MemberStats: Codable, Equatable, Sendable {
    public let active: Int
    public let monthlyRecurring: Double
}

public struct Stats: Codable, Equatable, Sendable {
    public let handle: String
    public let name: String
    public let url: String
    public let currency: String
    public let last30Days: Totals
    public let allTime: Totals
    public let members: MemberStats
    public let openDisputes: Int
}

public struct Payment: Codable, Equatable, Sendable {
    public let id: Int
    public let type: String
    public let method: String
    public let status: String
    public let amount: Double
    public let fee: Double
    public let currency: String
    public let email: String?
    public let message: String?
    public let reference: String?
    public let test: Bool
    public let createdAt: String
}

public struct PaymentDetail: Codable, Equatable, Sendable {
    public let id: Int
    public let type: String
    public let method: String
    public let status: String
    public let amount: Double
    public let fee: Double
    public let currency: String
    public let email: String?
    public let message: String?
    public let reference: String?
    public let test: Bool
    public let createdAt: String
    public let item: String
    public let purchaseIp: String?
    public let purchaseDevice: String?
    public let dispute: PaymentDispute?
    public let activity: [ActivityEvent]
    public let evidencePdf: String
}

public struct PaymentDispute: Codable, Equatable, Sendable {
    public let id: String
    public let status: String
    public let reason: String?
    public let respondBy: String?
}

public struct ActivityEvent: Codable, Equatable, Sendable {
    public let at: String
    public let event: String
    public let detail: String?
    public let ip: String?
}

public struct Member: Codable, Equatable, Sendable {
    public let email: String
    public let tier: String
    public let method: String
    public let status: String
    public let price: Double
    public let interval: String
    public let currentPeriodEnds: String
    public let joinedAt: String
}

public struct IssuedLicense: Codable, Equatable, Sendable {
    public let key: String
    /// The product name.
    public let product: String
    public let email: String
    public let activations: Int
    public let maxActivations: Int
    public let disabled: Bool
    public let issuedAt: String
}

public struct Dispute: Codable, Equatable, Sendable {
    public let id: String
    public let paymentId: Int
    public let email: String?
    public let amount: Double
    public let reason: String?
    public let status: String
    public let respondBy: String?
    public let openedAt: String
}

public struct Product: Codable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let description: String
    public let price: Double
    public let currency: String
    public let deliversFile: Bool
    public let issuesLicenseKey: Bool
    public let page: String
    public let x402: String?
}

public struct Membership: Codable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let description: String
    public let price: Double
    public let currency: String
    public let interval: String
    public let x402: String?
}

public struct CreatorLink: Codable, Equatable, Sendable {
    public let label: String
    public let url: String
}

public struct PaymentMethods: Codable, Equatable, Sendable {
    public let card: Bool
    public let crypto: Bool
    public let x402: Bool
}

public struct Tip: Codable, Equatable, Sendable {
    public let suggested: Double
    public let currency: String
    public let page: String
    public let x402: String?
}

public struct Creator: Codable, Equatable, Sendable {
    public let handle: String
    public let name: String
    public let bio: String
    public let url: String
    public let avatar: String?
    public let links: [CreatorLink]
    public let paymentMethods: PaymentMethods
    public let tip: Tip
    public let memberships: [Membership]
    public let products: [Product]
}
