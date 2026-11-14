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
    if (r.Valid) settings.LicenseCheckedAt = DateTime.UtcNow;
    else if (r.Status == LicenseStatus.Disabled) Lock("This license was refunded."); // Invalid, Disabled or NotActivated
    else Lock("Invalid license.");
} catch (SendclapNetworkException) { // offline: accept the last good check for 7 days
    if (DateTime.UtcNow - settings.LicenseCheckedAt > TimeSpan.FromDays(7)) Lock("Could not verify the license.");
}
```

`ValidateAsync` returns `Invalid` for an unknown key and `Disabled` for a refunded or disputed one, and `ActivateAsync` throws `DisabledLicenseException` for the latter. `DeactivateAsync(key, instance)` frees the seat, for example from a "Sign out of this computer" button, and throws `InstanceNotFoundException` if that instance wasn't activated.

`LicenseClient.InstanceName()` returns `Environment.MachineName`. It is sent to Sendclap and shown to the creator, and two machines with the same name share one activation, so pass your own stable id (such as a `Guid` saved on first run) if that matters. The instance id Sendclap returns is the name you pass (up to 200 characters).

## Creator API

> **Never ship your `sc_…` API key inside an app.** It can read your payments and customers. Use `ApiClient` only on your own server.

```csharp
var api = new ApiClient(Environment.GetEnvironmentVariable("SENDCLAP_API_KEY"));
var checkout = await api.CreateCheckoutAsync(new CheckoutParams { Type = "product", ProductId = 1, Email = "buyer@example.com" });
// send the customer to checkout.Url, then poll:
var paid = (await api.GetCheckoutAsync(checkout.Id)).Status == "paid";

var page = await api.ListPaymentsAsync(status: "paid", limit: 20); // page.Data, page.HasMore, page.Next
if (page.HasMore) page = await api.ListPaymentsAsync(status: "paid", limit: 20, after: page.Next);
await foreach (var p in api.AllPaymentsAsync(status: "paid")) // follows Next across pages
    Console.WriteLine($"{p.Id} {p.Amount}");
```

Lists return a `Page<T>` (`Data`, `HasMore`, `Next`), newest first; `limit` is at most 500 and `after` is the previous page's `Next`. `AllPaymentsAsync`, `AllMembersAsync`, `AllLicensesAsync` and `AllDisputesAsync` return an `IAsyncEnumerable<T>` and take a `CancellationToken`.

Also: `MeAsync`, `GetPaymentAsync(id)`, `ListPaymentsAsync(status, type, email, limit, after)`, `ListMembersAsync(limit, after)`, `ListLicensesAsync(email, limit, after)`, `ListDisputesAsync(limit, after)`, `ListProductsAsync`, `ListMembershipsAsync` and the public `GetCreatorAsync(handle)`, which works with a null key. Both clients take `baseUrl`, `timeout` (default 15 s) and an `HttpClient` to share; every method takes a `CancellationToken`.

## Errors

All exceptions derive from `SendclapException`, which has `Status`, `Code` (the server's machine-readable code) and `Message`. The typed ones are chosen by `Code`:

| Exception | `Code` | When |
| --- | --- | --- |
| `InvalidLicenseException` | `license_not_found` | 404: the key does not exist |
| `DisabledLicenseException` | `license_disabled` | 403: disabled after a refund or dispute |
| `InstanceNotFoundException` | `instance_not_found` | 404: `DeactivateAsync` for an instance that isn't activated |
| `ActivationLimitException` | `activation_limit` | 409: the key is activated on all the devices it allows (`License`, `Product`) |
| `SendclapNetworkException` | `network_error` | no response: offline, DNS, TLS or timeout (`Status` 0) |
| `SendclapException` | anything else | e.g. `bad_request`, `invalid_api_key`, `not_found` |

Cancelling your own `CancellationToken` throws `OperationCanceledException` as usual.
