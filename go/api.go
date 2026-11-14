package sendclap

import (
	"context"
	"net/http"
	"net/url"
	"strconv"
)

// APIClient calls the creator REST API with an sc_ API key. Server side only: never ship the key in an app.
type APIClient struct{ c client }

// NewAPIClient creates a client. apiKey may be empty when you only call GetCreator.
func NewAPIClient(apiKey string, opts ...Option) *APIClient {
	return &APIClient{newClient(apiKey, opts)}
}

type CheckoutParams struct {
	Type      string  `json:"type"` // "tip", "product" or "membership"
	Amount    float64 `json:"amount,omitempty"`
	ProductID int     `json:"product_id,omitempty"`
	TierID    int     `json:"tier_id,omitempty"`
	Email     string  `json:"email,omitempty"`
	Method    string  `json:"method,omitempty"` // "card" (default) or "crypto"
	Message   string  `json:"message,omitempty"`
}

type Checkout struct {
	ID       string  `json:"id"`
	Status   string  `json:"status"`
	Type     string  `json:"type"`
	Amount   float64 `json:"amount"`
	Currency string  `json:"currency"`
	Method   string  `json:"method"`
	Email    string  `json:"email"`
	URL      string  `json:"url"` // only set by CreateCheckout
}

type Totals struct {
	Payments int     `json:"payments"`
	Gross    float64 `json:"gross"`
	Fees     float64 `json:"fees"`
	Net      float64 `json:"net"`
}

type Stats struct {
	Handle     string `json:"handle"`
	Name       string `json:"name"`
	URL        string `json:"url"`
	Currency   string `json:"currency"`
	Last30Days Totals `json:"last_30_days"`
	AllTime    Totals `json:"all_time"`
	Members    struct {
		Active           int     `json:"active"`
		MonthlyRecurring float64 `json:"monthly_recurring"`
	} `json:"members"`
	OpenDisputes int `json:"open_disputes"`
}

type PaymentFilter struct {
	Status string
	Type   string
	Email  string
	Limit  int // 1..500, server default 50
}

type Payment struct {
	ID        int     `json:"id"`
	Type      string  `json:"type"`
	Method    string  `json:"method"`
	Status    string  `json:"status"`
	Amount    float64 `json:"amount"`
	Fee       float64 `json:"fee"`
	Currency  string  `json:"currency"`
	Email     string  `json:"email"`
	Message   string  `json:"message"`
	Reference string  `json:"reference"`
	Test      bool    `json:"test"`
	CreatedAt string  `json:"created_at"`
}

type PaymentDetail struct {
	Payment
	Item           string `json:"item"`
	PurchaseIP     string `json:"purchase_ip"`
	PurchaseDevice string `json:"purchase_device"`
	Dispute        *struct {
		ID        string `json:"id"`
		Status    string `json:"status"`
		Reason    string `json:"reason"`
		RespondBy string `json:"respond_by"`
	} `json:"dispute"`
	Activity []struct {
		At     string `json:"at"`
		Event  string `json:"event"`
		Detail string `json:"detail"`
		IP     string `json:"ip"`
	} `json:"activity"`
	EvidencePDF string `json:"evidence_pdf"`
}

type Member struct {
	Email             string  `json:"email"`
	Tier              string  `json:"tier"`
	Method            string  `json:"method"`
	Status            string  `json:"status"`
	Price             float64 `json:"price"`
	Interval          string  `json:"interval"`
	CurrentPeriodEnds string  `json:"current_period_ends"`
	JoinedAt          string  `json:"joined_at"`
}

type IssuedLicense struct {
	Key            string `json:"key"`
	Product        string `json:"product"`
	Email          string `json:"email"`
	Activations    int    `json:"activations"`
	MaxActivations int    `json:"max_activations"`
	Disabled       bool   `json:"disabled"`
	IssuedAt       string `json:"issued_at"`
}

type Dispute struct {
	ID        string  `json:"id"`
	PaymentID int     `json:"payment_id"`
	Email     string  `json:"email"`
	Amount    float64 `json:"amount"`
	Reason    string  `json:"reason"`
	Status    string  `json:"status"`
	RespondBy string  `json:"respond_by"`
	OpenedAt  string  `json:"opened_at"`
}

