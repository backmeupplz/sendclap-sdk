using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using Sendclap;

namespace Sendclap.Tests;

/// <summary>Answers like the real server for the fixtures in SPEC.md, and records the last request.</summary>
sealed class MockServer : HttpMessageHandler
{
    public HttpRequestMessage? Last;
    public string? LastBody;
    public TimeSpan Delay = TimeSpan.Zero;

    const string Meta = "\"license\":{\"key\":\"GOOD\",\"activations\":1,\"max_activations\":3},\"product\":{\"id\":1,\"name\":\"Pro\"}";
    const string Lapsed = "\"license\":{\"key\":\"LAPSED\",\"activations\":1,\"max_activations\":3,\"expires_at\":\"2026-01-01T00:00:00.000Z\"},\"product\":{\"id\":1,\"name\":\"Pro\"}";
    const string CheckoutJson = "{\"id\":\"0xabc\",\"status\":\"pending\",\"type\":\"product\",\"amount\":29,\"currency\":\"usd\",\"method\":\"card\",\"email\":\"b@example.com\",\"url\":\"https://sendclap.com/checkout/0xabc\",\"paid_at\":null";

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage req, CancellationToken ct)
    {
        await Task.Delay(Delay, ct);
        Last = req;
        LastBody = req.Content == null ? null : await req.Content.ReadAsStringAsync(ct);
        var path = req.RequestUri!.AbsolutePath;
        var (status, body) = Route(req.Method.Method, path, req.RequestUri.Query, req.Headers.Authorization?.ToString());
        return new HttpResponseMessage((HttpStatusCode)status)
        {
            Content = new StringContent(body, Encoding.UTF8, body.StartsWith("<") ? "text/html" : "application/json"),
        };
    }

    static string PaymentJson(int id, string reference) =>
        $"{{\"id\":{id},\"type\":\"product\",\"method\":\"card\",\"status\":\"paid\",\"amount\":29,\"fee\":0.29,\"currency\":\"usd\",\"email\":\"b@example.com\",\"message\":null,\"reference\":\"{reference}\",\"test\":false,\"created_at\":\"2026-11-13T18:04:11.000Z\"}}";

    (int, string) Route(string method, string path, string query, string? auth)
    {
        if (path.StartsWith("/api/v1/licenses/"))
        {
            var b = JsonDocument.Parse(LastBody!).RootElement;
            var key = b.GetProperty("license_key").GetString();
            var instance = b.TryGetProperty("instance_id", out var i) ? i.GetString() : null;
            var action = path.Substring("/api/v1/licenses/".Length);
            if (action == "validate")
            {
                if (key == "LAPSED") return (200, $"{{\"valid\":false,\"status\":\"expired\",{Lapsed}}}");
                if (key == "REFUNDED") return (200, "{\"valid\":false,\"status\":\"disabled\"}");
                if (key != "GOOD" && key != "FULL") return (200, "{\"valid\":false,\"status\":\"not_found\"}");
                var ok = instance == null || instance == "dev-1";
                return (200, $"{{\"valid\":{(ok ? "true" : "false")},\"status\":\"{(ok ? "active" : "not_activated")}\",{Meta}}}");
            }
            if (key == "LAPSED") return (403, $"{{\"error\":\"this license key has expired\",\"code\":\"license_expired\",{Lapsed}}}");
            if (key == "REFUNDED") return (403, "{\"error\":\"this license key is disabled\",\"code\":\"license_disabled\"}");
            if (key != "GOOD" && key != "FULL") return (404, "{\"error\":\"license key not found\",\"code\":\"license_not_found\"}");
            if (instance == null) return (400, "{\"error\":\"instance_id is required\",\"code\":\"bad_request\"}");
            if (action == "deactivate" && instance != "dev-1")
                return (404, $"{{\"error\":\"that instance is not activated\",\"code\":\"instance_not_found\"}}");
            if (action == "activate" && key == "FULL")
                return (409, "{\"error\":\"activation limit reached\",\"code\":\"activation_limit\",\"license\":{\"key\":\"FULL\",\"activations\":3,\"max_activations\":3},\"product\":{\"id\":1,\"name\":\"Pro\"}}");
            if (action == "activate") return (200, $"{{\"activated\":true,\"instance_id\":\"{instance}\",{Meta}}}");
            return (200, $"{{\"deactivated\":true,{Meta.Replace("\"activations\":1", "\"activations\":0")}}}");
        }
        if (path == "/api/v1/creators/demo")
            return (200, "{\"handle\":\"demo\",\"name\":\"Ada Builds\",\"bio\":\"\",\"url\":\"https://sendclap.com/demo\",\"avatar\":null,\"links\":[{\"label\":\"GitHub\",\"url\":\"https://github.com/ada\"}],\"payment_methods\":{\"card\":true,\"crypto\":false,\"x402\":false},\"tip\":{\"suggested\":5,\"currency\":\"usd\",\"page\":\"https://sendclap.com/demo\",\"x402\":null},\"memberships\":[{\"id\":1,\"name\":\"Supporter\",\"description\":\"\",\"price\":5,\"currency\":\"usd\",\"interval\":\"month\",\"x402\":null}],\"products\":[]}");
        if (!path.StartsWith("/api/v1/")) return (404, "<!doctype html><h1>Not found</h1>");
        if (auth != "Bearer sc_test") return (401, "{\"error\":\"invalid API key\",\"code\":\"invalid_api_key\"}");
        return (method, path) switch
        {
            ("POST", "/api/v1/checkouts") => (201, CheckoutJson + "}"),
            ("GET", "/api/v1/checkouts/0xabc") => (200, CheckoutJson + "}"),
            ("GET", "/api/v1/checkouts/0xpaid") => (200, CheckoutJson.Replace("\"paid_at\":null", "\"paid_at\":\"2026-11-14T10:00:00.000Z\"") + "}"),
            ("GET", "/api/v1/me") => (200, "{\"handle\":\"demo\",\"name\":\"Ada\",\"url\":\"u\",\"currency\":\"usd\",\"last_30_days\":{\"payments\":2,\"gross\":58,\"fees\":0.58,\"net\":57.42},\"all_time\":{\"payments\":3,\"gross\":87,\"fees\":0.87,\"net\":86.13},\"members\":{\"active\":1,\"monthly_recurring\":5},\"open_disputes\":0}"),
            // two pages, the reference echoes the query so tests can check it
            ("GET", "/api/v1/payments") when !query.Contains("after=") => (200, $"{{\"data\":[{PaymentJson(42, query)},{PaymentJson(41, query)}],\"has_more\":true,\"next\":41}}"),
            ("GET", "/api/v1/payments") => (200, $"{{\"data\":[{PaymentJson(40, query)}],\"has_more\":false,\"next\":null}}"),
            ("GET", "/api/v1/payments/42") => (200, "{\"id\":42,\"type\":\"product\",\"method\":\"card\",\"status\":\"paid\",\"amount\":29,\"fee\":0.29,\"currency\":\"usd\",\"email\":null,\"message\":null,\"reference\":null,\"test\":true,\"created_at\":\"2026-11-13T18:04:11.000Z\",\"item\":\"Pro\",\"purchase_ip\":null,\"purchase_device\":null,\"dispute\":{\"id\":\"dp_1\",\"status\":\"open\",\"reason\":null,\"respond_by\":null},\"activity\":[{\"at\":\"2026-11-13T18:04:11.000Z\",\"event\":\"license_activate\",\"detail\":\"Pro\",\"ip\":null}],\"evidence_pdf\":\"https://sendclap.com/dashboard/evidence/42/pdf\"}"),
            ("GET", "/api/v1/payments/7") => (404, "{\"error\":\"payment not found\",\"code\":\"not_found\"}"),
            ("GET", "/api/v1/licenses") => (200, $"{{\"data\":[{{\"key\":\"GOOD\",\"product\":\"Pro\",\"email\":\"{query}\",\"activations\":1,\"max_activations\":3,\"disabled\":false,\"issued_at\":\"2026-11-13T18:04:11.000Z\"}}],\"has_more\":false,\"next\":null}}"),
            ("GET", "/api/v1/members") or ("GET", "/api/v1/disputes") => (200, "{\"data\":[],\"has_more\":false,\"next\":null}"),
            ("GET", "/api/v1/products") or ("GET", "/api/v1/memberships") => (200, "[]"),
            _ => (404, "<!doctype html><h1>Not found</h1>"),
        };
    }
}

