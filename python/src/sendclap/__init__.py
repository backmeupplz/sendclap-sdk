"""Official Sendclap client: license checks for shipped apps and the creator REST API."""
from __future__ import annotations

import json
import socket
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, TypedDict

__version__ = "0.1.0"
DEFAULT_BASE_URL = "https://sendclap.com"
USER_AGENT = f"sendclap-python/{__version__}"

__all__ = [
    "LicenseClient", "ApiClient", "instance_name",
    "SendclapError", "InvalidLicenseError", "ActivationLimitError", "NetworkError",
    "ActivateResult", "ValidateResult", "DeactivateResult", "LicenseInfo", "ProductRef",
    "Checkout", "Totals", "Stats", "Payment", "PaymentDetail", "Member", "IssuedLicense",
    "Dispute", "Product", "Membership", "Creator",
]


# ---- errors ----

class SendclapError(Exception):
    """Any failed request. `status` is the HTTP status, 0 when no response arrived."""

    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.message = message


class InvalidLicenseError(SendclapError):
    """The key does not exist, or was disabled after a refund or dispute (the server can't tell them apart)."""


class ActivationLimitError(SendclapError):
    """The key is already activated on its maximum number of instances."""

    def __init__(self, status: int, message: str, license: LicenseInfo, product: ProductRef) -> None:
        super().__init__(status, message)
        self.license = license
        self.product = product


class NetworkError(SendclapError):
    """No HTTP response: DNS, refused connection, TLS or timeout."""

    def __init__(self, message: str) -> None:
        super().__init__(0, message)


# ---- license results ----

@dataclass(frozen=True)
class LicenseInfo:
    key: str
    activations: int
    max_activations: int


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
    status: str  # "active", "not_activated" or "invalid"
    license: Optional[LicenseInfo] = None
    product: Optional[ProductRef] = None


@dataclass(frozen=True)
class DeactivateResult:
    license: LicenseInfo
    product: ProductRef


# ---- API response shapes (plain dicts at runtime) ----

class _CheckoutBase(TypedDict):
    id: str
    status: str
    type: str
    amount: float
    currency: str
    method: str
    email: Optional[str]


class Checkout(_CheckoutBase, total=False):
    url: str  # only returned by create_checkout


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
        if status == 404 and d.get("valid") is False:
            raise InvalidLicenseError(status, msg)
        if status == 409 and d.get("activated") is False:
            raise ActivationLimitError(status, msg, _license(d), _product(d))
        raise SendclapError(status, msg)


def _license(d: Dict[str, Any]) -> LicenseInfo:
    lic = d.get("license") or {}
    return LicenseInfo(key=lic.get("key", ""), activations=lic.get("activations", 0),
                       max_activations=lic.get("max_activations", 0))


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
        """Never raises for a bad key: returns status "invalid". Raises NetworkError when offline."""
        try:
            d = self._post("validate", license_key, instance_id)
        except InvalidLicenseError:
            return ValidateResult(valid=False, status="invalid")
        valid = d.get("valid") is True
        return ValidateResult(valid=valid, status="active" if valid else "not_activated",
                              license=_license(d), product=_product(d))

    def deactivate(self, license_key: str, instance_id: str) -> DeactivateResult:
        d = self._post("deactivate", license_key, instance_id)
        return DeactivateResult(license=_license(d), product=_product(d))


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

    def list_payments(self, status: Optional[str] = None, type: Optional[str] = None,
                      email: Optional[str] = None, limit: Optional[int] = None) -> List[Payment]:
        return self._http.request("GET", "/payments", query={"status": status, "type": type, "email": email, "limit": limit})

    def get_payment(self, id: int) -> PaymentDetail:
        return self._http.request("GET", f"/payments/{_seg(id)}")

    def list_members(self) -> List[Member]:
        return self._http.request("GET", "/members")

    def list_licenses(self, email: Optional[str] = None) -> List[IssuedLicense]:
        return self._http.request("GET", "/licenses", query={"email": email})

    def list_disputes(self) -> List[Dispute]:
        return self._http.request("GET", "/disputes")

    def list_products(self) -> List[Product]:
        return self._http.request("GET", "/products")

    def list_memberships(self) -> List[Membership]:
        return self._http.request("GET", "/memberships")

    def get_creator(self, handle: str) -> Creator:
        """Public: works without an API key."""
        return self._http.request("GET", f"/creators/{_seg(handle)}")
