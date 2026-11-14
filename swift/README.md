# Sendclap for Swift

The official Swift client for [Sendclap](https://sendclap.com): license keys for the apps you sell, and the creator API for your server. URLSession with async/await, no dependencies, macOS 12+ / iOS 15+ (and Linux). API docs: https://sendclap.com/docs

## Install

```swift
.package(url: "https://github.com/backmeupplz/sendclap-sdk", from: "0.1.0")
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
    if r.valid { UserDefaults.standard.set(Date(), forKey: "licenseCheckedAt") } else { lock() } // .invalid or .notActivated
} catch { // offline: accept the last good check for 7 days
    let last = UserDefaults.standard.object(forKey: "licenseCheckedAt") as? Date ?? .distantPast
    if Date().timeIntervalSince(last) > 7 * 86400 { lock() }
}
```

`deactivate(licenseKey:instanceId:)` frees the seat, for example from a "Sign out of this Mac" button.

`LicenseClient.instanceName()` returns the host name. It is sent to Sendclap and shown to the creator, and two machines with the same host name share one activation. On iOS the host name is not useful: pass `UIDevice.current.identifierForVendor?.uuidString`, or a UUID you save on first launch. The instance id Sendclap returns is the name you pass (up to 200 characters).

## Creator API

> **Never ship your `sc_…` API key inside an app.** It can read your payments and customers. Use `APIClient` only on your own server.

```swift
let api = APIClient(apiKey: ProcessInfo.processInfo.environment["SENDCLAP_API_KEY"])
let checkout = try await api.createCheckout(CheckoutParams(type: "product", productId: 1, email: "buyer@example.com"))
// send the customer to checkout.url, then poll:
let paid = try await api.getCheckout(id: checkout.id).status == "paid"
```

Also: `me()`, `listPayments(status:type:email:limit:)`, `getPayment(id:)`, `listMembers()`, `listLicenses(email:)`, `listDisputes()`, `listProducts()`, `listMemberships()` and the public `getCreator(handle:)`, which works with `apiKey: nil`. Both clients take `baseURL:`, `timeout:` (seconds, default 15) and `session:`.

## Errors

Everything throws `SendclapError`, with `.status` and `.message`:

| Case | When |
| --- | --- |
| `.invalidLicense` | 404: the key does not exist, or it was disabled after a refund or dispute |
| `.activationLimit(_, license:, product:)` | 409: the key is activated on all the devices it allows |
| `.network` | no response: offline, DNS, TLS or timeout (status 0) |
| `.api(status:message:)` | anything else: 400 bad request, 401 wrong API key, 404 not found, 5xx |
