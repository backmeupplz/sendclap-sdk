# Sendclap for .NET

The official .NET client for [Sendclap](https://sendclap.com): license keys for the apps you sell, and the creator API for your server. Targets .NET 8+ and netstandard2.0 (Unity, .NET Framework 4.6.2+), HttpClient and System.Text.Json only. API docs: https://sendclap.com/docs

## Install

```sh
dotnet add package Sendclap
```

## License check

The license endpoints need no API key, so this code ships inside your app. Activate once when the customer enters their key, then validate on every start. `ValidateAsync` only throws when it could not reach Sendclap, so an offline customer keeps working for a 7-day grace period:

```csharp
using Sendclap;

var licenses = new LicenseClient();
var instance = LicenseClient.InstanceName();
await licenses.ActivateAsync(key, instance); // once, when the key is entered

try {
    var r = await licenses.ValidateAsync(key, instance);
    if (r.Valid) settings.LicenseCheckedAt = DateTime.UtcNow; else Lock(); // Invalid or NotActivated
} catch (SendclapException) { // offline: accept the last good check for 7 days
    if (DateTime.UtcNow - settings.LicenseCheckedAt > TimeSpan.FromDays(7)) Lock();
}
```

`DeactivateAsync(key, instance)` frees the seat, for example from a "Sign out of this computer" button.

`LicenseClient.InstanceName()` returns `Environment.MachineName`. It is sent to Sendclap and shown to the creator, and two machines with the same name share one activation, so pass your own stable id (such as a `Guid` saved on first run) if that matters. The instance id Sendclap returns is the name you pass (up to 200 characters).

## Creator API

> **Never ship your `sc_…` API key inside an app.** It can read your payments and customers. Use `ApiClient` only on your own server.

```csharp
var api = new ApiClient(Environment.GetEnvironmentVariable("SENDCLAP_API_KEY"));
var checkout = await api.CreateCheckoutAsync(new CheckoutParams { Type = "product", ProductId = 1, Email = "buyer@example.com" });
// send the customer to checkout.Url, then poll:
var paid = (await api.GetCheckoutAsync(checkout.Id)).Status == "paid";
```

Also: `MeAsync`, `ListPaymentsAsync(status, type, email, limit)`, `GetPaymentAsync(id)`, `ListMembersAsync`, `ListLicensesAsync(email)`, `ListDisputesAsync`, `ListProductsAsync`, `ListMembershipsAsync` and the public `GetCreatorAsync(handle)`, which works with a null key. Both clients take `baseUrl`, `timeout` (default 15 s) and an `HttpClient` to share; every method takes a `CancellationToken`.

## Errors

All exceptions derive from `SendclapException`, which has `Status` and `Message`:

| Exception | When |
| --- | --- |
| `InvalidLicenseException` | 404: the key does not exist, or it was disabled after a refund or dispute |
| `ActivationLimitException` | 409: the key is activated on all the devices it allows (`License`, `Product`) |
| `SendclapNetworkException` | no response: offline, DNS, TLS or timeout (`Status` 0) |
| `SendclapException` | anything else: 400 bad request, 401 wrong API key, 404 not found, 5xx |

Cancelling your own `CancellationToken` throws `OperationCanceledException` as usual.
