//! Official Rust client for [Sendclap](https://sendclap.com/docs): keyless license
//! activation/validation for apps you ship ([`LicenseClient`]) and the creator REST API for
//! your server ([`ApiClient`]).

use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::Value;
use std::time::Duration;

mod api;
pub use api::*;

pub const VERSION: &str = "0.4.0";
pub const DEFAULT_BASE_URL: &str = "https://sendclap.com";
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Debug, Clone)]
pub enum Error {
    /// `license_not_found` (404): the key is unknown.
    InvalidLicense { message: String },
    /// `license_disabled` (403): the key was disabled after a refund or dispute.
    LicenseDisabled { message: String },
    /// `license_expired` (403): the subscription key has expired; `license.expires_at` says when.
    LicenseExpired {
        message: String,
        license: LicenseInfo,
        product: ProductRef,
    },
    /// `instance_not_found` (404): deactivate for an instance that isn't activated.
    InstanceNotFound { message: String },
    /// `activation_limit` (409): every activation of the key is in use.
    ActivationLimit {
        message: String,
        license: LicenseInfo,
        product: ProductRef,
    },
    /// Any other non-2xx answer (400, 401, 404, 5xx, HTML error pages) or an unparsable body.
    /// `code` is the server's code such as `invalid_api_key` or `not_found`, empty when the
    /// reply wasn't a Sendclap error.
    Api {
        status: u16,
        code: String,
        message: String,
    },
    /// No HTTP response: DNS, connection refused, TLS, timeout.
    Network(String),
}

impl Error {
    /// HTTP status, 0 for network errors.
    pub fn status(&self) -> u16 {
        match self {
            Error::InvalidLicense { .. } | Error::InstanceNotFound { .. } => 404,
            Error::LicenseDisabled { .. } | Error::LicenseExpired { .. } => 403,
            Error::ActivationLimit { .. } => 409,
            Error::Api { status, .. } => *status,
            Error::Network(_) => 0,
        }
    }

    /// The server's machine-readable code; `"network_error"` with no reply, empty for non-Sendclap replies.
    pub fn code(&self) -> &str {
        match self {
            Error::InvalidLicense { .. } => "license_not_found",
            Error::LicenseDisabled { .. } => "license_disabled",
            Error::LicenseExpired { .. } => "license_expired",
            Error::InstanceNotFound { .. } => "instance_not_found",
            Error::ActivationLimit { .. } => "activation_limit",
            Error::Api { code, .. } => code,
            Error::Network(_) => "network_error",
        }
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Network(m) => write!(f, "sendclap: network error: {m}"),
            Error::InvalidLicense { message }
            | Error::LicenseDisabled { message }
            | Error::LicenseExpired { message, .. }
            | Error::InstanceNotFound { message }
            | Error::ActivationLimit { message, .. }
            | Error::Api { message, .. } => {
                write!(f, "sendclap: {message} (HTTP {})", self.status())
            }
        }
    }
}

impl std::error::Error for Error {}

pub type Result<T> = std::result::Result<T, Error>;

pub(crate) struct Http {
    agent: ureq::Agent,
    base: String,
    api_key: String,
}

impl Http {
    fn new(api_key: &str, base_url: &str, timeout: Duration) -> Self {
        let agent = ureq::Agent::config_builder()
            .timeout_global(Some(timeout))
            .http_status_as_error(false)
            .build()
            .into();
        Http {
            agent,
            base: base_url.trim_end_matches('/').to_string(),
            api_key: api_key.to_string(),
        }
    }

    pub(crate) fn request<T: DeserializeOwned>(
        &self,
        method: &str,
        path: &str,
        query: &[(&str, String)],
        body: Option<Value>,
    ) -> Result<T> {
        let url = format!("{}/api/v1{}", self.base, path);
        let auth = format!("Bearer {}", self.api_key);
        let ua = format!("sendclap-rust/{VERSION}");
        let net = |e: ureq::Error| Error::Network(e.to_string());
        let mut res = if method == "POST" {
            let mut req = self
                .agent
                .post(&url)
                .header("Accept", "application/json")
                .header("User-Agent", &ua);
            if !self.api_key.is_empty() {
                req = req.header("Authorization", &auth);
            }
            req.header("Content-Type", "application/json")
                .send(body.unwrap_or(Value::Null).to_string())
                .map_err(net)?
        } else {
            let mut req = self
                .agent
                .get(&url)
                .header("Accept", "application/json")
                .header("User-Agent", &ua);
            if !self.api_key.is_empty() {
                req = req.header("Authorization", &auth);
            }
            for (k, v) in query {
                req = req.query(*k, v);
            }
            req.call().map_err(net)?
        };
        let status = res.status().as_u16();
        let text = res.body_mut().read_to_string().map_err(net)?;
        if (200..300).contains(&status) {
            return serde_json::from_str(&text).map_err(|_| Error::Api {
                status,
                code: String::new(),
                message: "invalid JSON response".into(),
            });
        }
        // HTML error pages (wrong base URL, crashes) stay plain Api errors
        let v: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
        let message = v["error"]
            .as_str()
            .map(String::from)
            .unwrap_or_else(|| format!("HTTP {status}"));
        let code = v["code"].as_str().unwrap_or_default().to_string();
        Err(match code.as_str() {
            "license_not_found" => Error::InvalidLicense { message },
            "license_disabled" => Error::LicenseDisabled { message },
            "license_expired" => Error::LicenseExpired {
                message,
                license: serde_json::from_value(v["license"].clone()).unwrap_or_default(),
                product: serde_json::from_value(v["product"].clone()).unwrap_or_default(),
            },
            "instance_not_found" => Error::InstanceNotFound { message },
            "activation_limit" => Error::ActivationLimit {
                message,
                license: serde_json::from_value(v["license"].clone()).unwrap_or_default(),
                product: serde_json::from_value(v["product"].clone()).unwrap_or_default(),
            },
            _ => Error::Api {
                status,
                code,
                message,
            },
        })
    }
}

