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
| Swift (macOS 12+, iOS 15+) | [`swift/`](swift) | `.package(url: "https://github.com/backmeupplz/sendclap-sdk", from: "0.1.0")` |
| PHP 8.1+ | [`php/`](php) | `composer require sendclap/sendclap` |

Every SDK is small and has no dependencies beyond the language's standard library, except Rust (`ureq` and `serde`) and .NET Standard 2.0 (`System.Text.Json`).

## The same API in every language

The method names below use JavaScript casing. Each SDK follows its own language's conventions, so the same call is `list_payments` in Python and Rust, `ListPayments(ctx, …)` in Go and `ListPaymentsAsync` in C#.

**`LicenseClient`** needs no key and is safe to ship.

- `activate(licenseKey, instanceName)` returns the instance id (which is the name you passed), the license counts and the product.
- `validate(licenseKey, instanceId?)` returns `valid` and a `status` of `active`, `not_activated` or `invalid`. It throws only when no definite answer arrived.
- `deactivate(licenseKey, instanceId)` frees one activation.
- `instanceName()` returns this machine's hostname, which you can use as the instance name.

**`ApiClient`** takes your `sc_` key and is for server-side use only. **Never ship the key in an app or a web page.**

- `createCheckout`, `getCheckout`
- `me`, `listPayments`, `getPayment`, `listMembers`, `listLicenses`, `listDisputes`, `listProducts`, `listMemberships`
- `getCreator(handle)`, which is public and needs no key

Both clients accept a base URL (default `https://sendclap.com`) and a timeout (default 15 s). They send `User-Agent: sendclap-<lang>/0.1.0`.

**Errors** work the same way everywhere. `SendclapError` carries the HTTP `status` and the server's message. Three special cases extend it: `InvalidLicenseError` (404, the key is unknown or was disabled after a refund or a dispute), `ActivationLimitError` (409, with the license counts) and `NetworkError` (no response, `status` 0).

## Working offline

Validate at startup or once a day, and store the time of the last successful validation. The SDK's errors let your app tell three situations apart:

- If `validate` returns `valid`, update the stored time and carry on.
- If it returns `invalid` or `not_activated`, the answer is definite, so lock the app or ask for a key.
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

## Publishing (not set up yet)

Every package is at version 0.1.0. Nothing has been published.

- **npm (`sendclap`)**: trusted publishing from a GitHub Actions workflow on the mirror, the same way plain is published, or an npm token as a Forgejo secret. Run `npm publish --provenance` in `js/`.
- **PyPI (`sendclap`)**: PyPI trusted publishing (GitHub Actions on the mirror), then `python -m build` and `pypa/gh-action-pypi-publish` in `python/`.
- **crates.io (`sendclap`)**: crates.io trusted publishing (GitHub Actions on the mirror), then `cargo publish` in `rust/`.
- **NuGet (`Sendclap`)**: a nuget.org API key as a Forgejo secret, then `dotnet pack -c Release` and `dotnet nuget push`.
- **Packagist (`sendclap/sendclap`)**: submit the repo URL on packagist.org once and add the Packagist webhook (or GitHub integration) so that tags show up. Packagist takes the version from git tags such as `v0.1.0`. Composer installs fetch the whole repo, which is small.
- **Swift**: no registry. SwiftPM resolves git tags on the repo, so tag `v0.1.0` (or `0.1.0`).
- **Go**: no registry. Because the module lives in `go/`, its tags need the prefix `go/v0.1.0`. pkg.go.dev picks them up from the proxy.
- The repo has to exist publicly as `github.com/backmeupplz/sendclap-sdk` (the Forgejo mirror) before Swift, Go and Packagist can resolve it.

MIT licensed. See [LICENSE](LICENSE).
