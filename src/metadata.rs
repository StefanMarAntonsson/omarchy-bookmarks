use std::{
    error::Error,
    fmt,
    io::Read,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, ToSocketAddrs},
    sync::{Arc, mpsc},
    thread,
    time::Duration,
};

use regex::Regex;
use reqwest::{
    blocking::Client,
    dns::{Addrs, Name, Resolve, Resolving},
    header::CONTENT_TYPE,
    redirect::{Attempt, Policy},
};
use serde::Serialize;
use url::{Host, Url};

const MAX_BODY: usize = 1_000_000;
const MAX_REDIRECTS: usize = 4;
const MAX_FIELD_CHARS: usize = 2048;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Metadata {
    pub title: String,
    pub description: String,
    pub final_url: String,
}

/// Destination rules for a fetch. Production fetches only reach public
/// addresses on default ports; tests relax this to use loopback servers.
#[derive(Clone, Copy)]
struct FetchPolicy {
    connect_timeout: Duration,
    overall_timeout: Duration,
    public_only: bool,
}

/// Raised when a destination is refused, so the reason survives reqwest's
/// error wrapping and can be reported without echoing remote content.
#[derive(Debug)]
struct Blocked(&'static str);
impl fmt::Display for Blocked {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.0)
    }
}
impl Error for Blocked {}

pub fn fetch(url: &str) -> Result<Metadata, String> {
    fetch_with(
        url,
        FetchPolicy {
            connect_timeout: Duration::from_secs(3),
            overall_timeout: Duration::from_secs(8),
            public_only: true,
        },
    )
}

