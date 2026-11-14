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
  else lockApp(r.status) // "invalid" (unknown, refunded or disputed key) or "not_activated"
} catch (e) {
  // offline: keep working for 7 days after the last successful check
  if (!(e instanceof NetworkError) || Date.now() - settings.lastValidated > 7 * 86400_000) lockApp('unverified')
}
```

- `activate(licenseKey, instanceName)` registers this device and returns `{ instance_id, license, product }`. Activating the same instance again counts once, and the instance id is simply the name you passed.
- `validate(licenseKey, instanceId?)` returns `{ valid, status, license?, product? }`. Its `status` is `active`, `not_activated` (the key exists but this device isn't activated) or `invalid`. It throws only when no definite answer came back, which is how you tell "offline" from "invalid".
- `deactivate(licenseKey, instanceId)` frees one activation so the customer can move to another machine.

`instanceName()` returns the hostname in Node, Bun, Deno and Electron's main process, and a random id kept in `localStorage` in browsers. The name is sent to Sendclap and shown to the creator in the activity log, and machines that share a hostname share an activation. If that matters, generate your own id (for example `crypto.randomUUID()` saved on first run) and pass it instead.

Cache the result of the last successful `validate` and validate again at startup or once a day. On a `NetworkError`, accept the cached result for a grace period. On `invalid` or `not_activated`, lock.

## Creator API

> **Never ship your `sc_` API key inside an app, a browser bundle or anything a customer can download.** Anyone who has it can read your payments and customers. Use `ApiClient` only on your own server.

```ts
import { ApiClient } from 'sendclap'

const sendclap = new ApiClient(process.env.SENDCLAP_API_KEY!)
const checkout = await sendclap.createCheckout({ type: 'product', product_id: 1, email: 'buyer@example.com' })
redirect(checkout.url) // then poll until it is paid
const { status } = await sendclap.getCheckout(checkout.id)
const recent = await sendclap.listPayments({ status: 'paid', limit: 10 })
```

The methods are `createCheckout`, `getCheckout`, `me`, `listPayments`, `getPayment`, `listMembers`, `listLicenses`, `listDisputes`, `listProducts`, `listMemberships` and `getCreator`. The last one is public and works with an empty key. Responses keep the API's own snake_case field names, as described in the [API docs](https://sendclap.com/docs).

Both clients take `{ baseUrl, timeout }` options. The defaults are `https://sendclap.com` and 15000 ms.

## Errors

| Error | When |
| --- | --- |
| `InvalidLicenseError` | 404: the key doesn't exist, or it was disabled after a refund or a dispute |
| `ActivationLimitError` | 409: every activation is in use, and `.license` shows the counts |
| `NetworkError` | No response arrived (offline, DNS, TLS or timeout), and `.status` is 0 |
| `SendclapError` | Any other failure, such as 400, 401 or 404, with `.status` and the server's message. All of the errors above extend it. |
