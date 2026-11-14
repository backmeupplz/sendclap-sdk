# Sendclap for Go

Official Go client for [Sendclap](https://sendclap.com): check license keys from the app you ship, and call the creator API from your server. Standard library only, every call takes a `context.Context`. API reference: https://sendclap.com/docs

```sh
go get github.com/backmeupplz/sendclap-sdk/go
```

## License check

The license endpoints need no API key, so this code is safe to ship inside your app.

```go
lc := sendclap.NewLicenseClient()
name, _ := sendclap.InstanceName()
if _, err := lc.Activate(ctx, key, name); err != nil && !errors.Is(err, sendclap.ErrNetwork) {
	return err // ErrInvalidLicense, ErrLicenseDisabled, *ActivationLimitError, ...
}
v, err := lc.Validate(ctx, key, name)
switch {
case errors.Is(err, sendclap.ErrNetwork): unlocked = time.Since(lastValidated) < 7*24*time.Hour // offline grace
case err != nil: return err
default: unlocked = v.Valid; if v.Valid { lastValidated = time.Now() } // save lastValidated to disk
}
```

`Validate` never fails for a bad key: an unknown key comes back as `Status == StatusNotFound`, a refunded or disputed one as `StatusDisabled` (so you can say "this license was refunded"), an inactive device as `StatusNotActivated`. `Activate` returns `ErrLicenseDisabled` for a refunded key, and `Deactivate` returns `ErrInstanceNotFound` for an instance that isn't activated. An error means the answer is unknown (offline, server down), so cache the time of the last successful validation and keep the app unlocked for a grace period. Activate once on first run and store the instance name; `Deactivate(ctx, key, name)` frees the seat when the user moves to another machine.

`InstanceName()` returns the machine hostname. It is sent to Sendclap and shown to the creator, and two machines with the same hostname share one activation; pass your own stable id (for example a random UUID saved on first run) if that matters. The instance id Sendclap returns is the name you pass.

## Creator API

> **Server side only. Never ship your `sc_` API key in an app, website or anything a customer can download:** anyone who has it can read your payments and customers.

```go
api := sendclap.NewAPIClient(os.Getenv("SENDCLAP_API_KEY"))
c, err := api.CreateCheckout(ctx, sendclap.CheckoutParams{Type: "product", ProductID: 1, Email: "buyer@example.com"})
// redirect the buyer to c.URL, then poll:
c, err = api.GetCheckout(ctx, c.ID) // c.Status == "paid"
page, err := api.ListPayments(ctx, sendclap.PaymentFilter{Status: "paid", Limit: 20}) // page.Data, page.HasMore, page.Next
if page.HasMore {
	page, err = api.ListPayments(ctx, sendclap.PaymentFilter{Status: "paid", Limit: 20, After: *page.Next})
}
for p, err := range api.AllPayments(ctx, sendclap.PaymentFilter{Status: "paid"}) { // follows Next across pages
	if err != nil {
		return err
	}
	fmt.Println(p.ID, p.Amount)
}
```

Lists return a `*Page[T]` (`Data`, `HasMore`, `Next`), newest first; `Limit` defaults to 50 and is at most 500 and `After` is the previous page's `Next`. `AllPayments`, `AllMembers`, `AllLicenses` and `AllDisputes` return an `iter.Seq2[T, error]`, so the module needs Go 1.23.

Methods: `CreateCheckout` and `GetCheckout` (both return the checkout `URL`), `Me`, `GetPayment`, `ListProducts`, `ListMemberships`, `ListPayments`, `ListMembers`, `ListLicenses`, `ListDisputes`, the `All…` iterators, and `GetCreator` (public, works with an empty key). Options for both clients: `sendclap.WithBaseURL(url)`, `sendclap.WithTimeout(d)` (default 15 s).

## Errors

Every error is a `*sendclap.Error` (`errors.As`) with `Status`, `Code` (the server's machine-readable code) and `Message`. The `Err…` values are chosen by `Code`.

| Check | `Code` | When |
|---|---|---|
| `errors.Is(err, sendclap.ErrInvalidLicense)` | `license_not_found` | 404: key unknown |
| `errors.Is(err, sendclap.ErrLicenseDisabled)` | `license_disabled` | 403: disabled after a refund or dispute |
| `errors.Is(err, sendclap.ErrInstanceNotFound)` | `instance_not_found` | 404: `Deactivate` for an instance that isn't activated |
| `errors.Is(err, sendclap.ErrActivationLimit)` / `*sendclap.ActivationLimitError` | `activation_limit` | 409: all activations in use; carries `License` and `Product` |
| `errors.Is(err, sendclap.ErrNetwork)` | `network_error` | no response (DNS, refused, TLS, timeout); `Status` is 0 |
| anything else | e.g. `bad_request`, `invalid_api_key`, `not_found` | `Status` 400, 401 (bad API key), 404, 5xx |

## License

MIT
