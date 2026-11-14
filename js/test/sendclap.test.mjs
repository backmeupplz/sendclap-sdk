import { test, before, after } from 'node:test'
import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { LicenseClient, ApiClient, SendclapError, InvalidLicenseError, DisabledLicenseError, InstanceNotFoundError, ActivationLimitError, NetworkError, instanceName } from '../dist/esm/index.js'
import * as cjs from '../dist/cjs/index.js'

const license = (activations = 1) => ({ key: 'GOOD', activations, max_activations: 3 })
const product = { id: 1, name: 'Pro' }
const checkout = { id: '0xabc', status: 'pending', type: 'product', amount: 29, currency: 'usd', method: 'card', email: 'a@b.co', url: 'https://sendclap.com/checkout/0xabc', paid_at: null }
const paidCheckout = { ...checkout, status: 'paid', paid_at: '2026-11-14T10:00:00.000Z' }
const payments = [{ id: 3, status: 'paid' }, { id: 2, status: 'paid' }, { id: 1, status: 'paid' }]
let last // the last request the mock saw

// A small stand-in for the Sendclap server, answering the way server.ts does.
const server = createServer(async (req, res) => {
  let raw = ''
  for await (const chunk of req) raw += chunk
  const url = new URL(req.url, 'http://x'), body = raw ? JSON.parse(raw) : null
  last = { method: req.method, path: url.pathname, query: Object.fromEntries(url.searchParams), headers: req.headers, body }
  const send = (status, data) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(data)) }
  const fail = (status, code, error, extra = {}) => send(status, { ...extra, error, code })
  const p = url.pathname
  if (p === '/html/api/v1/licenses/validate') { res.writeHead(404, { 'content-type': 'text/html' }); return res.end('<h1>Not found</h1>') }
  const lic = p.match(/^\/api\/v1\/licenses\/(\w+)$/)
  if (lic) {
    const action = lic[1], { license_key: key, instance_id: inst } = body
    if (action === 'validate') {
      if (key === 'REFUNDED') return send(200, { valid: false, status: 'disabled' })
      if (key !== 'GOOD' && key !== 'FULL') return send(200, { valid: false, status: 'not_found' })
      const ok = !inst || inst === 'dev-1'
      return send(200, { valid: ok, status: ok ? 'active' : 'not_activated', license: license(), product })
    }
    if (key === 'REFUNDED') return fail(403, 'license_disabled', 'this license key is disabled')
    if (key !== 'GOOD' && key !== 'FULL') return fail(404, 'license_not_found', 'license key not found')
    if (!inst) return fail(400, 'bad_request', 'instance_id is required')
    if (action === 'activate' && key === 'FULL') return fail(409, 'activation_limit', 'activation limit reached', { license: license(3), product })
    if (action === 'activate') return send(200, { activated: true, instance_id: inst, license: license(), product })
    if (inst !== 'dev-1') return fail(404, 'instance_not_found', 'that instance is not activated')
    return send(200, { deactivated: true, license: license(0), product })
  }
  if (p === '/api/v1/creators/demo') return send(200, { handle: 'demo', name: 'Ada' })
  if (req.headers.authorization !== 'Bearer sc_test') return fail(401, 'invalid_api_key', 'invalid API key')
  if (p === '/api/v1/checkouts' && req.method === 'POST') return send(201, checkout)
  if (p === '/api/v1/checkouts/0xabc') return send(200, checkout)
  if (p === '/api/v1/checkouts/0xpaid') return send(200, paidCheckout)
  if (p === '/api/v1/payments') { // two per page, newest first, cursor = the last id on the page
    const after = Number(url.searchParams.get('after')) || Infinity, rows = payments.filter(r => r.id < after)
    const data = rows.slice(0, 2), more = rows.length > 2
    return send(200, { data, has_more: more, next: more ? data.at(-1).id : null })
  }
  if (p === '/api/v1/payments/42') return send(200, { id: 42, activity: [] })
  if (p === '/api/v1/payments/7') return fail(404, 'not_found', 'payment not found')
  if (p === '/api/v1/boom') return fail(500, 'internal_error', 'something went wrong')
  for (const name of ['members', 'licenses', 'disputes']) if (p === `/api/v1/${name}`) return send(200, { data: [{ id: name }], has_more: false, next: null })
  for (const name of ['me', 'products', 'memberships']) if (p === `/api/v1/${name}`) return send(200, name === 'me' ? { handle: 'demo' } : [])
  fail(404, 'not_found', 'no such endpoint')
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
  assert.equal(last.headers['user-agent'], 'sendclap-js/0.3.0')
  assert.equal(last.headers['x-sendclap-client'], undefined)
  assert.equal(last.headers['content-type'], 'application/json')
  assert.equal(last.headers.authorization, undefined)
})