/// Activation state of a license key.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct LicenseInfo {
    pub key: String,
    pub activations: u32,
    pub max_activations: u32,
    /// ISO 8601 time a subscription key expires, `None` for a key bought outright.
    #[serde(default)]
    pub expires_at: Option<String>,
}

/// The product a key belongs to; fields are `None` if the product was deleted.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ProductRef {
    pub id: Option<i64>,
    pub name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ActivateResult {
    /// The instance name you passed to `activate`; Sendclap uses it as the instance id.
    pub instance_id: String,
    pub license: LicenseInfo,
    pub product: ProductRef,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DeactivateResult {
    pub license: LicenseInfo,
    pub product: ProductRef,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ValidationStatus {
    /// The key is valid (and, if you passed an instance, that instance is activated).
    Active,
    /// The key exists but this instance is not activated.
    NotActivated,
    /// A subscription key past its `expires_at`.
    Expired,
    /// The key was disabled after a refund or dispute.
    Disabled,
    /// The key is unknown.
    NotFound,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ValidateResult {
    pub valid: bool,
    pub status: ValidationStatus,
    /// `None` when status is `NotFound` or `Disabled`; present for `Expired`.
    pub license: Option<LicenseInfo>,
    pub product: Option<ProductRef>,
}

/// Keyless license client; safe to ship inside apps.
pub struct LicenseClient {
    http: Http,
}

impl Default for LicenseClient {
    fn default() -> Self {
        Self::new()
    }
}

impl LicenseClient {
    pub fn new() -> Self {
        Self::with_options(DEFAULT_BASE_URL, DEFAULT_TIMEOUT)
    }

    pub fn with_options(base_url: &str, timeout: Duration) -> Self {
        LicenseClient {
            http: Http::new("", base_url, timeout),
        }
    }

    fn call<T: DeserializeOwned>(
        &self,
        action: &str,
        key: &str,
        instance: Option<&str>,
    ) -> Result<T> {
        let mut body = serde_json::json!({ "license_key": key });
        if let Some(i) = instance.filter(|i| !i.is_empty()) {
            body["instance_id"] = i.into();
        }
        self.http
            .request("POST", &format!("/licenses/{action}"), &[], Some(body))
    }

    /// Registers this instance against the key. Re-activating the same instance counts once.
    pub fn activate(&self, license_key: &str, instance_name: &str) -> Result<ActivateResult> {
        self.call("activate", license_key, Some(instance_name))
    }

    /// Checks a key, and with an instance id that the instance is activated. An unknown, disabled or expired
    /// key is `Ok` with status `NotFound`, `Disabled` or `Expired`; `Err` means the answer is unknown (e.g. offline).
    pub fn validate(&self, license_key: &str, instance_id: Option<&str>) -> Result<ValidateResult> {
        self.call("validate", license_key, instance_id)
    }

    /// Releases an instance, freeing one activation. `Error::InstanceNotFound` if it wasn't activated.
    pub fn deactivate(&self, license_key: &str, instance_id: &str) -> Result<DeactivateResult> {
        self.call("deactivate", license_key, Some(instance_id))
    }
}

/// The machine hostname, a simple per-machine instance name for `activate`.
///
/// It is sent to Sendclap and shown to the creator, and two machines with the same hostname share
/// one activation; pass your own stable id (e.g. a random UUID saved on first run) if that matters.
pub fn instance_name() -> Option<String> {
    ["COMPUTERNAME", "HOSTNAME"]
        .iter()
        .find_map(|k| std::env::var(k).ok().filter(|v| !v.is_empty()))
        .or_else(|| {
            let out = std::process::Command::new("hostname").output().ok()?;
            Some(String::from_utf8(out.stdout).ok()?.trim().to_string()).filter(|s| !s.is_empty())
        })
}
