using System;
using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace Sendclap
{
    // ---- License API ----

    /// <summary>Activation counts for a license key.</summary>
    public sealed record LicenseInfo
    {
        public string Key { get; init; } = "";
        public int Activations { get; init; }
        public int MaxActivations { get; init; }
    }

    /// <summary>The product a license key belongs to. Both fields are null if the product was deleted.</summary>
    public sealed record ProductRef
    {
        public long? Id { get; init; }
        public string? Name { get; init; }
    }

    public sealed record ActivateResult
    {
        /// <summary>The instance id, which is the instance name you passed (Sendclap keeps up to 200 characters).</summary>
        public string InstanceId { get; init; } = "";
        public LicenseInfo License { get; init; } = new();
        public ProductRef Product { get; init; } = new();
    }

    public enum LicenseStatus
    {
        /// <summary>The key is valid (and, if an instance was given, that instance is activated).</summary>
        Active,
        /// <summary>The key exists but this instance is not activated on it.</summary>
        NotActivated,
        /// <summary>The key does not exist.</summary>
        Invalid,
        /// <summary>The key exists but was disabled after a refund or dispute.</summary>
        Disabled,
    }

    public sealed record ValidateResult
    {
        public bool Valid { get; init; }
        [JsonIgnore] public LicenseStatus Status { get; init; }
        /// <summary>Null when <see cref="Status"/> is <see cref="LicenseStatus.Invalid"/> or <see cref="LicenseStatus.Disabled"/>.</summary>
        public LicenseInfo? License { get; init; }
        /// <summary>Null when <see cref="Status"/> is <see cref="LicenseStatus.Invalid"/> or <see cref="LicenseStatus.Disabled"/>.</summary>
        public ProductRef? Product { get; init; }
    }

    public sealed record DeactivateResult
    {
        public LicenseInfo License { get; init; } = new();
        public ProductRef Product { get; init; } = new();
    }

    // ---- Creator API ----

    /// <summary>Body of <c>POST /api/v1/checkouts</c>. Null fields are not sent.</summary>
    public sealed record CheckoutParams
    {
        /// <summary><c>tip</c>, <c>product</c> or <c>membership</c>.</summary>
        public string Type { get; init; } = "";
        /// <summary>Tip amount in US dollars (1 to 10000). Required for a tip.</summary>
        public decimal? Amount { get; init; }
        public long? ProductId { get; init; }
        public long? TierId { get; init; }
        /// <summary>Required for a membership.</summary>
        public string? Email { get; init; }
        /// <summary><c>card</c> (default) or <c>crypto</c>.</summary>
        public string? Method { get; init; }
        public string? Message { get; init; }
    }

    public sealed record Checkout
    {
        public string Id { get; init; } = "";
        /// <summary><c>pending</c> or <c>paid</c>.</summary>
        public string Status { get; init; } = "";
        public string Type { get; init; } = "";
        public decimal Amount { get; init; }
        public string Currency { get; init; } = "";
        public string Method { get; init; } = "";
        public string? Email { get; init; }
        /// <summary>Where to send the customer to pay.</summary>
        public string Url { get; init; } = "";
    }

    /// <summary>One page of a list, newest first. When <see cref="HasMore"/> is true, pass <see cref="Next"/> as <c>after</c> for the following page.</summary>
    public sealed record Page<T>
    {
        public IReadOnlyList<T> Data { get; init; } = Array.Empty<T>();
        public bool HasMore { get; init; }
        public long? Next { get; init; }
    }

    public sealed record Totals
    {
        public int Payments { get; init; }
        public decimal Gross { get; init; }
        public decimal Fees { get; init; }
        public decimal Net { get; init; }
    }

    public sealed record MemberStats
    {
        public int Active { get; init; }
        public decimal MonthlyRecurring { get; init; }
    }

    public sealed record Stats
    {
        public string Handle { get; init; } = "";
        public string Name { get; init; } = "";
        public string Url { get; init; } = "";
        public string Currency { get; init; } = "";
        [JsonPropertyName("last_30_days")] public Totals Last30Days { get; init; } = new();
        public Totals AllTime { get; init; } = new();
        public MemberStats Members { get; init; } = new();
        public int OpenDisputes { get; init; }
    }

    public record Payment
    {
        public long Id { get; init; }
        public string Type { get; init; } = "";
        public string Method { get; init; } = "";
        public string Status { get; init; } = "";
        public decimal Amount { get; init; }
        public decimal Fee { get; init; }
        public string Currency { get; init; } = "";
        public string? Email { get; init; }
        public string? Message { get; init; }
        public string? Reference { get; init; }
        public bool Test { get; init; }
        public DateTimeOffset CreatedAt { get; init; }
    }

    public sealed record PaymentDetail : Payment
    {
        public string Item { get; init; } = "";
        public string? PurchaseIp { get; init; }
        public string? PurchaseDevice { get; init; }
        public PaymentDispute? Dispute { get; init; }
        public IReadOnlyList<ActivityEvent> Activity { get; init; } = Array.Empty<ActivityEvent>();
        public string EvidencePdf { get; init; } = "";
    }

    public sealed record PaymentDispute
    {
        public string Id { get; init; } = "";
        public string Status { get; init; } = "";
        public string? Reason { get; init; }
        public DateTimeOffset? RespondBy { get; init; }
    }

    public sealed record ActivityEvent
    {
        public DateTimeOffset At { get; init; }
        public string Event { get; init; } = "";
        public string? Detail { get; init; }
        public string? Ip { get; init; }
    }

    public sealed record Member
    {
        public string Email { get; init; } = "";
        public string Tier { get; init; } = "";
        public string Method { get; init; } = "";
        public string Status { get; init; } = "";
        public decimal Price { get; init; }
        public string Interval { get; init; } = "";
        public DateTimeOffset CurrentPeriodEnds { get; init; }
        public DateTimeOffset JoinedAt { get; init; }
    }

    public sealed record IssuedLicense
    {
        public string Key { get; init; } = "";
        /// <summary>The product name.</summary>
        public string Product { get; init; } = "";
        public string Email { get; init; } = "";
        public int Activations { get; init; }
        public int MaxActivations { get; init; }
        public bool Disabled { get; init; }
        public DateTimeOffset IssuedAt { get; init; }
    }

    public sealed record Dispute
    {
        public string Id { get; init; } = "";
        public long PaymentId { get; init; }
        public string? Email { get; init; }
        public decimal Amount { get; init; }
        public string? Reason { get; init; }
        public string Status { get; init; } = "";
        public DateTimeOffset? RespondBy { get; init; }
        public DateTimeOffset OpenedAt { get; init; }
    }

    public sealed record Product
    {
        public long Id { get; init; }
        public string Name { get; init; } = "";
        public string Description { get; init; } = "";
        public decimal Price { get; init; }
        public string Currency { get; init; } = "";
        public bool DeliversFile { get; init; }
        public bool IssuesLicenseKey { get; init; }
        public string Page { get; init; } = "";
        public string? X402 { get; init; }
    }

    public sealed record Membership
    {
        public long Id { get; init; }
        public string Name { get; init; } = "";
        public string Description { get; init; } = "";
        public decimal Price { get; init; }
        public string Currency { get; init; } = "";
        public string Interval { get; init; } = "";
        public string? X402 { get; init; }
    }

    public sealed record CreatorLink
    {
        public string Label { get; init; } = "";
        public string Url { get; init; } = "";
    }

    public sealed record PaymentMethods
    {
        public bool Card { get; init; }
        public bool Crypto { get; init; }
        public bool X402 { get; init; }
    }

    public sealed record Tip
    {
        public decimal Suggested { get; init; }
        public string Currency { get; init; } = "";
        public string Page { get; init; } = "";
        public string? X402 { get; init; }
    }

    public sealed record Creator
    {
        public string Handle { get; init; } = "";
        public string Name { get; init; } = "";
        public string Bio { get; init; } = "";
        public string Url { get; init; } = "";
        public string? Avatar { get; init; }
        public IReadOnlyList<CreatorLink> Links { get; init; } = Array.Empty<CreatorLink>();
        public PaymentMethods PaymentMethods { get; init; } = new();
        public Tip Tip { get; init; } = new();
        public IReadOnlyList<Membership> Memberships { get; init; } = Array.Empty<Membership>();
        public IReadOnlyList<Product> Products { get; init; } = Array.Empty<Product>();
    }
}

#if NETSTANDARD2_0
namespace System.Runtime.CompilerServices
{
    internal static class IsExternalInit { }
}
#endif
