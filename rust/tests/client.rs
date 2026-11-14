use sendclap::*;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::time::Duration;

const LIC: &str = r#""license":{"key":"GOOD","activations":1,"max_activations":3},"product":{"id":1,"name":"Pro"}"#;
const PAYMENT: &str = r#""id":42,"type":"product","method":"card","status":"paid","amount":29,"fee":0.29,"currency":"usd","email":"b@x.com","message":null,"reference":"pi:1","test":false,"created_at":"2026-11-13T18:04:11.000Z""#;

struct Req {
    method: String,
    target: String,
    headers: Vec<(String, String)>,
    body: String,
}

impl Req {
    fn header(&self, name: &str) -> &str {
        self.headers
            .iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
            .unwrap_or("")
    }
}

/// Canned Sendclap answers; a failed expectation answers 418 so the client call fails the test.
fn route(r: &Req) -> (u16, String) {
    if r.header("user-agent") != "sendclap-rust/0.1.0" {
        return (418, "{}".into());
    }
    if let Some(action) = r.target.strip_prefix("/api/v1/licenses/") {
        if r.header("content-type") != "application/json" || !r.header("authorization").is_empty() {
            return (418, "{}".into());
        }
        let b: serde_json::Value = serde_json::from_str(&r.body).unwrap();
        let (key, inst) = (
            b["license_key"].as_str().unwrap_or(""),
            b["instance_id"].as_str().unwrap_or(""),
        );
        return match (action, key) {
            (_, "BAD") => (404, r#"{"valid":false,"error":"license key not found"}"#.into()),
            ("validate", _) => (200, format!(r#"{{"valid":{},{LIC}}}"#, inst.is_empty() || inst == "dev-1")),
            _ if inst.is_empty() => (400, r#"{"error":"instance_id is required"}"#.into()),
            ("activate", "FULL") => (409, r#"{"activated":false,"error":"activation limit reached","license":{"key":"FULL","activations":3,"max_activations":3},"product":{"id":1,"name":"Pro"}}"#.into()),
            ("activate", _) => (200, format!(r#"{{"activated":true,"instance_id":"{inst}",{LIC}}}"#)),
            _ => (200, r#"{"deactivated":true,"license":{"key":"GOOD","activations":0,"max_activations":3},"product":{"id":null}}"#.into()),
        };
    }
    if r.target == "/api/v1/creators/demo" {
        if !r.header("authorization").is_empty() {
            return (418, "{}".into());
        }
        return (200, r#"{"handle":"demo","name":"Ada","bio":"","url":"u","avatar":null,"links":[{"label":"GitHub","url":"g"}],"payment_methods":{"card":true,"crypto":true,"x402":false},"tip":{"suggested":5,"currency":"usd","page":"u","x402":null},"memberships":[{"id":1,"name":"Supporter","description":"","price":5,"currency":"usd","interval":"month","x402":null}],"products":[]}"#.into());
    }
    if !r.target.starts_with("/api/v1/") {
        return (404, "<h1>Not found</h1>".into());
    }
    if r.header("authorization") != "Bearer sc_test" {
        return (401, r#"{"error":"invalid API key"}"#.into());
    }
    match (r.method.as_str(), r.target.as_str()) {
        ("POST", "/api/v1/checkouts") if r.body == r#"{"email":"b@x.com","product_id":1,"type":"product"}"# => (201, r#"{"id":"0xabc","status":"pending","type":"product","amount":29,"currency":"usd","method":"card","email":"b@x.com","url":"https://sendclap.com/checkout/0xabc"}"#.into()),
        ("GET", "/api/v1/checkouts/0xabc") => (200, r#"{"id":"0xabc","status":"paid","type":"product","amount":29,"currency":"usd","method":"card","email":null}"#.into()),
        ("GET", "/api/v1/me") => (200, r#"{"handle":"demo","name":"Ada","url":"u","currency":"usd","last_30_days":{"payments":2,"gross":58,"fees":0.58,"net":57.42},"all_time":{"payments":2,"gross":58,"fees":0.58,"net":57.42},"members":{"active":1,"monthly_recurring":5},"open_disputes":0}"#.into()),
        ("GET", "/api/v1/payments?status=paid&limit=2") => (200, format!("[{{{PAYMENT}}}]")),
        ("GET", "/api/v1/payments/42") => (200, format!(r#"{{{PAYMENT},"item":"Pro","purchase_ip":null,"purchase_device":null,"dispute":{{"id":"dp_1","status":"open","reason":null,"respond_by":null}},"activity":[{{"at":"t","event":"license_activate","detail":"Pro","ip":null}}],"evidence_pdf":"p"}}"#)),
        ("GET", "/api/v1/payments/7") => (404, r#"{"error":"payment not found"}"#.into()),
        ("GET", "/api/v1/licenses?email=b%40x.com") => (200, r#"[{"key":"GOOD","product":"Pro","email":"b@x.com","activations":1,"max_activations":3,"disabled":true,"issued_at":"t"}]"#.into()),
        ("GET", "/api/v1/members" | "/api/v1/disputes" | "/api/v1/products" | "/api/v1/memberships") => (200, "[]".into()),
        _ => (418, "{}".into()),
    }
}

/// A one-thread HTTP/1.1 server on a random port; returns its base URL.
fn mock() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let mut stream = stream.unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let mut parts = line.split_whitespace();
            let (method, target) = (
                parts.next().unwrap_or("").to_string(),
                parts.next().unwrap_or("").to_string(),
            );
            let mut headers = vec![];
            loop {
                let mut h = String::new();
                reader.read_line(&mut h).unwrap();
                match h.trim_end().split_once(": ") {
                    Some((k, v)) => headers.push((k.to_lowercase(), v.to_string())),
                    None => break,
                }
            }
            let len: usize = headers
                .iter()
                .find(|(k, _)| k == "content-length")
                .map_or(0, |(_, v)| v.parse().unwrap());
            let mut body = vec![0; len];
            reader.read_exact(&mut body).unwrap();
            let req = Req {
                method,
                target,
                headers,
                body: String::from_utf8(body).unwrap(),
            };
            let (status, body) = route(&req);
            let ctype = if body.starts_with('<') {
                "text/html"
            } else {
                "application/json"
            };
            write!(stream, "HTTP/1.1 {status} X\r\nContent-Type: {ctype}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
        }
    });
    url
}

fn licenses(base: &str) -> LicenseClient {
    LicenseClient::with_options(base, Duration::from_secs(5))
}

#[test]
fn license_success() {
    let l = licenses(&(mock() + "/"));
    let a = l.activate("GOOD", "dev-1").unwrap();
    assert_eq!(a.instance_id, "dev-1");
    assert_eq!(a.license.max_activations, 3);
    assert_eq!(a.product.name.as_deref(), Some("Pro"));

    let d = l.deactivate("GOOD", "dev-1").unwrap();
    assert_eq!(d.license.activations, 0);
    assert_eq!(d.product.id, None);

    for (inst, want) in [
        (None, ValidationStatus::Active),
        (Some("dev-1"), ValidationStatus::Active),
        (Some("dev-2"), ValidationStatus::NotActivated),
    ] {
        let v = l.validate("GOOD", inst).unwrap();
        assert_eq!(v.status, want);
        assert_eq!(v.valid, want == ValidationStatus::Active);
        assert_eq!(v.license.unwrap().key, "GOOD");
    }
    let v = l.validate("BAD", Some("dev-1")).unwrap();
    assert_eq!(
        (v.valid, v.status, v.license),
        (false, ValidationStatus::Invalid, None)
    );
}

#[test]
fn license_errors() {
    let base = mock();
    let l = licenses(&base);
    match l.activate("BAD", "dev-1") {
        Err(e @ Error::InvalidLicense { .. }) => assert_eq!(
            (e.status(), e.to_string().contains("license key not found")),
            (404, true)
        ),
        r => panic!("{r:?}"),
    }
    match l.activate("FULL", "dev-9") {
        Err(Error::ActivationLimit { license, .. }) => assert_eq!(license.activations, 3),
        r => panic!("{r:?}"),
    }
    match l.activate("GOOD", "") {
        Err(Error::Api {
            status: 400,
            message,
        }) => assert_eq!(message, "instance_id is required"),
        r => panic!("{r:?}"),
    }
    // an HTML 404 from a wrong base URL must not lock the user out
    match licenses(&format!("{base}/nope")).validate("GOOD", Some("dev-1")) {
        Err(Error::Api {
            status: 404,
            message,
        }) => assert_eq!(message, "HTTP 404"),
        r => panic!("{r:?}"),
    }
    match licenses("http://127.0.0.1:1").validate("GOOD", None) {
        Err(e @ Error::Network(_)) => assert_eq!(e.status(), 0),
        r => panic!("{r:?}"),
    }
}

#[test]
fn api() {
    let base = mock();
    let a = ApiClient::with_options("sc_test", &base, Duration::from_secs(5));

    let c = a
        .create_checkout(&CheckoutParams {
            type_: "product".into(),
            product_id: Some(1),
            email: Some("b@x.com".into()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(
        (c.id.as_str(), c.amount, c.url.is_some()),
        ("0xabc", 29.0, true)
    );
    let c = a.get_checkout("0xabc").unwrap();
    assert_eq!((c.status.as_str(), c.email, c.url), ("paid", None, None));
    let s = a.me().unwrap();
    assert_eq!((s.last_30_days.net, s.members.active), (57.42, 1));
    let p = a
        .list_payments(&PaymentFilter {
            status: Some("paid".into()),
            limit: Some(2),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(p[0].fee, 0.29);
    let p = a.get_payment(42).unwrap();
    assert_eq!(
        (
            p.payment.id,
            p.dispute.unwrap().id.as_str(),
            p.activity[0].event.as_str()
        ),
        (42, "dp_1", "license_activate")
    );
    let l = a.list_licenses(Some("b@x.com")).unwrap();
    assert!(l[0].disabled);
    a.list_members().unwrap();
    a.list_disputes().unwrap();
    a.list_products().unwrap();
    a.list_memberships().unwrap();

    match a.get_payment(7) {
        Err(Error::Api {
            status: 404,
            message,
        }) => assert_eq!(message, "payment not found"),
        r => panic!("{r:?}"),
    }
    match ApiClient::with_options("sc_wrong", &base, Duration::from_secs(5)).me() {
        Err(Error::Api {
            status: 401,
            message,
        }) => assert_eq!(message, "invalid API key"),
        r => panic!("{r:?}"),
    }
    let cr = ApiClient::with_options("", &base, Duration::from_secs(5))
        .get_creator("demo")
        .unwrap();
    assert_eq!(
        (
            cr.handle.as_str(),
            cr.payment_methods.card,
            cr.memberships[0].interval.as_str()
        ),
        ("demo", true, "month")
    );
}

#[test]
fn instance_name_is_set() {
    assert!(instance_name().is_some_and(|n| !n.is_empty()));
}
