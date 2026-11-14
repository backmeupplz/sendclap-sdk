// Sendclap client for JavaScript and TypeScript: license checks for the apps you ship, and the creator REST API for your server.
// Zero dependencies; uses the global fetch (Node 18+, Bun, Deno, browsers, Electron).

export const VERSION = '0.2.0'
const DEFAULT_BASE_URL = 'https://sendclap.com'
const DEFAULT_TIMEOUT_MS = 15_000

export interface ClientOptions {
  /** Defaults to https://sendclap.com. */
  baseUrl?: string
  /** Request timeout in milliseconds. Defaults to 15000. */
  timeout?: number
}

// ---------- errors ----------

/**
 * Any failed request. `status` is the HTTP status (0 when no response arrived) and `code` the server's machine-readable
 * code, such as `invalid_api_key` or `not_found` ('' when the reply wasn't a Sendclap error, 'network_error' with no reply).
 */
export class SendclapError extends Error {
  constructor(message: string, readonly status: number, readonly code: string, readonly body?: unknown) {
    super(message)
    this.name = 'SendclapError'
  }
}
/** The license key doesn't exist (`license_not_found`). */
export class InvalidLicenseError extends SendclapError {
  constructor(message: string, body?: unknown) {
    super(message, 404, 'license_not_found', body)
    this.name = 'InvalidLicenseError'
  }
}
/** The key exists but was disabled after a refund or a dispute (`license_disabled`). */
export class DisabledLicenseError extends SendclapError {
  constructor(message: string, body?: unknown) {
    super(message, 403, 'license_disabled', body)
    this.name = 'DisabledLicenseError'
  }
}
/** Every activation of the key is in use; deactivate another instance first (`activation_limit`). */
export class ActivationLimitError extends SendclapError {
  constructor(message: string, readonly license: LicenseInfo, readonly product: ProductRef, body?: unknown) {
    super(message, 409, 'activation_limit', body)
    this.name = 'ActivationLimitError'
  }
}
/** Deactivate was called for an instance that isn't activated (`instance_not_found`). */
export class InstanceNotFoundError extends SendclapError {
  constructor(message: string, body?: unknown) {
    super(message, 404, 'instance_not_found', body)
    this.name = 'InstanceNotFoundError'
  }
}
/** No response: offline, DNS, TLS or timeout. Fall back to your cached validation. */
export class NetworkError extends SendclapError {
  constructor(message: string, readonly cause?: unknown) {
    super(message, 0, 'network_error')
    this.name = 'NetworkError'
  }
}

// ---------- license types ----------

export interface LicenseInfo { key: string; activations: number; max_activations: number }
export interface ProductRef { id?: number; name?: string }
export interface ActivateResult { instance_id: string; license: LicenseInfo; product: ProductRef }
export interface DeactivateResult { license: LicenseInfo; product: ProductRef }
export interface ValidateResult {
  valid: boolean
  /** `active`: valid. `not_activated`: the key exists but this instance isn't activated. `invalid`: unknown key. `disabled`: refunded or disputed. */
  status: 'active' | 'not_activated' | 'invalid' | 'disabled'
  license?: LicenseInfo
  product?: ProductRef
}

// ---------- API types ----------

