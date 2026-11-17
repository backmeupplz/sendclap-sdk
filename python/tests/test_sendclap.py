import json
import os
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import sendclap  # noqa: E402
from sendclap import (  # noqa: E402
    ActivationLimitError, ApiClient, DisabledLicenseError, ExpiredLicenseError, InstanceNotFoundError, InvalidLicenseError,
    LicenseClient, NetworkError, SendclapError,
)

LICENSE = {"key": "GOOD", "activations": 1, "max_activations": 3}
PRODUCT = {"id": 1, "name": "Pro"}
LAPSED = {**LICENSE, "expires_at": "2026-01-01T00:00:00.000Z"}
CHECKOUT = {"id": "0xabc", "status": "pending", "type": "product", "amount": 29, "currency": "usd",
            "method": "card", "email": "buyer@example.com", "url": "http://x/checkout/0xabc", "paid_at": None}
PAYMENTS = [{"id": 3, "status": "paid"}, {"id": 2, "status": "paid"}, {"id": 1, "status": "paid"}]
SEEN = []  # (method, path, headers, body) of every request


class Mock(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body, ctype="application/json"):
        raw = (json.dumps(body) if ctype == "application/json" else body).encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def handle_any(self, method):
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n)) if n else None
        url = urlparse(self.path)
        SEEN.append((method, self.path, dict(self.headers), body))
        p = url.path
        if p.startswith("/api/v1/licenses/"):
            action, key, inst = p.rsplit("/", 1)[1], body.get("license_key"), body.get("instance_id")
            if action == "validate":
                if key == "REFUNDED":
                    return self.reply(200, {"valid": False, "status": "disabled"})
                if key == "LAPSED":
                    return self.reply(200, {"valid": False, "status": "expired", "license": LAPSED, "product": PRODUCT})
                if key not in ("GOOD", "FULL"):
                    return self.reply(200, {"valid": False, "status": "not_found"})
                ok = inst in (None, "dev-1")
                return self.reply(200, {"valid": ok, "status": "active" if ok else "not_activated",
                                        "license": LICENSE, "product": PRODUCT})
            if key == "REFUNDED":
                return self.reply(403, {"error": "this license key is disabled", "code": "license_disabled"})
            if key == "LAPSED":
                return self.reply(403, {"error": "this license key has expired", "code": "license_expired",
                                        "license": LAPSED, "product": PRODUCT})
            if key not in ("GOOD", "FULL"):
                return self.reply(404, {"error": "license key not found", "code": "license_not_found"})
            if not inst:
                return self.reply(400, {"error": "instance_id is required", "code": "bad_request"})
            if action == "activate" and key == "FULL":
                return self.reply(409, {"error": "activation limit reached", "code": "activation_limit",
                                        "license": {"key": "FULL", "activations": 3, "max_activations": 3}, "product": PRODUCT})
            if action == "activate":
                return self.reply(200, {"activated": True, "instance_id": inst, "license": LICENSE, "product": PRODUCT})
            if inst != "dev-1":
                return self.reply(404, {"error": "that instance is not activated", "code": "instance_not_found"})
            return self.reply(200, {"deactivated": True, "license": dict(LICENSE, activations=0), "product": PRODUCT})
        if p == "/api/v1/creators/demo":
            return self.reply(200, {"handle": "demo", "name": "Ada Builds"})
        if p.startswith("/api/v1/") and self.headers.get("Authorization") != "Bearer sc_test":
            return self.reply(401, {"error": "invalid API key", "code": "invalid_api_key"})
        if p == "/api/v1/checkouts" and method == "POST":
            return self.reply(201, CHECKOUT)
        if p == "/api/v1/checkouts/0xabc":
            return self.reply(200, CHECKOUT)
        if p == "/api/v1/checkouts/0xpaid":
            return self.reply(200, dict(CHECKOUT, status="paid", paid_at="2026-11-14T10:00:00.000Z"))
        if p == "/api/v1/payments":  # two per page, newest first, cursor = the last id on the page
            after = int(parse_qs(url.query).get("after", ["1000"])[0])
            rows = [r for r in PAYMENTS if r["id"] < after]
            data, more = rows[:2], len(rows) > 2
            return self.reply(200, {"data": data, "has_more": more, "next": data[-1]["id"] if more else None})
        if p == "/api/v1/members":
            return self.reply(200, {"data": [{"email": "a@b.co"}], "has_more": False, "next": None})
        if p == "/api/v1/payments/42":
            return self.reply(200, {"id": 42, "item": "Pro", "activity": []})
        if p == "/api/v1/payments/7":
            return self.reply(404, {"error": "payment not found", "code": "not_found"})
        if p == "/api/v1/broken":
            return self.reply(200, "not json", "text/plain")
        return self.reply(404, "<html>Not found</html>", "text/html")

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")


class SendclapTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Mock)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cls.server.server_address[1]}"
        cls.lic = LicenseClient(base_url=cls.base + "/")
        cls.api = ApiClient("sc_test", base_url=cls.base)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def test_activate(self):
        r = self.lic.activate("GOOD", "dev-1")
        self.assertEqual(r.instance_id, "dev-1")
        self.assertEqual(r.license.max_activations, 3)
        self.assertEqual(r.product.name, "Pro")
        method, path, headers, body = SEEN[-1]
        self.assertEqual((method, path), ("POST", "/api/v1/licenses/activate"))
        self.assertEqual(body, {"license_key": "GOOD", "instance_id": "dev-1"})
        self.assertEqual(headers["User-Agent"], "sendclap-python/0.4.0")
        self.assertEqual(headers["Content-Type"], "application/json")
        self.assertNotIn("Authorization", headers)

    def test_activate_limit(self):
        with self.assertRaises(ActivationLimitError) as cm:
            self.lic.activate("FULL", "dev-9")
        self.assertEqual((cm.exception.status, cm.exception.code), (409, "activation_limit"))
        self.assertEqual(cm.exception.license.activations, 3)
        self.assertEqual(cm.exception.product.id, 1)
        self.assertEqual(str(cm.exception), "activation limit reached")

    def test_activate_invalid_key(self):
        with self.assertRaises(InvalidLicenseError) as cm:
            self.lic.activate("BAD", "dev-1")
        self.assertEqual((cm.exception.status, cm.exception.code), (404, "license_not_found"))
        self.assertEqual(cm.exception.message, "license key not found")

    def test_activate_disabled_key(self):
        with self.assertRaises(DisabledLicenseError) as cm:
            self.lic.activate("REFUNDED", "dev-1")
        self.assertNotIsInstance(cm.exception, InvalidLicenseError)
        self.assertEqual((cm.exception.status, cm.exception.code), (403, "license_disabled"))

    def test_expired_key(self):
        r = self.lic.validate("LAPSED", "dev-1")
        self.assertEqual((r.valid, r.status, r.license.expires_at, r.product.name), (False, "expired", "2026-01-01T00:00:00.000Z", "Pro"))
        with self.assertRaises(ExpiredLicenseError) as cm:
            self.lic.activate("LAPSED", "dev-1")
        self.assertEqual((cm.exception.status, cm.exception.code, cm.exception.license.expires_at),
                         (403, "license_expired", "2026-01-01T00:00:00.000Z"))

    def test_activate_missing_instance(self):
        with self.assertRaises(SendclapError) as cm:
            self.lic.activate("GOOD", "")
        self.assertEqual((cm.exception.status, cm.exception.code), (400, "bad_request"))
        self.assertEqual(cm.exception.message, "instance_id is required")

    def test_validate(self):
        r = self.lic.validate("GOOD")
        self.assertEqual((r.valid, r.status), (True, "active"))
        self.assertEqual(SEEN[-1][3], {"license_key": "GOOD"})
        self.assertEqual(self.lic.validate("GOOD", "dev-1").status, "active")
        r = self.lic.validate("GOOD", "other")
        self.assertEqual((r.valid, r.status, r.license.key), (False, "not_activated", "GOOD"))
        r = self.lic.validate("BAD", "dev-1")
        self.assertEqual((r.valid, r.status, r.license, r.product), (False, "not_found", None, None))
        r = self.lic.validate("REFUNDED", "dev-1")
        self.assertEqual((r.valid, r.status, r.license, r.product), (False, "disabled", None, None))

    def test_deactivate(self):
        r = self.lic.deactivate("GOOD", "dev-1")
        self.assertEqual(r.license.activations, 0)
        with self.assertRaises(InvalidLicenseError):
            self.lic.deactivate("BAD", "dev-1")
        with self.assertRaises(InstanceNotFoundError) as cm:
            self.lic.deactivate("GOOD", "nope")
        self.assertEqual((cm.exception.status, cm.exception.code), (404, "instance_not_found"))

    def test_html_404_is_not_invalid_license(self):
        wrong = LicenseClient(base_url=self.base + "/nope")
        with self.assertRaises(SendclapError) as cm:
            wrong.validate("GOOD")
        self.assertNotIsInstance(cm.exception, InvalidLicenseError)
        self.assertEqual((cm.exception.status, cm.exception.message, cm.exception.code), (404, "HTTP 404", ""))

    def test_network_error(self):
        with self.assertRaises(NetworkError) as cm:
            LicenseClient(base_url="http://127.0.0.1:1", timeout=2).validate("GOOD")
        self.assertEqual((cm.exception.status, cm.exception.code), (0, "network_error"))

    def test_invalid_json(self):
        with self.assertRaises(SendclapError) as cm:
            self.api._http.request("GET", "/broken")
        self.assertEqual((cm.exception.status, cm.exception.message), (200, "invalid JSON response"))

    def test_checkouts(self):
        c = self.api.create_checkout("product", product_id=1, email="buyer@example.com")
        self.assertEqual(c["url"], "http://x/checkout/0xabc")
        method, path, headers, body = SEEN[-1]
        self.assertEqual(body, {"type": "product", "product_id": 1, "email": "buyer@example.com"})
        self.assertEqual(headers["Authorization"], "Bearer sc_test")
        g = self.api.get_checkout("0xabc")
        self.assertEqual((g["status"], g["url"]), ("pending", "http://x/checkout/0xabc"))
        self.assertIsNone(g["paid_at"])
        self.assertEqual(self.api.get_checkout("0xpaid")["paid_at"], "2026-11-14T10:00:00.000Z")

    def test_payments_page(self):
        page = self.api.list_payments(status="paid", limit=2)
        self.assertEqual((page.data, page.has_more, page.next), (PAYMENTS[:2], True, 2))
        self.assertEqual(SEEN[-1][1], "/api/v1/payments?status=paid&limit=2")
        last = self.api.list_payments(after=page.next)
        self.assertEqual((last.data, last.has_more, last.next), (PAYMENTS[2:], False, None))
        self.assertEqual(self.api.get_payment(42)["item"], "Pro")
        with self.assertRaises(SendclapError) as cm:
            self.api.get_payment(7)
        self.assertEqual((cm.exception.status, cm.exception.code, cm.exception.message), (404, "not_found", "payment not found"))

    def test_all_payments_follows_next(self):
        self.assertEqual([p["id"] for p in self.api.all_payments(status="paid")], [3, 2, 1])
        self.assertEqual(SEEN[-1][1], "/api/v1/payments?status=paid&after=2")
        self.assertEqual(len(list(self.api.all_members())), 1)

    def test_unauthorized(self):
        with self.assertRaises(SendclapError) as cm:
            ApiClient("sc_wrong", base_url=self.base).me()
        self.assertEqual((cm.exception.status, cm.exception.code, cm.exception.message), (401, "invalid_api_key", "invalid API key"))

    def test_creator_without_key(self):
        self.assertEqual(ApiClient(base_url=self.base).get_creator("demo")["name"], "Ada Builds")
        self.assertNotIn("Authorization", SEEN[-1][2])

    def test_instance_name(self):
        self.assertTrue(sendclap.instance_name())


if __name__ == "__main__":
    unittest.main()
