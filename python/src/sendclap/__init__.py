"""Official Sendclap client: license checks for shipped apps and the creator REST API."""
from __future__ import annotations

import json
import socket
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any, Callable, Dict, Generic, Iterator, List, Optional, TypedDict, TypeVar

__version__ = "0.4.0"
DEFAULT_BASE_URL = "https://sendclap.com"
USER_AGENT = f"sendclap-python/{__version__}"

__all__ = [
    "LicenseClient", "ApiClient", "instance_name",
    "SendclapError", "InvalidLicenseError", "DisabledLicenseError", "ExpiredLicenseError", "InstanceNotFoundError",
    "ActivationLimitError", "NetworkError",
    "ActivateResult", "ValidateResult", "DeactivateResult", "LicenseInfo", "ProductRef",
    "Page", "Checkout", "Totals", "Stats", "Payment", "PaymentDetail", "Member", "IssuedLicense",
    "Dispute", "Product", "Membership", "Creator",
]


# ---- errors ----

class SendclapError(Exception):
    """Any failed request.

    `status` is the HTTP status (0 when no response arrived) and `code` the server's machine-readable
    code, such as "invalid_api_key" or "not_found" ("" when the reply wasn't a Sendclap error,
    "network_error" with no reply).
    """

    def __init__(self, status: int, message: str, code: str = "") -> None:
        super().__init__(message)
        self.status = status
        self.message = message
        self.code = code


class InvalidLicenseError(SendclapError):
    """The license key does not exist (license_not_found)."""


class DisabledLicenseError(SendclapError):
    """The key exists but was disabled after a refund or dispute (license_disabled)."""


class ExpiredLicenseError(SendclapError):
    """The subscription license key has expired (license_expired); license.expires_at says when."""

    def __init__(self, status: int, message: str, license: LicenseInfo, product: ProductRef) -> None:
        super().__init__(status, message, "license_expired")
        self.license = license
        self.product = product


class InstanceNotFoundError(SendclapError):
    """Deactivate was called for an instance that isn't activated (instance_not_found)."""


class ActivationLimitError(SendclapError):
    """The key is already activated on its maximum number of instances (activation_limit)."""

    def __init__(self, status: int, message: str, license: LicenseInfo, product: ProductRef) -> None:
        super().__init__(status, message, "activation_limit")
        self.license = license
        self.product = product


class NetworkError(SendclapError):
    """No HTTP response: DNS, refused connection, TLS or timeout."""

    def __init__(self, message: str) -> None:
        super().__init__(0, message, "network_error")


# ---- license results ----

@dataclass(frozen=True)
class LicenseInfo:
    key: str
    activations: int
    max_activations: int
    expires_at: Optional[str] = None  # ISO 8601 time a subscription key expires, None if bought outright


@dataclass(frozen=True)
class ProductRef:
    id: Optional[int] = None
    name: Optional[str] = None


@dataclass(frozen=True)
class ActivateResult:
    instance_id: str
    license: LicenseInfo
    product: ProductRef


@dataclass(frozen=True)
class ValidateResult:
    valid: bool
    status: str  # "active", "not_activated", "expired" (subscription over), "disabled" (refunded or disputed) or "not_found" (unknown key)
    license: Optional[LicenseInfo] = None
    product: Optional[ProductRef] = None


@dataclass(frozen=True)
class DeactivateResult:
    license: LicenseInfo
    product: ProductRef


# ---- API response shapes (plain dicts at runtime) ----

class Checkout(TypedDict):
    id: str
    status: str
    type: str
    amount: float
    currency: str
    method: str
    email: Optional[str]
    url: str  # where to send the customer to pay
    paid_at: Optional[str]  # ISO 8601 time it was paid, None while unpaid


T = TypeVar("T")


@dataclass(frozen=True)
class Page(Generic[T]):
    data: List[T]
    has_more: bool
    next: Optional[int]  # pass as `after` to get the following page


class Totals(TypedDict):
    payments: int
    gross: float
    fees: float
    net: float


class Stats(TypedDict):
    handle: str
    name: str
    url: str
    currency: str
    last_30_days: Totals
    all_time: Totals
    members: Dict[str, float]  # {"active": int, "monthly_recurring": float}
    open_disputes: int


class Payment(TypedDict):
    id: int
    type: str
    method: str
    status: str
    amount: float
    fee: float
    currency: str
    email: Optional[str]
    message: Optional[str]
    reference: Optional[str]
    test: bool
    created_at: str