public class LicenseClientTests
{
    readonly MockServer server = new();
    LicenseClient Client() => new("http://mock.test/", http: new HttpClient(server));

    [Fact]
    public async Task ActivateSendsJsonAndReturnsInstance()
    {
        var r = await Client().ActivateAsync("GOOD", "dev-1");
        Assert.Equal("dev-1", r.InstanceId);
        Assert.Equal(new LicenseInfo { Key = "GOOD", Activations = 1, MaxActivations = 3 }, r.License);
        Assert.Equal(1, r.Product.Id);
        Assert.Equal("http://mock.test/api/v1/licenses/activate", server.Last!.RequestUri!.ToString());
        Assert.Equal("{\"license_key\":\"GOOD\",\"instance_id\":\"dev-1\"}", server.LastBody);
        Assert.Equal("sendclap-dotnet/0.4.0", server.Last.Headers.UserAgent.ToString());
        Assert.Null(server.Last.Headers.Authorization);
    }

    [Fact]
    public async Task ActivateLimit()
    {
        var e = await Assert.ThrowsAsync<ActivationLimitException>(() => Client().ActivateAsync("FULL", "dev-9"));
        Assert.Equal((409, "activation_limit"), (e.Status, e.Code));
        Assert.Equal("activation limit reached", e.Message);
        Assert.Equal(3, e.License.MaxActivations);
        Assert.Equal("Pro", e.Product.Name);
    }

