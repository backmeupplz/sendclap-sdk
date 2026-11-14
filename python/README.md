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
    return r.valid  # status "invalid" or "not_activated": lock the app
```

On first run, activate the device and remember the instance id:

```python
from sendclap import ActivationLimitError, InvalidLicenseError
try:
    cache["instance"] = LicenseClient().activate(key, instance_name()).instance_id
except InvalidLicenseError: ...   # unknown key, or refunded / disputed
except ActivationLimitError as e: print(f"Used on {e.license.activations}/{e.license.max_activations} devices")
```

`deactivate(key, instance_id)` frees the device again. `validate` never raises for a bad key; it returns `status` `"active"`, `"not_activated"` or `"invalid"`, and raises `NetworkError` only when it could not reach Sendclap, so you can tell "offline" from "invalid".

**Instance name:** `instance_name()` is the machine's hostname. It is sent to Sendclap and shown to the creator, and two machines with the same hostname share one activation. If that matters, pass your own stable id instead (for example a `uuid4()` saved on first run). The instance id Sendclap returns is the name you send.

## Creator API (server side only)

> **Never ship your `sc_` API key inside an app, website or anything a customer can download.** Anyone holding it can read your payments and customers. Use it only on your own server.

```python
from sendclap import ApiClient

api = ApiClient("sc_your_key")  # base_url="https://sendclap.com", timeout=15.0
checkout = api.create_checkout("product", product_id=1, email="buyer@example.com")
print(checkout["url"])            # send the buyer here
api.get_checkout(checkout["id"])  # poll until status == "paid"
for p in api.list_payments(status="paid", limit=10):
    print(p["amount"], p["email"])
```

Methods: `create_checkout`, `get_checkout`, `me`, `list_payments`, `get_payment`, `list_members`, `list_licenses`, `list_disputes`, `list_products`, `list_memberships`, `get_creator` (public, works with `ApiClient()` and no key). They return plain dicts and lists with the API's JSON fields, typed with `TypedDict`.

The client is synchronous. In async code, wrap calls with `await asyncio.to_thread(api.me)`.

## Errors

| Exception | When |
|---|---|
| `InvalidLicenseError` | 404: the key doesn't exist, or was disabled after a refund or dispute |
| `ActivationLimitError` | 409: every activation is used; `.license` and `.product` say how many |
| `NetworkError` | No response: offline, DNS, TLS, timeout (`.status == 0`) |
| `SendclapError` | Base class; anything else, e.g. 400 bad request, 401 bad API key, 404 not found (`.status`, `.message`) |

## Tests

```sh
python3 -m unittest discover -s tests   # or: python3 -m pytest
```