test('in a browser the client sends x-sendclap-client instead of User-Agent', async () => {
  globalThis.document = {}
  try {
    await licenses().validate('GOOD')
  } finally { delete globalThis.document }
  assert.equal(last.headers['x-sendclap-client'], 'sendclap-js/0.3.0')
  assert.ok(!/sendclap/.test(last.headers['user-agent'] ?? ''))
})

test('activate maps activation_limit to ActivationLimitError with the license', async () => {
  const e = await licenses().activate('FULL', 'dev-9').catch(e => e)
  assert.ok(e instanceof ActivationLimitError && e instanceof SendclapError)
  assert.equal(e.status, 409)
  assert.equal(e.code, 'activation_limit')
  assert.equal(e.message, 'activation limit reached')
  assert.equal(e.license.activations, 3)
})

test('activate maps license_not_found to InvalidLicenseError', async () => {
  const e = await licenses().activate('BAD', 'dev-1').catch(e => e)
  assert.ok(e instanceof InvalidLicenseError)
  assert.equal(e.code, 'license_not_found')
  assert.equal(e.message, 'license key not found')
})

test('activate on a refunded key is a DisabledLicenseError', async () => {
  const e = await licenses().activate('REFUNDED', 'dev-1').catch(e => e)
  assert.ok(e instanceof DisabledLicenseError && !(e instanceof InvalidLicenseError))
  assert.equal(e.status, 403)
  assert.equal(e.code, 'license_disabled')
})

test('activate without an instance is a bad_request', async () => {
  const e = await licenses().activate('GOOD', '').catch(e => e)
  assert.ok(e instanceof SendclapError && !(e instanceof InvalidLicenseError))
  assert.equal(e.status, 400)
  assert.equal(e.code, 'bad_request')
  assert.equal(e.message, 'instance_id is required')
})

test('validate: active, not activated, not found and disabled', async () => {
  assert.deepEqual(await licenses().validate('GOOD', 'dev-1'), { valid: true, status: 'active', license: license(), product })
  assert.deepEqual(await licenses().validate('GOOD'), { valid: true, status: 'active', license: license(), product })
  assert.deepEqual(last.body, { license_key: 'GOOD' })
  assert.equal((await licenses().validate('GOOD', 'other')).status, 'not_activated')
  assert.deepEqual(await licenses().validate('BAD', 'dev-1'), { valid: false, status: 'not_found' })
  assert.deepEqual(await licenses().validate('REFUNDED', 'dev-1'), { valid: false, status: 'disabled' })
})

test('validate does not treat an HTML 404 as an invalid key', async () => {
  const e = await new LicenseClient({ baseUrl: base + '/html' }).validate('GOOD').catch(e => e)
  assert.ok(e instanceof SendclapError && !(e instanceof InvalidLicenseError))
  assert.equal(e.status, 404)
  assert.equal(e.code, '')
  assert.equal(e.message, 'HTTP 404')
})

test('deactivate, and instance_not_found', async () => {
  assert.deepEqual(await licenses().deactivate('GOOD', 'dev-1'), { license: license(0), product })
  const e = await licenses().deactivate('GOOD', 'nope').catch(e => e)
  assert.ok(e instanceof InstanceNotFoundError)
  assert.equal(e.status, 404)
  assert.equal(e.code, 'instance_not_found')
})

