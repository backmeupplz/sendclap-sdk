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
	return err // ErrInvalidLicense, *ActivationLimitError, ...
}
v, err := lc.Validate(ctx, key, name)
switch {
case errors.Is(err, sendclap.ErrNetwork): unlocked = time.Since(lastValidated) < 7*24*time.Hour // offline grace
case err != nil: return err
default: unlocked = v.Valid; if v.Valid { lastValidated = time.Now() } // save lastValidated to disk
}
```

`Validate` never fails for a bad key: an unknown or refunded key comes back as `Status == StatusInvalid`, an inactive device as `StatusNotActivated`. An error means the answer is unknown (offline, server down), so cache the time of the last successful validation and keep the app unlocked for a grace period. Activate once on first run and store the instance name; `Deactivate(ctx, key, name)` frees the seat when the user moves to another machine.

`InstanceName()` returns the machine hostname. It is sent to Sendclap and shown to the creator, and two machines with the same hostname share one activation; pass your own stable id (for example a random UUID saved on first run) if that matters. The instance id Sendclap returns is the name you pass.

## Creator API

> **Server side only. Never ship your `sc_` API key in an app, website or anything a customer can download:** anyone who has it can read your payments and customers.

```go
api := sendclap.NewAPIClient(os.Getenv("SENDCLAP_API_KEY"))
c, err := api.CreateCheckout(ctx, sendclap.CheckoutParams{Type: "product", ProductID: 1, Email: "buyer@example.com"})
// redirect the buyer to c.URL, then poll:
c, err = api.GetCheckout(ctx, c.ID) // c.Status == "paid"
payments, err := api.ListPayments(ctx, sendclap.PaymentFilter{Status: "paid", Limit: 20})
```

Methods: `CreateCheckout`, `GetCheckout`, `Me`, `ListPayments`, `GetPayment`, `ListMembers`, `ListLicenses`, `ListDisputes`, `ListProducts`, `ListMemberships`, `GetCreator` (public, works with an empty key). Options for both clients: `sendclap.WithBaseURL(url)`, `sendclap.WithTimeout(d)` (default 15 s).

## Errors

Every error is a `*sendclap.Error` (`errors.As`) with `Status` and `Message`.

| Check | When |
|---|---|
| `errors.Is(err, sendclap.ErrInvalidLicense)` | 404: key unknown, or disabled after a refund or dispute |
| `errors.Is(err, sendclap.ErrActivationLimit)` / `*sendclap.ActivationLimitError` | 409: all activations in use; carries `License` and `Product` |
| `errors.Is(err, sendclap.ErrNetwork)` | no response (DNS, refused, TLS, timeout); `Status` is 0 |
| anything else | `Status` 400, 401 (bad API key), 404, 5xx |

## License

MIT
