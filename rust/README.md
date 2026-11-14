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
lc.activate(&key, &name)?; // once, on first run; Error::InvalidLicense / Error::ActivationLimit
let unlocked = match lc.validate(&key, Some(&name)) {
    Ok(v) => { if v.valid { save_last_validated(now()) } v.status == ValidationStatus::Active }
    Err(Error::Network(_)) => now() - last_validated() < 7 * 24 * 3600, // offline grace
    Err(e) => return Err(e.into()),
};
```

`validate` never fails for a bad key: an unknown or refunded key comes back as `ValidationStatus::Invalid`, an inactive device as `NotActivated`. An `Err` means the answer is unknown (offline, server down), so cache the time of the last successful validation and keep the app unlocked for a grace period. `ValidateResult` is `Serialize`, so you can store it as is. `deactivate(&key, &name)` frees the seat when the user moves to another machine.

`instance_name()` returns the machine hostname (`COMPUTERNAME`/`HOSTNAME`, else the `hostname` command). It is sent to Sendclap and shown to the creator, and two machines with the same hostname share one activation; pass your own stable id (for example a random UUID saved on first run) if that matters. The instance id Sendclap returns is the name you pass.

## Creator API

> **Server side only. Never ship your `sc_` API key in an app, website or anything a customer can download:** anyone who has it can read your payments and customers.

```rust
use sendclap::{ApiClient, CheckoutParams, PaymentFilter};

let api = ApiClient::new(&std::env::var("SENDCLAP_API_KEY")?);
let c = api.create_checkout(&CheckoutParams { type_: "product".into(), product_id: Some(1), email: Some("buyer@example.com".into()), ..Default::default() })?;
// redirect the buyer to c.url, then poll:
let paid = api.get_checkout(&c.id)?.status == "paid";
let payments = api.list_payments(&PaymentFilter { status: Some("paid".into()), limit: Some(20), ..Default::default() })?;
```

Methods: `create_checkout`, `get_checkout`, `me`, `list_payments`, `get_payment`, `list_members`, `list_licenses`, `list_disputes`, `list_products`, `list_memberships`, `get_creator` (public, works with an empty key). Use `LicenseClient::with_options(base_url, timeout)` / `ApiClient::with_options(key, base_url, timeout)` to change the base URL or the 15 s timeout.

## Errors

`sendclap::Error`, with `status()` giving the HTTP status (0 for network errors):

| Variant | When |
|---|---|
| `InvalidLicense { message }` | 404: key unknown, or disabled after a refund or dispute |
| `ActivationLimit { message, license, product }` | 409: all activations in use |
| `Network(String)` | no response (DNS, refused, TLS, timeout) |
| `Api { status, message }` | anything else: 400, 401 (bad API key), 404, 5xx |

## License

MIT