export interface CheckoutParams {
  type: 'tip' | 'product' | 'membership'
  /** Tip amount in US dollars, 1 to 10000. */
  amount?: number
  product_id?: number
  tier_id?: number
  /** Required for memberships. */
  email?: string
  method?: 'card' | 'crypto'
  message?: string
}
export interface Checkout {
  id: string
  status: string
  type: string
  amount: number
  currency: string
  method: string
  email: string | null
  /** Where to send the customer to pay. */
  url: string
}
export interface Totals { payments: number; gross: number; fees: number; net: number }
export interface Stats {
  handle: string; name: string; url: string; currency: string
  last_30_days: Totals; all_time: Totals
  members: { active: number; monthly_recurring: number }
  open_disputes: number
}
/** `limit` is at most 500; `after` is the previous page's `next`. */
export interface PageParams { limit?: number; after?: number }
export interface PaymentFilter extends PageParams { status?: string; type?: string; email?: string }
export interface LicenseFilter extends PageParams { email?: string }
export interface Page<T> { data: T[]; has_more: boolean; next: number | null }
export interface Payment {
  id: number; type: string; method: string; status: string; amount: number; fee: number; currency: string
  email: string | null; message: string | null; reference: string | null; test: boolean; created_at: string
}
export interface PaymentDetail extends Payment {
  item: string
  purchase_ip: string | null
  purchase_device: string | null
  dispute: { id: string; status: string; reason: string | null; respond_by: string | null } | null
  activity: { at: string; event: string; detail: string | null; ip: string | null }[]
  evidence_pdf: string
}
export interface Member {
  email: string; tier: string; method: string; status: string; price: number; interval: string
  current_period_ends: string; joined_at: string
}
export interface IssuedLicense {
  key: string; product: string; email: string; activations: number; max_activations: number; disabled: boolean; issued_at: string
}
export interface Dispute {
  id: string; payment_id: number; email: string | null; amount: number; reason: string | null; status: string
  respond_by: string | null; opened_at: string
}
export interface Product {
  id: number; name: string; description: string; price: number; currency: string
  delivers_file: boolean; issues_license_key: boolean; page: string; x402: string | null
}
export interface Membership { id: number; name: string; description: string; price: number; currency: string; interval: string; x402: string | null }
export interface Creator {
  handle: string; name: string; bio: string; url: string; avatar: string | null
  links: { label: string; url: string }[]
  payment_methods: { card: boolean; crypto: boolean; x402: boolean }
  tip: { suggested: number; currency: string; page: string; x402: string | null }
  memberships: Membership[]
  products: Product[]
}

// ---------- transport ----------

type Query = Record<string, string | number | undefined>

async function request<T>(o: ClientOptions, method: 'GET' | 'POST', path: string, init: { body?: object; query?: Query; apiKey?: string } = {}): Promise<T> {
  const url = new URL(`${(o.baseUrl ?? DEFAULT_BASE_URL).replace(/\/+$/, '')}/api/v1${path}`)
  for (const [k, v] of Object.entries(init.query ?? {})) if (v !== undefined && v !== '') url.searchParams.set(k, String(v))
  const headers: Record<string, string> = { accept: 'application/json' }
  // browsers forbid setting User-Agent, so a web page identifies itself with x-sendclap-client instead
  if (typeof (globalThis as any).document === 'undefined') headers['user-agent'] = `sendclap-js/${VERSION}`
  else headers['x-sendclap-client'] = `sendclap-js/${VERSION}`
  if (init.body) headers['content-type'] = 'application/json'
  if (init.apiKey) headers.authorization = `Bearer ${init.apiKey}`
  let res: Response, text: string
  try {
    res = await fetch(url, { method, headers, body: init.body && JSON.stringify(init.body), signal: AbortSignal.timeout(o.timeout ?? DEFAULT_TIMEOUT_MS) })
    text = await res.text()
  } catch (e) {
    throw new NetworkError(e instanceof Error ? e.message : String(e), e)
  }
  let data: any
  try { data = JSON.parse(text) } catch { data = undefined }
  if (res.ok) {
    if (data === undefined) throw new SendclapError('invalid JSON response', res.status, text)
    return data as T
  }
  const message = typeof data?.error === 'string' ? data.error : `HTTP ${res.status}`
  const code = typeof data?.code === 'string' ? data.code : ''
  if (code === 'license_not_found') throw new InvalidLicenseError(message, data)
  if (code === 'license_disabled') throw new DisabledLicenseError(message, data)
  if (code === 'instance_not_found') throw new InstanceNotFoundError(message, data)
  if (code === 'activation_limit') throw new ActivationLimitError(message, data.license, data.product, data)
  throw new SendclapError(message, res.status, code, data ?? text)
}

// ---------- clients ----------

/** License checks from the app you ship. Needs no API key. */
export class LicenseClient {
  constructor(private options: ClientOptions = {}) {}

  private call<T>(action: string, licenseKey: string, instanceId?: string) {
    return request<T>(this.options, 'POST', `/licenses/${action}`, { body: { license_key: licenseKey, ...(instanceId ? { instance_id: instanceId } : {}) } })
  }

  /** Registers this device against the key. Throws InvalidLicenseError, DisabledLicenseError or ActivationLimitError. Activating the same instance twice counts once. The returned instance_id is the name you passed. */
  async activate(licenseKey: string, instanceName: string): Promise<ActivateResult> {
    const { instance_id, license, product } = await this.call<ActivateResult>('activate', licenseKey, instanceName)
    return { instance_id, license, product }
  }