type Product struct {
	ID               int     `json:"id"`
	Name             string  `json:"name"`
	Description      string  `json:"description"`
	Price            float64 `json:"price"`
	Currency         string  `json:"currency"`
	DeliversFile     bool    `json:"delivers_file"`
	IssuesLicenseKey bool    `json:"issues_license_key"`
	Page             string  `json:"page"`
	X402             string  `json:"x402"`
}

type Membership struct {
	ID          int     `json:"id"`
	Name        string  `json:"name"`
	Description string  `json:"description"`
	Price       float64 `json:"price"`
	Currency    string  `json:"currency"`
	Interval    string  `json:"interval"`
	X402        string  `json:"x402"`
}

type Creator struct {
	Handle string `json:"handle"`
	Name   string `json:"name"`
	Bio    string `json:"bio"`
	URL    string `json:"url"`
	Avatar string `json:"avatar"`
	Links  []struct {
		Label string `json:"label"`
		URL   string `json:"url"`
	} `json:"links"`
	PaymentMethods struct {
		Card   bool `json:"card"`
		Crypto bool `json:"crypto"`
		X402   bool `json:"x402"`
	} `json:"payment_methods"`
	Tip struct {
		Suggested float64 `json:"suggested"`
		Currency  string  `json:"currency"`
		Page      string  `json:"page"`
		X402      string  `json:"x402"`
	} `json:"tip"`
	Memberships []Membership `json:"memberships"`
	Products    []Product    `json:"products"`
}

func call[T any](ctx context.Context, a *APIClient, method, path string, body any) (T, error) {
	var out T
	err := a.c.do(ctx, method, path, body, &out)
	return out, err
}

func (a *APIClient) CreateCheckout(ctx context.Context, p CheckoutParams) (*Checkout, error) {
	return call[*Checkout](ctx, a, http.MethodPost, "/checkouts", p)
}

func (a *APIClient) GetCheckout(ctx context.Context, id string) (*Checkout, error) {
	return call[*Checkout](ctx, a, http.MethodGet, "/checkouts/"+url.PathEscape(id), nil)
}

func (a *APIClient) Me(ctx context.Context) (*Stats, error) {
	return call[*Stats](ctx, a, http.MethodGet, "/me", nil)
}

func (a *APIClient) ListPayments(ctx context.Context, f PaymentFilter) ([]Payment, error) {
	q := url.Values{}
	for k, v := range map[string]string{"status": f.Status, "type": f.Type, "email": f.Email} {
		if v != "" {
			q.Set(k, v)
		}
	}
	if f.Limit > 0 {
		q.Set("limit", strconv.Itoa(f.Limit))
	}
	path := "/payments"
	if len(q) > 0 {
		path += "?" + q.Encode()
	}
	return call[[]Payment](ctx, a, http.MethodGet, path, nil)
}

func (a *APIClient) GetPayment(ctx context.Context, id int) (*PaymentDetail, error) {
	return call[*PaymentDetail](ctx, a, http.MethodGet, "/payments/"+strconv.Itoa(id), nil)
}

func (a *APIClient) ListMembers(ctx context.Context) ([]Member, error) {
	return call[[]Member](ctx, a, http.MethodGet, "/members", nil)
}

// ListLicenses lists issued keys; a non-empty email filters by customer.
func (a *APIClient) ListLicenses(ctx context.Context, email string) ([]IssuedLicense, error) {
	path := "/licenses"
	if email != "" {
		path += "?email=" + url.QueryEscape(email)
	}
	return call[[]IssuedLicense](ctx, a, http.MethodGet, path, nil)
}

func (a *APIClient) ListDisputes(ctx context.Context) ([]Dispute, error) {
	return call[[]Dispute](ctx, a, http.MethodGet, "/disputes", nil)
}

func (a *APIClient) ListProducts(ctx context.Context) ([]Product, error) {
	return call[[]Product](ctx, a, http.MethodGet, "/products", nil)
}

func (a *APIClient) ListMemberships(ctx context.Context) ([]Membership, error) {
	return call[[]Membership](ctx, a, http.MethodGet, "/memberships", nil)
}

// GetCreator is public and works without an API key.
func (a *APIClient) GetCreator(ctx context.Context, handle string) (*Creator, error) {
	return call[*Creator](ctx, a, http.MethodGet, "/creators/"+url.PathEscape(handle), nil)
}
