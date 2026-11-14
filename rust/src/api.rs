use crate::{Http, Result, DEFAULT_BASE_URL, DEFAULT_TIMEOUT};
use serde::{Deserialize, Serialize};
use std::time::Duration;

/// Creator REST API client (Bearer `sc_` key). Server side only: never ship the key in an app.
pub struct ApiClient {
    http: Http,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct CheckoutParams {
    /// "tip", "product" or "membership".
    #[serde(rename = "type")]
    pub type_: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub amount: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub product_id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tier_id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub email: Option<String>,
    /// "card" (default) or "crypto".
    #[serde(skip_serializing_if = "Option::is_none")]
    pub method: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Checkout {
    pub id: String,
    pub status: String,
    #[serde(rename = "type")]
    pub type_: String,
    pub amount: f64,
    pub currency: String,
    pub method: String,
    pub email: Option<String>,
    /// Only returned by `create_checkout`.
    pub url: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Totals {
    pub payments: u64,
    pub gross: f64,
    pub fees: f64,
    pub net: f64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct MemberTotals {
    pub active: u64,
    pub monthly_recurring: f64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Stats {
    pub handle: String,
    pub name: String,
    pub url: String,
    pub currency: String,
    pub last_30_days: Totals,
    pub all_time: Totals,
    pub members: MemberTotals,
    pub open_disputes: u64,
}

#[derive(Debug, Clone, Default)]
pub struct PaymentFilter {
    pub status: Option<String>,
    pub type_: Option<String>,
    pub email: Option<String>,
    /// 1..500, server default 50.
    pub limit: Option<u32>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Payment {
    pub id: i64,
    #[serde(rename = "type")]
    pub type_: String,
    pub method: String,
    pub status: String,
    pub amount: f64,
    pub fee: f64,
    pub currency: String,
    pub email: Option<String>,
    pub message: Option<String>,
    pub reference: Option<String>,
    pub test: bool,
    pub created_at: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PaymentDispute {
    pub id: String,
    pub status: String,
    pub reason: Option<String>,
    pub respond_by: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ActivityEvent {
    pub at: String,
    pub event: String,
    pub detail: Option<String>,
    pub ip: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PaymentDetail {
    #[serde(flatten)]
    pub payment: Payment,
    pub item: String,
    pub purchase_ip: Option<String>,
    pub purchase_device: Option<String>,
    pub dispute: Option<PaymentDispute>,
    pub activity: Vec<ActivityEvent>,
    pub evidence_pdf: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Member {
    pub email: String,
    pub tier: String,
    pub method: String,
    pub status: String,
    pub price: f64,
    pub interval: String,
    pub current_period_ends: String,
    pub joined_at: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct IssuedLicense {
    pub key: String,
    /// Product name.
    pub product: String,
    pub email: String,
    pub activations: u32,
    pub max_activations: u32,
    pub disabled: bool,
    pub issued_at: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Dispute {
    pub id: String,
    pub payment_id: i64,
    pub email: Option<String>,
    pub amount: f64,
    pub reason: Option<String>,
    pub status: String,
    pub respond_by: Option<String>,
    pub opened_at: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Product {
    pub id: i64,
    pub name: String,
    pub description: String,
    pub price: f64,
    pub currency: String,
    pub delivers_file: bool,
    pub issues_license_key: bool,
    pub page: String,
    pub x402: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Membership {
    pub id: i64,
    pub name: String,
    pub description: String,
    pub price: f64,
    pub currency: String,
    pub interval: String,
    pub x402: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Link {
    pub label: String,
    pub url: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PaymentMethods {
    pub card: bool,
    pub crypto: bool,
    pub x402: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Tip {
    pub suggested: f64,
    pub currency: String,
    pub page: String,
    pub x402: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Creator {
    pub handle: String,
    pub name: String,
    pub bio: String,
    pub url: String,
    pub avatar: Option<String>,
    pub links: Vec<Link>,
    pub payment_methods: PaymentMethods,
    pub tip: Tip,
    pub memberships: Vec<Membership>,
    pub products: Vec<Product>,
}

/// Percent-encodes a path segment.
fn enc(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

impl ApiClient {
    /// `api_key` may be empty when you only call `get_creator`.
    pub fn new(api_key: &str) -> Self {
        Self::with_options(api_key, DEFAULT_BASE_URL, DEFAULT_TIMEOUT)
    }

    pub fn with_options(api_key: &str, base_url: &str, timeout: Duration) -> Self {
        ApiClient {
            http: Http::new(api_key, base_url, timeout),
        }
    }

    fn get<T: serde::de::DeserializeOwned>(
        &self,
        path: &str,
        query: &[(&str, String)],
    ) -> Result<T> {
        self.http.request("GET", path, query, None)
    }

    pub fn create_checkout(&self, params: &CheckoutParams) -> Result<Checkout> {
        self.http.request(
            "POST",
            "/checkouts",
            &[],
            Some(serde_json::to_value(params).expect("params serialize")),
        )
    }

    pub fn get_checkout(&self, id: &str) -> Result<Checkout> {
        self.get(&format!("/checkouts/{}", enc(id)), &[])
    }

    pub fn me(&self) -> Result<Stats> {
        self.get("/me", &[])
    }

    pub fn list_payments(&self, filter: &PaymentFilter) -> Result<Vec<Payment>> {
        let q: Vec<(&str, String)> = [
            ("status", filter.status.clone()),
            ("type", filter.type_.clone()),
            ("email", filter.email.clone()),
            ("limit", filter.limit.map(|l| l.to_string())),
        ]
        .into_iter()
        .filter_map(|(k, v)| Some((k, v?)))
        .collect();
        self.get("/payments", &q)
    }

    pub fn get_payment(&self, id: i64) -> Result<PaymentDetail> {
        self.get(&format!("/payments/{id}"), &[])
    }

    pub fn list_members(&self) -> Result<Vec<Member>> {
        self.get("/members", &[])
    }

    pub fn list_licenses(&self, email: Option<&str>) -> Result<Vec<IssuedLicense>> {
        let q: Vec<(&str, String)> = email
            .map(|e| ("email", e.to_string()))
            .into_iter()
            .collect();
        self.get("/licenses", &q)
    }

    pub fn list_disputes(&self) -> Result<Vec<Dispute>> {
        self.get("/disputes", &[])
    }

    pub fn list_products(&self) -> Result<Vec<Product>> {
        self.get("/products", &[])
    }

    pub fn list_memberships(&self) -> Result<Vec<Membership>> {
        self.get("/memberships", &[])
    }

    /// Public; works without an API key.
    pub fn get_creator(&self, handle: &str) -> Result<Creator> {
        self.get(&format!("/creators/{}", enc(handle)), &[])
    }
}
