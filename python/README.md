# sendclap (Python)

Official Python client for [Sendclap](https://sendclap.com): check license keys from the app you ship, and call the creator REST API from your server. Standard library only, Python 3.9+, fully typed. API reference: https://sendclap.com/docs

```sh
pip install sendclap
```

## License check (in your app, no API key)

```python
import time
from sendclap import LicenseClient, NetworkError, instance_name

def licensed(key: str, cache: dict) -> bool:
    try:
        r = LicenseClient().validate(key, cache.get("instance") or instance_name())
    except NetworkError:  # offline: allow a 7-day grace period since the last good check
        return time.time() - cache.get("validated_at", 0) < 7 * 86400
    if r.valid:
        cache["validated_at"] = time.time()  # persist cache to disk yourself
    return r.valid  # status "not_found", "disabled", "expired" or "not_activated": lock the app
```

On first run, activate the device and remember the instance id:

```python
from sendclap import ActivationLimitError, DisabledLicenseError, InvalidLicenseError
try:
    cache["instance"] = LicenseClient().activate(key, instance_name()).instance_id
except InvalidLicenseError: ...   # unknown key
except DisabledLicenseError: ...  # the payment was refunded or disputed
except ActivationLimitError as e: print(f"Used on {e.license.activations}/{e.license.max_activations} devices")
```

`deactivate(key, instance_id)` frees the device again, and raises `InstanceNotFoundError` if it wasn't activated. `validate` never raises for a bad key; it returns `status` `"active"`, `"not_activated"`, `"expired"` (subscription over, see `license.expires_at`), `"disabled"` (refunded or disputed) or `"not_found"` (unknown key), and raises `NetworkError` only when it could not reach Sendclap, so you can tell "offline" from "not found" and show "this license was refunded" for `"disabled"`.

**Instance name:** `instance_name()` is the machine's hostname. It is sent to Sendclap and shown to the creator, and two machines with the same hostname share one activation. If that matters, pass your own stable id instead (for example a `uuid4()` saved on first run). The instance id Sendclap returns is the name you send.

## Creator API (server side only)

> **Never ship your `sc_` API key inside an app, website or anything a customer can download.** Anyone holding it can read your payments and customers. Use it only on your own server.

```python
from sendclap import ApiClient

api = ApiClient("sc_your_key")  # base_url="https://sendclap.com", timeout=15.0
checkout = api.create_checkout("product", product_id=1, email="buyer@example.com")
print(checkout["url"])            # send the buyer here
api.get_checkout(checkout["id"])  # poll until status == "paid"
page = api.list_payments(status="paid", limit=10)  # page.data, page.has_more, page.next
if page.has_more:
    page = api.list_payments(status="paid", limit=10, after=page.next)
for p in api.all_payments(status="paid"):  # a generator that follows `next` across pages
    print(p["amount"], p["email"])
```

Lists (`list_payments`, `list_members`, `list_licenses`, `list_disputes`) return a `Page` with `data`, `has_more` and `next`, newest first; `limit` defaults to 50 and is at most 500 and `after` is the previous page's `next`. `all_payments`, `all_members`, `all_licenses` and `all_disputes` take the same filters and yield every item.

Methods: `create_checkout` and `get_checkout` (both return the checkout `url`), `me`, `get_payment`, `list_products`, `list_memberships`, the list and `all_*` methods above, and `get_creator` (public, works with `ApiClient()` and no key). Items are plain dicts with the API's JSON fields, typed with `TypedDict`.

The client is synchronous. In async code, wrap calls with `await asyncio.to_thread(api.me)`.

## Errors

Every exception is a `SendclapError` with `.status`, `.code` (the server's machine-readable code) and `.message`. The typed ones are chosen by `code`:

| Exception | `code` | When |
|---|---|---|
| `InvalidLicenseError` | `license_not_found` | 404: the key doesn't exist |
| `DisabledLicenseError` | `license_disabled` | 403: disabled after a refund or dispute |
| `ExpiredLicenseError` | `license_expired` | 403: the subscription key expired; `.license.expires_at` says when |
| `InstanceNotFoundError` | `instance_not_found` | 404: `deactivate` for an instance that isn't activated |
| `ActivationLimitError` | `activation_limit` | 409: every activation is used; `.license` and `.product` say how many |
| `NetworkError` | `network_error` | No response: offline, DNS, TLS, timeout (`.status == 0`) |
| `SendclapError` | anything else | e.g. `bad_request`, `invalid_api_key`, `not_found` |

## Tests

```sh
python3 -m unittest discover -s tests   # or: python3 -m pytest
```