    [Fact]
    public async Task ActivateInvalidKey()
    {
        var e = await Assert.ThrowsAsync<InvalidLicenseException>(() => Client().ActivateAsync("BAD", "dev-1"));
        Assert.Equal((404, "license_not_found"), (e.Status, e.Code));
        Assert.Equal("license key not found", e.Message);
    }

    [Fact]
    public async Task ActivateDisabledKey()
    {
        var e = await Assert.ThrowsAsync<DisabledLicenseException>(() => Client().ActivateAsync("REFUNDED", "dev-1"));
        Assert.Equal((403, "license_disabled"), (e.Status, e.Code));
    }

    [Fact]
    public async Task ExpiredKey()
    {
        var expires = DateTimeOffset.Parse("2026-01-01T00:00:00Z");
        var v = await Client().ValidateAsync("LAPSED", "dev-1");
        Assert.False(v.Valid);
        Assert.Equal(LicenseStatus.Expired, v.Status);
        Assert.Equal(expires, v.License!.ExpiresAt);
        Assert.Equal("Pro", v.Product!.Name);

        var e = await Assert.ThrowsAsync<ExpiredLicenseException>(() => Client().ActivateAsync("LAPSED", "dev-1"));
        Assert.Equal((403, "license_expired"), (e.Status, e.Code));
        Assert.Equal(expires, e.License.ExpiresAt);
    }

    [Fact]
    public async Task ActivateWithoutInstanceIsBadRequest()
    {
        var e = await Assert.ThrowsAsync<SendclapException>(() => Client().ActivateAsync("GOOD", ""));
        Assert.Equal((400, "bad_request"), (e.Status, e.Code));
        Assert.Equal("instance_id is required", e.Message);
    }

