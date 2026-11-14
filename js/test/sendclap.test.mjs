import { test, before, after } from 'node:test'
import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { LicenseClient, ApiClient, SendclapError, InvalidLicenseError, ActivationLimitError, NetworkError, instanceName } from '../dist/esm/index.js'
import * as cjs from '../dist/cjs/index.js'

const license = (activations = 1) => ({ key: 'GOOD', activations, max_activations: 3 })
const product = { id: 1, name: 'Pro' }
const checkout = { id: '0xabc', status: 'pending', type: 'product', amount: 29, currency: 'usd', method: 'card', email: 'a@b.co' }
let last // the last request the mock saw

// A small stand-in for the Sendclap server, answering the way server.ts does.
const server = createServer(async (req, res) => {
  let raw = ''
  for await (const chunk of req) raw += chunk
  const url = new URL(req.url, 'http://x'), body = raw ? JSON.parse(raw) : null
  last = { method: req.method, path: url.pathname, query: Object.fromEntries(url.searchParams), headers: req.headers, body }
  const send = (status, data) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(data)) }
  const p = url.pathname
  if (p === '/html/api/v1/licenses/validate') { res.writeHead(404, { 'content-type': 'text/html' }); return res.end('<h1>Not found</h1>') }
  const lic = p.match(/^\/api\/v1\/licenses\/(\w+)$/)
  if (lic) {
    const [action] = [lic[1]], { license_key: key, instance_id: inst } = body
    if (key !== 'GOOD' && key !== 'FULL') return send(404, { valid: false, error: 'license key not found' })
    if (action === 'validate') return send(200, { valid: !inst || inst === 'dev-1', license: license(), product })
    if (!inst) return send(400, { error: 'instance_id is required' })
    if (action === 'activate' && key === 'FULL') return send(409, { activated: false, error: 'activation limit reached', license: license(3), product })
    if (action === 'activate') return send(200, { activated: true, instance_id: inst, license: license(), product })
    return send(200, { deactivated: true, license: license(0), product })
  }
  if (p === '/api/v1/creators/demo') return send(200, { handle: 'demo', name: 'Ada' })
  if (req.headers.authorization !== 'Bearer sc_test') return send(401, { error: 'invalid API key' })
  if (p === '/api/v1/checkouts' && req.method === 'POST') return send(201, { ...checkout, url: 'https://sendclap.com/checkout/0xabc' })
  if (p === '/api/v1/checkouts/0xabc') return send(200, checkout)
  if (p === '/api/v1/payments') return send(200, [{ id: 42, status: 'paid' }])
  if (p === '/api/v1/payments/42') return send(200, { id: 42, activity: [] })
  if (p === '/api/v1/payments/7') return send(404, { error: 'payment not found' })
  for (const name of ['me', 'members', 'licenses', 'disputes', 'products', 'memberships']) if (p === `/api/v1/${name}`) return send(200, name === 'me' ? { handle: 'demo' } : [])
  send(500, { error: 'unexpected' })
})

let base
before(() => new Promise(r => server.listen(0, '127.0.0.1', () => { base = `http://127.0.0.1:${server.address().port}`; r() })))
after(() => server.close())

const licenses = () => new LicenseClient({ baseUrl: base + '/' })
const api = (key = 'sc_test') => new ApiClient(key, { baseUrl: base })

test('activate returns the instance and license', async () => {
  const r = await licenses().activate('GOOD', 'dev-1')
  assert.deepEqual(r, { instance_id: 'dev-1', license: license(), product })
  assert.deepEqual(last.body, { license_key: 'GOOD', instance_id: 'dev-1' })
  assert.equal(last.headers['user-agent'], 'sendclap-js/0.1.0')
  assert.equal(last.headers['content-type'], 'application/json')
  assert.equal(last.headers.authorization, undefined)
})

test('activate maps 409 to ActivationLimitError with the license', async () => {
  const e = await licenses().activate('FULL', 'dev-9').catch(e => e)
  assert.ok(e instanceof ActivationLimitError && e instanceof SendclapError)
  assert.equal(e.status, 409)
  assert.equal(e.message, 'activation limit reached')
  assert.equal(e.license.activations, 3)
})

