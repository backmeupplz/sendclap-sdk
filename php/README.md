# sendclap/sendclap (PHP)

Official PHP client for [Sendclap](https://sendclap.com): check license keys from the app you ship, and call the creator REST API from your server. PHP 8.1+, ext-curl, no other dependencies. API reference: https://sendclap.com/docs

```sh
composer require sendclap/sendclap
```

## License check (in your app, no API key)

```php
use Sendclap\{LicenseClient, NetworkException};

function licensed(string $key, array &$cache): bool {
    try {
        $r = (new LicenseClient())->validate($key, $cache['instance'] ?? LicenseClient::instanceName());
    } catch (NetworkException) { // offline: allow a 7-day grace period since the last good check
        return time() - ($cache['validated_at'] ?? 0) < 7 * 86400;
    }
    if ($r->valid) $cache['validated_at'] = time(); // persist $cache yourself
    return $r->valid; // status "not_found", "disabled" (refunded or disputed), "expired" (subscription over) or "not_activated": lock the app
}
```

On first run, activate the device and remember the instance id:

```php
use Sendclap\{ActivationLimitException, DisabledLicenseException, InvalidLicenseException, LicenseClient};
try {
    $cache['instance'] = (new LicenseClient())->activate($key, LicenseClient::instanceName())->instanceId;
} catch (InvalidLicenseException) { /* unknown key */ }
catch (DisabledLicenseException) { /* the payment was refunded or disputed */ }
catch (ActivationLimitException $e) { echo "Used on {$e->license->activations}/{$e->license->maxActivations} devices"; }
```

`deactivate($key, $instanceId)` frees the device again, and throws `InstanceNotFoundException` if it wasn't activated. `validate()` never throws for a bad key; it returns `status` `"active"`, `"not_activated"`, `"expired"` (subscription over, see `license->expiresAt`), `"disabled"` (refunded or disputed) or `"not_found"` (unknown key), and throws `NetworkException` only when it could not reach Sendclap, so you can tell "offline" from "not found".

**Instance name:** `LicenseClient::instanceName()` is the machine's hostname. It is sent to Sendclap and shown to the creator, and two machines with the same hostname share one activation. If that matters, pass your own stable id instead (for example a random UUID saved on first run). The instance id Sendclap returns is the name you send.

## Creator API (server side only)

> **Never ship your `sc_` API key inside an app, website or anything a customer can download.** Anyone holding it can read your payments and customers. Use it only on your own server.

```php
use Sendclap\ApiClient;

$api = new ApiClient('sc_your_key'); // baseUrl: 'https://sendclap.com', timeout: 15.0
$checkout = $api->createCheckout(['type' => 'product', 'product_id' => 1, 'email' => 'buyer@example.com']);
header('Location: ' . $checkout['url']);        // send the buyer here
$api->getCheckout($checkout['id'])['status'];   // "pending" until "paid"
$page = $api->listPayments(['status' => 'paid', 'limit' => 10]); // $page->data, $page->hasMore, $page->next
if ($page->hasMore) $page = $api->listPayments(['status' => 'paid', 'limit' => 10, 'after' => $page->next]);
foreach ($api->allPayments(['status' => 'paid']) as $p) echo $p['amount'], ' ', $p['email'], "\n"; // a generator that follows `next`
```

Lists (`listPayments`, `listMembers`, `listLicenses`, `listDisputes`) take an array of filters plus `limit` (default 50, at most 500) and `after` (the previous page's `next`) and return a `Page` with `data`, `hasMore` and `next`, newest first. `allPayments`, `allMembers`, `allLicenses` and `allDisputes` take the same filters and are generators over every item.

Methods: `createCheckout` and `getCheckout` (both return the checkout `url`), `me`, `getPayment`, `listProducts`, `listMemberships`, the list and `all*` methods above, `getCreator` (public, works with `new ApiClient()` and no key). Items are the API's JSON as associative arrays with snake_case keys.

## Errors

Every exception is a `SendclapException` with `->status`, `->errorCode` (the server's machine-readable code; it is not `->code` because PHP's `Exception` already owns that) and `getMessage()`. The typed ones are chosen by the code:

| Exception | `errorCode` | When |
|---|---|---|
| `InvalidLicenseException` | `license_not_found` | 404: the key doesn't exist |
| `DisabledLicenseException` | `license_disabled` | 403: disabled after a refund or dispute |
| `ExpiredLicenseException` | `license_expired` | 403: subscription over; `->license->expiresAt` says when |
| `InstanceNotFoundException` | `instance_not_found` | 404: `deactivate` for an instance that isn't activated |
| `ActivationLimitException` | `activation_limit` | 409: every activation is used; `->license` and `->product` say how many |
| `NetworkException` | `network_error` | No response: offline, DNS, TLS, timeout (`->status === 0`) |
| `SendclapException` | anything else | e.g. `bad_request`, `invalid_api_key`, `not_found` |

## Tests

From the repository root (the Composer package lives there):

```sh
php php/tests/run.php   # or: composer test
```

The runner starts `php/tests/mock.php` on PHP's built-in server and needs no Composer install.