    [Fact]
    public async Task ValidateStatuses()
    {
        var c = Client();
        var keyOnly = await c.ValidateAsync("GOOD");
        Assert.True(keyOnly.Valid);
        Assert.Equal(LicenseStatus.Active, keyOnly.Status);
        Assert.Equal("{\"license_key\":\"GOOD\"}", server.LastBody);

        Assert.Equal(LicenseStatus.Active, (await c.ValidateAsync("GOOD", "dev-1")).Status);

        var other = await c.ValidateAsync("GOOD", "dev-2");
        Assert.False(other.Valid);
        Assert.Equal(LicenseStatus.NotActivated, other.Status);
        Assert.Equal(3, other.License!.MaxActivations);

        var bad = await c.ValidateAsync("BAD", "dev-1");
        Assert.False(bad.Valid);
        Assert.Equal(LicenseStatus.NotFound, bad.Status);
        Assert.Null(bad.License);

        var refunded = await c.ValidateAsync("REFUNDED", "dev-1");
        Assert.False(refunded.Valid);
        Assert.Equal(LicenseStatus.Disabled, refunded.Status);
        Assert.Null(refunded.License);
    }

    [Fact]
    public async Task Deactivate()
    {
        var r = await Client().DeactivateAsync("GOOD", "dev-1");
        Assert.Equal(0, r.License.Activations);
        await Assert.ThrowsAsync<InvalidLicenseException>(() => Client().DeactivateAsync("BAD", "dev-1"));
        var e = await Assert.ThrowsAsync<InstanceNotFoundException>(() => Client().DeactivateAsync("GOOD", "nope"));
        Assert.Equal((404, "instance_not_found"), (e.Status, e.Code));
    }

    [Fact]
    public async Task HtmlNotFoundIsNotAnInvalidLicense()
    {
        var c = new LicenseClient("http://mock.test/wrong", http: new HttpClient(server));
        var e = await Assert.ThrowsAsync<SendclapException>(() => c.ValidateAsync("GOOD"));
        Assert.IsType<SendclapException>(e);
        Assert.Equal((404, ""), (e.Status, e.Code));
        Assert.Equal("HTTP 404", e.Message);
    }

    [Fact]
    public async Task ConnectionRefusedIsNetworkError()
    {
        var e = await Assert.ThrowsAsync<SendclapNetworkException>(() => new LicenseClient("http://127.0.0.1:1").ValidateAsync("GOOD"));
        Assert.Equal((0, "network_error"), (e.Status, e.Code));
    }

    [Fact]
    public async Task TimeoutIsNetworkError()
    {
        server.Delay = TimeSpan.FromSeconds(5);
        var c = new LicenseClient("http://mock.test", TimeSpan.FromMilliseconds(50), new HttpClient(server));
        await Assert.ThrowsAsync<SendclapNetworkException>(() => c.ValidateAsync("GOOD"));
    }

    [Fact]
    public async Task CallerCancellationIsNotANetworkError()
    {
        server.Delay = TimeSpan.FromSeconds(5);
        using var cts = new CancellationTokenSource(50);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Client().ValidateAsync("GOOD", null, cts.Token));
    }

    [Fact]
    public void InstanceNameIsMachineName() => Assert.Equal(Environment.MachineName, LicenseClient.InstanceName());
}

public class ApiClientTests
{
    readonly MockServer server = new();
    ApiClient Client(string? key = "sc_test") => new(key, "http://mock.test", http: new HttpClient(server));

    [Fact]
    public async Task CreateCheckout()
    {
        var c = await Client().CreateCheckoutAsync(new CheckoutParams { Type = "product", ProductId = 1, Email = "b@example.com" });
        Assert.Equal("0xabc", c.Id);
        Assert.Equal(29m, c.Amount);
        Assert.Equal("https://sendclap.com/checkout/0xabc", c.Url);
        Assert.Equal("{\"type\":\"product\",\"product_id\":1,\"email\":\"b@example.com\"}", server.LastBody);
        Assert.Equal("Bearer sc_test", server.Last!.Headers.Authorization!.ToString());
        Assert.Equal("sendclap-dotnet/0.4.0", server.Last.Headers.UserAgent.ToString());
    }