class PaymentDetail(Payment):
    item: str
    purchase_ip: Optional[str]
    purchase_device: Optional[str]
    dispute: Optional[Dict[str, Any]]  # {id, status, reason, respond_by}
    activity: List[Dict[str, Any]]  # [{at, event, detail, ip}]
    evidence_pdf: str


class Member(TypedDict):
    email: str
    tier: str
    method: str
    status: str
    price: float
    interval: str
    current_period_ends: str
    joined_at: str


class IssuedLicense(TypedDict):
    key: str
    product: str
    email: str
    activations: int
    max_activations: int
    disabled: bool
    issued_at: str
    expires_at: Optional[str]


class Dispute(TypedDict):
    id: str
    payment_id: int
    email: Optional[str]
    amount: float
    reason: Optional[str]
    status: str
    respond_by: Optional[str]
    opened_at: str


class Product(TypedDict):
    id: int
    name: str
    description: str
    price: float
    currency: str
    delivers_file: bool
    issues_license_key: bool
    page: str
    x402: Optional[str]
    license_product_id: Optional[int]


class Membership(TypedDict):
    id: int
    name: str
    description: str
    price: float
    currency: str
    interval: str
    x402: Optional[str]


class Creator(TypedDict):
    handle: str
    name: str
    bio: str
    url: str
    avatar: Optional[str]
    links: List[Dict[str, str]]
    payment_methods: Dict[str, bool]
    tip: Dict[str, Any]
    memberships: List[Membership]
    products: List[Product]


# ---- transport ----

class _Http:
    def __init__(self, base_url: str, timeout: float, api_key: Optional[str] = None) -> None:
        self.base = base_url.rstrip("/") + "/api/v1"
        self.timeout = timeout
        self.api_key = api_key

    def request(self, method: str, path: str, body: Optional[Dict[str, Any]] = None,
                query: Optional[Dict[str, Any]] = None) -> Any:
        url = self.base + path
        q = {k: v for k, v in (query or {}).items() if v is not None}
        if q:
            url += "?" + urllib.parse.urlencode(q)
        headers = {"Accept": "application/json", "User-Agent": USER_AGENT}
        data = None
        if body is not None:
            data = json.dumps({k: v for k, v in body.items() if v is not None}).encode()
            headers["Content-Type"] = "application/json"
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as res:
                status, text = res.status, res.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            with e:
                status, text = e.code, e.read().decode("utf-8", "replace")
        except (urllib.error.URLError, OSError) as e:  # covers socket.timeout and ConnectionError
            raise NetworkError(str(getattr(e, "reason", e))) from e
        try:
            parsed = json.loads(text)
        except ValueError:
            if 200 <= status < 300:
                raise SendclapError(status, "invalid JSON response") from None
            parsed = None
        if 200 <= status < 300:
            return parsed
        d = parsed if isinstance(parsed, dict) else {}
        msg = d["error"] if isinstance(d.get("error"), str) else f"HTTP {status}"
        code = d["code"] if isinstance(d.get("code"), str) else ""
        if code == "license_not_found":
            raise InvalidLicenseError(status, msg, code)
        if code == "license_disabled":
            raise DisabledLicenseError(status, msg, code)
        if code == "license_expired":
            raise ExpiredLicenseError(status, msg, _license(d), _product(d))
        if code == "instance_not_found":
            raise InstanceNotFoundError(status, msg, code)
        if code == "activation_limit":
            raise ActivationLimitError(status, msg, _license(d), _product(d))
        raise SendclapError(status, msg, code)


def _license(d: Dict[str, Any]) -> LicenseInfo:
    lic = d.get("license") or {}
    return LicenseInfo(key=lic.get("key", ""), activations=lic.get("activations", 0),
                       max_activations=lic.get("max_activations", 0), expires_at=lic.get("expires_at"))


def _product(d: Dict[str, Any]) -> ProductRef:
    p = d.get("product") or {}
    return ProductRef(id=p.get("id"), name=p.get("name"))


# ---- clients ----

def instance_name() -> str:
    """This machine's hostname, a stable default instance name.

    It is sent to Sendclap and shown to the creator, and two machines with the same
    hostname share one activation. Pass your own id (a UUID saved on first run) if that matters.
    """
    return socket.gethostname()