test('activate maps 404 to InvalidLicenseError', async () => {
  const e = await licenses().activate('BAD', 'dev-1').catch(e => e)
  assert.ok(e instanceof InvalidLicenseError)
  assert.equal(e.message, 'license key not found')
})

test('activate without an instance is a 400', async () => {
  const e = await licenses().activate('GOOD', '').catch(e => e)
  assert.ok(e instanceof SendclapError && !(e instanceof InvalidLicenseError))
  assert.equal(e.status, 400)
  assert.equal(e.message, 'instance_id is required')
})

test('validate: active, not activated and invalid', async () => {
  assert.deepEqual(await licenses().validate('GOOD', 'dev-1'), { valid: true, status: 'active', license: license(), product })
  assert.deepEqual(await licenses().validate('GOOD'), { valid: true, status: 'active', license: license(), product })
  assert.deepEqual(last.body, { license_key: 'GOOD' })
  assert.equal((await licenses().validate('GOOD', 'other')).status, 'not_activated')
  assert.deepEqual(await licenses().validate('BAD', 'dev-1'), { valid: false, status: 'invalid' })
})

test('validate does not treat an HTML 404 as an invalid key', async () => {
  const e = await new LicenseClient({ baseUrl: base + '/html' }).validate('GOOD').catch(e => e)
  assert.ok(e instanceof SendclapError && !(e instanceof InvalidLicenseError))
  assert.equal(e.status, 404)
  assert.equal(e.message, 'HTTP 404')
})

test('deactivate', async () => {
  assert.deepEqual(await licenses().deactivate('GOOD', 'dev-1'), { license: license(0), product })
})

test('network failures and timeouts are NetworkError', async () => {
  const e = await new LicenseClient({ baseUrl: 'http://127.0.0.1:1' }).validate('GOOD').catch(e => e)
  assert.ok(e instanceof NetworkError)
  assert.equal(e.status, 0)
  const slow = createServer(() => {}).listen(0, '127.0.0.1')
  await new Promise(r => slow.once('listening', r))
  const t = await new LicenseClient({ baseUrl: `http://127.0.0.1:${slow.address().port}`, timeout: 50 }).validate('GOOD').catch(e => e)
  slow.closeAllConnections(); slow.close()
  assert.ok(t instanceof NetworkError)
})

test('createCheckout sends the key and body', async () => {
  const c = await api().createCheckout({ type: 'product', product_id: 1, email: 'a@b.co' })
  assert.equal(c.url, 'https://sendclap.com/checkout/0xabc')
  assert.equal(last.headers.authorization, 'Bearer sc_test')
  assert.deepEqual(last.body, { type: 'product', product_id: 1, email: 'a@b.co' })
})

test('getCheckout, listPayments with filters, getPayment', async () => {
  assert.equal((await api().getCheckout('0xabc')).status, 'pending')
  assert.equal((await api().listPayments({ status: 'paid', limit: 2 }))[0].id, 42)
  assert.deepEqual(last.query, { status: 'paid', limit: '2' })
  assert.equal((await api().getPayment(42)).id, 42)
  const e = await api().getPayment(7).catch(e => e)
  assert.ok(e instanceof SendclapError)
  assert.equal(e.status, 404)
  assert.equal(e.message, 'payment not found')
})

test('the list endpoints and me', async () => {
  const a = api()
  assert.equal((await a.me()).handle, 'demo')
  for (const [fn, path] of [[() => a.listMembers(), '/members'], [() => a.listLicenses('x@y.z'), '/licenses'], [() => a.listDisputes(), '/disputes'],
    [() => a.listProducts(), '/products'], [() => a.listMemberships(), '/memberships']]) {
    assert.deepEqual(await fn(), [])
    assert.equal(last.path, '/api/v1' + path)
  }
})

test('a wrong key is a 401', async () => {
  const e = await api('sc_wrong').me().catch(e => e)
  assert.equal(e.status, 401)
  assert.equal(e.message, 'invalid API key')
})

test('getCreator works without a key', async () => {
  assert.equal((await api('').getCreator('demo')).name, 'Ada')
  assert.equal(last.headers.authorization, undefined)
})

test('CommonJS build and instanceName', async () => {
  assert.equal(typeof cjs.LicenseClient, 'function')
  assert.ok((await instanceName()).length > 0)
})
