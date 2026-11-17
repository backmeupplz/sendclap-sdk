package sendclap

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const lapsed = `"license":{"key":"LAPSED","activations":1,"max_activations":3,"expires_at":"2026-01-01T00:00:00.000Z"},"product":{"id":1,"name":"Pro"}`
const lic = `"license":{"key":"GOOD","activations":1,"max_activations":3},"product":{"id":1,"name":"Pro"}`

func mock(t *testing.T) *httptest.Server {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		send := func(status int, body string) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(status)
			io.WriteString(w, body)
		}
		if ua := r.Header.Get("User-Agent"); ua != "sendclap-go/0.5.0" {
			t.Errorf("user agent %q", ua)
		}
		if action, ok := strings.CutPrefix(r.URL.Path, "/api/v1/licenses/"); ok {
			if r.Header.Get("Content-Type") != "application/json" || r.Header.Get("Authorization") != "" {
				t.Errorf("license headers %v", r.Header)
			}
			var b struct {
				Key      string `json:"license_key"`
				Instance string `json:"instance_id"`
			}
			json.NewDecoder(r.Body).Decode(&b)
			switch {
			case action == "validate" && b.Key == "BAD":
				send(200, `{"valid":false,"status":"not_found"}`)
			case action == "validate" && b.Key == "LAPSED":
				send(200, `{"valid":false,"status":"expired",`+lapsed+`}`)
			case action == "validate" && b.Key == "REFUNDED":
				send(200, `{"valid":false,"status":"disabled"}`)
			case action == "validate":
				ok := b.Instance == "" || b.Instance == "dev-1"
				send(200, fmt.Sprintf(`{"valid":%t,"status":%q,%s}`, ok, map[bool]string{true: "active", false: "not_activated"}[ok], lic))
			case b.Key == "BAD":
				send(404, `{"error":"license key not found","code":"license_not_found"}`)
			case b.Key == "LAPSED":
				send(403, `{"error":"this license key has expired","code":"license_expired",`+lapsed+`}`)
			case b.Key == "REFUNDED":
				send(403, `{"error":"this license key is disabled","code":"license_disabled"}`)
			case b.Instance == "":
				send(400, `{"error":"instance_id is required","code":"bad_request"}`)
			case action == "deactivate" && b.Instance != "dev-1":
				send(404, `{"error":"that instance is not activated","code":"instance_not_found"}`)
			case action == "activate" && b.Key == "FULL":
				send(409, `{"error":"activation limit reached","code":"activation_limit","license":{"key":"FULL","activations":3,"max_activations":3},"product":{"id":1,"name":"Pro"}}`)
			case action == "activate":
				send(200, fmt.Sprintf(`{"activated":true,"instance_id":%q,%s}`, b.Instance, lic))
			case action == "deactivate":
				send(200, `{"deactivated":true,"license":{"key":"GOOD","activations":0,"max_activations":3},"product":{"id":1,"name":"Pro"}}`)
			}
			return
		}
		if r.URL.Path == "/api/v1/creators/demo" {
			if r.Header.Get("Authorization") != "" {
				t.Errorf("creator lookup sent a key")
			}
			send(200, `{"handle":"demo","name":"Ada","bio":"","url":"u","avatar":null,"links":[],"payment_methods":{"card":true,"crypto":true,"x402":false},"tip":{"suggested":5,"currency":"usd","page":"u","x402":null},"memberships":[{"id":1,"name":"Supporter","price":5,"interval":"month"}],"products":[{"id":1,"name":"Weekly","description":"","price":3,"currency":"usd","delivers_file":false,"issues_license_key":true,"page":"p","x402":null,"interval":"week"},{"id":2,"name":"Once","description":"","price":9,"currency":"usd","delivers_file":true,"issues_license_key":false,"page":"p","x402":null,"interval":null}]}`)
			return
		}
		if !strings.HasPrefix(r.URL.Path, "/api/v1/") {
			w.Header().Set("Content-Type", "text/html")
			w.WriteHeader(404)
			io.WriteString(w, "<h1>Not found</h1>")
			return
		}
		if r.Header.Get("Authorization") != "Bearer sc_test" {
			send(401, `{"error":"invalid API key","code":"invalid_api_key"}`)
			return
		}
		switch r.Method + " " + r.URL.Path {
		case "POST /api/v1/checkouts":
			body, _ := io.ReadAll(r.Body)
			if string(body) != `{"type":"product","product_id":1,"email":"b@x.com"}` {
				t.Errorf("checkout body %s", body)
			}
			send(201, `{"id":"0xabc","status":"pending","type":"product","amount":29,"currency":"usd","method":"card","email":"b@x.com","url":"https://sendclap.com/checkout/0xabc","paid_at":null}`)
		case "GET /api/v1/checkouts/0xabc":
			send(200, `{"id":"0xabc","status":"paid","type":"product","amount":29,"currency":"usd","method":"card","email":null,"url":"https://sendclap.com/checkout/0xabc","paid_at":"2026-11-14T10:00:00.000Z"}`)
		case "GET /api/v1/me":
			send(200, `{"handle":"demo","last_30_days":{"payments":2,"gross":58,"fees":0.58,"net":57.42},"all_time":{"payments":2,"gross":58,"fees":0.58,"net":57.42},"members":{"active":1,"monthly_recurring":5},"open_disputes":0}`)
		case "GET /api/v1/payments":
			// two per page, newest first, cursor = the last id on the page
			switch r.URL.RawQuery {
			case "limit=2&status=paid":
				send(200, `{"data":[{"id":3,"status":"paid","fee":0.29},{"id":2,"status":"paid"}],"has_more":true,"next":2}`)
			case "after=2&limit=2&status=paid":
				send(200, `{"data":[{"id":1,"status":"paid"}],"has_more":false,"next":null}`)
			default:
				t.Errorf("payments query %q", r.URL.RawQuery)
			}
		case "GET /api/v1/payments/42":
			send(200, `{"id":42,"type":"product","amount":29,"item":"Pro","purchase_ip":null,"dispute":{"id":"dp_1","status":"open","reason":null,"respond_by":null},"activity":[{"at":"t","event":"license_activate","detail":"Pro","ip":null}],"evidence_pdf":"p"}`)
		case "GET /api/v1/payments/7":
			send(404, `{"error":"payment not found","code":"not_found"}`)
		case "GET /api/v1/licenses":
			if r.URL.RawQuery != "email=b%40x.com" {
				t.Errorf("licenses query %q", r.URL.RawQuery)
			}
			send(200, `{"data":[{"key":"GOOD","product":"Pro","email":"b@x.com","activations":1,"max_activations":3,"disabled":true,"issued_at":"t"}],"has_more":false,"next":null}`)
		case "GET /api/v1/members", "GET /api/v1/disputes":
			send(200, `{"data":[],"has_more":false,"next":null}`)
		case "GET /api/v1/products", "GET /api/v1/memberships":
			send(200, `[]`)
		default:
			t.Errorf("unexpected %s %s", r.Method, r.URL)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

var ctx = context.Background()

func TestLicense(t *testing.T) {
	l := NewLicenseClient(WithBaseURL(mock(t).URL + "/"))

	a, err := l.Activate(ctx, "GOOD", "dev-1")
	if err != nil || a.InstanceID != "dev-1" || a.License.MaxActivations != 3 || a.Product.Name != "Pro" {
		t.Fatalf("activate %+v %v", a, err)
	}
	d, err := l.Deactivate(ctx, "GOOD", "dev-1")
	if err != nil || d.License.Activations != 0 {
		t.Fatalf("deactivate %+v %v", d, err)
	}
	var e *Error
	if _, err = l.Deactivate(ctx, "GOOD", "nope"); !errors.Is(err, ErrInstanceNotFound) || !errors.As(err, &e) || e.Status != 404 || e.Code != "instance_not_found" {
		t.Fatalf("deactivate unknown instance: %v", err)
	}
	for inst, want := range map[string]string{"": StatusActive, "dev-1": StatusActive, "dev-2": StatusNotActivated} {
		v, err := l.Validate(ctx, "GOOD", inst)
		if err != nil || v.Status != want || v.Valid != (want == StatusActive) || v.License.Key != "GOOD" {
			t.Fatalf("validate %q: %+v %v", inst, v, err)
		}
	}
	v, err := l.Validate(ctx, "BAD", "dev-1")
	if err != nil || v.Valid || v.Status != StatusNotFound || v.License != nil {
		t.Fatalf("validate BAD: %+v %v", v, err)
	}
	v, err = l.Validate(ctx, "REFUNDED", "dev-1")
	if err != nil || v.Valid || v.Status != StatusDisabled || v.License != nil {
		t.Fatalf("validate REFUNDED: %+v %v", v, err)
	}
}

func TestLicenseExpired(t *testing.T) {
	l := NewLicenseClient(WithBaseURL(mock(t).URL))

	v, err := l.Validate(ctx, "LAPSED", "dev-1")
	if err != nil || v.Valid || v.Status != StatusExpired || v.License == nil || v.License.ExpiresAt == nil || *v.License.ExpiresAt != "2026-01-01T00:00:00.000Z" || v.Product.Name != "Pro" {
		t.Fatalf("validate LAPSED: %+v %v", v, err)
	}
	_, err = l.Activate(ctx, "LAPSED", "dev-1")
	var exp *ExpiredLicenseError
	var e *Error
	if !errors.Is(err, ErrLicenseExpired) || errors.Is(err, ErrLicenseDisabled) || !errors.As(err, &exp) || *exp.License.ExpiresAt != "2026-01-01T00:00:00.000Z" || !errors.As(err, &e) || e.Status != 403 || e.Code != "license_expired" {
		t.Fatalf("activate LAPSED: %v", err)
	}
}

func TestLicenseErrors(t *testing.T) {
	srv := mock(t)
	l := NewLicenseClient(WithBaseURL(srv.URL))

	_, err := l.Activate(ctx, "BAD", "dev-1")
	var e *Error
	if !errors.Is(err, ErrInvalidLicense) || !errors.As(err, &e) || e.Status != 404 || e.Code != "license_not_found" || e.Message != "license key not found" {
		t.Fatalf("BAD: %v", err)
	}

	_, err = l.Activate(ctx, "REFUNDED", "dev-1")
	if !errors.Is(err, ErrLicenseDisabled) || errors.Is(err, ErrInvalidLicense) || !errors.As(err, &e) || e.Status != 403 || e.Code != "license_disabled" {
		t.Fatalf("REFUNDED: %v", err)
	}

	_, err = l.Activate(ctx, "FULL", "dev-9")
	var limit *ActivationLimitError
	if !errors.Is(err, ErrActivationLimit) || !errors.As(err, &limit) || limit.License.Activations != 3 || !errors.As(err, &e) || e.Status != 409 || e.Code != "activation_limit" {
		t.Fatalf("FULL: %v", err)
	}

	_, err = l.Activate(ctx, "GOOD", "")
	if !errors.As(err, &e) || e.Status != 400 || e.Code != "bad_request" || e.Message != "instance_id is required" || errors.Is(err, ErrInvalidLicense) {
		t.Fatalf("missing instance: %v", err)
	}

	// an HTML 404 from a wrong base URL must not lock the user out
	_, err = NewLicenseClient(WithBaseURL(srv.URL+"/nope")).Validate(ctx, "GOOD", "dev-1")
	if !errors.As(err, &e) || e.Status != 404 || e.Code != "" || e.Message != "HTTP 404" || errors.Is(err, ErrInvalidLicense) {
		t.Fatalf("html 404: %v", err)
	}

	_, err = NewLicenseClient(WithBaseURL("http://127.0.0.1:1")).Validate(ctx, "GOOD", "")
	if !errors.Is(err, ErrNetwork) || !errors.As(err, &e) || e.Status != 0 || e.Code != "network_error" {
		t.Fatalf("network: %v", err)
	}
}

func TestAPI(t *testing.T) {
	srv := mock(t)
	a := NewAPIClient("sc_test", WithBaseURL(srv.URL))

	c, err := a.CreateCheckout(ctx, CheckoutParams{Type: "product", ProductID: 1, Email: "b@x.com"})
	if err != nil || c.ID != "0xabc" || c.URL == "" || c.Amount != 29 {
		t.Fatalf("create checkout %+v %v", c, err)
	}
	if c.PaidAt != nil {
		t.Fatalf("unpaid checkout has paid_at %v", *c.PaidAt)
	}
	if c, err = a.GetCheckout(ctx, "0xabc"); err != nil || c.Status != "paid" || c.Email != "" || c.PaidAt == nil || *c.PaidAt != "2026-11-14T10:00:00.000Z" || c.URL != "https://sendclap.com/checkout/0xabc" {
		t.Fatalf("get checkout %+v %v", c, err)
	}
	if s, err := a.Me(ctx); err != nil || s.Last30Days.Net != 57.42 || s.Members.Active != 1 {
		t.Fatalf("me %+v %v", s, err)
	}
	if p, err := a.ListPayments(ctx, PaymentFilter{Status: "paid", Limit: 2}); err != nil || len(p.Data) != 2 || p.Data[0].Fee != 0.29 || !p.HasMore || *p.Next != 2 {
		t.Fatalf("payments %+v %v", p, err)
	}
	var ids []int
	for p, err := range a.AllPayments(ctx, PaymentFilter{Status: "paid", Limit: 2}) {
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, p.ID)
	}
	if fmt.Sprint(ids) != "[3 2 1]" {
		t.Fatalf("all payments %v", ids)
	}
	if p, err := a.GetPayment(ctx, 42); err != nil || p.ID != 42 || p.Dispute.ID != "dp_1" || p.Activity[0].Event != "license_activate" {
		t.Fatalf("payment %+v %v", p, err)
	}
	if l, err := a.ListLicenses(ctx, LicenseFilter{Email: "b@x.com"}); err != nil || !l.Data[0].Disabled || l.Data[0].Product != "Pro" || l.HasMore || l.Next != nil {
		t.Fatalf("licenses %+v %v", l, err)
	}
	if _, err := a.ListMembers(ctx, PageParams{}); err != nil {
		t.Fatal(err)
	}
	if _, err := a.ListDisputes(ctx, PageParams{}); err != nil {
		t.Fatal(err)
	}
	for _, err := range a.AllMembers(ctx, PageParams{}) {
		t.Fatal("no members expected", err)
	}
	if _, err := a.ListProducts(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := a.ListMemberships(ctx); err != nil {
		t.Fatal(err)
	}

	var e *Error
	if _, err := a.GetPayment(ctx, 7); !errors.As(err, &e) || e.Status != 404 || e.Code != "not_found" || e.Message != "payment not found" || errors.Is(err, ErrInvalidLicense) {
		t.Fatalf("payment 7: %v", err)
	}
	if _, err := NewAPIClient("sc_wrong", WithBaseURL(srv.URL)).Me(ctx); !errors.As(err, &e) || e.Status != 401 || e.Code != "invalid_api_key" || e.Message != "invalid API key" {
		t.Fatalf("401: %v", err)
	}
	cr, err := NewAPIClient("", WithBaseURL(srv.URL)).GetCreator(ctx, "demo")
	if err != nil || cr.Handle != "demo" || !cr.PaymentMethods.Card || cr.Memberships[0].Interval != "month" || len(cr.Products) != 2 || cr.Products[0].Interval == nil || *cr.Products[0].Interval != "week" || cr.Products[1].Interval != nil {
		t.Fatalf("creator %+v %v", cr, err)
	}
}

func TestInstanceName(t *testing.T) {
	if n, err := InstanceName(); err != nil || n == "" {
		t.Fatalf("instance name %q %v", n, err)
	}
}