test('network failures and timeouts are NetworkError', async () => {
  const e = await new LicenseClient({ baseUrl: 'http://127.0.0.1:1' }).validate('GOOD').catch(e => e)
  assert.ok(e instanceof NetworkError)
  assert.equal(e.status, 0)
  assert.equal(e.code, 'network_error')
  const slow = createServer(() => {}).listen(0, '127.0.0.1')
  await new Promise(r => slow.once('listening', r))
  const t = await new LicenseClient({ baseUrl: `http://127.0.0.1:${slow.address().port}`, timeout: 50 }).validate('GOOD').catch(e => e)
  slow.closeAllConnections(); slow.close()
  assert.ok(t instanceof NetworkError)
})

test('createCheckout sends the key and body; getCheckout has the url', async () => {
  const c = await api().createCheckout({ type: 'product', product_id: 1, email: 'a@b.co' })
  assert.equal(c.url, 'https://sendclap.com/checkout/0xabc')
  assert.equal(last.headers.authorization, 'Bearer sc_test')
  assert.deepEqual(last.body, { type: 'product', product_id: 1, email: 'a@b.co' })
  const g = await api().getCheckout('0xabc')
  assert.equal(g.status, 'pending')
  assert.equal(g.url, 'https://sendclap.com/checkout/0xabc')
  assert.equal(g.paid_at, null)
  assert.equal((await api().getCheckout('0xpaid')).paid_at, '2026-11-14T10:00:00.000Z')
})

test('listPayments returns a Page and getPayment errors carry the code', async () => {
  const page = await api().listPayments({ status: 'paid', limit: 2 })
  assert.deepEqual(page, { data: payments.slice(0, 2), has_more: true, next: 2 })
  assert.deepEqual(last.query, { status: 'paid', limit: '2' })
  const second = await api().listPayments({ after: page.next })
  assert.deepEqual(second, { data: [payments[2]], has_more: false, next: null })
  assert.equal(last.query.after, '2')
  assert.equal((await api().getPayment(42)).id, 42)
  const e = await api().getPayment(7).catch(e => e)
  assert.ok(e instanceof SendclapError)
  assert.equal(e.status, 404)
  assert.equal(e.code, 'not_found')
  assert.equal(e.message, 'payment not found')
})

test('allPayments follows next across pages', async () => {
  const ids = []
  for await (const p of api().allPayments({ status: 'paid' })) ids.push(p.id)
  assert.deepEqual(ids, [3, 2, 1])
  assert.equal(last.query.after, '2')
})

test('the other lists, auto-paging and me', async () => {
  const a = api()
  assert.equal((await a.me()).handle, 'demo')
  for (const [fn, all, path] of [[() => a.listMembers(), () => a.allMembers(), '/members'], [() => a.listLicenses({ email: 'x@y.z' }), () => a.allLicenses(), '/licenses'],
    [() => a.listDisputes(), () => a.allDisputes(), '/disputes']]) {
    assert.equal((await fn()).data.length, 1)
    assert.equal(last.path, '/api/v1' + path)
    const items = []
    for await (const x of all()) items.push(x)
    assert.equal(items.length, 1)
  }
  assert.deepEqual(await a.listProducts(), [])
  assert.deepEqual(await a.listMemberships(), [])
})

test('errors are mapped by code', async () => {
  const e = await api('sc_wrong').me().catch(e => e)
  assert.equal(e.status, 401)
  assert.equal(e.code, 'invalid_api_key')
  assert.equal(e.message, 'invalid API key')
  const s = await api().get('/boom').catch(e => e)
  assert.equal(s.code, 'internal_error')
})

test('getCreator works without a key', async () => {
  assert.equal((await api('').getCreator('demo')).name, 'Ada')
  assert.equal(last.headers.authorization, undefined)
})

test('CommonJS build and instanceName', async () => {
  assert.equal(typeof cjs.LicenseClient, 'function')
  assert.ok((await instanceName()).length > 0)
})
