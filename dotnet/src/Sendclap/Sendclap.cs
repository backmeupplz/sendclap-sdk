using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;

namespace Sendclap
{
    /// <summary>
    /// Any error from Sendclap. <see cref="Status"/> is the HTTP status (0 when no response arrived) and <see cref="Code"/> the
    /// server's machine-readable code such as <c>invalid_api_key</c> or <c>not_found</c> (empty when the reply wasn't a Sendclap
    /// error, <c>network_error</c> with no reply).
    /// </summary>
    public class SendclapException : Exception
    {
        public int Status { get; }
        public string Code { get; }
        public SendclapException(int status, string code, string message, Exception? inner = null) : base(message, inner)
        {
            Status = status;
            Code = code;
        }
    }

    /// <summary>The license key does not exist (<c>license_not_found</c>).</summary>
    public sealed class InvalidLicenseException : SendclapException
    {
        public InvalidLicenseException(string message) : base(404, "license_not_found", message) { }
    }

    /// <summary>The key exists but was disabled after a refund or dispute (<c>license_disabled</c>).</summary>
    public sealed class DisabledLicenseException : SendclapException
    {
        public DisabledLicenseException(string message) : base(403, "license_disabled", message) { }
    }

    /// <summary>Deactivate was called for an instance that isn't activated (<c>instance_not_found</c>).</summary>
    public sealed class InstanceNotFoundException : SendclapException
    {
        public InstanceNotFoundException(string message) : base(404, "instance_not_found", message) { }
    }

    /// <summary>The key is already activated on as many instances as it allows (<c>activation_limit</c>).</summary>
    public sealed class ActivationLimitException : SendclapException
    {
        public LicenseInfo License { get; }
        public ProductRef Product { get; }
        public ActivationLimitException(string message, LicenseInfo license, ProductRef product) : base(409, "activation_limit", message)
        {
            License = license;
            Product = product;
        }
    }

    /// <summary>No HTTP response: DNS, connection, TLS failure or timeout. Status is 0.</summary>
    public sealed class SendclapNetworkException : SendclapException
    {
        public SendclapNetworkException(string message, Exception? inner = null) : base(0, "network_error", message, inner) { }
    }

    internal sealed class Transport
    {
        internal const string Version = "0.3.0";
        internal const string DefaultBaseUrl = "https://sendclap.com";
        // One shared client avoids socket exhaustion; the timeout is applied per request instead.
        static readonly HttpClient Shared = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
        static readonly JsonSerializerOptions Json = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            Converters = { new JsonStringEnumConverter(JsonNamingPolicy.SnakeCaseLower) }, // "not_activated" <-> LicenseStatus.NotActivated
        };

        readonly HttpClient http;
        readonly string baseUrl;
        readonly TimeSpan timeout;
        readonly string? apiKey;

        internal Transport(string? baseUrl, TimeSpan? timeout, HttpClient? http, string? apiKey)
        {
            this.baseUrl = (baseUrl ?? DefaultBaseUrl).TrimEnd('/');
            this.timeout = timeout ?? TimeSpan.FromSeconds(15);
            this.http = http ?? Shared;
            this.apiKey = apiKey;
        }

        internal async Task<T> SendAsync<T>(HttpMethod method, string path, object? body, CancellationToken ct)
        {
            using var req = new HttpRequestMessage(method, baseUrl + "/api/v1" + path);
            req.Headers.TryAddWithoutValidation("User-Agent", "sendclap-dotnet/" + Version);
            req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
            if (!string.IsNullOrEmpty(apiKey)) req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
            if (body != null) req.Content = new StringContent(JsonSerializer.Serialize(body, Json), Encoding.UTF8, "application/json");

            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(timeout);
            int status;
            string text;
            try
            {
                using var res = await http.SendAsync(req, cts.Token).ConfigureAwait(false);
                status = (int)res.StatusCode;
                text = await res.Content.ReadAsStringAsync().ConfigureAwait(false);
            }
            catch (OperationCanceledException e) when (!ct.IsCancellationRequested)
            {
                throw new SendclapNetworkException("request timed out", e);
            }
            catch (HttpRequestException e)
            {
                throw new SendclapNetworkException(e.Message, e);
            }

            if (status < 200 || status >= 300) throw Error(status, text);
            try
            {
                return JsonSerializer.Deserialize<T>(text, Json) ?? throw new JsonException();
            }
            catch (JsonException)
            {
                throw new SendclapException(status, "", "invalid JSON response");
            }
        }

