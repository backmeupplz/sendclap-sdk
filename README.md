# Sendclap SDKs

These are the official client libraries for [Sendclap](https://sendclap.com), which sells memberships, tips and digital products with license keys. They do two jobs:

- **License checks from the app you ship.** You can activate, validate and deactivate a customer's license key without an API key, the same way the Lemon Squeezy License API works.
- **The creator REST API from your server.** You can create checkouts and read your payments, members, licenses, disputes, products and tiers with your `sc_` API key.

The full API reference is at **https://sendclap.com/docs**.

| Language | Folder | Install |
| --- | --- | --- |
| JavaScript / TypeScript (Node 18+, Bun, Deno, browsers, Electron) | [`js/`](js) | `npm install sendclap` |
| Python 3.9+ | [`python/`](python) | `pip install sendclap` |
| Go | [`go/`](go) | `go get github.com/backmeupplz/sendclap-sdk/go` |
| Rust | [`rust/`](rust) | `cargo add sendclap` |
| C# (.NET 8+, .NET Standard 2.0 for Unity and older apps) | [`dotnet/`](dotnet) | `dotnet add package Sendclap` |
| Swift (macOS 12+, iOS 15+) | [`swift/`](swift) | `.package(url: "https://github.com/backmeupplz/sendclap-sdk", from: "0.2.0")` |
| PHP 8.1+ | [`php/`](php) | `composer require sendclap/sendclap` |

Every SDK is small and has no dependencies beyond the language's standard library, except Rust (`ureq` and `serde`) and .NET Standard 2.0 (`System.Text.Json` and `Microsoft.Bcl.AsyncInterfaces`). Go needs 1.23 for the `iter` package.

## The same API in every language

The method names below use JavaScript casing. Each SDK follows its own language's conventions, so the same call is `list_payments` in Python and Rust, `ListPayments(ctx, …)` in Go and `ListPaymentsAsync` in C#.

**`LicenseClient`** needs no key and is safe to ship.

- `activate(licenseKey, instanceName)` returns the instance id (which is the name you passed), the license counts and the product.
- `validate(licenseKey, instanceId?)` returns `valid` and a `status` of `active`, `not_activated`, `invalid` (unknown key) or `disabled` (refunded or disputed). It throws only when no definite answer arrived, so "this license was refunded" and "invalid key" are different outcomes you can show.
- `deactivate(licenseKey, instanceId)` frees one activation, and fails with `InstanceNotFoundError` if that instance wasn't activated.
- `instanceName()` returns this machine's hostname, which you can use as the instance name.

**`ApiClient`** takes your `sc_` key and is for server-side use only. **Never ship the key in an app or a web page.**

- `createCheckout`, `getCheckout` (both return the checkout's `url`)
- `me`, `getPayment`, `listProducts`, `listMemberships`
- `listPayments`, `listMembers`, `listLicenses`, `listDisputes`, which return a page: `{ data, has_more, next }`
- `allPayments`, `allMembers`, `allLicenses`, `allDisputes`, which auto-page through every item
- `getCreator(handle)`, which is public and needs no key

Both clients accept a base URL (default `https://sendclap.com`) and a timeout (default 15 s). They send `User-Agent: sendclap-<lang>/0.2.0`. In a browser the JavaScript SDK sends `x-sendclap-client: sendclap-js/0.2.0` instead, because browsers forbid setting `User-Agent`.

**Pages.** The four list endpoints return newest first and take `limit` (at most 500) and `after`. A page has `data`, `has_more` and `next`, and when `has_more` is true you pass `next` as `after` to get the following page. The `all…` helpers do that for you with each language's idiom: an async iterator in JavaScript, a generator in Python and PHP, an `iter.Seq2` in Go, an `Iterator` in Rust, `IAsyncEnumerable` in C# and `AsyncThrowingStream` in Swift.

**Errors** work the same way everywhere. Every failed call raises a `SendclapError` with the HTTP `status`, the server's `code` (for example `invalid_api_key`, `not_found`, `bad_request`, `rate_limited`, `internal_error`) and its message. The SDK maps typed errors from the `code`:

| Error | `code` | Status |
| --- | --- | --- |
| `InvalidLicenseError` | `license_not_found` | 404 |
| `DisabledLicenseError` | `license_disabled` | 403 |
| `InstanceNotFoundError` | `instance_not_found` | 404 |
| `ActivationLimitError` (with the license counts) | `activation_limit` | 409 |
| `NetworkError` | `network_error` | 0 (no response) |

The names follow each language's convention (`ErrLicenseDisabled` in Go, `DisabledLicenseException` in C# and PHP, `.licenseDisabled` in Swift, `Error::LicenseDisabled` in Rust). In PHP the property is `errorCode`, because `Exception::$code` is already taken. A reply that isn't a Sendclap error (such as an HTML page from a proxy) has an empty `code`.

## Working offline

Validate at startup or once a day, and store the time of the last successful validation. The SDK's errors let your app tell three situations apart:

- If `validate` returns `valid`, update the stored time and carry on.
- If it returns `invalid`, `disabled` or `not_activated`, the answer is definite, so lock the app or ask for a key (and say that the license was refunded when it is `disabled`).
- If it throws `NetworkError`, the customer is probably offline. Keep working while the last success is within your grace period (for example 7 days), and lock after that.

Each package README shows this pattern in about ten lines.

## Development

Each folder is a self-contained package with its own tests against a local mock server:

| Folder | Test command |
| --- | --- |
| `js/` | `npm install && npm test` |
| `python/` | `python3 -m unittest discover -s tests` |
| `go/` | `go test ./...` |
| `rust/` | `cargo test` |
| `dotnet/` | `dotnet test` |
| repo root (Swift) | `swift test` |
| repo root (PHP) | `php php/tests/run.php` |

Swift's `Package.swift` and PHP's `composer.json` live at the repo root because SwiftPM and Packagist read only the root. CI runs every suite on each push and pull request (`.forgejo/workflows/test.yml`).

## Releasing

1. `scripts/version.sh bump X.Y.Z`, run every test suite, commit and merge to `main`.
2. `tea release create --repo backmeupplz/sendclap-sdk --tag vX.Y.Z --title vX.Y.Z --note "what changed"`.

The release runs [.forgejo/workflows/release.yml](.forgejo/workflows/release.yml), which checks that every package says
X.Y.Z, tags `go/vX.Y.Z` for the Go module, waits for both tags on the GitHub mirror and creates the GitHub Release.
That release runs [.github/workflows/release.yml](.github/workflows/release.yml) on GitHub, which publishes:

| Registry | Package | How |
| --- | --- | --- |
| npm | `sendclap` | trusted publishing, with provenance |
| PyPI | `sendclap` | trusted publishing |
| crates.io | `sendclap` | trusted publishing |
| NuGet | `Sendclap` | trusted publishing (`NUGET_USER` repository variable on GitHub) |
| Packagist | `sendclap/sendclap` | follows the mirror's tags |
| Swift Package Manager | `Sendclap` | the `vX.Y.Z` tag |
| Go | `github.com/backmeupplz/sendclap-sdk/go` | the `go/vX.Y.Z` tag; the release asks the Go proxy to fetch it |

No registry token is stored anywhere: npm, PyPI, crates.io and NuGet trust `backmeupplz/sendclap-sdk`'s
`.github/workflows/release.yml` by name. The one-time setup is [scripts/first-publish.sh](scripts/first-publish.sh) plus a
trusted publisher on each registry's website.

MIT licensed. See [LICENSE](LICENSE).