  /** Checks the key (and, with an instance id, that this device is activated). Throws only when no definite answer came back. */
  async validate(licenseKey: string, instanceId?: string): Promise<ValidateResult> {
    try {
      const { valid, license, product } = await this.call<{ valid: boolean; license: LicenseInfo; product: ProductRef }>('validate', licenseKey, instanceId)
      return { valid, status: valid ? 'active' : 'not_activated', license, product }
    } catch (e) {
      if (e instanceof InvalidLicenseError) return { valid: false, status: 'invalid' }
      if (e instanceof DisabledLicenseError) return { valid: false, status: 'disabled' }
      throw e
    }
  }

  /** Releases a device, freeing one activation. Throws InstanceNotFoundError if it wasn't activated. */
  async deactivate(licenseKey: string, instanceId: string): Promise<DeactivateResult> {
    const { license, product } = await this.call<DeactivateResult>('deactivate', licenseKey, instanceId)
    return { license, product }
  }
}

async function* paginate<T>(fetchPage: (after?: number) => Promise<Page<T>>): AsyncGenerator<T> {
  let page = await fetchPage()
  for (;;) {
    yield* page.data
    if (!page.has_more || page.next === null) return
    page = await fetchPage(page.next)
  }
}

/** The creator REST API. Server side only: never ship an sc_ key inside an app or a web page. */
export class ApiClient {
  /** `apiKey` may be empty if you only call getCreator. */
  constructor(private apiKey: string, private options: ClientOptions = {}) {}

  private get<T>(path: string, query?: Query) {
    return request<T>(this.options, 'GET', path, { query, apiKey: this.apiKey })
  }

  createCheckout(params: CheckoutParams) {
    return request<Checkout>(this.options, 'POST', '/checkouts', { body: params, apiKey: this.apiKey })
  }
  getCheckout(id: string) { return this.get<Checkout>(`/checkouts/${encodeURIComponent(id)}`) }
  me() { return this.get<Stats>('/me') }
  listPayments(filter: PaymentFilter = {}) { return this.get<Page<Payment>>('/payments', { ...filter }) }
  getPayment(id: number) { return this.get<PaymentDetail>(`/payments/${encodeURIComponent(id)}`) }
  listMembers(page: PageParams = {}) { return this.get<Page<Member>>('/members', { ...page }) }
  listLicenses(filter: LicenseFilter = {}) { return this.get<Page<IssuedLicense>>('/licenses', { ...filter }) }
  listDisputes(page: PageParams = {}) { return this.get<Page<Dispute>>('/disputes', { ...page }) }
  /** The auto-paging versions: `for await (const p of api.allPayments({ status: 'paid' }))` follows `next` until the end. */
  allPayments(filter: PaymentFilter = {}) { return paginate(after => this.listPayments({ ...filter, after })) }
  allMembers(page: PageParams = {}) { return paginate(after => this.listMembers({ ...page, after })) }
  allLicenses(filter: LicenseFilter = {}) { return paginate(after => this.listLicenses({ ...filter, after })) }
  allDisputes(page: PageParams = {}) { return paginate(after => this.listDisputes({ ...page, after })) }
  listProducts() { return this.get<Product[]>('/products') }
  listMemberships() { return this.get<Membership[]>('/memberships') }
  /** Public: works without an API key. */
  getCreator(handle: string) { return this.get<Creator>(`/creators/${encodeURIComponent(handle)}`) }
}

/**
 * A name for this installation: the hostname in Node, Bun, Deno and Electron's main process, and a random id kept in
 * localStorage in browsers. It is sent to Sendclap and shown to the creator; machines sharing a hostname share an activation.
 */
export async function instanceName(): Promise<string> {
  const g = globalThis as any
  if (g.Deno?.hostname) return g.Deno.hostname()
  if (g.process?.versions?.node) {
    const id = 'node:os' // a variable keeps browser bundlers from trying to resolve it
    const os = g.process.getBuiltinModule?.(id) ?? await import(/* webpackIgnore: true */ /* @vite-ignore */ id)
    return os.hostname()
  }
  try { return (g.localStorage.sendclap_instance ??= g.crypto.randomUUID()) } catch { return g.crypto.randomUUID() }
}
