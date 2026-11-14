package sendclap

import (
	"context"
	"iter"
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
	URL      string  `json:"url"` // where to send the customer to pay
}

// Page is one page of a list, newest first. When HasMore is true, pass Next as After to get the following page.
type Page[T any] struct {
	Data    []T  `json:"data"`
	HasMore bool `json:"has_more"`
	Next    *int `json:"next"`
}

// PageParams pages through a list: Limit is 1..500, After is the previous page's Next.
type PageParams struct {
	Limit int
	After int
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
	After  int
}

type LicenseFilter struct {
	Email string
	Limit int
	After int
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

// list fetches one page; empty values and zero numbers are left out of the query.
func list[T any](ctx context.Context, a *APIClient, path string, limit, after int, filters map[string]string) (*Page[T], error) {
	q := url.Values{}
	for k, v := range filters {
		if v != "" {
			q.Set(k, v)
		}
	}
	if limit > 0 {
		q.Set("limit", strconv.Itoa(limit))
	}
	if after > 0 {
		q.Set("after", strconv.Itoa(after))
	}
	if len(q) > 0 {
		path += "?" + q.Encode()
	}
	return call[*Page[T]](ctx, a, http.MethodGet, path, nil)
}

// all follows Next until the last page. The sequence yields an error once and stops.
func all[T any](fetch func(after int) (*Page[T], error)) iter.Seq2[T, error] {
	return func(yield func(T, error) bool) {
		for after := 0; ; {
			p, err := fetch(after)
			if err != nil {
				var zero T
				yield(zero, err)
				return
			}
			for _, v := range p.Data {
				if !yield(v, nil) {
					return
				}
			}
			if !p.HasMore || p.Next == nil {
				return
			}
			after = *p.Next
		}
	}
}

func (a *APIClient) ListPayments(ctx context.Context, f PaymentFilter) (*Page[Payment], error) {
	return list[Payment](ctx, a, "/payments", f.Limit, f.After, map[string]string{"status": f.Status, "type": f.Type, "email": f.Email})
}

// AllPayments iterates every matching payment across pages; f.After is ignored.
func (a *APIClient) AllPayments(ctx context.Context, f PaymentFilter) iter.Seq2[Payment, error] {
	return all(func(after int) (*Page[Payment], error) { f.After = after; return a.ListPayments(ctx, f) })
}

func (a *APIClient) GetPayment(ctx context.Context, id int) (*PaymentDetail, error) {
	return call[*PaymentDetail](ctx, a, http.MethodGet, "/payments/"+strconv.Itoa(id), nil)
}

func (a *APIClient) ListMembers(ctx context.Context, p PageParams) (*Page[Member], error) {
	return list[Member](ctx, a, "/members", p.Limit, p.After, nil)
}

func (a *APIClient) AllMembers(ctx context.Context, p PageParams) iter.Seq2[Member, error] {
	return all(func(after int) (*Page[Member], error) { p.After = after; return a.ListMembers(ctx, p) })
}

// ListLicenses lists issued keys; a non-empty Email filters by customer.
func (a *APIClient) ListLicenses(ctx context.Context, f LicenseFilter) (*Page[IssuedLicense], error) {
	return list[IssuedLicense](ctx, a, "/licenses", f.Limit, f.After, map[string]string{"email": f.Email})
}

func (a *APIClient) AllLicenses(ctx context.Context, f LicenseFilter) iter.Seq2[IssuedLicense, error] {
	return all(func(after int) (*Page[IssuedLicense], error) { f.After = after; return a.ListLicenses(ctx, f) })
}

func (a *APIClient) ListDisputes(ctx context.Context, p PageParams) (*Page[Dispute], error) {
	return list[Dispute](ctx, a, "/disputes", p.Limit, p.After, nil)
}

func (a *APIClient) AllDisputes(ctx context.Context, p PageParams) iter.Seq2[Dispute, error] {
	return all(func(after int) (*Page[Dispute], error) { p.After = after; return a.ListDisputes(ctx, p) })
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
