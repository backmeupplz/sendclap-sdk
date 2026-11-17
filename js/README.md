# sendclap

The official JavaScript and TypeScript client for [Sendclap](https://sendclap.com). It checks license keys from the app you ship and talks to the creator REST API from your server. It has no dependencies and uses the global `fetch`, so it runs in Node 18+, Bun, Deno, browsers and Electron, and it ships ESM, CommonJS and type definitions.

```sh
npm install sendclap
```

## License checks

The license calls need no API key, so they are safe to make from the app your customers run.

```ts
import { LicenseClient, NetworkError, instanceName } from 'sendclap'

const licenses = new LicenseClient()
const key = settings.licenseKey
try {
  settings.instanceId ??= (await licenses.activate(key, await instanceName())).instance_id // first run
  const r = await licenses.validate(key, settings.instanceId)
  if (r.valid) settings.lastValidated = Date.now()
  else lockApp(r.status) // "not_found" (unknown key), "disabled" (refunded or disputed), "expired" (subscription over) or "not_activated"
} catch (e) {
  // offline: keep working for 7 days after the last successful check
  if (!(e instanceof NetworkError) || Date.now() - settings.lastValidated > 7 * 86400_000) lockApp('unverified')
}
```

- `activate(licenseKey, instanceName)` registers this device and returns `{ instance_id, license, product }`. Activating the same instance again counts once, and the instance id is simply the name you passed.
- `validate(licenseKey, instanceId?)` returns `{ valid, status, license?, product? }`. Its `status` is `active`, `not_activated` (the key exists but this device isn't activated), `expired` (a subscription key past `license.expires_at`), `disabled` (the payment was refunded or disputed) or `not_found` (unknown key). It throws only when no definite answer came back, which is how you tell "offline" from "not found".
- `deactivate(licenseKey, instanceId)` frees one activation so the customer can move to another machine. It throws `InstanceNotFoundError` if that instance wasn't activated.

To tell a customer why a license doesn't work, branch on the status, or catch the typed error from `activate`:

```ts
const r = await licenses.validate(key, instanceId)
if (r.status === 'disabled') showMessage('This license was refunded or disputed.')
else if (r.status === 'not_found') showMessage('That license key does not exist.')

try { await licenses.activate(key, name) } catch (e) {
  if (e instanceof DisabledLicenseError) showMessage('This license was refunded or disputed.')
}
```

`instanceName()` returns the hostname in Node, Bun, Deno and Electron's main process, and a random id kept in `localStorage` in browsers. The name is sent to Sendclap and shown to the creator in the activity log, and machines that share a hostname share an activation. If that matters, generate your own id (for example `crypto.randomUUID()` saved on first run) and pass it instead.

Cache the result of the last successful `validate` and validate again at startup or once a day. On a `NetworkError`, accept the cached result for a grace period. On `not_found`, `disabled`, `expired` or `not_activated`, lock.

## Creator API

> **Never ship your `sc_` API key inside an app, a browser bundle or anything a customer can download.** Anyone who has it can read your payments and customers. Use `ApiClient` only on your own server.

```ts
import { ApiClient } from 'sendclap'

const sendclap = new ApiClient(process.env.SENDCLAP_API_KEY!)
const checkout = await sendclap.createCheckout({ type: 'product', product_id: 1, email: 'buyer@example.com' })
redirect(checkout.url) // then poll until it is paid
const { status } = await sendclap.getCheckout(checkout.id)
const page = await sendclap.listPayments({ status: 'paid', limit: 10 }) // { data, has_more, next }
```

Lists come back as pages of `{ data, has_more, next }`, newest first. Pass `next` back as `after` for the following page, or use the auto-paging `all…` methods, which are async iterators:

```ts
if (page.has_more) await sendclap.listPayments({ status: 'paid', limit: 10, after: page.next! })
for await (const p of sendclap.allPayments({ status: 'paid' })) console.log(p.id, p.amount)
```

The methods are `createCheckout`, `getCheckout` (both return the checkout `url`), `me`, `getPayment`, `listProducts`, `listMemberships`, `listPayments`, `listMembers`, `listLicenses` and `listDisputes` (pages), `allPayments`, `allMembers`, `allLicenses` and `allDisputes` (iterators), and `getCreator`. The last one is public and works with an empty key. Responses keep the API's own snake_case field names, as described in the [API docs](https://sendclap.com/docs).

Both clients take `{ baseUrl, timeout }` options. The defaults are `https://sendclap.com` and 15000 ms. Requests send `User-Agent: sendclap-js/<version>`, or `x-sendclap-client: sendclap-js/<version>` in a browser, where `User-Agent` can't be set.

## Errors

Every error is a `SendclapError` with `.status`, `.code` (the server's machine-readable code, such as `invalid_api_key` or `not_found`) and the server's message. The typed errors are chosen by `code`:

| Error | `code` | When |
| --- | --- | --- |
| `InvalidLicenseError` | `license_not_found` | The key doesn't exist (404) |
| `DisabledLicenseError` | `license_disabled` | The key was disabled after a refund or a dispute (403) |
| `ExpiredLicenseError` | `license_expired` | The subscription key has expired, and `.license.expires_at` says when (403) |
| `InstanceNotFoundError` | `instance_not_found` | `deactivate` for an instance that isn't activated (404) |
| `ActivationLimitError` | `activation_limit` | Every activation is in use, and `.license` shows the counts (409) |
| `NetworkError` | `network_error` | No response arrived (offline, DNS, TLS or timeout), and `.status` is 0 |
| `SendclapError` | anything else | Such as `bad_request`, `invalid_api_key` or `not_found`. All of the errors above extend it. |