        static SendclapException Error(int status, string text)
        {
            JsonElement obj = default;
            try
            {
                using var doc = JsonDocument.Parse(text);
                obj = doc.RootElement.Clone();
            }
            catch (JsonException) { } // HTML error pages from proxies or unknown routes
            bool isObject = obj.ValueKind == JsonValueKind.Object;
            string message = isObject && obj.TryGetProperty("error", out var e) && e.ValueKind == JsonValueKind.String ? e.GetString()! : "HTTP " + status;
            string code = isObject && obj.TryGetProperty("code", out var c) && c.ValueKind == JsonValueKind.String ? c.GetString()! : "";

            switch (code)
            {
                case "license_not_found": return new InvalidLicenseException(message);
                case "license_disabled": return new DisabledLicenseException(message);
                case "instance_not_found": return new InstanceNotFoundException(message);
                case "activation_limit":
                    var r = obj.Deserialize<DeactivateResult>(Json)!;
                    return new ActivationLimitException(message, r.License, r.Product);
                default: return new SendclapException(status, code, message);
            }
        }

        internal static string Query(params (string Name, string? Value)[] pairs)
        {
            var set = pairs.Where(p => !string.IsNullOrEmpty(p.Value)).Select(p => p.Name + "=" + Uri.EscapeDataString(p.Value!)).ToList();
            return set.Count == 0 ? "" : "?" + string.Join("&", set);
        }
    }

    /// <summary>
    /// License keys from the app you ship. Needs no API key: activate a device, validate on start, deactivate to free a seat.
    /// </summary>
    public sealed class LicenseClient
    {
        readonly Transport t;

        /// <param name="baseUrl">Defaults to https://sendclap.com.</param>
        /// <param name="timeout">Per request, defaults to 15 seconds.</param>
        /// <param name="http">An HttpClient to share; a static one is used otherwise.</param>
        public LicenseClient(string? baseUrl = null, TimeSpan? timeout = null, HttpClient? http = null) =>
            t = new Transport(baseUrl, timeout, http, null);

        /// <summary>
        /// A per-machine instance name: the machine name. It is sent to Sendclap and shown to the creator, and two machines
        /// with the same name share one activation, so pass your own stable id (such as a GUID saved on first run) if that matters.
        /// </summary>
        public static string InstanceName() => Environment.MachineName;

        /// <summary>Registers this instance against the key. Activating the same instance again counts once.</summary>
        /// <exception cref="InvalidLicenseException"/>
        /// <exception cref="DisabledLicenseException"/>
        /// <exception cref="ActivationLimitException"/>
        /// <exception cref="SendclapNetworkException"/>
        public Task<ActivateResult> ActivateAsync(string licenseKey, string instanceName, CancellationToken ct = default) =>
            t.SendAsync<ActivateResult>(HttpMethod.Post, "/licenses/activate", Body(licenseKey, instanceName), ct);

        /// <summary>
        /// Checks the key, and with <paramref name="instanceId"/> that this instance is activated. An unknown or disabled key
        /// returns <see cref="LicenseStatus.NotFound"/> or <see cref="LicenseStatus.Disabled"/> instead of throwing, so an exception means "could not check" (offline).
        /// </summary>
        /// <exception cref="SendclapNetworkException"/>
        public Task<ValidateResult> ValidateAsync(string licenseKey, string? instanceId = null, CancellationToken ct = default) =>
            t.SendAsync<ValidateResult>(HttpMethod.Post, "/licenses/validate", Body(licenseKey, instanceId), ct);

        /// <summary>Releases an instance, freeing one activation.</summary>
        /// <exception cref="InvalidLicenseException"/>
        /// <exception cref="DisabledLicenseException"/>
        /// <exception cref="InstanceNotFoundException">The instance wasn't activated.</exception>
        /// <exception cref="SendclapNetworkException"/>
        public Task<DeactivateResult> DeactivateAsync(string licenseKey, string instanceId, CancellationToken ct = default) =>
            t.SendAsync<DeactivateResult>(HttpMethod.Post, "/licenses/deactivate", Body(licenseKey, instanceId), ct);

        static Dictionary<string, string> Body(string key, string? instance)
        {
            var b = new Dictionary<string, string> { ["license_key"] = key };
            if (!string.IsNullOrEmpty(instance)) b["instance_id"] = instance!;
            return b;
        }
    }

    /// <summary>
    /// The creator REST API, authenticated with an <c>sc_…</c> key. Server side only: never ship the key inside an app.
    /// </summary>
    public sealed class ApiClient
    {
        readonly Transport t;

        /// <param name="apiKey">Your <c>sc_…</c> key. May be null for <see cref="GetCreatorAsync"/>, which is public.</param>
        public ApiClient(string? apiKey, string? baseUrl = null, TimeSpan? timeout = null, HttpClient? http = null) =>
            t = new Transport(baseUrl, timeout, http, apiKey);

        public Task<Checkout> CreateCheckoutAsync(CheckoutParams checkout, CancellationToken ct = default) =>
            t.SendAsync<Checkout>(HttpMethod.Post, "/checkouts", checkout, ct);

        public Task<Checkout> GetCheckoutAsync(string id, CancellationToken ct = default) =>
            Get<Checkout>("/checkouts/" + Uri.EscapeDataString(id), ct);

        public Task<Stats> MeAsync(CancellationToken ct = default) => Get<Stats>("/me", ct);

        // Lists are pages, newest first. limit is 1 to 500 (the server defaults to 50); after is the
        // previous page's Next. The All...Async methods follow Next: await foreach (var p in api.AllPaymentsAsync(status: "paid")).

        public Task<Page<Payment>> ListPaymentsAsync(string? status = null, string? type = null, string? email = null, int? limit = null, long? after = null, CancellationToken ct = default) =>
            Get<Page<Payment>>("/payments" + Transport.Query(("status", status), ("type", type), ("email", email), ("limit", limit?.ToString()), ("after", after?.ToString())), ct);

        public IAsyncEnumerable<Payment> AllPaymentsAsync(string? status = null, string? type = null, string? email = null, int? limit = null, CancellationToken ct = default) =>
            Paginate(after => ListPaymentsAsync(status, type, email, limit, after, ct), ct);

        public Task<PaymentDetail> GetPaymentAsync(long id, CancellationToken ct = default) => Get<PaymentDetail>("/payments/" + id, ct);

        public Task<Page<Member>> ListMembersAsync(int? limit = null, long? after = null, CancellationToken ct = default) =>
            Get<Page<Member>>("/members" + Transport.Query(("limit", limit?.ToString()), ("after", after?.ToString())), ct);

        public IAsyncEnumerable<Member> AllMembersAsync(int? limit = null, CancellationToken ct = default) =>
            Paginate(after => ListMembersAsync(limit, after, ct), ct);

        public Task<Page<IssuedLicense>> ListLicensesAsync(string? email = null, int? limit = null, long? after = null, CancellationToken ct = default) =>
            Get<Page<IssuedLicense>>("/licenses" + Transport.Query(("email", email), ("limit", limit?.ToString()), ("after", after?.ToString())), ct);

        public IAsyncEnumerable<IssuedLicense> AllLicensesAsync(string? email = null, int? limit = null, CancellationToken ct = default) =>
            Paginate(after => ListLicensesAsync(email, limit, after, ct), ct);

        public Task<Page<Dispute>> ListDisputesAsync(int? limit = null, long? after = null, CancellationToken ct = default) =>
            Get<Page<Dispute>>("/disputes" + Transport.Query(("limit", limit?.ToString()), ("after", after?.ToString())), ct);

        public IAsyncEnumerable<Dispute> AllDisputesAsync(int? limit = null, CancellationToken ct = default) =>
            Paginate(after => ListDisputesAsync(limit, after, ct), ct);

        public Task<IReadOnlyList<Product>> ListProductsAsync(CancellationToken ct = default) => Get<IReadOnlyList<Product>>("/products", ct);

        public Task<IReadOnlyList<Membership>> ListMembershipsAsync(CancellationToken ct = default) => Get<IReadOnlyList<Membership>>("/memberships", ct);

        /// <summary>Public: works without an API key.</summary>
        public Task<Creator> GetCreatorAsync(string handle, CancellationToken ct = default) =>
            Get<Creator>("/creators/" + Uri.EscapeDataString(handle), ct);

        static async IAsyncEnumerable<T> Paginate<T>(Func<long?, Task<Page<T>>> fetch, [EnumeratorCancellation] CancellationToken ct = default)
        {
            Page<T> page = await fetch(null).ConfigureAwait(false);
            while (true)
            {
                foreach (var item in page.Data) yield return item;
                if (!page.HasMore || page.Next is not long next) yield break;
                ct.ThrowIfCancellationRequested();
                page = await fetch(next).ConfigureAwait(false);
            }
        }

        Task<T> Get<T>(string path, CancellationToken ct) => t.SendAsync<T>(HttpMethod.Get, path, null, ct);
    }
}
