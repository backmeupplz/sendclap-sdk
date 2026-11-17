# Sendclap for Swift

The official Swift client for [Sendclap](https://sendclap.com): license keys for the apps you sell, and the creator API for your server. URLSession with async/await, no dependencies, macOS 12+ / iOS 15+ (and Linux). API docs: https://sendclap.com/docs

## Install

```swift
.package(url: "https://github.com/backmeupplz/sendclap-sdk", from: "0.3.0")
```

and add the `Sendclap` product to your target.

## License check

The license endpoints need no API key, so this code ships inside your app. Activate once when the customer enters their key, then validate on every start. `validate` only throws when it could not reach Sendclap, so an offline customer keeps working for a 7-day grace period:

```swift
import Sendclap

let licenses = LicenseClient()
let instance = LicenseClient.instanceName()
_ = try await licenses.activate(licenseKey: key, instanceName: instance) // once, when the key is entered

do {
    let r = try await licenses.validate(licenseKey: key, instanceId: instance)
    if r.valid { UserDefaults.standard.set(Date(), forKey: "licenseCheckedAt") }
    else { lock(refunded: r.status == .disabled) } // .notFound, .disabled (refunded or disputed), .expired (subscription over) or .notActivated
} catch { // offline: accept the last good check for 7 days
    let last = UserDefaults.standard.object(forKey: "licenseCheckedAt") as? Date ?? .distantPast
    if Date().timeIntervalSince(last) > 7 * 86400 { lock() }
}
```

`validate` returns `.notFound` for an unknown key and `.disabled` for a refunded or disputed one and `.expired` for a subscription key past `license.expiresAt`, while `activate` throws `.licenseDisabled` or `.licenseExpired` for those. `deactivate(licenseKey:instanceId:)` frees the seat, for example from a "Sign out of this Mac" button, and throws `.instanceNotFound` if that instance wasn't activated.

`LicenseClient.instanceName()` returns the host name. It is sent to Sendclap and shown to the creator, and two machines with the same host name share one activation. On iOS the host name is not useful: pass `UIDevice.current.identifierForVendor?.uuidString`, or a UUID you save on first launch. The instance id Sendclap returns is the name you pass (up to 200 characters).

## Creator API

> **Never ship your `sc_…` API key inside an app.** It can read your payments and customers. Use `APIClient` only on your own server.

```swift
let api = APIClient(apiKey: ProcessInfo.processInfo.environment["SENDCLAP_API_KEY"])
let checkout = try await api.createCheckout(CheckoutParams(type: "product", productId: 1, email: "buyer@example.com"))
// send the customer to checkout.url, then poll:
let paid = try await api.getCheckout(id: checkout.id).status == "paid"

let page = try await api.listPayments(status: "paid", limit: 20) // page.data, page.hasMore, page.next
if page.hasMore { _ = try await api.listPayments(status: "paid", limit: 20, after: page.next) }
for try await p in api.allPayments(status: "paid") { // follows `next` across pages
    print(p.id, p.amount)
}
```

Lists return a `Page<T>` (`data`, `hasMore`, `next`), newest first; `limit` defaults to 50 and is at most 500 and `after` is the previous page's `next`. `allPayments`, `allMembers`, `allLicenses` and `allDisputes` return an `AsyncThrowingStream`.

Also: `me()`, `getPayment(id:)`, `listPayments(status:type:email:limit:after:)`, `listMembers(limit:after:)`, `listLicenses(email:limit:after:)`, `listDisputes(limit:after:)`, `listProducts()`, `listMemberships()` and the public `getCreator(handle:)`, which works with `apiKey: nil`. Both clients take `baseURL:`, `timeout:` (seconds, default 15) and `session:`.

## Errors

Everything throws `SendclapError`, with `.status`, `.code` (the server's machine-readable code) and `.message`. The cases are chosen by `code`:

| Case | `code` | When |
| --- | --- | --- |
| `.invalidLicense` | `license_not_found` | 404: the key does not exist |
| `.licenseDisabled` | `license_disabled` | 403: disabled after a refund or dispute |
| `.licenseExpired(_, license:, product:)` | `license_expired` | 403: subscription over (`license.expiresAt`) |
| `.instanceNotFound` | `instance_not_found` | 404: `deactivate` for an instance that isn't activated |
| `.activationLimit(_, license:, product:)` | `activation_limit` | 409: the key is activated on all the devices it allows |
| `.network` | `network_error` | no response: offline, DNS, TLS or timeout (status 0) |
| `.api(status:code:message:)` | anything else, e.g. `bad_request`, `invalid_api_key`, `not_found` | 400, 401, 404, 5xx |
