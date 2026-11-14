# Changelog

## 0.3.0

Breaking changes to follow the Sendclap API.

- `validate` reads the `status` the API now returns (it always answers 200) instead of mapping 404 and 403 itself. The `invalid` status is renamed `not_found` in every SDK (`StatusNotFound`, `ValidationStatus::NotFound`, `LicenseStatus.NotFound`, `.notFound`).
- Errors are bare `{ error, code }` bodies, and the SDKs choose the typed error from `code` alone. Only `activation_limit` (409) carries `license` and `product`. `activate` and `deactivate` no longer return `activated: false` or `deactivated: false` in error bodies.
- Every list defaults to 50 items (at most 500).
- `Checkout` has `paid_at`, an ISO 8601 string or null.

## 0.2.0

First release: license client (`activate`, `validate`, `deactivate`) and API client (checkouts, payments, members, licenses, disputes, products, memberships, creator) for JavaScript, Python, Go, Rust, C#, Swift and PHP.
