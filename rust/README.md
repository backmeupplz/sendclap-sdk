# sendclap

Official Rust client for [Sendclap](https://sendclap.com): check license keys from the app you ship, and call the creator API from your server. Blocking, built on `ureq`. API reference: https://sendclap.com/docs

```sh
cargo add sendclap
```

## License check

The license endpoints need no API key, so this code is safe to ship inside your app.

```rust
use sendclap::{Error, LicenseClient, ValidationStatus};

let lc = LicenseClient::new();
let name = sendclap::instance_name().unwrap_or_else(|| "my-app".into());
lc.activate(&key, &name)?; // once, on first run; Error::InvalidLicense / LicenseDisabled / ActivationLimit
let unlocked = match lc.validate(&key, Some(&name)) {
    Ok(v) => { if v.valid { save_last_validated(now()) } v.status == ValidationStatus::Active }
    Err(Error::Network(_)) => now() - last_validated() < 7 * 24 * 3600, // offline grace
    Err(e) => return Err(e.into()),
};
```

`validate` never fails for a bad key: an unknown key comes back as `ValidationStatus::Invalid`, a refunded or disputed one as `Disabled` (so you can say "this license was refunded"), an inactive device as `NotActivated`. `activate` returns `Error::LicenseDisabled` for a refunded key, and `deactivate` returns `Error::InstanceNotFound` for an instance that isn't activated. An `Err` means the answer is unknown (offline, server down), so cache the time of the last successful validation and keep the app unlocked for a grace period. `ValidateResult` is `Serialize`, so you can store it as is. `deactivate(&key, &name)` frees the seat when the user moves to another machine.

`instance_name()` returns the machine hostname (`COMPUTERNAME`/`HOSTNAME`, else the `hostname` command). It is sent to Sendclap and shown to the creator, and two machines with the same hostname share one activation; pass your own stable id (for example a random UUID saved on first run) if that matters. The instance id Sendclap returns is the name you pass.

## Creator API

> **Server side only. Never ship your `sc_` API key in an app, website or anything a customer can download:** anyone who has it can read your payments and customers.

```rust
use sendclap::{ApiClient, CheckoutParams, PaymentFilter};

let api = ApiClient::new(&std::env::var("SENDCLAP_API_KEY")?);
let c = api.create_checkout(&CheckoutParams { type_: "product".into(), product_id: Some(1), email: Some("buyer@example.com".into()), ..Default::default() })?;
// redirect the buyer to c.url, then poll:
let paid = api.get_checkout(&c.id)?.status == "paid";
let filter = PaymentFilter { status: Some("paid".into()), limit: Some(20), ..Default::default() };
let page = api.list_payments(&filter)?; // page.data, page.has_more, page.next
for payment in api.all_payments(&filter) { // follows `next` across pages
    println!("{}", payment?.amount);
}
```

Lists return a `Page<T>` (`data`, `has_more`, `next`), newest first; `limit` is at most 500 and `after` is the previous page's `next`. `all_payments`, `all_members`, `all_licenses` and `all_disputes` return an iterator of `Result<T>` that fetches pages lazily.

Methods: `create_checkout` and `get_checkout` (both return the checkout `url`), `me`, `get_payment`, `list_products`, `list_memberships`, `list_payments`, `list_members(&PageParams)`, `list_licenses(&LicenseFilter)`, `list_disputes(&PageParams)`, the `all_*` iterators, `get_creator` (public, works with an empty key). Use `LicenseClient::with_options(base_url, timeout)` / `ApiClient::with_options(key, base_url, timeout)` to change the base URL or the 15 s timeout.

## Errors

`sendclap::Error`, with `status()` giving the HTTP status (0 for network errors) and `code()` the server's machine-readable code. The variants are chosen by code:

| Variant | `code()` | When |
|---|---|---|
| `InvalidLicense { message }` | `license_not_found` | 404: key unknown |
| `LicenseDisabled { message }` | `license_disabled` | 403: disabled after a refund or dispute |
| `InstanceNotFound { message }` | `instance_not_found` | 404: `deactivate` for an instance that isn't activated |
| `ActivationLimit { message, license, product }` | `activation_limit` | 409: all activations in use |
| `Network(String)` | `network_error` | no response (DNS, refused, TLS, timeout) |
| `Api { status, code, message }` | e.g. `bad_request`, `invalid_api_key`, `not_found` | anything else: 400, 401 (bad API key), 404, 5xx |

## License

MIT