class LicenseClient:
    """Keyless license checks, safe to call from the app you ship."""

    def __init__(self, base_url: str = DEFAULT_BASE_URL, timeout: float = 15.0) -> None:
        self._http = _Http(base_url, timeout)

    def _post(self, action: str, license_key: str, instance_id: Optional[str]) -> Dict[str, Any]:
        return self._http.request("POST", f"/licenses/{action}",
                                  {"license_key": license_key, "instance_id": instance_id})

    def activate(self, license_key: str, instance_name: str) -> ActivateResult:
        d = self._post("activate", license_key, instance_name)
        return ActivateResult(instance_id=d["instance_id"], license=_license(d), product=_product(d))

    def validate(self, license_key: str, instance_id: Optional[str] = None) -> ValidateResult:
        """Never raises for a bad key: returns status "not_found", "disabled" or "expired". Raises NetworkError when offline."""
        d = self._post("validate", license_key, instance_id)
        known = "license" in d
        return ValidateResult(valid=d.get("valid") is True, status=d["status"],
                              license=_license(d) if known else None, product=_product(d) if known else None)

    def deactivate(self, license_key: str, instance_id: str) -> DeactivateResult:
        d = self._post("deactivate", license_key, instance_id)
        return DeactivateResult(license=_license(d), product=_product(d))


def _paginate(fetch: Callable[..., Page[T]], filters: Dict[str, Any]) -> Iterator[T]:
    after = None
    while True:
        page = fetch(**filters, after=after)
        yield from page.data
        if not page.has_more or page.next is None:
            return
        after = page.next


def _seg(s: Any) -> str:
    return urllib.parse.quote(str(s), safe="")


class ApiClient:
    """Creator REST API. Server side only: never ship the sc_ key inside an app."""

    def __init__(self, api_key: Optional[str] = None, base_url: str = DEFAULT_BASE_URL, timeout: float = 15.0) -> None:
        self._http = _Http(base_url, timeout, api_key)

    def create_checkout(self, type: str, amount: Optional[float] = None, product_id: Optional[int] = None,
                        tier_id: Optional[int] = None, email: Optional[str] = None,
                        method: Optional[str] = None, message: Optional[str] = None) -> Checkout:
        return self._http.request("POST", "/checkouts", {
            "type": type, "amount": amount, "product_id": product_id, "tier_id": tier_id,
            "email": email, "method": method, "message": message})

    def get_checkout(self, id: str) -> Checkout:
        return self._http.request("GET", f"/checkouts/{_seg(id)}")

    def me(self) -> Stats:
        return self._http.request("GET", "/me")

    def _page(self, path: str, query: Dict[str, Any]) -> Page:
        d = self._http.request("GET", path, query=query)
        return Page(data=d["data"], has_more=d["has_more"], next=d["next"])

    # Lists are pages: `limit` defaults to 50 and is at most 500, `after` is the previous page's `next`. The all_* generators follow `next`.
    def list_payments(self, status: Optional[str] = None, type: Optional[str] = None, email: Optional[str] = None,
                      limit: Optional[int] = None, after: Optional[int] = None) -> Page[Payment]:
        return self._page("/payments", {"status": status, "type": type, "email": email, "limit": limit, "after": after})

    def get_payment(self, id: int) -> PaymentDetail:
        return self._http.request("GET", f"/payments/{_seg(id)}")

    def list_members(self, limit: Optional[int] = None, after: Optional[int] = None) -> Page[Member]:
        return self._page("/members", {"limit": limit, "after": after})

    def list_licenses(self, email: Optional[str] = None, limit: Optional[int] = None,
                      after: Optional[int] = None) -> Page[IssuedLicense]:
        return self._page("/licenses", {"email": email, "limit": limit, "after": after})

    def list_disputes(self, limit: Optional[int] = None, after: Optional[int] = None) -> Page[Dispute]:
        return self._page("/disputes", {"limit": limit, "after": after})

    def all_payments(self, **filters: Any) -> Iterator[Payment]:
        return _paginate(self.list_payments, filters)

    def all_members(self, **filters: Any) -> Iterator[Member]:
        return _paginate(self.list_members, filters)

    def all_licenses(self, **filters: Any) -> Iterator[IssuedLicense]:
        return _paginate(self.list_licenses, filters)

    def all_disputes(self, **filters: Any) -> Iterator[Dispute]:
        return _paginate(self.list_disputes, filters)

    def list_products(self) -> List[Product]:
        return self._http.request("GET", "/products")

    def list_memberships(self) -> List[Membership]:
        return self._http.request("GET", "/memberships")

    def get_creator(self, handle: str) -> Creator:
        """Public: works without an API key."""
        return self._http.request("GET", f"/creators/{_seg(handle)}")