    [Fact]
    public async Task GetCheckoutHasUrl()
    {
        var c = await Client().GetCheckoutAsync("0xabc");
        Assert.Equal("pending", c.Status);
        Assert.Null(c.PaidAt);
        Assert.Equal("2026-11-14T10:00:00.000Z", (await Client().GetCheckoutAsync("0xpaid")).PaidAt);
        Assert.Equal("https://sendclap.com/checkout/0xabc", c.Url);
        Assert.Equal(HttpMethod.Get, server.Last!.Method);
    }

    [Fact]
    public async Task Me()
    {
        var s = await Client().MeAsync();
        Assert.Equal(2, s.Last30Days.Payments);
        Assert.Equal(86.13m, s.AllTime.Net);
        Assert.Equal(5m, s.Members.MonthlyRecurring);
    }

    [Fact]
    public async Task ListPaymentsReturnsAPage()
    {
        var p = await Client().ListPaymentsAsync(status: "paid", email: "a+b@example.com", limit: 2);
        Assert.Equal("?status=paid&email=a%2Bb%40example.com&limit=2", p.Data[0].Reference);
        Assert.Equal(new DateTimeOffset(2026, 11, 13, 18, 4, 11, TimeSpan.Zero), p.Data[0].CreatedAt);
        Assert.Equal(0.29m, p.Data[0].Fee);
        Assert.True(p.HasMore);
        Assert.Equal(41L, p.Next);
        var last = await Client().ListPaymentsAsync(after: p.Next);
        Assert.Equal("?after=41", last.Data[0].Reference);
        Assert.False(last.HasMore);
        Assert.Null(last.Next);
    }

    [Fact]
    public async Task AllPaymentsFollowsNext()
    {
        var ids = new List<long>();
        await foreach (var p in Client().AllPaymentsAsync(status: "paid", limit: 2)) ids.Add(p.Id);
        Assert.Equal(new long[] { 42, 41, 40 }, ids);
        Assert.Equal("?status=paid&limit=2&after=41", server.Last!.RequestUri!.Query);
    }

    [Fact]
    public async Task GetPayment()
    {
        var p = await Client().GetPaymentAsync(42);
        Assert.Equal("Pro", p.Item);
        Assert.Equal("dp_1", p.Dispute!.Id);
        Assert.Equal("license_activate", p.Activity[0].Event);
        var e = await Assert.ThrowsAsync<SendclapException>(() => Client().GetPaymentAsync(7));
        Assert.Equal((404, "not_found"), (e.Status, e.Code));
        Assert.Equal("payment not found", e.Message);
    }

    [Fact]
    public async Task ListEndpoints()
    {
        var c = Client();
        Assert.Equal("?email=a%40b.c", (await c.ListLicensesAsync("a@b.c")).Data[0].Email);
        Assert.Single(await Collect(c.AllLicensesAsync()));
        Assert.Empty((await c.ListMembersAsync()).Data);
        Assert.Empty((await c.ListDisputesAsync()).Data);
        Assert.Empty(await Collect(c.AllMembersAsync()));
        Assert.Empty(await Collect(c.AllDisputesAsync()));
        Assert.Empty(await c.ListProductsAsync());
        Assert.Empty(await c.ListMembershipsAsync());
    }

    static async Task<List<T>> Collect<T>(IAsyncEnumerable<T> items)
    {
        var list = new List<T>();
        await foreach (var i in items) list.Add(i);
        return list;
    }

    [Fact]
    public async Task WrongKeyIs401()
    {
        var e = await Assert.ThrowsAsync<SendclapException>(() => Client("sc_wrong").MeAsync());
        Assert.Equal((401, "invalid_api_key"), (e.Status, e.Code));
        Assert.Equal("invalid API key", e.Message);
    }

    [Fact]
    public async Task GetCreatorWithoutKey()
    {
        var c = await Client(null).GetCreatorAsync("demo");
        Assert.Null(server.Last!.Headers.Authorization);
        Assert.Equal("Ada Builds", c.Name);
        Assert.True(c.PaymentMethods.Card);
        Assert.Equal("month", c.Memberships[0].Interval);
        Assert.Equal(5m, c.Tip.Suggested);
    }
}
