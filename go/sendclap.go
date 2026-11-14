// Package sendclap is the official Go client for Sendclap (https://sendclap.com/docs):
// keyless license activation/validation for apps you ship, and the creator REST API for your server.
package sendclap

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

const (
	Version        = "0.1.0"
	DefaultBaseURL = "https://sendclap.com"
	DefaultTimeout = 15 * time.Second
)

var (
	ErrInvalidLicense  = errors.New("sendclap: invalid license")
	ErrActivationLimit = errors.New("sendclap: activation limit reached")
	ErrNetwork         = errors.New("sendclap: network error")
)

// Error is returned for every failed call. Status is the HTTP status, 0 when no response arrived.
// Use errors.Is(err, ErrInvalidLicense / ErrActivationLimit / ErrNetwork) to tell the cases apart.
type Error struct {
	Status  int
	Message string
	kind    error
	cause   error
}

func (e *Error) Error() string {
	if e.Status == 0 {
		return "sendclap: network error: " + e.Message
	}
	return fmt.Sprintf("sendclap: %s (HTTP %d)", e.Message, e.Status)
}

func (e *Error) Is(target error) bool { return target != nil && target == e.kind }
func (e *Error) Unwrap() error        { return e.cause }

// ActivationLimitError is returned by Activate when every activation of the key is in use.
// errors.As(err, &*Error) also matches it (Status 409).
type ActivationLimitError struct {
	Err     *Error
	License LicenseInfo
	Product ProductRef
}

func (e *ActivationLimitError) Error() string { return e.Err.Error() }
func (e *ActivationLimitError) Unwrap() error { return e.Err }

type client struct {
	base   string
	apiKey string
	http   *http.Client
}

// Option configures a client.
type Option func(*client)

func WithBaseURL(url string) Option      { return func(c *client) { c.base = strings.TrimRight(url, "/") } }
func WithTimeout(d time.Duration) Option { return func(c *client) { c.http.Timeout = d } }

func newClient(apiKey string, opts []Option) client {
	c := client{base: DefaultBaseURL, apiKey: apiKey, http: &http.Client{Timeout: DefaultTimeout}}
	for _, o := range opts {
		o(&c)
	}
	return c
}

func (c *client) do(ctx context.Context, method, path string, body, out any) error {
	var rd io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.base+"/api/v1"+path, rd)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "sendclap-go/"+Version)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if c.apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+c.apiKey)
	}
	res, err := c.http.Do(req)
	if err != nil {
		return &Error{Message: err.Error(), kind: ErrNetwork, cause: err}
	}
	defer res.Body.Close()
	data, err := io.ReadAll(res.Body)
	if err != nil {
		return &Error{Message: err.Error(), kind: ErrNetwork, cause: err}
	}
	if res.StatusCode/100 == 2 {
		if err := json.Unmarshal(data, out); err != nil {
			return &Error{Status: res.StatusCode, Message: "invalid JSON response", cause: err}
		}
		return nil
	}
	var e struct {
		Error     string      `json:"error"`
		Valid     *bool       `json:"valid"`
		Activated *bool       `json:"activated"`
		License   LicenseInfo `json:"license"`
		Product   ProductRef  `json:"product"`
	}
	parsed := json.Unmarshal(data, &e) == nil // HTML error pages (wrong base URL, crashes) stay plain errors
	base := Error{Status: res.StatusCode, Message: e.Error}
	if base.Message == "" {
		base.Message = fmt.Sprintf("HTTP %d", res.StatusCode)
	}
	switch {
	case parsed && res.StatusCode == 404 && e.Valid != nil && !*e.Valid:
		base.kind = ErrInvalidLicense
	case parsed && res.StatusCode == 409 && e.Activated != nil && !*e.Activated:
		base.kind = ErrActivationLimit
		return &ActivationLimitError{Err: &base, License: e.License, Product: e.Product}
	}
	return &base
}

// InstanceName returns the machine hostname, a simple per-machine instance name for Activate.
// It is sent to Sendclap and shown to the creator, and two machines with the same hostname share one
// activation; pass your own stable id (e.g. a random UUID saved on first run) if that matters.
func InstanceName() (string, error) { return os.Hostname() }

// LicenseInfo is the activation state of a license key.
type LicenseInfo struct {
	Key            string `json:"key"`
	Activations    int    `json:"activations"`
	MaxActivations int    `json:"max_activations"`
}

// ProductRef names the product a key belongs to. Fields are zero if the product was deleted.
type ProductRef struct {
	ID   int    `json:"id"`
	Name string `json:"name"`
}

type ActivateResult struct {
	InstanceID string      `json:"instance_id"`
	License    LicenseInfo `json:"license"`
	Product    ProductRef  `json:"product"`
}

type DeactivateResult struct {
	License LicenseInfo `json:"license"`
	Product ProductRef  `json:"product"`
}

const (
	StatusActive       = "active"        // valid
	StatusNotActivated = "not_activated" // key exists, this instance is not activated
	StatusInvalid      = "invalid"       // key unknown, or disabled after a refund or dispute
)

type ValidateResult struct {
	Valid   bool         `json:"valid"`
	Status  string       `json:"status"`
	License *LicenseInfo `json:"license,omitempty"` // nil when Status is StatusInvalid
	Product *ProductRef  `json:"product,omitempty"`
}

// LicenseClient calls the keyless license endpoints; safe to ship inside apps.
type LicenseClient struct{ c client }

func NewLicenseClient(opts ...Option) *LicenseClient { return &LicenseClient{newClient("", opts)} }

func licenseBody(key, instance string) map[string]string {
	b := map[string]string{"license_key": key}
	if instance != "" {
		b["instance_id"] = instance
	}
	return b
}

// Activate registers this instance against the key. The returned InstanceID is the instanceName you passed.
func (l *LicenseClient) Activate(ctx context.Context, licenseKey, instanceName string) (*ActivateResult, error) {
	var r ActivateResult
	if err := l.c.do(ctx, http.MethodPost, "/licenses/activate", licenseBody(licenseKey, instanceName), &r); err != nil {
		return nil, err
	}
	return &r, nil
}

// Validate checks a key, and with a non-empty instanceID that the instance is activated.
// An unknown or disabled key is a result (StatusInvalid), not an error; errors mean the answer is unknown (e.g. offline).
func (l *LicenseClient) Validate(ctx context.Context, licenseKey, instanceID string) (*ValidateResult, error) {
	var r struct {
		Valid   bool        `json:"valid"`
		License LicenseInfo `json:"license"`
		Product ProductRef  `json:"product"`
	}
	if err := l.c.do(ctx, http.MethodPost, "/licenses/validate", licenseBody(licenseKey, instanceID), &r); err != nil {
		if errors.Is(err, ErrInvalidLicense) {
			return &ValidateResult{Status: StatusInvalid}, nil
		}
		return nil, err
	}
	status := StatusActive
	if !r.Valid {
		status = StatusNotActivated
	}
	return &ValidateResult{Valid: r.Valid, Status: status, License: &r.License, Product: &r.Product}, nil
}

// Deactivate releases an instance, freeing one activation.
func (l *LicenseClient) Deactivate(ctx context.Context, licenseKey, instanceID string) (*DeactivateResult, error) {
	var r DeactivateResult
	if err := l.c.do(ctx, http.MethodPost, "/licenses/deactivate", licenseBody(licenseKey, instanceID), &r); err != nil {
		return nil, err
	}
	return &r, nil
}