fn fetch_with(url: &str, policy: FetchPolicy) -> Result<Metadata, String> {
    let parsed = Url::parse(url).map_err(|_| "Invalid URL")?;
    check_destination(&parsed, policy.public_only).map_err(|b| b.0.to_string())?;
    let mut builder = Client::builder()
        .connect_timeout(policy.connect_timeout)
        .timeout(policy.overall_timeout)
        .redirect(redirect_policy(policy.public_only))
        .referer(false)
        .no_proxy()
        .user_agent("OmarchyBookmarks/2.0");
    if policy.public_only {
        builder = builder.dns_resolver(Arc::new(PublicResolver {
            timeout: policy.connect_timeout,
        }));
    }
    let client = builder
        .build()
        .map_err(|_| "Could not create HTTP client")?;
    let mut response = client.get(parsed).send().map_err(describe_error)?;
    if !response.status().is_success() {
        return Err(format!(
            "Page lookup returned HTTP {}",
            response.status().as_u16()
        ));
    }
    if let Some(length) = response.content_length()
        && length > MAX_BODY as u64
    {
        return Err("Page is too large to read".into());
    }
    let content_type = response
        .headers()
        .get(CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_ascii_lowercase();
    if !content_type.contains("text/html") && !content_type.contains("application/xhtml+xml") {
        return Err("Page is not HTML".into());
    }
    let mut bytes = Vec::new();
    response
        .by_ref()
        .take((MAX_BODY + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| "Could not read page")?;
    if bytes.len() > MAX_BODY {
        return Err("Page is too large to read".into());
    }
    let html = String::from_utf8_lossy(&bytes);
    let title = meta(&html, "property", "og:title")
        .or_else(|| title_tag(&html))
        .unwrap_or_default();
    let description = meta(&html, "property", "og:description")
        .or_else(|| meta(&html, "name", "description"))
        .unwrap_or_default();
    Ok(Metadata {
        title: decode(&title),
        description: decode(&description),
        final_url: response.url().to_string(),
    })
}

fn describe_error(error: reqwest::Error) -> String {
    let mut source: Option<&(dyn Error + 'static)> = Some(&error);
    while let Some(current) = source {
        if let Some(blocked) = current.downcast_ref::<Blocked>() {
            return blocked.0.to_string();
        }
        source = current.source();
    }
    if error.is_timeout() {
        "Page lookup timed out".into()
    } else if error.is_redirect() {
        "Page lookup stopped after too many redirects".into()
    } else if error.is_connect() {
        "Could not connect to the website".into()
    } else {
        "Page lookup failed".into()
    }
}

fn check_destination(url: &Url, public_only: bool) -> Result<(), Blocked> {
    if !matches!(url.scheme(), "http" | "https") {
        return Err(Blocked("Only HTTP and HTTPS pages can be looked up"));
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Err(Blocked("URLs containing credentials are not supported"));
    }
    if !public_only {
        return Ok(());
    }
    // `Url::port` is None for the scheme's default port.
    if url.port().is_some() {
        return Err(Blocked("Page lookup only uses default web ports"));
    }
    match url.host() {
        Some(Host::Ipv4(ip)) if is_public_ip(IpAddr::V4(ip)) => Ok(()),
        Some(Host::Ipv6(ip)) if is_public_ip(IpAddr::V6(ip)) => Ok(()),
        Some(Host::Domain(_)) => Ok(()),
        _ => Err(Blocked("Page lookup only contacts public addresses")),
    }
}

fn redirect_policy(public_only: bool) -> Policy {
    Policy::custom(move |attempt: Attempt| {
        if attempt.previous().len() > MAX_REDIRECTS {
            return attempt.error(Blocked("Page lookup stopped after too many redirects"));
        }
        let downgrade = attempt
            .previous()
            .last()
            .is_some_and(|previous| previous.scheme() == "https")
            && attempt.url().scheme() != "https";
        if downgrade {
            return attempt.error(Blocked("Page lookup refused an HTTPS to HTTP redirect"));
        }
        match check_destination(attempt.url(), public_only) {
            Ok(()) => attempt.follow(),
            Err(blocked) => attempt.error(blocked),
        }
    })
}

/// Resolves names itself so every address is checked before reqwest connects
/// to it. The connection uses exactly these addresses, so DNS rebinding
/// between the check and the connect is not possible.
struct PublicResolver {
    timeout: Duration,
}

impl Resolve for PublicResolver {
    fn resolve(&self, name: Name) -> Resolving {
        let host = name.as_str().to_owned();
        let timeout = self.timeout;
        Box::pin(async move {
            let (tx, rx) = mpsc::channel();
            thread::spawn(move || {
                let _ = tx.send((host.as_str(), 0).to_socket_addrs().map(Vec::from_iter));
            });
            let addresses: Vec<SocketAddr> = match rx.recv_timeout(timeout) {
                Ok(Ok(addresses)) => addresses,
                Ok(Err(_)) => return Err("Could not resolve the website".into()),
                Err(_) => return Err("Resolving the website timed out".into()),
            };
            if addresses.is_empty() || addresses.iter().any(|a| !is_public_ip(a.ip())) {
                return Err(
                    Box::new(Blocked("Page lookup only contacts public addresses"))
                        as Box<dyn Error + Send + Sync>,
                );
            }
            Ok(Box::new(addresses.into_iter()) as Addrs)
        })
    }
}

pub fn is_public_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => is_public_v4(v4),
        IpAddr::V6(v6) => is_public_v6(v6),
    }
}

fn is_public_v4(ip: Ipv4Addr) -> bool {
    let [a, b, c, _] = ip.octets();
    !(a == 0
        || a == 10
        || a == 127
        || (a == 100 && (64..=127).contains(&b))
        || (a == 169 && b == 254)
        || (a == 172 && (16..=31).contains(&b))
        || (a == 192 && b == 0 && c == 0)
        || (a == 192 && b == 0 && c == 2)
        || (a == 192 && b == 88 && c == 99)
        || (a == 192 && b == 168)
        || (a == 198 && (18..=19).contains(&b))
        || (a == 198 && b == 51 && c == 100)
        || (a == 203 && b == 0 && c == 113)
        || a >= 224)
}

fn is_public_v6(ip: Ipv6Addr) -> bool {
    if let Some(v4) = ip.to_ipv4_mapped() {
        return is_public_v4(v4);
    }
    let s = ip.segments();
    // Only global unicast (2000::/3), minus ranges that embed or tunnel to
    // other addresses or are reserved for documentation.
    (s[0] & 0xe000) == 0x2000
        && !(s[0] == 0x2001 && s[1] < 0x0200) // Teredo, benchmarking, ORCHID and IETF protocol ranges
        && !(s[0] == 0x2001 && s[1] == 0x0db8) // documentation
        && s[0] != 0x2002 // 6to4
        && s[0] != 0x3fff // documentation
}

fn meta(html: &str, kind: &str, key: &str) -> Option<String> {
    let tag = Regex::new(r"(?is)<meta\s+[^>]*>").unwrap();
    let attr = Regex::new(r#"(?is)([a-z_:.-]+)\s*=\s*(?:\"([^\"]*)\"|'([^']*)')"#).unwrap();
    for found in tag.find_iter(html) {
        let mut wanted = false;
        let mut content = None;
        for cap in attr.captures_iter(found.as_str()) {
            let name = cap[1].to_ascii_lowercase();
            let value = cap
                .get(2)
                .or_else(|| cap.get(3))
                .map(|v| v.as_str())
                .unwrap_or("")
                .trim();
            if name == kind && value.eq_ignore_ascii_case(key) {
                wanted = true
            }
            if name == "content" {
                content = Some(value.to_string())
            }
        }
        if wanted && content.is_some() {
            return content;
        }
    }
    None
}
fn title_tag(html: &str) -> Option<String> {
    Regex::new(r"(?is)<title[^>]*>(.*?)</title>")
        .unwrap()
        .captures(html)
        .map(|c| c[1].trim().to_string())
}
fn decode(value: &str) -> String {
    let decoded = value
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&amp;", "&");
    decoded
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .take(MAX_FIELD_CHARS)
        .collect::<String>()
        .trim()
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::{Read, Write},
        net::TcpListener,
    };

    fn loopback() -> FetchPolicy {
        FetchPolicy {
            connect_timeout: Duration::from_secs(3),
            overall_timeout: Duration::from_secs(8),
            public_only: false,
        }
    }
    fn fetch_local(url: &str) -> Result<Metadata, String> {
        fetch_with(url, loopback())
    }
    fn server(response: &'static [u8]) -> String {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        thread::spawn(move || {
            let (mut s, _) = l.accept().unwrap();
            let mut b = [0; 1024];
            let _ = s.read(&mut b);
            s.write_all(response).unwrap();
        });
        format!("http://{addr}/")
    }
    #[test]
    fn extracts_og_and_description() {
        let u=server(b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n<title>Fallback</title><meta property='og:title' content='Hello &amp; world'><meta name='description' content='Desc'>");
        let m = fetch_local(&u).unwrap();
        assert_eq!(m.title, "Hello & world");
        assert_eq!(m.description, "Desc");
    }
    #[test]
    fn rejects_oversized() {
        let body = "x".repeat(MAX_BODY + 1);
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\n\r\n{}",
            body.len(),
            body
        );
        let leaked = Box::leak(response.into_bytes().into_boxed_slice());
        let u = server(leaked);
        assert!(fetch_local(&u).unwrap_err().contains("too large"));
    }
    #[test]
    fn follows_redirect() {
        let final_listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let final_addr = final_listener.local_addr().unwrap();
        thread::spawn(move || {
            let (mut s, _) = final_listener.accept().unwrap();
            let mut b = [0; 512];
            let _ = s.read(&mut b);
            s.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n<title>Final</title>").unwrap();
        });
        let redirect = format!(
            "HTTP/1.1 302 Found\r\nLocation: http://{final_addr}/done\r\nContent-Length: 0\r\n\r\n"
        );
        let u = server(Box::leak(redirect.into_bytes().into_boxed_slice()));
        assert_eq!(fetch_local(&u).unwrap().title, "Final");
    }
    #[test]
    fn invalid_or_missing_content_type_fails() {
        let u =
            server(b"HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 3\r\n\r\nPNG");
        assert!(fetch_local(&u).is_err());
        let u = server(b"HTTP/1.1 200 OK\r\nContent-Length: 15\r\n\r\n<title>x</title>");
        assert!(fetch_local(&u).is_err());
    }

    #[test]
    fn decoded_fields_are_single_line_and_bounded() {
        assert_eq!(decode("  a\r\nb&lt;i&gt;  "), "a  b<i>");
        assert_eq!(decode("&amp;lt;"), "&lt;");
        assert_eq!(decode(&"x".repeat(5000)).chars().count(), MAX_FIELD_CHARS);
    }

    #[test]
    fn timeout_and_connection_failure_are_recoverable_errors() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        thread::spawn(move || {
            let (_stream, _) = listener.accept().unwrap();
            thread::sleep(Duration::from_millis(300));
        });
        let quick = FetchPolicy {
            connect_timeout: Duration::from_millis(50),
            overall_timeout: Duration::from_millis(75),
            public_only: false,
        };
        assert!(fetch_with(&format!("http://{address}/"), quick).is_err());

        let closed = TcpListener::bind("127.0.0.1:0").unwrap();
        let closed_address = closed.local_addr().unwrap();
        drop(closed);
        assert!(fetch_with(&format!("http://{closed_address}/"), quick).is_err());
    }

    #[test]
    fn production_policy_refuses_private_destinations_without_connecting() {
        for url in [
            "http://127.0.0.1/",
            "http://10.0.0.1/",
            "http://192.168.1.1/",
            "http://169.254.169.254/latest/meta-data/",
            "http://[::1]/",
            "http://[fe80::1]/",
            "http://[fd00::1]/",
            "http://[::ffff:127.0.0.1]/",
            "http://0.0.0.0/",
            "http://localhost/",
            "https://example.com:8443/",
            "ftp://example.com/",
        ] {
            let error = fetch(url).unwrap_err();
            assert!(
                error.contains("public") || error.contains("port") || error.contains("HTTP"),
                "{url}: {error}"
            );
        }
    }

    #[test]
    fn production_policy_refuses_redirects_to_private_addresses() {
        let redirect =
            b"HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1/\r\nContent-Length: 0\r\n\r\n";
        let origin = server(redirect);
        let policy = redirect_policy(true);
        // Exercise the policy through a relaxed client that still applies the
        // production redirect rules.
        let client = Client::builder()
            .redirect(policy)
            .no_proxy()
            .build()
            .unwrap();
        let error = client.get(origin).send().unwrap_err();
        assert_eq!(
            describe_error(error),
            "Page lookup only contacts public addresses"
        );
    }

    #[test]
    fn classifies_public_addresses() {
        for ip in ["1.1.1.1", "8.8.8.8", "2606:4700:4700::1111"] {
            assert!(is_public_ip(ip.parse().unwrap()), "{ip}");
        }
        for ip in [
            "0.1.2.3",
            "10.1.1.1",
            "100.64.0.1",
            "127.0.0.1",
            "169.254.1.1",
            "172.16.0.1",
            "192.0.0.1",
            "192.0.2.1",
            "192.168.0.1",
            "198.18.0.1",
            "224.0.0.1",
            "255.255.255.255",
            "::",
            "::1",
            "::127.0.0.1",
            "::ffff:10.0.0.1",
            "64:ff9b::a00:1",
            "fc00::1",
            "fe80::1",
            "ff02::1",
            "2001::1",
            "2001:db8::1",
            "2002:a00:1::1",
        ] {
            assert!(!is_public_ip(ip.parse().unwrap()), "{ip}");
        }
    }
}
